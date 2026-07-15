#[cfg(feature = "mlx")]
pub mod mlx;
pub mod openai_compatible;

use crate::errors::Result;

/// Strip a leading reasoning block emitted by reasoning models (Qwen3, R1,
/// DeepSeek, etc.) when the server ignores the no-reasoning request flags.
///
/// Handles two cases:
/// - Closed `<think>...</think>`: drops everything up to and including `</think>`
///   and trims leading whitespace from the answer that follows.
/// - Unterminated `<think>` (truncated by max_tokens): the model never produced
///   an answer, so returns `""` so the caller's empty-content guard fires and
///   falls back to raw ASR text.
pub fn strip_reasoning(s: &str) -> &str {
    // A reasoning block is metadata only when it is the first non-whitespace
    // content. Preserve ordinary answer text that happens to mention a think
    // tag later in the response.
    let trimmed = s.trim_start();
    let lower = trimmed.to_ascii_lowercase();
    if lower.starts_with("<think>") {
        if let Some(close) = lower.find("</think>") {
            let end = close + "</think>".len();
            return trimmed[end..].trim_start();
        }
        // Unterminated reasoning block (response was cut off by max_tokens).
        // There is no answer — return "" so the empty-content guard triggers
        // ASR fallback rather than pasting a partial monologue.
        return "";
    }
    s
}

/// LLM correction providers supported by this build.
pub fn supported_providers() -> &'static [&'static str] {
    &[
        "openai",
        "anthropic",
        "apfel",
        #[cfg(feature = "mlx")]
        "mlx",
    ]
}

/// Request for LLM text correction.
pub struct CorrectionRequest {
    pub asr_text: String,
    pub dictionary_entries: Vec<String>,
    pub system_prompt: String,
    pub user_prompt: String,
    /// Byte length of the prefix of `user_prompt` that stays identical across
    /// requests (see `prompt::stable_user_prompt_prefix_len`). 0 disables the
    /// per-prompt cache breakpoint for providers that use explicit caching.
    pub user_prompt_stable_prefix_len: usize,
}

/// Trait for LLM correction providers.
#[async_trait::async_trait]
pub trait LlmProvider: Send {
    async fn correct(&self, request: &CorrectionRequest) -> Result<String>;
}

#[cfg(test)]
mod tests {
    use super::strip_reasoning;

    #[test]
    fn strip_reasoning_no_think_block_unchanged() {
        assert_eq!(strip_reasoning("hello world"), "hello world");
    }

    #[test]
    fn strip_reasoning_removes_closed_think_block() {
        let s = "<think>some reasoning here</think>final answer";
        assert_eq!(strip_reasoning(s), "final answer");
    }

    #[test]
    fn strip_reasoning_trims_whitespace_after_think() {
        let s = "<think>reasoning</think>\n\nfinal answer";
        assert_eq!(strip_reasoning(s), "final answer");
    }

    #[test]
    fn strip_reasoning_unterminated_returns_empty() {
        let s = "<think>reasoning that was cut off by max_tokens";
        assert_eq!(strip_reasoning(s), "");
    }

    #[test]
    fn strip_reasoning_case_insensitive() {
        let s = "<THINK>reasoning</THINK>answer";
        assert_eq!(strip_reasoning(s), "answer");
    }

    #[test]
    fn strip_reasoning_allows_leading_whitespace() {
        let s = "  \n<think>reasoning</think>answer";
        assert_eq!(strip_reasoning(s), "answer");
    }

    #[test]
    fn strip_reasoning_preserves_mid_answer_tag() {
        let closed = "Keep this prefix <think>literal tag</think> and suffix";
        let open = "Keep this prefix <think>literal unclosed tag";
        assert_eq!(strip_reasoning(closed), closed);
        assert_eq!(strip_reasoning(open), open);
    }

    #[test]
    fn strip_reasoning_cjk_answer_preserved() {
        let s = "<think>思考过程</think>会议纪要：今天讨论了项目进展。";
        assert_eq!(strip_reasoning(s), "会议纪要：今天讨论了项目进展。");
    }
}
