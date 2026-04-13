use std::time::Instant;

/// Metrics collected for each session.
pub struct SessionMetrics {
    pub session_id: String,
    pub hotkey_start: Option<Instant>,
    pub hotkey_end: Option<Instant>,
    pub asr_connect_start: Option<Instant>,
    pub asr_connected: Option<Instant>,
    pub asr_final_received: Option<Instant>,
    pub llm_start: Option<Instant>,
    pub llm_end: Option<Instant>,
    pub paste_done: Option<Instant>,
    pub clipboard_restored: Option<Instant>,
    pub error_type: Option<String>,
    pub auto_pasted: bool,
}

impl SessionMetrics {
    pub fn new(session_id: &str) -> Self {
        Self {
            session_id: session_id.to_string(),
            hotkey_start: None,
            hotkey_end: None,
            asr_connect_start: None,
            asr_connected: None,
            asr_final_received: None,
            llm_start: None,
            llm_end: None,
            paste_done: None,
            clipboard_restored: None,
            error_type: None,
            auto_pasted: false,
        }
    }

    fn duration_ms(start: Option<Instant>, end: Option<Instant>) -> Option<u64> {
        match (start, end) {
            (Some(s), Some(e)) => Some(e.duration_since(s).as_millis() as u64),
            _ => None,
        }
    }

    pub fn recording_duration_ms(&self) -> Option<u64> {
        Self::duration_ms(self.hotkey_start, self.hotkey_end)
    }

    pub fn asr_connect_duration_ms(&self) -> Option<u64> {
        Self::duration_ms(self.asr_connect_start, self.asr_connected)
    }

    pub fn asr_finalize_duration_ms(&self) -> Option<u64> {
        Self::duration_ms(self.hotkey_end, self.asr_final_received)
    }

    pub fn llm_duration_ms(&self) -> Option<u64> {
        Self::duration_ms(self.llm_start, self.llm_end)
    }

    pub fn summary(&self) -> String {
        format!(
            "session={} recording={}ms asr_connect={}ms asr_finalize={}ms llm={}ms pasted={} error={:?}",
            self.session_id,
            self.recording_duration_ms().map_or("?".into(), |v| v.to_string()),
            self.asr_connect_duration_ms().map_or("?".into(), |v| v.to_string()),
            self.asr_finalize_duration_ms().map_or("?".into(), |v| v.to_string()),
            self.llm_duration_ms().map_or("?".into(), |v| v.to_string()),
            self.auto_pasted,
            self.error_type,
        )
    }
}

pub fn init_logging() {
    let _ = env_logger::Builder::from_env(
        env_logger::Env::default().default_filter_or("info"),
    )
    .try_init();
}
