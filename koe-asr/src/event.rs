/// Events emitted by an ASR provider during streaming recognition.
#[derive(Debug, Clone)]
pub enum AsrEvent {
    /// Connection established successfully.
    Connected,
    /// Interim (partial) recognition result — may change as more audio arrives.
    Interim(String),
    /// A confirmed sentence from two-pass recognition (definite=true).
    /// Higher accuracy than Interim when `enable_nonstream` is on.
    Definite(String),
    /// Final recognition result for the entire session.
    Final(String),
    /// Server-side error message.
    Error(String),
    /// Connection closed, optionally with provider-specific close details.
    Closed(Option<String>),
}
