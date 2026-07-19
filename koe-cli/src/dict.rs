//! Dictionary suggestions mined from voice-input history.
//!
//! Sessions recorded since the history schema upgrade carry both the raw ASR
//! transcript and the LLM-corrected text. Places where they differ are
//! exactly the recognitions a dictionary entry could fix. This module aligns
//! each pair, extracts recurring substitutions, filters out noise
//! (punctuation, casing, filler-word cleanup, wholesale rewrites), and
//! presents candidates for the user to confirm. Nothing is ever added to the
//! dictionary automatically.

use std::collections::HashMap;
use std::path::Path;

use crate::text::{is_cjk, merge_hyphenated, tokenize_spans, Token};

/// Dict-flavoured tokenization: hyphenated compounds are single tokens.
fn dict_tokens(text: &str) -> Vec<Token> {
    merge_hyphenated(text, tokenize_spans(text))
}

// ─── Replacement extraction ────────────────────────────────────────

/// A single "ASR wrote X, the correction says Y" pair, sliced from the
/// original strings so casing, hyphens, and spacing are preserved.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Replacement {
    pub asr: String,
    pub corrected: String,
    /// The full corrected sentence, for display as an example.
    pub example: String,
}

/// Align two token sequences case-insensitively and return the replacement
/// pairs between common anchors. Case-only differences align as anchors and
/// therefore never surface as replacements.
pub fn replacements(asr_text: &str, corrected_text: &str) -> Vec<Replacement> {
    let a = dict_tokens(asr_text);
    let b = dict_tokens(corrected_text);

    // Longest common subsequence DP over lowercased tokens.
    let (m, n) = (a.len(), b.len());
    let mut lcs = vec![vec![0usize; n + 1]; m + 1];
    for i in (0..m).rev() {
        for j in (0..n).rev() {
            lcs[i][j] = if a[i].lower == b[j].lower {
                lcs[i + 1][j + 1] + 1
            } else {
                lcs[i + 1][j].max(lcs[i][j + 1])
            };
        }
    }

    let mut out = Vec::new();
    let (mut i, mut j) = (0usize, 0usize);
    let (mut gap_a_start, mut gap_b_start) = (0usize, 0usize);
    let mut in_gap = false;

    let mut close_gap = |a_lo: usize, a_hi: usize, b_lo: usize, b_hi: usize| {
        // Substitution gaps only: both sides non-empty. One-sided gaps are
        // insertions/deletions (filler removal, punctuation cleanup) and are
        // not dictionary material.
        if a_lo < a_hi && b_lo < b_hi {
            out.push(Replacement {
                asr: slice_tokens(asr_text, &a[a_lo..a_hi]),
                corrected: slice_tokens(corrected_text, &b[b_lo..b_hi]),
                example: corrected_text.to_string(),
            });
        }
    };

    while i < m && j < n {
        if a[i].lower == b[j].lower {
            if in_gap {
                close_gap(gap_a_start, i, gap_b_start, j);
                in_gap = false;
            }
            i += 1;
            j += 1;
        } else {
            if !in_gap {
                gap_a_start = i;
                gap_b_start = j;
                in_gap = true;
            }
            if lcs[i + 1][j] >= lcs[i][j + 1] {
                i += 1;
            } else {
                j += 1;
            }
        }
    }
    if in_gap {
        close_gap(gap_a_start, m, gap_b_start, n);
    } else if i < m || j < n {
        close_gap(i, m, j, n);
    }

    out
}

/// Slice the original text covering a run of tokens.
fn slice_tokens(text: &str, tokens: &[Token]) -> String {
    if tokens.is_empty() {
        return String::new();
    }
    text[tokens[0].start..tokens[tokens.len() - 1].end].to_string()
}

// ─── Filtering ──────────────────────────────────────────────────────

/// Whether a replacement is a plausible dictionary candidate.
pub fn is_candidate(r: &Replacement) -> bool {
    let asr_tokens = dict_tokens(&r.asr);
    let corrected_tokens = dict_tokens(&r.corrected);

    // Wholesale rewrites are grammar cleanup, not vocabulary.
    if corrected_tokens.len() > 5 || asr_tokens.len() > 8 {
        return false;
    }
    if r.corrected.chars().count() > 30 {
        return false;
    }
    // Same after normalization → punctuation/case/spacing change only.
    let norm = |tokens: &[Token]| {
        tokens
            .iter()
            .map(|t| t.lower.as_str())
            .collect::<Vec<_>>()
            .join(" ")
    };
    if norm(&asr_tokens) == norm(&corrected_tokens) {
        return false;
    }
    // The suggestion must contain letters or CJK (not bare numbers).
    if !r.corrected.chars().any(|c| c.is_alphabetic() || is_cjk(c)) {
        return false;
    }
    true
}

