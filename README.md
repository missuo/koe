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
├── system_prompt.txt    # LLM system prompt (customizable)
└── user_prompt.txt      # LLM user prompt template (customizable)
```

### config.yaml

```yaml
asr:
  app_key: ""              # Volcengine App ID
  access_key: ""           # Volcengine Access Token

llm:
  base_url: ""             # OpenAI-compatible endpoint
  api_key: ""              # API key (supports ${ENV_VAR} syntax)
  model: ""                # e.g. "gpt-4o-mini"
```

See the generated `config.yaml` for all available options.

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

The LLM correction behavior is fully customizable via:

- `~/.koe/system_prompt.txt` — defines the correction rules
- `~/.koe/user_prompt.txt` — template with `{{asr_text}}` and `{{dictionary_entries}}` placeholders

The default prompts are tuned for software developers working in mixed Chinese-English, but you can adapt them for any language or domain.

## Architecture

Koe is built as a native macOS app with two layers:

- **Objective-C shell** — handles macOS integration: hotkey detection, audio capture, clipboard management, paste simulation, and the menu bar icon
- **Rust core library** — handles all network operations: ASR WebSocket streaming, LLM API calls, config management, and session orchestration

The two layers communicate via C FFI (Foreign Function Interface). The Rust core is compiled as a static library (`libkoe_core.a`) and linked into the Xcode project.

```
┌─────────────────────────────────────────────┐
│  macOS (Objective-C)                        │
│  ┌──────────┐ ┌──────────┐ ┌─────────────┐ │
│  │ Hotkey   │ │ Audio    │ │ Clipboard   │ │
│  │ Monitor  │ │ Capture  │ │ + Paste     │ │
│  └────┬─────┘ └────┬─────┘ └──────▲──────┘ │
│       │             │              │        │
│  ┌────▼─────────────▼──────────────┴──────┐ │
│  │         SPRustBridge (FFI)             │ │
│  └────────────────┬───────────────────────┘ │
└───────────────────┼─────────────────────────┘
                    │ C ABI
┌───────────────────▼─────────────────────────┐
│  Rust Core (libkoe_core.a)                  │
│  ┌──────────┐ ┌──────────┐ ┌─────────────┐ │
│  │ ASR      │ │ LLM      │ │ Config      │ │
│  │ (WS)     │ │ (HTTP)   │ │ + Dict      │ │
│  └──────────┘ └──────────┘ └─────────────┘ │
└─────────────────────────────────────────────┘
```

## License

MIT
