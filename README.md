# Koe (声)

A background-first macOS voice input tool. Press a hotkey, speak, and the corrected text is pasted into whatever app you're using.

For more information, visit the documentation at **[koe.li](https://koe.li)**.

## The Name

**Koe** (声, pronounced "ko-eh") is the Japanese word for *voice*. Written as こえ in hiragana, it's one of the most fundamental words in the language — simple, clear, and direct. That's exactly the philosophy behind this tool: your voice goes in, clean text comes out, with nothing in between. No flashy UI, no unnecessary steps. Just 声 — voice, in its purest form.

## Why Koe?

I tried nearly every voice input app on the market. They were either paid, ugly, or inconvenient — bloated UIs, clunky dictionary management, and too many clicks to do simple things.

Koe takes a different approach:

- **Minimal runtime UI.** Koe stays out of the way with a menu bar item, a small floating status pill with native frosted-glass vibrancy during active sessions, and an optional built-in settings window when you actually need to configure it.
- **All configuration lives in plain text files** under `~/.koe/`. You can edit them with any text editor, vim, a script, or the built-in settings UI.
- **Dictionary is a plain `.txt` file.** No need to open an app and add words one by one through a GUI. Just edit `~/.koe/dictionary.txt` — one term per line. You can even use Claude Code or other AI tools to bulk-generate domain-specific terms.
- **Changes take effect immediately.** Edit any config file and the new settings are used automatically. ASR, LLM, dictionary, and prompt changes apply on the next hotkey press. Hotkey changes are detected within a few seconds. No restart, no reload button.
- **Tiny footprint.** Even after installation, Koe stays **under 15 MB**, and its memory usage is typically **around 20 MB**. It launches fast, wastes almost no disk space, and stays out of your way.
- **Built with native macOS technologies.** Objective-C handles hotkeys, audio capture, clipboard access, permissions, and paste automation directly through Apple's own APIs.
- **Rust does the heavy lifting.** The performance-critical core runs in Rust, which gives Koe low overhead, fast execution, and strong memory safety guarantees.
- **No Chromium tax.** Many comparable Electron-based apps ship at **200+ MB** and carry the overhead of an embedded Chromium runtime. Koe avoids that entire stack, which helps keep memory usage low and the app feeling lightweight.

## How It Works

1. Press and hold the trigger key (default: **Fn**, configurable) — Koe starts listening
2. Audio streams in real-time to a cloud ASR service (Doubao/豆包 by ByteDance)
3. A floating status pill shows real-time interim recognition text as you speak
4. The ASR transcript is corrected by an LLM (any OpenAI-compatible API) — fixing capitalization, punctuation, spacing, and terminology
5. The corrected text is automatically pasted into the active input field

ASR provider support:

- **Cloud**: **Doubao (豆包)** and **Qwen (通义)** streaming ASR
- **Local**: **Apple Speech** (macOS 26+, zero-config on-device), **MLX** (Apple Silicon, Qwen3-ASR models), and **sherpa-onnx** (CPU, streaming zipformer models)
- **LLM**: any **OpenAI-compatible API** for text correction
- **Planned**: future ASR support may include the **OpenAI Transcriptions API**

## Installation

Koe's standard prebuilt path is still **Apple Silicon first**, but Intel Macs
can now build from source with the dedicated `x86_64` target.

### Homebrew

```bash
brew tap owo-network/brew
brew install owo-network/brew/koe
```

### Release

You can also download the latest release directly from GitHub:

- [Download the latest release](https://github.com/missuo/koe/releases/latest)

### App Updates

Koe can check a JSON update feed hosted directly in this repository. The app reads
the raw GitHub URL below and compares the published version with the running build:

- `APP_UPDATE_FEED_URL`: `https://raw.githubusercontent.com/missuo/koe/main/docs/update-feed.json`

The feed file lives at `docs/update-feed.json` and should contain at least:

```json
{
  "version": "1.0.10",
  "build": 11,
  "download_url": "https://github.com/missuo/koe/releases/download/v1.0.10/Koe-macOS-arm64.zip"
}
```

Optional fields such as `minimum_system_version`, `release_notes_url`, `published_at`,
and `notes` can also be included. On launch, Koe checks this raw feed automatically,
checks again periodically, and you can also trigger a manual check from the menu bar
with `Check for Updates...`. When an update is found, Koe opens the release download
URL instead of patching the installed app in place.

### Build from Source

#### Prerequisites

- macOS 14.0+ (13.0+ without MLX support)
- Apple Silicon or Intel Mac
- Rust toolchain (`rustup`)
- Xcode with command line tools
- [xcodegen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`)

#### Build

```bash
git clone https://github.com/missuo/koe.git
cd koe

# Generate Xcode project
cd KoeApp && xcodegen && cd ..

# Build Apple Silicon
make build

# Build Intel
make build-x86_64
```

#### Run

```bash
make run
```

Or open the built app directly:

```bash
open ~/Library/Developer/Xcode/DerivedData/Koe-*/Build/Products/Release/Koe.app
```

### Permissions

Koe requires **three macOS permissions** to function. You'll be prompted to grant them on first launch. All three are mandatory — without any one of them, Koe cannot complete its core workflow.

| Permission | Why it's needed | What happens without it |
|---|---|---|
| **Microphone** | Captures audio from your mic and streams it to the ASR service for speech recognition. | Koe cannot hear you at all. Recording will not start. |
| **Accessibility** | Simulates a `Cmd+V` keystroke to paste the corrected text into the active input field of any app. | Koe will still copy the text to your clipboard, but cannot auto-paste. You'll need to paste manually. |
| **Input Monitoring** | Listens for the trigger key (default: **Fn**, configurable) globally so Koe can detect when you press/release it, regardless of which app is in the foreground. | Koe cannot detect the hotkey. You won't be able to trigger recording. |
| **Speech Recognition** | Required only when using the Apple Speech provider (macOS 26+). Allows on-device speech recognition. | Other providers (cloud, MLX, sherpa-onnx) work without this permission. |

To grant permissions: **System Settings → Privacy & Security** → enable Koe under each of the three categories above.

## Configuration

All config files live in `~/.koe/` and are auto-generated on first launch. You
can edit them directly, or use the built-in settings window (Setup Wizard) from
the menu bar. The settings window includes tabs for ASR, LLM, Controls, Dictionary,
and Prompt. When a local ASR provider is selected, the ASR tab shows provider-specific
controls: model picker with download/delete for MLX and Sherpa-ONNX, or language
picker with asset status and download for Apple Speech.

```
~/.koe/
├── config.yaml          # Main configuration
├── dictionary.txt       # User dictionary (hotwords + LLM correction)
├── history.db           # Usage statistics (SQLite, auto-created)
├── system_prompt.txt    # LLM system prompt (customizable)
├── user_prompt.txt      # LLM user prompt template (customizable)
└── models/              # Local ASR models
    ├── mlx/
    │   └── Qwen3-ASR-0.6B-4bit/
    │       ├── .koe-manifest.json
    │       └── *.safetensors, config.json, ...
    └── sherpa-onnx/
        └── bilingual-zh-en/
            ├── .koe-manifest.json
            └── *.onnx, tokens.txt, ...
```

### config.yaml

Below is the full configuration with explanations for every field.

#### ASR (Speech Recognition)

Koe uses a provider-based ASR config layout. Built-in providers: **Doubao**, **Qwen**, **Apple Speech** (local, macOS 26+), **MLX** (local, Apple Silicon), and **sherpa-onnx** (local, CPU).

```yaml
asr:
  # ASR provider: "doubao", "qwen", "apple-speech", "mlx", "sherpa-onnx"
  provider: "doubao"

  doubao:
    # WebSocket endpoint. Default uses ASR 2.0 optimized bidirectional streaming.
    # Do not change unless you know what you're doing.
    url: "wss://openspeech.bytedance.com/api/v3/sauc/bigmodel_async"

    # Volcengine credentials — get these from the 火山引擎 console.
    # Go to: https://console.volcengine.com/speech/app → create an app → copy App ID and Access Token.
    app_key: ""          # X-Api-App-Key (火山引擎 App ID)
    access_key: ""       # X-Api-Access-Key (火山引擎 Access Token)

    # Resource ID for billing. Default is the standard duration-based billing plan.
    resource_id: "volc.seedasr.sauc.duration"

    # Connection timeout in milliseconds. Increase if you have slow network.
    connect_timeout_ms: 3000

    # How long to wait for the final ASR result after you stop speaking (ms).
    # If ASR doesn't return a final result within this time, the best available result is used.
    final_wait_timeout_ms: 5000

    # Disfluency removal (语义顺滑). Removes spoken repetitions and filler words like 嗯, 那个.
    # Recommended: true. Set to false if you want raw transcription.
    enable_ddc: true

    # Inverse text normalization (文本规范化). Converts spoken numbers, dates, etc.
    # e.g., "二零二四年" → "2024年", "百分之五十" → "50%"
    # Recommended: true.
    enable_itn: true

    # Automatic punctuation. Inserts commas, periods, question marks, etc.
    # Recommended: true.
    enable_punc: true

    # Two-pass recognition (二遍识别). First pass gives fast streaming results,
    # second pass re-recognizes with higher accuracy. Slight latency increase (~200ms)
    # but significantly better accuracy, especially for technical terms.
    # Recommended: true.
    enable_nonstream: true

  # Apple Speech local ASR (macOS 26+, system-managed assets)
  apple-speech:
    locale: "zh_CN"                        # available locales depend on system; see Setup Wizard

  # MLX local ASR (Apple Silicon only, requires model download)
  mlx:
    model: "mlx/Qwen3-ASR-0.6B-4bit"    # relative to ~/.koe/models/, or absolute path
    delay_preset: "realtime"              # realtime | agent | subtitle
    language: "auto"                      # auto | zh | en

  # Sherpa-ONNX local ASR (CPU, requires model download)
  sherpa-onnx:
    model: "sherpa-onnx/bilingual-zh-en"  # relative to ~/.koe/models/, or absolute path
    num_threads: 2                         # CPU inference threads
    hotwords_score: 1.5                    # dictionary term boost
    endpoint_silence: 1.2                  # trailing silence for sentence boundary (seconds)
```

Older Koe versions stored Doubao fields directly under `asr:`. Current builds
migrate that flat format into the provider-based v2 layout automatically.

#### LLM (Text Correction)

After ASR, the transcript is sent to an LLM for correction (capitalization,
spacing, terminology, filler word removal). Koe currently supports
**OpenAI-compatible APIs only** for this step. Native provider-specific APIs that
are not OpenAI-compatible are not supported directly.

The LLM HTTP client is shared across sessions with HTTP/2 support and connection
pooling for lower latency. For GPT-5-style endpoints (using `max_completion_tokens`),
Koe automatically sets `reasoning_effort: "none"` to skip unnecessary reasoning
on the latency-sensitive correction path.

```yaml
llm:
  # Set to false to skip LLM correction and paste raw ASR output directly.
  enabled: true

  # OpenAI-compatible API endpoint.
  # Examples:
  #   OpenAI:    "https://api.openai.com/v1"
  #   Anthropic: "https://api.anthropic.com/v1"  (needs compatible proxy)
  #   Local:     "http://localhost:8080/v1"
  base_url: "https://api.openai.com/v1"

  # API key. Supports environment variable substitution with ${VAR_NAME} syntax.
  # Examples:
  #   Direct:  "sk-xxxxxxxx"
  #   Env var: "${LLM_API_KEY}"
  api_key: ""

  # Model name. Use a fast, cheap model — latency matters here.
  # Recommended: "gpt-5.4-nano" or any similar fast model.
  model: "gpt-5.4-nano"

  # LLM sampling parameters. temperature: 0 = deterministic, best for correction tasks.
  temperature: 0
  top_p: 1

  # LLM request timeout in milliseconds.
  timeout_ms: 8000

  # Max tokens in LLM response. 1024 is plenty for voice input correction.
  max_output_tokens: 1024

  # Token limit field sent to the OpenAI-compatible API.
  # Use "max_tokens" for older model endpoints.
  max_token_parameter: "max_completion_tokens"

  # How many dictionary entries to include in the LLM prompt.
  # 0 = send all entries (recommended for dictionaries under ~500 entries).
  # Set a limit if your dictionary is very large and you want to reduce prompt size.
  dictionary_max_candidates: 0

  # Paths to prompt files, relative to ~/.koe/.
  # Edit these files to customize how the LLM corrects text.
  system_prompt_path: "system_prompt.txt"
  user_prompt_path: "user_prompt.txt"
```

#### Feedback (Sound Effects)

```yaml
feedback:
  start_sound: false   # Play sound when recording starts
  stop_sound: false    # Play sound when recording stops
  error_sound: false   # Play sound on errors
```

#### Hotkey

```yaml
hotkey:
  # Trigger key for voice input.
  # Options: fn | left_option | right_option | left_command | right_command | left_control | right_control
  trigger_key: "fn"
  # Cancel key for aborting the current session.
  # Must be different from trigger_key.
  cancel_key: "left_option"
```

| Option | Key | Notes |
|---|---|---|
| `fn` | Fn/Globe key | Default. Works on all Mac keyboards |
| `left_option` | Left Option | Good alternative if Fn is remapped |
| `right_option` | Right Option | Least likely to conflict with shortcuts |
| `left_command` | Left Command | May conflict with system shortcuts |
| `right_command` | Right Command | Less conflict-prone than left Command |
| `left_control` | Left Control | Available on all Mac keyboards |
| `right_control` | Right Control | Only on full-size/external keyboards |

Hotkey changes take effect automatically within a few seconds. The trigger key
starts voice input, and the cancel key aborts the current session without output.
If the configured trigger key and cancel key collide, Koe normalizes them and
writes the corrected pair back to `config.yaml`.

#### Dictionary

```yaml
dictionary:
  path: "dictionary.txt"  # Relative to ~/.koe/
```

### Dictionary

The dictionary serves two purposes:

1. **ASR hotwords** — sent to the speech recognition engine to improve accuracy for specific terms
2. **LLM correction** — included in the prompt so the LLM prefers these spellings and terms

Edit `~/.koe/dictionary.txt`:

```
# One term per line. Lines starting with # are comments.
Cloudflare
PostgreSQL
Kubernetes
GitHub Actions
VS Code
```

#### Bulk-Generating Dictionary Terms

Instead of typing terms one by one, you can use AI tools to generate domain-specific vocabulary. For example, with [Claude Code](https://claude.com/claude-code):

```
You: Add common DevOps and cloud infrastructure terms to my dictionary file at ~/.koe/dictionary.txt
```

Or with a simple shell command:

```bash
# Append terms from a project's codebase
grep -roh '[A-Z][a-zA-Z]*' src/ | sort -u >> ~/.koe/dictionary.txt

# Append terms from a package.json
jq -r '.dependencies | keys[]' package.json >> ~/.koe/dictionary.txt
```

Since the dictionary is just a text file, you can version-control it, share it across machines, or script its maintenance however you like.

### Prompts

The LLM correction behavior is fully customizable via two prompt files:

- **`~/.koe/system_prompt.txt`** — defines the correction rules (capitalization, spacing, punctuation, filler word removal, etc.)
- **`~/.koe/user_prompt.txt`** — template that assembles the ASR output, interim history, and dictionary into the final LLM request

Available template placeholders in `user_prompt.txt`:

| Placeholder | Description |
|---|---|
| `{{asr_text}}` | The final ASR transcript text |
| `{{interim_history}}` | ASR interim revision history — shows how the transcript changed over time, helping the LLM identify uncertain words |
| `{{dictionary_entries}}` | Filtered dictionary entries for LLM context |

The default prompts are tuned for software developers working in mixed Chinese-English, but you can adapt them for any language or domain.

## Usage Statistics

Koe automatically tracks your voice input usage in a local SQLite database at `~/.koe/history.db`. You can view a summary directly in the menu bar dropdown — it shows total characters, words, recording time, session count, and input speed.

### Database Schema

```sql
CREATE TABLE sessions (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    timestamp INTEGER NOT NULL,   -- Unix timestamp
    duration_ms INTEGER NOT NULL, -- Recording duration in milliseconds
    text TEXT NOT NULL,            -- Final transcribed text
    char_count INTEGER NOT NULL,  -- CJK character count
    word_count INTEGER NOT NULL   -- English word count
);
```

### Querying Your Data

You can query the database directly with `sqlite3`:

```bash
# View all sessions
sqlite3 ~/.koe/history.db "SELECT * FROM sessions ORDER BY timestamp DESC LIMIT 10;"

# Total stats
sqlite3 ~/.koe/history.db "SELECT COUNT(*) as sessions, SUM(duration_ms)/1000 as total_seconds, SUM(char_count) as chars, SUM(word_count) as words FROM sessions;"

# Daily breakdown
sqlite3 ~/.koe/history.db "SELECT date(timestamp, 'unixepoch', 'localtime') as day, COUNT(*) as sessions, SUM(char_count) as chars, SUM(word_count) as words FROM sessions GROUP BY day ORDER BY day DESC;"
```

You can also build your own dashboard or visualization on top of this database — it's just a standard SQLite file.

## Local ASR

Koe supports three on-device speech recognition providers:

- **Apple Speech** (macOS 26+) — uses Apple's built-in SpeechAnalyzer. Select the provider and language in the Setup Wizard — speech assets are managed by macOS and downloaded automatically on first use (or manually via the Setup Wizard). No API key needed. Dictionary entries are automatically passed as contextual strings for vocabulary bias.
- **MLX** (Apple Silicon) — runs Qwen3-ASR models via the MLX framework. Requires model download (~680 MB–1.5 GB).
- **sherpa-onnx** (CPU) — runs streaming zipformer models. Requires model download (~189 MB–735 MB).

MLX and sherpa-onnx models are managed through `.koe-manifest.json` files under `~/.koe/models/`. You can manage them in two ways:

1. **Setup Wizard** — select a local provider in the ASR tab, pick a model from the dropdown, and click the download button. Progress is shown inline with a progress bar.
2. **koe CLI** — command-line model management (see below).

### koe CLI

The `koe` CLI tool manages local models:

```bash
# List all discovered models and their status
koe model list

# Download a model
koe model pull mlx/Qwen3-ASR-0.6B-4bit

# Check model status
koe model status mlx/Qwen3-ASR-0.6B-4bit

# Remove downloaded files (keeps manifest for re-download)
koe model remove mlx/Qwen3-ASR-0.6B-4bit

# Generate manifest from a HuggingFace repo
koe manifest generate mlx-community/Qwen3-ASR-0.6B-4bit \
    --provider mlx --description "Qwen3 ASR 0.6B 4-bit"
```

### Available Models

**MLX (Apple Silicon)**:
- `mlx/Qwen3-ASR-0.6B-4bit` — Qwen3 ASR 0.6B 4-bit (~680 MB, fast)
- `mlx/Qwen3-ASR-1.7B-4bit` — Qwen3 ASR 1.7B 4-bit (~1.5 GB, higher accuracy)

**sherpa-onnx (CPU)**:
- `sherpa-onnx/bilingual-zh-en` — Bilingual Chinese-English (~189 MB)
- `sherpa-onnx/multilingual-8lang` — 8-language multilingual (~322 MB)
- `sherpa-onnx/zh-xlarge` — Chinese extra-large (~735 MB, best accuracy)

### Model Manifest

Each model directory contains a `.koe-manifest.json` describing the model and its files:

```json
{
  "provider": "mlx",
  "description": "Qwen3 ASR 0.6B 4-bit (fast, lightweight)",
  "repo": "mlx-community/Qwen3-ASR-0.6B-4bit",
  "files": [
    {"name": "config.json", "size": 7187, "sha256": "...", "url": "https://huggingface.co/..."}
  ]
}
```

Default manifests are installed automatically on first launch. `koe model pull` downloads the actual model files using the URLs and verifies them with sha256 checksums.

## AI-Assisted Setup

Koe provides a skill that works with any AI coding agent (Claude Code, Codex, etc.) to guide you through the entire setup process interactively.

### Install the Skill

```bash
npx skills add missuo/koe
```

The command will let you choose which AI coding tool to install the skill for.

### What It Does

Once installed, the `koe-setup` skill will:

1. Check your installation and permissions
2. Walk you through ASR and LLM credential setup
3. Ask about your profession and generate a **personalized dictionary** tailored to your domain
4. Customize the **system prompt** based on your use case
5. Help you configure the trigger key and sound feedback

This is especially useful for first-time users who want a guided, interactive setup experience.

## Architecture

Koe is built as a native macOS app with two layers:

- **Objective-C shell** — handles macOS integration: hotkey detection, audio capture, clipboard management, paste simulation, menu bar UI, and usage statistics (SQLite)
- **Rust core library** — handles ASR (cloud WebSocket streaming + local MLX/sherpa-onnx/Apple Speech), LLM API calls, config management, model management, transcript aggregation, and session orchestration
- **Swift KoeMLX package** — bridges MLX inference (Qwen3-ASR) to Rust via C FFI for on-device ASR on Apple Silicon
- **Swift KoeAppleSpeech package** — bridges Apple's SpeechAnalyzer to Rust via C FFI for zero-config on-device ASR (macOS 26+)

The two layers communicate via C FFI (Foreign Function Interface). The Rust core is compiled as a static library (`libkoe_core.a`) and linked into the Xcode project.

```
┌──────────────────────────────────────────────────┐
│  macOS (Objective-C)                             │
│  ┌──────────┐ ┌──────────┐ ┌───────────────────┐│
│  │ Hotkey   │ │ Audio    │ │ Clipboard + Paste ││
│  │ Monitor  │ │ Capture  │ │                   ││
│  └────┬─────┘ └────┬─────┘ └────────▲──────────┘│
│       │             │                │           │
│  ┌────▼─────────────▼────────────────┴─────────┐ │
│  │           SPRustBridge (FFI)                 │ │
│  └────────────────┬────────────────────────────┘ │
│                   │                              │
│  ┌────────────────┴───────┐  ┌────────────────┐  │
│  │ Menu Bar + Status Bar  │  │ History Store  │  │
│  │ (SPStatusBarManager)   │  │ (SQLite)       │  │
│  └────────────────────────┘  └────────────────┘  │
└───────────────────┼──────────────────────────────┘
                    │ C ABI
┌───────────────────▼──────────────────────────────┐
│  Rust Core (libkoe_core.a)                       │
│  ┌──────────────────────────┐ ┌────────────────┐  │
│  │ ASR Providers            │ │ Config + Dict  │  │
│  │ ┌────────┐ ┌───────────┐ │ │ + Prompts      │  │
│  │ │ Doubao │ │ Qwen      │ │ │ + Models       │  │
│  │ │ (WS)   │ │ (WS)      │ │ └────────────────┘  │
│  │ ├────────┤ ├───────────┤ │ ┌────────────────┐  │
│  │ │ MLX    │ │ sherpa-   │ │ │ LLM (HTTP)     │  │
│  │ │ (FFI)  │ │ onnx(CPU) │ │ │                │  │
│  │ ├────────┤ ├───────────┤ │ └───────▲────────┘  │
│  │ │ Apple  │ │           │ │                     │
│  │ │ Speech │ │           │ │                     │
│  │ └────────┘ └───────────┘ │                     │
│  └──────────┬───────────────┘         │           │
│  ┌──────────▼─────────────────────────┴────────┐  │
│  │ TranscriptAggregator                        │  │
│  │ (interim → definite → final + history)      │  │
│  └─────────────────────────────────────────────┘  │
└──────────────────────────────────────────────────┘
```

### ASR Pipeline

Cloud providers (Doubao, Qwen):

1. Audio streams via WebSocket to the cloud ASR service
2. First-pass streaming results arrive in real-time (`Interim` events) and are displayed in the overlay
3. Second-pass re-recognition confirms segments with higher accuracy (`Definite` events)

Local providers (Apple Speech, MLX, sherpa-onnx):

1. Audio is processed on-device — Apple Speech via SpeechAnalyzer (macOS 26+), MLX via Swift FFI on Apple Silicon, sherpa-onnx via a dedicated CPU worker thread
2. Streaming results are emitted through the same `Interim`/`Definite`/`Final` event model

All providers:

4. `TranscriptAggregator` merges all results and tracks interim revision history
5. Final transcript + interim history + dictionary are sent to the LLM for correction

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md) for commit conventions, PR guidelines, and the full contributor workflow.

## License

MIT
