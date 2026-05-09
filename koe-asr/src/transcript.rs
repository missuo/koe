/// Aggregates ASR interim, definite, and final results into a single final transcript.
/// Also collects interim revision history to help identify uncertain segments.
pub struct TranscriptAggregator {
    interim_text: String,
    definite_text: String,
    final_text: String,
    has_final: bool,
    has_definite: bool,
    interim_history: Vec<String>,
}

impl TranscriptAggregator {
    pub fn new() -> Self {
        Self {
            interim_text: String::new(),
            definite_text: String::new(),
            final_text: String::new(),
            has_final: false,
            has_definite: false,
            interim_history: Vec::new(),
        }
    }

    /// Update with an interim result (replaces previous interim).
    pub fn update_interim(&mut self, text: &str) {
        if !text.is_empty() {
            if self.interim_history.last().map(|s| s.as_str()) != Some(text) {
                self.interim_history.push(text.to_string());
            }
            self.interim_text = text.to_string();
        }
    }

    /// Live preview that combines committed final text with the in-progress
    /// interim. After a pause, providers like DoubaoIME emit `Interim` events
    /// containing only the new segment, so showing `interim_text` alone would
    /// hide previously-finalized sentences. Merge them with the same
    /// overlap-trimming logic used for final segments.
    pub fn live_preview(&self) -> String {
        if self.final_text.is_empty() {
            return self.interim_text.clone();
        }
        if self.interim_text.is_empty() {
            return self.final_text.clone();
        }
        if self.interim_text.starts_with(&self.final_text) {
            return self.interim_text.clone();
        }
        if self.final_text.starts_with(&self.interim_text) {
            return self.final_text.clone();
        }
        let overlap = longest_overlap(&self.final_text, &self.interim_text);
        let mut out = self.final_text.clone();
        out.push_str(&self.interim_text[overlap..]);
        out
    }

    /// Update with a definite result from two-pass recognition.
    pub fn update_definite(&mut self, text: &str) {
        if !text.is_empty() {
            self.has_definite = true;
            self.definite_text = text.to_string();
            log::info!("definite segment confirmed: {} chars", text.len());
        }
    }

    /// Update with a final result.
    ///
    /// Providers like DoubaoIME have ambiguous `Final` semantics: within a
    /// single utterance `Final` is the best full transcript so far, but after
    /// a speech pause the server starts a new segment and may either send only
    /// the new content or replay earlier content. Neither pure replace nor
    /// pure append is correct — we merge by prefix / suffix-overlap instead.
    pub fn update_final(&mut self, text: &str) {
        self.has_final = true;
        if text.is_empty() {
            return;
        }
        if self.final_text.is_empty() {
            self.final_text = text.to_string();
        } else if text.starts_with(&self.final_text) {
            // New final is a refreshed full transcript of the same utterance.
            self.final_text = text.to_string();
        } else if self.final_text.starts_with(text) {
            // Stale replay of earlier content — ignore.
            return;
        } else {
            // New segment: strip the longest overlap between the existing tail
            // and the incoming head so we don't duplicate boundary characters.
            let overlap = longest_overlap(&self.final_text, text);
            self.final_text.push_str(&text[overlap..]);
        }
        // The segment this interim was tracking is now finalized; clear it so
        // the next segment's live preview starts clean.
        self.interim_text.clear();
    }

    /// Get the best available text.
    /// Priority: final > definite > interim.
    pub fn best_text(&self) -> &str {
        if self.has_final && !self.final_text.is_empty() {
            &self.final_text
        } else if self.has_definite && !self.definite_text.is_empty() {
            &self.definite_text
        } else {
            &self.interim_text
        }
    }

    pub fn has_final_result(&self) -> bool {
        self.has_final
    }

    pub fn has_any_text(&self) -> bool {
        !self.final_text.is_empty()
            || !self.definite_text.is_empty()
            || !self.interim_text.is_empty()
    }

    /// Return the interim revision history.
    /// Keeps only the last `max_entries` to avoid bloating prompts.
    pub fn interim_history(&self, max_entries: usize) -> &[String] {
        let len = self.interim_history.len();
        if len <= max_entries {
            &self.interim_history
        } else {
            &self.interim_history[len - max_entries..]
        }
    }
}

impl Default for TranscriptAggregator {
    fn default() -> Self {
        Self::new()
    }
}

/// Longest k such that `tail.ends_with(&head[..k])`, aligned to char boundaries.
fn longest_overlap(tail: &str, head: &str) -> usize {
    let max = tail.len().min(head.len());
    let mut k = max;
    while k > 0 {
        if head.is_char_boundary(k)
            && tail.is_char_boundary(tail.len() - k)
            && tail.as_bytes()[tail.len() - k..] == head.as_bytes()[..k]
        {
            return k;
        }
        k -= 1;
    }
    0
}
