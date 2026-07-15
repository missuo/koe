use std::path::Path;

/// Load system prompt from file, or return built-in default.
/// cbindgen:ignore
pub fn load_system_prompt(path: &Path) -> String {
    match std::fs::read_to_string(path) {
        Ok(content) => {
            let trimmed = content.trim();
            if trimmed.is_empty() {
                log::warn!("system prompt file is empty, using built-in default");
                build_default_system_prompt()
            } else {
                log::info!("loaded system prompt from {}", path.display());
                trimmed.to_string()
            }
        }
        Err(e) => {
            log::warn!(
                "failed to load system prompt from {}: {e}, using built-in default",
                path.display()
            );
            build_default_system_prompt()
        }
    }
}

/// Load user prompt template from file, or return built-in default.
/// The template should contain {{asr_text}} and {{dictionary_entries}} placeholders.
/// cbindgen:ignore
pub fn load_user_prompt_template(path: &Path) -> String {
    match std::fs::read_to_string(path) {
        Ok(content) => {
            let trimmed = content.trim();
            if trimmed.is_empty() {
                log::warn!("user prompt file is empty, using built-in default");
                build_default_user_prompt_template()
            } else {
                log::info!("loaded user prompt template from {}", path.display());
                trimmed.to_string()
            }
        }
        Err(e) => {
            log::warn!(
                "failed to load user prompt from {}: {e}, using built-in default",
                path.display()
            );
            build_default_user_prompt_template()
        }
    }
}

/// Render the user prompt by replacing placeholders in the template.
/// cbindgen:ignore
pub fn render_user_prompt(
    template: &str,
    asr_text: &str,
    dictionary_entries: &[String],
    interim_history: &[String],
) -> String {
    let dict_str = if dictionary_entries.is_empty() {
        String::from("（无）")
    } else {
        dictionary_entries.join("\n")
    };

    let interim_str = if interim_history.is_empty() {
        String::from("（无）")
    } else {
        interim_history
            .iter()
            .enumerate()
            .map(|(i, t)| format!("{}. {}", i + 1, t))
            .collect::<Vec<_>>()
            .join("\n")
    };

    template
        .replace("{{asr_text}}", asr_text)
        .replace("{{dictionary_entries}}", &dict_str)
        .replace("{{interim_history}}", &interim_str)
}

/// Built-in default system prompt.
/// cbindgen:ignore
fn build_default_system_prompt() -> String {
    include_str!("default_system_prompt.txt").trim().to_string()
}

/// Built-in default user prompt template.
/// cbindgen:ignore
fn build_default_user_prompt_template() -> String {
    include_str!("default_user_prompt.txt").trim().to_string()
}

