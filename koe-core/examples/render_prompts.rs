//! Render the EXACT runtime LLM prompts for a batch of ASR inputs.
//!
//! Reuses the real `prompt`/`config`/`dictionary` code paths so the offline
//! A/B/C test feeds the model byte-identical prompts to what the running app
//! produces (same system prompt, same filtered dictionary candidates, same
//! template). Reads one ASR line per input file, emits one JSON object per
//! line: {"id", "asr_text", "system", "user"}.
//!
//! Usage: cargo run --example render_prompts --release -- <inputs.txt>

use koe_core::{config, dictionary, prompt};
use std::io::Write;

fn main() {
    let input_path = std::env::args()
        .nth(1)
        .expect("usage: render_prompts <inputs.txt>");

    let cfg = config::load_config().unwrap_or_default();
    let system_prompt = prompt::load_system_prompt(&config::resolve_system_prompt_path(&cfg));
    let user_tpl = prompt::load_user_prompt_template(&config::resolve_user_prompt_path(&cfg));
    let dict =
        dictionary::load_dictionary(&config::resolve_dictionary_path(&cfg)).unwrap_or_default();
    let max = cfg.llm.dictionary_max_candidates;

    let content = std::fs::read_to_string(&input_path).expect("read inputs");
    let stdout = std::io::stdout();
    let mut out = stdout.lock();

    for (i, line) in content.lines().enumerate() {
        let asr = line.trim();
        if asr.is_empty() {
            continue;
        }
        let candidates = prompt::filter_dictionary_candidates(&dict, asr, max);
        let user = prompt::render_user_prompt(&user_tpl, asr, &candidates, &[]);
        let obj = serde_json::json!({
            "id": i,
            "asr_text": asr,
            "system": system_prompt,
            "user": user,
        });
        writeln!(out, "{obj}").expect("write");
    }
}