/// Terms with distinctive shape — likely proper nouns, camelCase words,
/// acronyms, or mixed CJK/Latin phrases. These rank above plain terms.
pub fn is_distinctive(term: &str) -> bool {
    let has_upper = term.chars().any(|c| c.is_uppercase());
    let has_digit_and_alpha = term.chars().any(|c| c.is_ascii_digit())
        && term.chars().any(|c| c.is_alphabetic());
    let has_cjk = term.chars().any(is_cjk);
    let has_latin = term.chars().any(|c| c.is_ascii_alphabetic());
    let has_hyphen_word = term.contains('-') && has_latin;
    has_upper || has_digit_and_alpha || (has_cjk && has_latin) || has_hyphen_word
}

// ─── Aggregation ────────────────────────────────────────────────────

#[derive(Debug, serde::Serialize)]
pub struct Suggestion {
    /// The corrected term to add to the dictionary.
    pub term: String,
    /// How many sessions contained this correction.
    pub count: usize,
    /// Distinct raw-ASR forms that were corrected into `term`.
    pub asr_forms: Vec<String>,
    /// One real corrected sentence containing the term.
    pub example: String,
    pub distinctive: bool,
}

/// Aggregate replacements from many sessions into ranked suggestions.
/// `existing` is the current dictionary; terms already present are dropped.
pub fn aggregate(all: Vec<Replacement>, existing: &[String], min_count: usize) -> Vec<Suggestion> {
    let existing_lower: Vec<String> = existing.iter().map(|e| e.to_lowercase()).collect();

    let mut by_term: HashMap<String, Suggestion> = HashMap::new();
    for r in all {
        if !is_candidate(&r) {
            continue;
        }
        if existing_lower.contains(&r.corrected.to_lowercase()) {
            continue;
        }
        let entry = by_term
            .entry(r.corrected.clone())
            .or_insert_with(|| Suggestion {
                distinctive: is_distinctive(&r.corrected),
                term: r.corrected.clone(),
                count: 0,
                asr_forms: Vec::new(),
                example: r.example.clone(),
            });
        entry.count += 1;
        if !entry.asr_forms.contains(&r.asr) {
            entry.asr_forms.push(r.asr.clone());
        }
    }

    let mut suggestions: Vec<Suggestion> = by_term
        .into_values()
        .filter(|s| s.count >= min_count)
        .collect();
    suggestions.sort_by(|a, b| {
        b.count
            .cmp(&a.count)
            .then(b.distinctive.cmp(&a.distinctive))
            .then(a.term.cmp(&b.term))
    });
    suggestions
}

// ─── History access ─────────────────────────────────────────────────

/// Load (asr_text, corrected_text) pairs from history.db. Only sessions
/// where the LLM actually changed something are useful; legacy sessions
/// recorded before the schema upgrade have no asr_text and are skipped.
pub fn load_history_pairs(db_path: &Path) -> Result<Vec<(String, String)>, String> {
    if !db_path.exists() {
        return Err(format!("history database not found: {}", db_path.display()));
    }
    let conn = rusqlite::Connection::open_with_flags(
        db_path,
        rusqlite::OpenFlags::SQLITE_OPEN_READ_ONLY,
    )
    .map_err(|e| format!("open {}: {e}", db_path.display()))?;

    let mut stmt = conn
        .prepare(
            "SELECT asr_text, text FROM sessions \
             WHERE llm_applied = 1 AND asr_text IS NOT NULL AND asr_text != text \
             ORDER BY id",
        )
        .map_err(|e| {
            if e.to_string().contains("no such column") {
                "history database predates the asr_text schema — record some new \
                 sessions first (koe ≥ this build stores raw ASR text)"
                    .to_string()
            } else {
                format!("query sessions: {e}")
            }
        })?;

    let rows = stmt
        .query_map([], |row| {
            Ok((row.get::<_, String>(0)?, row.get::<_, String>(1)?))
        })
        .map_err(|e| format!("query sessions: {e}"))?;

    let mut pairs = Vec::new();
    for row in rows {
        pairs.push(row.map_err(|e| format!("read session row: {e}"))?);
    }
    Ok(pairs)
}