/// Detect a degenerate LLM rewrite that has dropped the user's words.
///
/// The post-ASR cleanup model (a small local LLM) sometimes fails to follow
/// the rewrite instruction and instead emits garbage in three observed shapes,
/// all of which erase what the user actually said:
///
/// 1. **Dump** — the model echoes the prompt's dictionary back, so the output
///    is a concatenation of dozens of dictionary entries the user never spoke.
/// 2. **Collapse** — the model extracts one salient fragment (e.g. "ASR" or
///    "PPT master") and emits only it, discarding the rest of the sentence.
/// 3. **Severe truncation** — the output is a small fraction of the input even
///    when it is not a verbatim fragment.
///
/// On any of these we reject the output and let the caller fall back to the
/// raw ASR text. This is the output-side sibling of the trim-aware empty
/// guard, which catches blank *input*. Note the collapse/truncation checks are
/// dictionary-independent — a stronger model lowers the odds of degeneration
/// but never eliminates them, so this guard is the deterministic backstop.
/// cbindgen:ignore
pub fn looks_like_degenerate_rewrite(
    output: &str,
    asr_text: &str,
    dictionary_entries: &[String],
) -> bool {
    let output_lower = output.to_lowercase();
    let asr_lower = asr_text.to_lowercase();
    let remove_fillers = |s: &str| -> String {
        let mut normalized = s.to_lowercase();
        for filler in ["那个", "就是", "其实", "嗯", "啊", "哦", "额", "呃"] {
            normalized = normalized.replace(filler, "");
        }
        normalized
    };

    // --- Dump: many dictionary terms appear in the output that the user never
    // spoke. Terms the user actually said are excluded, so a normal rewrite
    // (which injects ~none) cannot reach the threshold.
    if !dictionary_entries.is_empty() {
        let leaked = dictionary_entries
            .iter()
            .filter(|e| {
                let el = e.to_lowercase();
                output_lower.contains(&el) && !asr_lower.contains(&el)
            })
            .count();
        // Absolute floor (so short, legitimately term-heavy rewrites pass) AND
        // half the candidate list (so a large dictionary doesn't lower the bar).
        // Use a lower floor for small candidate lists (e.g. when
        // dictionary_max_candidates is set to a small value) so that a partial
        // dump of a short filtered list is still detected.
        let half = dictionary_entries.len() / 2;
        let dump_threshold = if dictionary_entries.len() < 12 {
            half.max(4)
        } else {
            half.max(8)
        };
        if leaked >= dump_threshold {
            return true;
        }
    }

    // --- Translation: a CJK-dominant input that comes back with almost no CJK
    // is a script flip — the model translated instead of rewriting, erasing the
    // user's language (observed on the 0.6B for English-dense mixed input).
    // Mixed CN+English dictation keeps most of its CJK, so it passes.
    let cjk_count = |s: &str| {
        let mut previous = None;
        remove_fillers(s)
            .chars()
            .filter(|c| ('\u{4e00}'..='\u{9fff}').contains(c))
            .filter(|c| {
                let repeated = previous == Some(*c);
                previous = Some(*c);
                !repeated
            })
            .count()
    };
    let asr_cjk = cjk_count(asr_text);
    if asr_cjk >= 4 && cjk_count(output) * 4 < asr_cjk {
        return true;
    }

    // Whitespace-stripped, lowercased forms so CJK/latin spacing and trailing
    // sentence punctuation don't skew the length/substring comparison.
    let strip = |s: &str| -> String { s.chars().filter(|c| !c.is_whitespace()).collect() };
    let out_core = strip(&output_lower);
    let out_core = out_core.trim_end_matches(['。', '.', '，', ',', '！', '!', '？', '?']);
    let asr_core = strip(&asr_lower);
    // Compare content-bearing characters rather than raw length. The prompt
    // explicitly allows removing fillers and adjacent stutters, so counting
    // those as lost content would reject a legitimate cleanup.
    let meaningful_chars = |s: &str| -> usize {
        let mut previous = None;
        remove_fillers(s)
            .chars()
            .filter(|c| c.is_alphanumeric())
            .filter(|c| {
                let repeated = previous == Some(*c);
                previous = Some(*c);
                !repeated
            })
            .count()
    };
    let out_chars = meaningful_chars(out_core);
    let asr_chars = meaningful_chars(&asr_core);
    if out_chars == 0 {
        return false;
    }
    let dropped = asr_chars.saturating_sub(out_chars);

    // --- Collapse: the output is a verbatim fragment of the ASR text (the
    // model extracted a span instead of rewriting) while dropping at least
    // half the content. A genuine rewrite adds punctuation / fixes terms, so
    // it is rarely a verbatim substring of the raw ASR — this is high-precision.
    if asr_core.contains(out_core) && out_chars * 2 <= asr_chars && dropped >= 8 {
        return true;
    }

    // --- Severe truncation: even without a verbatim match, an output that is
    // under a third of a non-trivial input has lost the user's content.
    if out_chars * 3 <= asr_chars && asr_chars >= 18 && dropped >= 12 {
        return true;
    }

    false
}

