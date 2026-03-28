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
            log::warn!("failed to load system prompt from {}: {e}, using built-in default", path.display());
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
            log::warn!("failed to load user prompt from {}: {e}, using built-in default", path.display());
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
            let substring_bonus = if asr_lower.contains(&entry_lower)
                || entry_lower.contains(&asr_lower)
            {
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
