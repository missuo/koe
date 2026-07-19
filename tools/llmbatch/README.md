# llmbatch — LLM Degeneration A/B/C Test Harness

Offline batch runner for koe's MLX LLM rewrite path.  
It calls the same `MLXLLM` generation API (`LLMModelFactory`, `ModelContainer`,
`UserInput` chat format, `<think>` stripping) that `KoeMLX/MLXLlmManager` uses at
runtime, so the A/B/C results faithfully reflect what users see.

## Latest result (2026-05-31, 124 samples)

| arm | degrade% | breakdown |
|-----|----------|-----------|
| A — no LLM (baseline) | 0% | — |
| B — Qwen3-0.6B-4bit | 2.4% | 1 collapse + 2 translation |
| C — Qwen3-1.7B-4bit | 0% | — |

---

## Full A/B/C procedure

### Step 1 — Build the Swift harness

```bash
cd /path/to/koe/tools/llmbatch
swift build -c release
```

Binary lands at `.build/release/llmbatch`.

### Step 2 — Copy the Metal bundle (one-time per Xcode build)

`SwiftPM` CLI does not bundle the Metal resource bundle that `mlx-swift` requires
(`mlx-swift_Cmlx.bundle`).  Without it the binary panics at model-load time.
Copy it from the Xcode-produced Release build:

```bash
cp -R \
  ~/Library/Developer/Xcode/DerivedData/Koe-*/Build/Products/Release/mlx-swift_Cmlx.bundle \
  /path/to/koe/tools/llmbatch/.build/release/
```

The glob `Koe-*` matches whatever derived-data hash Xcode assigned; adjust if you
have multiple entries (`ls ~/Library/Developer/Xcode/DerivedData/`).

You must redo this copy each time you do a clean Xcode Release build of koe.

### Step 3 — Build the corpus

```bash
cd /path/to/koe
python3 tools/llmbatch/regression/make_corpus.py
```

Outputs:
- `/tmp/koe-corpus.txt` — one ASR line per row (124 lines: 100 real + 24 adversarial)
- `/tmp/koe-corpus-meta.jsonl` — `{id, source, asr_text}` per line

Real samples are drawn from `~/.koe/history.db` (seed=42, reproducible).
Adversarial samples cover the four known failure modes: dictionary dump,
translation, collapse, and truncation.

### Step 4 — Render prompts

From the repo root, render the exact runtime system+user prompt pair for each
corpus line, reusing the live `~/.koe/config.yaml` / `~/.koe/dictionary.txt`:

```bash
cargo run --example render_prompts --release -- /tmp/koe-corpus.txt \
  > /tmp/koe-prompts.jsonl
```

Each output line: `{"id": N, "asr_text": "...", "system": "...", "user": "..."}`.

### Step 5 — Run llmbatch for each model arm

```bash
BIN=/path/to/koe/tools/llmbatch/.build/release/llmbatch

# Arm B — 0.6B
$BIN ~/.koe/models/mlx/Qwen3-0.6B-4bit /tmp/koe-prompts.jsonl \
  > /tmp/koe-results-0.6b.jsonl

# Arm C — 1.7B
$BIN ~/.koe/models/mlx/Qwen3-1.7B-4bit /tmp/koe-prompts.jsonl \
  > /tmp/koe-results-1.7b.jsonl
```

Each output line: `{"id": N, "output": "..."}`.

Progress is implicit (lines print as they complete).  Expect ~5–10 min per arm on
Apple Silicon for 124 samples.

### Step 6 — Classify and compare

```bash
python3 tools/llmbatch/regression/classify.py
```

Reads `/tmp/koe-corpus-meta.jsonl`, `/tmp/koe-results-0.6b.jsonl`,
`/tmp/koe-results-1.7b.jsonl`, and `~/.koe/dictionary.txt`.

Prints a per-arm table of `ok / dump / collapse / truncation / translation /
empty / error` counts and a `degrade%`, followed by the per-arm degenerate
samples (up to 30 each).

---

## Files in this package

```
tools/llmbatch/
  Package.swift               Swift package manifest
  Package.resolved            pinned dependency versions
  Sources/llmbatch/Batch.swift  harness implementation
  regression/
    make_corpus.py            build the 124-sample test corpus
    classify.py               classify outputs and print the degrade table
  .gitignore                  excludes .build/ and *.bundle
```

The `render_prompts` Rust example lives at `koe-core/examples/render_prompts.rs`
(part of the main crate, not this package).