/// Count sessions that carry usable raw/corrected data, for the empty-state
/// message.
pub fn count_analyzable(db_path: &Path) -> usize {
    rusqlite::Connection::open_with_flags(db_path, rusqlite::OpenFlags::SQLITE_OPEN_READ_ONLY)
        .ok()
        .and_then(|conn| {
            conn.query_row(
                "SELECT COUNT(*) FROM sessions WHERE asr_text IS NOT NULL",
                [],
                |row| row.get::<_, usize>(0),
            )
            .ok()
        })
        .unwrap_or(0)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn rep(asr: &str, corrected: &str) -> Vec<Replacement> {
        replacements(asr, corrected)
    }

    #[test]
    fn extracts_simple_substitution() {
        let r = rep("安色皮克发布了新模型", "Anthropic 发布了新模型");
        assert_eq!(r.len(), 1);
        assert_eq!(r[0].asr, "安色皮克");
        assert_eq!(r[0].corrected, "Anthropic");
    }

    #[test]
    fn preserves_hyphens_and_case_from_original() {
        let r = rep("用夏尔巴 onnx 跑模型", "用 sherpa-onnx 跑模型");
        assert_eq!(r.len(), 1);
        assert_eq!(r[0].corrected, "sherpa-onnx");
    }

    #[test]
    fn case_only_change_is_not_a_replacement() {
        assert!(rep("deploy with cloudflare workers", "Deploy with Cloudflare Workers").is_empty());
    }

    #[test]
    fn punctuation_only_change_is_not_a_replacement() {
        assert!(rep("你好世界", "你好，世界。").is_empty());
    }

    #[test]
    fn filler_word_deletion_is_not_a_replacement() {
        // One-sided gap (deletion) — grammar cleanup, not vocabulary.
        assert!(rep("那个我们就是说开始吧", "我们开始吧").is_empty());
    }

    #[test]
    fn long_rewrite_is_filtered() {
        let r = Replacement {
            asr: "我想说的是这个东西大概可能也许行".into(),
            corrected: "这个方案经过评审后认为整体可行值得推进".into(),
            example: String::new(),
        };
        assert!(!is_candidate(&r));
    }

    #[test]
    fn distinctive_terms_detected() {
        assert!(is_distinctive("Anthropic"));
        assert!(is_distinctive("sherpa-onnx"));
        assert!(is_distinctive("GPT4"));
        assert!(is_distinctive("K8s"));
        assert!(!is_distinctive("banana"));
        assert!(!is_distinctive("模型"));
    }

    #[test]
    fn aggregate_counts_and_filters_existing() {
        let reps = vec![
            Replacement { asr: "安色皮克".into(), corrected: "Anthropic".into(), example: "Anthropic 发布".into() },
            Replacement { asr: "安瑟皮克".into(), corrected: "Anthropic".into(), example: "用 Anthropic".into() },
            Replacement { asr: "踹了".into(), corrected: "Trae".into(), example: "Trae 编辑器".into() },
            Replacement { asr: "库背".into(), corrected: "Kube".into(), example: "Kube 部署".into() },
        ];
        let existing = vec!["Kube".to_string()];
        let suggestions = aggregate(reps, &existing, 2);
        assert_eq!(suggestions.len(), 1);
        assert_eq!(suggestions[0].term, "Anthropic");
        assert_eq!(suggestions[0].count, 2);
        assert_eq!(suggestions[0].asr_forms.len(), 2);
    }

    #[test]
    fn min_count_one_keeps_singletons() {
        let reps = vec![Replacement {
            asr: "踹了".into(),
            corrected: "Trae".into(),
            example: "Trae 编辑器".into(),
        }];
        let suggestions = aggregate(reps, &[], 1);
        assert_eq!(suggestions.len(), 1);
        assert_eq!(suggestions[0].term, "Trae");
        assert!(suggestions[0].distinctive);
    }

    #[test]
    fn end_of_string_substitution_extracted() {
        let r = rep("部署到弗塞尔", "部署到 Vercel");
        assert_eq!(r.len(), 1);
        assert_eq!(r[0].corrected, "Vercel");
    }
}
