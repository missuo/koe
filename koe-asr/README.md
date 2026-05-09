# koe-asr

A Rust library for streaming ASR (Automatic Speech Recognition) with a unified async interface across multiple cloud and local provider backends.

## Features

- **Unified `AsrProvider` trait** — swap providers without changing application logic
- **Streaming recognition** — receive interim, definite, and final results as audio is processed
- **Cloud providers** — Volcengine Doubao, Doubao IME (free), Alibaba Qwen
- **Local providers** — Apple Speech Framework, MLX Whisper (Apple Silicon), Sherpa-ONNX
- **TranscriptAggregator** — built-in helper to merge streaming events into a single transcript
- **Hotword support** — boost recognition accuracy for domain-specific vocabulary
- **Async/await** — built on `tokio` with `async-trait`

## Providers

| Provider | Backend | Feature Flag | Connection | Credentials |
|---|---|---|---|---|
| `DoubaoWsProvider` | Volcengine Seed-ASR | *(default)* | WebSocket | App Key + Access Key |
| `DoubaoImeProvider` | Doubao IME | *(default)* | WebSocket | None (auto device registration) |
| `QwenAsrProvider` | Alibaba DashScope Qwen-ASR | *(default)* | WebSocket | API Key |
| `AppleSpeechProvider` | macOS Speech Framework | `apple-speech` | Local | None |
| `MlxProvider` | MLX Whisper (Apple Silicon) | `mlx` | Local | None (local model) |
| `SherpaOnnxProvider` | Sherpa-ONNX | `sherpa-onnx` | Local | None (local model) |

## Installation

Add `koe-asr` to your `Cargo.toml`:

```toml
[dependencies]
koe-asr = { git = "https://github.com/missuo/koe.git" }
```

To enable optional local providers:

```toml
[dependencies]
koe-asr = { git = "https://github.com/missuo/koe.git", features = ["sherpa-onnx"] }
```

## Quick Start

### Doubao (Volcengine Cloud ASR)

```rust
use koe_asr::{AsrConfig, AsrEvent, AsrProvider, DoubaoWsProvider, TranscriptAggregator};

#[tokio::main]
async fn main() -> Result<(), koe_asr::AsrError> {
    let config = AsrConfig {
        app_key: "your-app-key".into(),
        access_key: "your-access-key".into(),
        // Defaults: 16kHz sample rate, DDC/ITN/punctuation/two-pass enabled
        ..Default::default()
    };

    let mut asr = DoubaoWsProvider::new();
    asr.connect(&config).await?;

    // Feed PCM 16-bit LE mono audio in chunks
    // asr.send_audio(&pcm_chunk).await?;

    // Signal end of audio input
    asr.finish_input().await?;

    // Collect results
    let mut aggregator = TranscriptAggregator::new();
    loop {
        match asr.next_event().await? {
            AsrEvent::Interim(text) => aggregator.update_interim(&text),
            AsrEvent::Definite(text) => aggregator.update_definite(&text),
            AsrEvent::Final(text) => {
                aggregator.update_final(&text);
                break;
            }
            AsrEvent::Closed(_) => break,
            _ => {}
        }
    }

    println!("Result: {}", aggregator.best_text());
    asr.close().await?;
    Ok(())
}
```

### Qwen (Alibaba Cloud ASR)

```rust
use koe_asr::{AsrConfig, AsrEvent, AsrProvider, QwenAsrProvider, TranscriptAggregator};

#[tokio::main]
async fn main() -> Result<(), koe_asr::AsrError> {
    let config = AsrConfig {
        access_key: "your-dashscope-api-key".into(),
        language: Some("zh".into()),
        ..Default::default()
    };

    let mut asr = QwenAsrProvider::new();
    asr.connect(&config).await?;

    // Same streaming loop as Doubao...
    // asr.send_audio(&pcm_chunk).await?;
    // asr.finish_input().await?;
    // loop { match asr.next_event().await? { ... } }

    asr.close().await?;
    Ok(())
}
```

### Doubao IME (Free, No API Key Required)

```rust
use koe_asr::{AsrConfig, AsrEvent, AsrProvider, DoubaoImeProvider, TranscriptAggregator};

#[tokio::main]
async fn main() -> Result<(), koe_asr::AsrError> {
    // DoubaoImeProvider handles device registration automatically.
    // No API key needed — credentials are stored locally after first use.
    let config = AsrConfig::default();

    let mut asr = DoubaoImeProvider::new();
    asr.connect(&config).await?;

    // Same streaming loop...
    asr.close().await?;
    Ok(())
}
```

### Sherpa-ONNX (Local, Offline)

