use crate::errors::{KoeError, Result};
use crate::ffi::SPSessionMode;
use std::fmt;
use uuid::Uuid;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum SessionState {
    Idle,
    HotkeyDecisionPending,
    ConnectingAsr,
    RecordingHold,
    RecordingToggle,
    FinalizingAsr,
    Correcting,
    PreparingPaste,
    Pasting,
    RestoringClipboard,
    Completed,
    Failed,
}

impl fmt::Display for SessionState {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        let s = match self {
            SessionState::Idle => "idle",
            SessionState::HotkeyDecisionPending => "hotkey_decision_pending",
            SessionState::ConnectingAsr => "connecting_asr",
            SessionState::RecordingHold => "recording_hold",
            SessionState::RecordingToggle => "recording_toggle",
            SessionState::FinalizingAsr => "finalizing_asr",
            SessionState::Correcting => "correcting",
            SessionState::PreparingPaste => "preparing_paste",
            SessionState::Pasting => "pasting",
            SessionState::RestoringClipboard => "restoring_clipboard",
            SessionState::Completed => "completed",
            SessionState::Failed => "failed",
        };
        write!(f, "{s}")
    }
}

pub struct Session {
    pub id: String,
    pub mode: SPSessionMode,
    pub state: SessionState,
    pub frontmost_bundle_id: Option<String>,
    pub frontmost_pid: i32,
    pub asr_text: Option<String>,
    pub corrected_text: Option<String>,
    pub started_at: std::time::Instant,
}

impl Session {
    pub fn new(mode: SPSessionMode, frontmost_bundle_id: Option<String>, frontmost_pid: i32) -> Self {
        Self {
            id: Uuid::new_v4().to_string(),
            mode,
            state: SessionState::ConnectingAsr,
            frontmost_bundle_id,
            frontmost_pid,
            asr_text: None,
            corrected_text: None,
            started_at: std::time::Instant::now(),
        }
    }

    pub fn transition(&mut self, to: SessionState) -> Result<()> {
        if self.is_valid_transition(to) {
            log::debug!(
                "session {}: {} -> {}",
                self.id,
                self.state,
                to
            );
            self.state = to;
            Ok(())
        } else {
            Err(KoeError::SessionInvalidState {
                from: self.state.to_string(),
                action: format!("transition to {to}"),
            })
        }
    }

    fn is_valid_transition(&self, to: SessionState) -> bool {
        use SessionState::*;
        matches!(
            (self.state, to),
            (ConnectingAsr, RecordingHold)
                | (ConnectingAsr, RecordingToggle)
                | (ConnectingAsr, Failed)
                | (RecordingHold, FinalizingAsr)
                | (RecordingHold, Failed)
                | (RecordingToggle, FinalizingAsr)
                | (RecordingToggle, Failed)
                | (FinalizingAsr, Correcting)
                | (FinalizingAsr, Failed)
                | (Correcting, PreparingPaste)
                | (Correcting, Failed)
                | (PreparingPaste, Pasting)
                | (PreparingPaste, Failed)
                | (Pasting, RestoringClipboard)
                | (Pasting, Completed)
                | (Pasting, Failed)
                | (RestoringClipboard, Completed)
                | (RestoringClipboard, Failed)
                | (Completed, Idle)
                | (Failed, Idle)
        )
    }

    pub fn is_recording(&self) -> bool {
        matches!(
            self.state,
            SessionState::RecordingHold | SessionState::RecordingToggle
        )
    }

    pub fn elapsed_ms(&self) -> u64 {
        self.started_at.elapsed().as_millis() as u64
    }
}