/// Filter dictionary candidates to reduce prompt size.
/// When `max_candidates` is 0, all entries are sent without filtering.
/// When dictionary has more than `max_candidates` entries,
/// keep only those with character overlap with the ASR text.
/// cbindgen:ignore
pub fn filter_dictionary_candidates(
    dictionary: &[String],
    asr_text: &str,
    max_candidates: usize,
) -> Vec<String> {
    if max_candidates == 0 || dictionary.len() <= max_candidates {
        return dictionary.to_vec();
    }

    let asr_lower = asr_text.to_lowercase();
    let asr_chars: std::collections::HashSet<char> = asr_lower.chars().collect();

    let mut scored: Vec<(usize, &String)> = dictionary
        .iter()
        .map(|entry| {
            let entry_lower = entry.to_lowercase();
            let overlap = entry_lower
                .chars()
                .filter(|c| asr_chars.contains(c))
                .count();
            let substring_bonus =
                if asr_lower.contains(&entry_lower) || entry_lower.contains(&asr_lower) {
                    entry.len() * 10
                } else {
                    0
                };
            (overlap + substring_bonus, entry)
        })
        .collect();

    scored.sort_by(|a, b| b.0.cmp(&a.0));
    scored
        .into_iter()
        .take(max_candidates)
        .map(|(_, entry)| entry.clone())
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn default_user_prompt_places_stable_dictionary_before_dynamic_fields() {
        let template = build_default_user_prompt_template();

        assert_eq!(template.matches("{{dictionary_entries}}").count(), 1);
        assert_eq!(template.matches("{{interim_history}}").count(), 1);
        assert_eq!(template.matches("{{asr_text}}").count(), 1);

        let dictionary_pos = template.find("{{dictionary_entries}}").unwrap();
        let history_pos = template.find("{{interim_history}}").unwrap();
        let asr_pos = template.find("{{asr_text}}").unwrap();
        assert!(dictionary_pos < history_pos);
        assert!(dictionary_pos < asr_pos);

        let dictionary = vec!["StableTerm".to_string()];
        let history = vec!["interim revision".to_string()];
        let rendered = render_user_prompt(&template, "final ASR", &dictionary, &history);
        assert!(rendered.contains("StableTerm"));
        assert!(rendered.contains("1. interim revision"));
        assert!(rendered.contains("final ASR"));

        let rendered_empty = render_user_prompt(&template, "final ASR", &[], &[]);
        assert!(rendered_empty.contains("用户词典：\n（无）"));
        assert!(rendered_empty.contains("ASR 中间修订历史：\n（无）"));
    }

    fn dict() -> Vec<String> {
        [
            "cc-connect",
            "Anthropic",
            "Claudecode",
            "cloudflared",
            "Shadowrocket",
            "Karabiner",
            "Obsidian",
            "DoubaoIME",
            "Cloudflare",
            "Nextcloud",
            "Doubao",
            "Tailscale",
            "sing-box",
            "Docmost",
            "Hammerspoon",
            "GitHub",
            "Sherpa-ONNX",
            "Cursor",
            "Tauri",
            "Sonnet",
            "Claude",
            "Miniflux",
            "Forgejo",
            "OpenAI",
            "FastAPI",
            "Docker",
            "Telegram",
            "Gemini",
            "Haiku",
            "Codex",
            "Lucky",
            "Xcode",
            "Rustls",
            "Opus",
            "Type4Me",
            "OKR",
            "Whisper",
            "ASR",
            "PTT",
            "Vercel",
            "Qwen",
            "DeepSeek",
            "Hevy",
        ]
        .iter()
        .map(|s| s.to_string())
        .collect()
    }

    #[test]
    fn detects_dump_regurgitating_dictionary() {
        // Real failure capture (session 831): the model echoed the whole
        // candidate list back instead of rewriting.
        let dump = "cc-connectAnthropicClaudecodecloudflaredShadowrocketKarabinerObsidianDoubaoIMECloudflareNextcloudDoubaoTailscalesing-boxDocmostHammerspoonGitHubSherpa-ONNXCursorTauriSonnetClaudeMinifluxForgejoOpenAIFastAPIDockerTelegramGeminiHaikuCodexLuckyXcodeRustlsOpusType4MeOKRWhisperASRPTTVercelQwenDeepSeekHevy";
        assert!(looks_like_degenerate_rewrite(dump, "测试一下", &dict()));
    }

    #[test]
    fn detects_collapse_to_dictionary_term() {
        // Reported bug: a sentence containing "ASR" collapses to just "ASR".
        let asr = "当输入里头有 ASR 这三个字母的时候，输出其他的全部消失";
        assert!(looks_like_degenerate_rewrite("ASR", asr, &dict()));
        // Trailing punctuation the model may append must not defeat the guard.
        assert!(looks_like_degenerate_rewrite("ASR。", asr, &dict()));
    }

    #[test]
    fn detects_collapse_to_non_dictionary_fragment() {
        // Reported bug: a sentence collapses to "PPT master", which is NOT a
        // dictionary entry — the dictionary-membership check would miss it, so
        // the verbatim-fragment + heavy-drop check must catch it.
        let asr = "我刚才说的那个 PPT master 的功能其实挺好用的";
        assert!(looks_like_degenerate_rewrite("PPT master", asr, &dict()));
    }

    #[test]
    fn detects_translation_to_english() {
        // Observed 0.6B failure: Chinese input comes back fully translated.
        let asr = "我想测试这个功能是否正常工作";
        assert!(looks_like_degenerate_rewrite(
            "I want to test whether this feature works normally",
            asr,
            &dict()
        ));
    }

    #[test]
    fn passes_english_dense_mixed_dictation() {
        // Heavy CN+English mix must survive — it keeps most of its CJK.
        let asr = "我们用 Claude Code 配合 Cursor 写 Rust 然后 deploy 到 Vercel";
        let out = "我们用 Claude Code 配合 Cursor 写 Rust，然后 deploy 到 Vercel。";
        assert!(!looks_like_degenerate_rewrite(out, asr, &dict()));
    }

    #[test]
    fn passes_pure_english_input() {
        // Pure English in, English out is correct — no CJK to lose.
        let asr = "let me check whether claude code still works fine here";
        assert!(!looks_like_degenerate_rewrite(
            "Let me check whether Claude Code still works fine here.",
            asr,
            &dict()
        ));
    }

    #[test]
    fn passes_normal_rewrite() {
        // A genuine cleanup that keeps the user's content and a spoken term.
        let asr = "嗯那个我在用 Claude 写代码";
        assert!(!looks_like_degenerate_rewrite(
            "我在用 Claude 写代码",
            asr,
            &dict()
        ));
    }

    #[test]
    fn passes_short_utterance_kept_intact() {
        // The real non-collapsing capture: "现在测试 PPT master。" stays full.
        assert!(!looks_like_degenerate_rewrite(
            "现在测试 PPT master。",
            "现在测试 PPT master。",
            &dict()
        ));
    }

    #[test]
    fn passes_user_who_only_said_one_term() {
        // If the user genuinely just spoke "ASR", a short output is correct.
        assert!(!looks_like_degenerate_rewrite("ASR", "ASR", &dict()));
    }

    #[test]
    fn passes_legit_list_of_spoken_terms() {
        // User dictates a list of products — all terms were actually spoken,
        // so none count as leaked and the output must survive.
        let asr = "我对比了 Docker、Tailscale、Cloudflare、Nextcloud、Forgejo、Miniflux";
        let out = "我对比了 Docker、Tailscale、Cloudflare、Nextcloud、Forgejo、Miniflux";
        assert!(!looks_like_degenerate_rewrite(out, asr, &dict()));
    }

    #[test]
    fn empty_dictionary_still_catches_collapse() {
        // Collapse detection must not depend on the dictionary being present.
        let asr = "我刚才说的那个 PPT master 的功能其实挺好用的";
        assert!(looks_like_degenerate_rewrite("PPT master", asr, &[]));
    }

    #[test]
    fn passes_filler_heavy_cleanup() {
        let asr = "嗯嗯，那个，就是其实我我我想说的是，嗯，那个，我们明天开会啊";
        assert!(!looks_like_degenerate_rewrite(
            "我们明天开会。",
            asr,
            &dict()
        ));
    }

    #[test]
    fn detects_non_fragment_severe_truncation() {
        let asr = "We need to discuss deployment, review every open bug, and schedule next week's release work.";
        assert!(looks_like_degenerate_rewrite("Ship soon.", asr, &dict()));
    }
}
