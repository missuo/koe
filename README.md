# Koe (声)

A zero-GUI macOS voice input tool. Press a hotkey, speak, and the corrected text is pasted into whatever app you're using.

## The Name

**Koe** (声, pronounced "ko-eh") is the Japanese word for *voice*. Written as こえ in hiragana, it's one of the most fundamental words in the language — simple, clear, and direct. That's exactly the philosophy behind this tool: your voice goes in, clean text comes out, with nothing in between. No flashy UI, no unnecessary steps. Just 声 — voice, in its purest form.

## Why Koe?

I tried nearly every voice input app on the market. They were either paid, ugly, or inconvenient — bloated UIs, clunky dictionary management, and too many clicks to do simple things.

Koe takes a different approach:

- **No GUI at all.** The only visual element is a tiny icon in the menu bar.
- **All configuration lives in plain text files** under `~/.koe/`. Edit them with any text editor, vim, or even a script.
- **Dictionary is a plain `.txt` file.** No need to open an app and add words one by one through a GUI. Just edit `~/.koe/dictionary.txt` — one term per line. You can even use Claude Code or other AI tools to bulk-generate domain-specific terms.
- **Changes take effect immediately.** Edit any config file and the next time you press the hotkey, the new settings are used. No restart, no reload button.

## How It Works

1. Press and hold **Fn** (or tap to toggle) — Koe starts listening
2. Audio streams in real-time to a cloud ASR service (Doubao/豆包 by ByteDance)
3. The ASR transcript is corrected by an LLM (any OpenAI-compatible API) — fixing capitalization, punctuation, spacing, and terminology
4. The corrected text is automatically pasted into the active input field

## Installation

### Prerequisites

- macOS 13.0+
- Rust toolchain (`rustup`)
- Xcode with command line tools
- [xcodegen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`)

### Build

```bash
git clone https://github.com/missuo/koe.git
cd koe

# Generate Xcode project
cd KoeApp && xcodegen && cd ..

# Build everything
make build
```

### Run

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
| **Input Monitoring** | Listens for the **Fn** key globally so Koe can detect when you press/release it, regardless of which app is in the foreground. | Koe cannot detect the hotkey. You won't be able to trigger recording. |

To grant permissions: **System Settings → Privacy & Security** → enable Koe under each of the three categories above.

## Configuration

All config files live in `~/.koe/` and are auto-generated on first launch:

```
~/.koe/
├── config.yaml          # Main configuration
├── dictionary.txt       # User dictionary (hotwords + LLM correction)
├── history.db           # Usage statistics (SQLite, auto-created)
├── system_prompt.txt    # LLM system prompt (customizable)
└── user_prompt.txt      # LLM user prompt template (customizable)
```

### config.yaml

Below is the full configuration with explanations for every field.

#### ASR (Speech Recognition)

Koe uses Doubao (豆包) ASR 2.0 by ByteDance/Volcengine for streaming speech recognition.

```yaml
asr:
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
```

#### LLM (Text Correction)

After ASR, the transcript is sent to an LLM for correction (capitalization, spacing, terminology, filler word removal). Any OpenAI-compatible API works.

```yaml
llm:
  # OpenAI-compatible API endpoint.
  # Examples:
  #   OpenAI:    "https://api.openai.com/v1"
  #   Anthropic: "https://api.anthropic.com/v1"  (needs compatible proxy)
  #   Local:     "http://localhost:8080/v1"
  base_url: ""

  # API key. Supports environment variable substitution with ${VAR_NAME} syntax.
  # Examples:
  #   Direct:  "sk-xxxxxxxx"
  #   Env var: "${LLM_API_KEY}"
  api_key: ""

  # Model name. Use a fast, cheap model — latency matters here.
  # Recommended: "gpt-4o-mini" or any similar fast model.
  model: ""

  # LLM sampling parameters. temperature: 0 = deterministic, best for correction tasks.
  temperature: 0
  top_p: 1

  # LLM request timeout in milliseconds.
  timeout_ms: 8000

  # Max tokens in LLM response. 1024 is plenty for voice input correction.
  max_output_tokens: 1024

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
  start_sound: true    # Play sound when recording starts
  stop_sound: true     # Play sound when recording stops
  error_sound: true    # Play sound on errors
```

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

## Architecture

Koe is built as a native macOS app with two layers:

- **Objective-C shell** — handles macOS integration: hotkey detection, audio capture, clipboard management, paste simulation, menu bar UI, and usage statistics (SQLite)
- **Rust core library** — handles all network operations: ASR 2.0 WebSocket streaming with two-pass recognition, LLM API calls, config management, transcript aggregation, and session orchestration

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
│  ┌──────────────┐ ┌────────┐ ┌────────────────┐  │
│  │ ASR 2.0      │ │ LLM    │ │ Config + Dict  │  │
│  │ (WebSocket)  │ │ (HTTP) │ │ + Prompts      │  │
│  │ Two-pass     │ │        │ │                │  │
│  └──────┬───────┘ └───▲────┘ └────────────────┘  │
│         │             │                          │
│  ┌──────▼─────────────┴──────────────────────┐   │
│  │ TranscriptAggregator                      │   │
│  │ (interim → definite → final + history)    │   │
│  └───────────────────────────────────────────┘   │
└──────────────────────────────────────────────────┘
```

### ASR Pipeline

1. Audio streams to Doubao ASR 2.0 via WebSocket (binary protocol with gzip compression)
2. First-pass streaming results arrive in real-time (`Interim` events)
3. Second-pass re-recognition confirms segments with higher accuracy (`Definite` events)
4. `TranscriptAggregator` merges all results and tracks interim revision history
5. Final transcript + interim history + dictionary are sent to the LLM for correction

## License

MIT
