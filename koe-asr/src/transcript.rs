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
            return;
        }
        if text.starts_with(&self.final_text) {
            // New final is a refreshed full transcript of the same utterance.
            self.final_text = text.to_string();
            return;
        }
        if self.final_text.starts_with(text) {
            // Stale replay of earlier content — ignore.
            return;
        }
        // New segment: strip the longest overlap between the existing tail and
        // the incoming head so we don't duplicate the boundary characters.
        let overlap = longest_overlap(&self.final_text, text);
        self.final_text.push_str(&text[overlap..]);
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
        if head.is_char_boundary(k) && tail.is_char_boundary(tail.len() - k) && tail.as_bytes()[tail.len() - k..] == head.as_bytes()[..k] {
            return k;
        }
        k -= 1;
    }
    0
}
