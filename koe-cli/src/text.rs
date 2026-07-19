//! Mixed CJK/Latin tokenization shared by benchmarking and dictionary
//! suggestion. Each CJK ideograph or kana character is its own token;
//! alphanumeric runs (plus apostrophes) form word tokens. Punctuation and
//! whitespace are separators.

/// A token with its byte span in the original string, so callers can slice
/// the original text back out (preserving case, hyphens, and spacing that
/// tokenization normalizes away).
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Token {
    /// Lowercased token text, used for comparison.
    pub lower: String,
    /// Byte offset range in the original string.
    pub start: usize,
    pub end: usize,
}

pub fn is_cjk(ch: char) -> bool {
    matches!(ch as u32,
        0x3040..=0x30FF      // Hiragana + Katakana
        | 0x3400..=0x4DBF    // CJK Extension A
        | 0x4E00..=0x9FFF    // CJK Unified Ideographs
        | 0xF900..=0xFAFF    // CJK Compatibility Ideographs
        | 0x20000..=0x2A6DF  // CJK Extension B
    )
}

pub fn tokenize_spans(text: &str) -> Vec<Token> {
    let mut tokens = Vec::new();
    let mut word_start: Option<usize> = None;

    let flush = |tokens: &mut Vec<Token>, start: Option<usize>, end: usize, text: &str| {
        if let Some(start) = start {
            tokens.push(Token {
                lower: text[start..end].to_lowercase(),
                start,
                end,
            });
        }
    };

    for (idx, ch) in text.char_indices() {
        if is_cjk(ch) {
            flush(&mut tokens, word_start.take(), idx, text);
            tokens.push(Token {
                lower: ch.to_string(),
                start: idx,
                end: idx + ch.len_utf8(),
            });
        } else if ch.is_alphanumeric() || ch == '\'' {
            word_start.get_or_insert(idx);
        } else {
            flush(&mut tokens, word_start.take(), idx, text);
        }
    }
    flush(&mut tokens, word_start.take(), text.len(), text);
    tokens
}

/// Lowercased token strings (no spans) — the benchmark error-rate view.
pub fn tokenize(text: &str) -> Vec<String> {
    tokenize_spans(text).into_iter().map(|t| t.lower).collect()
}

/// Merge tokens separated by exactly a hyphen into compound tokens, so
/// "sherpa-onnx" or "gpt-4" is treated as one unit. Used by dictionary
/// suggestion, where splitting a compound at a shared part ("onnx") would
/// truncate the suggested term. Benchmark tokenization stays unmerged.
pub fn merge_hyphenated(text: &str, tokens: Vec<Token>) -> Vec<Token> {
    let mut out: Vec<Token> = Vec::with_capacity(tokens.len());
    for token in tokens {
        if let Some(last) = out.last_mut() {
            if last.end < token.start && &text[last.end..token.start] == "-" {
                last.lower = text[last.start..token.end].to_lowercase();
                last.end = token.end;
                continue;
            }
        }
        out.push(token);
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn spans_slice_back_to_original() {
        let text = "用 sherpa-onnx 部署 Whisper";
        let tokens = tokenize_spans(text);
        let words: Vec<&str> = tokens.iter().map(|t| &text[t.start..t.end]).collect();
        assert_eq!(words, vec!["用", "sherpa", "onnx", "部", "署", "Whisper"]);
        assert_eq!(tokens.last().unwrap().lower, "whisper");
    }

    #[test]
    fn apostrophes_stay_in_words() {
        let tokens = tokenize("Don't");
        assert_eq!(tokens, vec!["don't".to_string()]);
    }
}
