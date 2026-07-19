//! ASR benchmarking: run configured providers over a corpus of audio files
//! with reference transcripts, and report token error rates and latency.
//!
//! Corpus layout: a directory of audio files (anything ffmpeg can decode)
//! where each audio file has a sibling `.txt` reference transcript with the
//! same stem, e.g. `clip1.wav` + `clip1.txt`.

use std::path::{Path, PathBuf};
use std::time::Instant;

use koe_asr::{AsrEvent, TranscriptAggregator};
use koe_core::asr_factory;
use koe_core::config::Config;

pub struct CorpusEntry {
    pub audio: PathBuf,
    pub reference: String,
}

pub fn load_corpus(dir: &Path) -> Result<Vec<CorpusEntry>, String> {
    if !dir.is_dir() {
        return Err(format!("corpus directory not found: {}", dir.display()));
    }

    let mut entries = Vec::new();
    let mut skipped = Vec::new();
    let mut paths: Vec<PathBuf> = std::fs::read_dir(dir)
        .map_err(|e| format!("read corpus dir: {e}"))?
        .filter_map(|e| e.ok().map(|e| e.path()))
        .collect();
    paths.sort();

    for path in paths {
        let ext = path
            .extension()
            .and_then(|e| e.to_str())
            .unwrap_or("")
            .to_lowercase();
        if ext.is_empty() || ext == "txt" || ext == "md" || ext == "json" {
            continue;
        }
        let reference_path = path.with_extension("txt");
        if !reference_path.exists() {
            skipped.push(path);
            continue;
        }
        let reference = std::fs::read_to_string(&reference_path)
            .map_err(|e| format!("read {}: {e}", reference_path.display()))?
            .trim()
            .to_string();
        if reference.is_empty() {
            skipped.push(path);
            continue;
        }
        entries.push(CorpusEntry {
            audio: path,
            reference,
        });
    }

    for path in &skipped {
        eprintln!(
            "warning: skipping {} (missing or empty sibling .txt reference)",
            path.display()
        );
    }
    if entries.is_empty() {
        return Err(format!(
            "no benchmark entries in {} — expected audio files with sibling .txt references",
            dir.display()
        ));
    }
    Ok(entries)
}

// ─── Metrics ────────────────────────────────────────────────────────

/// Tokenize for error-rate computation: each CJK ideograph or kana character
/// is its own token (CER-style); alphanumeric runs form word tokens
/// (WER-style), lowercased. Punctuation and whitespace are separators.
/// For pure-English text this yields WER, for pure-Chinese CER, and a
/// uniform mixed token error rate for code-switched text.
pub use crate::text::tokenize;

#[derive(Debug, Clone, Copy, PartialEq, Eq, serde::Serialize)]
pub struct EditStats {
    pub substitutions: usize,
    pub insertions: usize,
    pub deletions: usize,
    pub reference_tokens: usize,
}

impl EditStats {
    pub fn edits(&self) -> usize {
        self.substitutions + self.insertions + self.deletions
    }

    /// Token error rate: edits / reference length. Can exceed 1.0.
    pub fn error_rate(&self) -> f64 {
        if self.reference_tokens == 0 {
            return if self.insertions > 0 { 1.0 } else { 0.0 };
        }
        self.edits() as f64 / self.reference_tokens as f64
    }
}

/// Levenshtein alignment between reference and hypothesis token sequences,
/// split into substitution/insertion/deletion counts.
pub fn token_errors(reference: &[String], hypothesis: &[String]) -> EditStats {
    let m = reference.len();
    let n = hypothesis.len();

    // dp[i][j] = min edits to turn reference[..i] into hypothesis[..j]
    let mut dp = vec![vec![0usize; n + 1]; m + 1];
    for (i, row) in dp.iter_mut().enumerate() {
        row[0] = i;
    }
    for j in 0..=n {
        dp[0][j] = j;
    }
    for i in 1..=m {
        for j in 1..=n {
            let sub_cost = usize::from(reference[i - 1] != hypothesis[j - 1]);
            dp[i][j] = (dp[i - 1][j - 1] + sub_cost)
                .min(dp[i - 1][j] + 1) // deletion
                .min(dp[i][j - 1] + 1); // insertion
        }
    }

    // Backtrack to attribute edit types
    let (mut i, mut j) = (m, n);
    let (mut subs, mut ins, mut dels) = (0usize, 0usize, 0usize);
    while i > 0 || j > 0 {
        if i > 0 && j > 0 {
            let sub_cost = usize::from(reference[i - 1] != hypothesis[j - 1]);
            if dp[i][j] == dp[i - 1][j - 1] + sub_cost {
                subs += sub_cost;
                i -= 1;
                j -= 1;
                continue;
            }
        }
        if i > 0 && dp[i][j] == dp[i - 1][j] + 1 {
            dels += 1;
            i -= 1;
        } else {
            ins += 1;
            j -= 1;
        }
    }

    EditStats {
        substitutions: subs,
        insertions: ins,
        deletions: dels,
        reference_tokens: m,
    }
}