```rust
use koe_asr::{AsrConfig, AsrEvent, AsrProvider, SherpaOnnxConfig, SherpaOnnxProvider, TranscriptAggregator};
use std::path::PathBuf;

#[tokio::main]
async fn main() -> Result<(), koe_asr::AsrError> {
    let sherpa_config = SherpaOnnxConfig {
        model_dir: PathBuf::from("/path/to/sherpa-onnx-model/"),
        num_threads: 4,
        hotwords: vec!["custom term".into()],
        hotwords_score: 1.5,
        endpoint_silence: 0.8,
    };

    let mut asr = SherpaOnnxProvider::new(sherpa_config);
    // Local providers ignore AsrConfig, but the trait requires it
    asr.connect(&AsrConfig::default()).await?;

    // Same streaming loop...
    asr.close().await?;
    Ok(())
}
```

## Provider Trait

All providers implement the `AsrProvider` trait, making them interchangeable:

```rust
#[async_trait]
pub trait AsrProvider: Send {
    /// Connect to the ASR service (or initialize local model)
    async fn connect(&mut self, config: &AsrConfig) -> Result<()>;
    /// Push a chunk of raw audio (PCM 16-bit LE, mono, 16kHz)
    async fn send_audio(&mut self, frame: &[u8]) -> Result<()>;
    /// Signal that no more audio will be sent
    async fn finish_input(&mut self) -> Result<()>;
    /// Wait for the next recognition event
    async fn next_event(&mut self) -> Result<AsrEvent>;
    /// Close the connection and release resources
    async fn close(&mut self) -> Result<()>;
}
```

You can write provider-agnostic code:

```rust
async fn transcribe(asr: &mut dyn AsrProvider, audio: &[u8]) -> Result<String, koe_asr::AsrError> {
    asr.connect(&AsrConfig::default()).await?;
    asr.send_audio(audio).await?;
    asr.finish_input().await?;

    let mut aggregator = TranscriptAggregator::new();
    loop {
        match asr.next_event().await? {
            AsrEvent::Interim(t) => aggregator.update_interim(&t),
            AsrEvent::Definite(t) => aggregator.update_definite(&t),
            AsrEvent::Final(t) => { aggregator.update_final(&t); break; }
            AsrEvent::Closed(_) => break,
            _ => {}
        }
    }
    asr.close().await?;
    Ok(aggregator.best_text().to_string())
}
```

## Events

The `AsrEvent` enum represents all possible events during streaming recognition:

| Event | Description |
|---|---|
| `Connected` | Connection established or local model loaded |
| `Interim(String)` | Partial result — may change as more audio arrives |
| `Definite(String)` | Confirmed sentence from two-pass recognition (higher accuracy) |
| `Final(String)` | Final result for the session |
| `Error(String)` | Server-side or provider error |
| `Closed` | Connection closed or session ended |

## Configuration

`AsrConfig` controls the behavior of cloud providers:

```rust
let config = AsrConfig {
    url: "wss://...".into(),              // WebSocket endpoint (provider-specific default)
    app_key: "...".into(),                // App ID (Doubao) or unused (Qwen)
    access_key: "...".into(),             // Access Token (Doubao) or API Key (Qwen)
    resource_id: "...".into(),            // Resource ID (Doubao-specific)
    sample_rate_hz: 16000,                // Audio sample rate in Hz
    connect_timeout_ms: 3000,             // Connection timeout
    final_wait_timeout_ms: 5000,          // Timeout for final result after finish
    enable_ddc: true,                     // Disfluency removal / smoothing
    enable_itn: true,                     // Inverse text normalization (e.g. "三百" → "300")
    enable_punc: true,                    // Automatic punctuation
    enable_nonstream: true,               // Two-pass recognition for higher accuracy
    hotwords: vec!["Koe".into()],         // Boost specific terms
    language: Some("zh".into()),          // Language code ("zh", "en", etc.)
    custom_headers: HashMap::new(),       // Custom HTTP headers
};
```

Local providers (`MlxProvider`, `AppleSpeechProvider`, `SherpaOnnxProvider`) use their own config structs passed to `new()` and ignore `AsrConfig`.

## TranscriptAggregator

A helper that merges the stream of interim/definite/final events into a single transcript:

```rust
let mut agg = TranscriptAggregator::new();

// As events arrive:
agg.update_interim("hel");
agg.update_interim("hello wo");
agg.update_definite("hello world");     // two-pass confirmed
agg.update_final("hello world.");       // session complete

// Get the best available text (priority: final > definite > interim)
println!("{}", agg.best_text()); // "hello world."

// Check state
agg.has_final_result();  // true
agg.has_any_text();      // true

// Access interim revision history (useful for debugging)
let history = agg.interim_history(10); // last 10 interim snapshots
```

## Error Handling

All providers return `Result<T, AsrError>`:

```rust
pub enum AsrError {
    Connection(String),  // WebSocket/network or model loading failure
    Timeout,             // Timed out waiting for ASR result
    Protocol(String),    // Binary protocol or server-side error
}
```

## License

MIT