// ─── Runner ─────────────────────────────────────────────────────────

#[derive(serde::Serialize)]
pub struct FileResult {
    pub file: String,
    pub hypothesis: String,
    pub stats: EditStats,
    pub audio_secs: f64,
    /// First audio byte sent → final result received.
    pub total_ms: u64,
    /// End of audio input → final result received.
    pub finalize_ms: u64,
    /// Connection setup time (not included in total_ms).
    pub connect_ms: u64,
}

#[derive(serde::Serialize)]
pub struct ProviderReport {
    pub provider: String,
    pub files: Vec<FileResult>,
    pub errors: Vec<String>,
}

impl ProviderReport {
    /// Micro-averaged token error rate across all files.
    pub fn overall_error_rate(&self) -> f64 {
        let edits: usize = self.files.iter().map(|f| f.stats.edits()).sum();
        let refs: usize = self.files.iter().map(|f| f.stats.reference_tokens).sum();
        if refs == 0 {
            return 0.0;
        }
        edits as f64 / refs as f64
    }

    pub fn mean_finalize_ms(&self) -> u64 {
        if self.files.is_empty() {
            return 0;
        }
        self.files.iter().map(|f| f.finalize_ms).sum::<u64>() / self.files.len() as u64
    }

    /// Real-time factor: processing wall time / audio duration (lower is better).
    pub fn mean_rtf(&self) -> f64 {
        let audio: f64 = self.files.iter().map(|f| f.audio_secs).sum();
        let wall: f64 = self.files.iter().map(|f| f.total_ms as f64 / 1000.0).sum();
        if audio == 0.0 {
            return 0.0;
        }
        wall / audio
    }
}

pub async fn run_provider(
    cfg: &Config,
    provider_name: &str,
    corpus: &[CorpusEntry],
    pcm_cache: &[(f64, Vec<u8>)],
) -> ProviderReport {
    let mut report = ProviderReport {
        provider: provider_name.to_string(),
        files: Vec::new(),
        errors: Vec::new(),
    };

    for (entry, (audio_secs, pcm)) in corpus.iter().zip(pcm_cache) {
        let file_name = entry
            .audio
            .file_name()
            .map(|n| n.to_string_lossy().to_string())
            .unwrap_or_else(|| entry.audio.display().to_string());
        eprintln!("  {file_name} ...");

        match transcribe_pcm(cfg, provider_name, pcm).await {
            Ok((hypothesis, total_ms, finalize_ms, connect_ms)) => {
                let stats = token_errors(&tokenize(&entry.reference), &tokenize(&hypothesis));
                report.files.push(FileResult {
                    file: file_name,
                    hypothesis,
                    stats,
                    audio_secs: *audio_secs,
                    total_ms,
                    finalize_ms,
                    connect_ms,
                });
            }
            Err(e) => report.errors.push(format!("{file_name}: {e}")),
        }
    }

    report
}

/// Run one PCM buffer through a fresh provider instance.
/// Returns (text, total_ms, finalize_ms, connect_ms).
async fn transcribe_pcm(
    cfg: &Config,
    provider_name: &str,
    pcm: &[u8],
) -> Result<(String, u64, u64, u64), String> {
    let (asr_config, mut asr) = asr_factory::create_asr_provider(cfg, provider_name, &[]);

    let connect_start = Instant::now();
    asr.connect(&asr_config)
        .await
        .map_err(|e| format!("connect: {e}"))?;
    let connect_ms = connect_start.elapsed().as_millis() as u64;

    // 20ms frames at 16kHz 16-bit mono, sent without realtime pacing.
    const CHUNK_SIZE: usize = 640;
    let send_start = Instant::now();
    for chunk in pcm.chunks(CHUNK_SIZE) {
        if let Err(e) = asr.send_audio(chunk).await {
            asr.close().await.ok();
            return Err(format!("send_audio: {e}"));
        }
    }
    if let Err(e) = asr.finish_input().await {
        asr.close().await.ok();
        return Err(format!("finish_input: {e}"));
    }
    let finalize_start = Instant::now();

    let mut aggregator = TranscriptAggregator::new();
    loop {
        match asr.next_event().await {
            Ok(AsrEvent::Interim(text)) => aggregator.update_interim(&text),
            Ok(AsrEvent::Definite(text)) => aggregator.update_definite(&text),
            Ok(AsrEvent::Final(text)) => {
                aggregator.update_final(&text);
                break;
            }
            Ok(AsrEvent::Error(msg)) => {
                asr.close().await.ok();
                return Err(format!("ASR error: {msg}"));
            }
            Ok(AsrEvent::Closed(_)) => break,
            Ok(_) => {}
            Err(e) => {
                asr.close().await.ok();
                return Err(format!("event: {e}"));
            }
        }
    }
    let total_ms = send_start.elapsed().as_millis() as u64;
    let finalize_ms = finalize_start.elapsed().as_millis() as u64;
    asr.close().await.ok();

    Ok((
        aggregator.best_text().to_string(),
        total_ms,
        finalize_ms,
        connect_ms,
    ))
}

// ─── Report rendering ───────────────────────────────────────────────

pub fn render_markdown(reports: &[ProviderReport]) -> String {
    let mut out = String::new();
    out.push_str("# Koe ASR Benchmark\n\n");
    out.push_str("## Summary\n\n");
    out.push_str("| Provider | Token error rate | Mean audio-end → final | Mean RTF | Files | Failures |\n");
    out.push_str("|---|---|---|---|---|---|\n");
    for r in reports {
        out.push_str(&format!(
            "| {} | {:.1}% | {} ms | {:.2} | {} | {} |\n",
            r.provider,
            r.overall_error_rate() * 100.0,
            r.mean_finalize_ms(),
            r.mean_rtf(),
            r.files.len(),
            r.errors.len(),
        ));
    }
    out.push_str(
        "\nToken error rate counts CJK characters and lowercase words as tokens \
         (WER for English, CER for Chinese, unified for mixed text). \
         RTF = processing wall time / audio duration; audio is streamed without \
         realtime pacing, so RTF is comparable across providers but not \
         identical to live-dictation latency.\n",
    );

    for r in reports {
        out.push_str(&format!("\n## {}\n\n", r.provider));
        if !r.files.is_empty() {
            out.push_str("| File | Error rate | S/I/D | Audio | Final latency |\n");
            out.push_str("|---|---|---|---|---|\n");
            for f in &r.files {
                out.push_str(&format!(
                    "| {} | {:.1}% | {}/{}/{} | {:.1}s | {} ms |\n",
                    f.file,
                    f.stats.error_rate() * 100.0,
                    f.stats.substitutions,
                    f.stats.insertions,
                    f.stats.deletions,
                    f.audio_secs,
                    f.finalize_ms,
                ));
            }
        }
        for e in &r.errors {
            out.push_str(&format!("\n- FAILED: {e}\n"));
        }
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    fn toks(items: &[&str]) -> Vec<String> {
        items.iter().map(|s| s.to_string()).collect()
    }

    #[test]
    fn tokenize_english_words() {
        assert_eq!(
            tokenize("Hello, World! don't stop"),
            toks(&["hello", "world", "don't", "stop"])
        );
    }

    #[test]
    fn tokenize_chinese_chars() {
        assert_eq!(tokenize("你好，世界。"), toks(&["你", "好", "世", "界"]));
    }

    #[test]
    fn tokenize_mixed_text() {
        assert_eq!(
            tokenize("用 Cloudflare 部署"),
            toks(&["用", "cloudflare", "部", "署"])
        );
    }

    #[test]
    fn perfect_match_has_zero_errors() {
        let r = toks(&["a", "b", "c"]);
        let stats = token_errors(&r, &r);
        assert_eq!(stats.edits(), 0);
        assert_eq!(stats.error_rate(), 0.0);
    }

    #[test]
    fn substitution_counted() {
        let stats = token_errors(&toks(&["a", "b", "c"]), &toks(&["a", "x", "c"]));
        assert_eq!(stats.substitutions, 1);
        assert_eq!(stats.insertions, 0);
        assert_eq!(stats.deletions, 0);
        assert!((stats.error_rate() - 1.0 / 3.0).abs() < 1e-9);
    }

    #[test]
    fn insertion_and_deletion_counted() {
        // hypothesis added one token
        let stats = token_errors(&toks(&["a", "b"]), &toks(&["a", "x", "b"]));
        assert_eq!(stats.insertions, 1);
        // hypothesis dropped one token
        let stats = token_errors(&toks(&["a", "b", "c"]), &toks(&["a", "c"]));
        assert_eq!(stats.deletions, 1);
    }

    #[test]
    fn empty_reference_with_hypothesis_is_full_error() {
        let stats = token_errors(&[], &toks(&["x"]));
        assert_eq!(stats.error_rate(), 1.0);
    }

    #[test]
    fn error_rate_can_exceed_one() {
        let stats = token_errors(&toks(&["a"]), &toks(&["x", "y", "z"]));
        assert!(stats.error_rate() > 1.0);
    }
}
