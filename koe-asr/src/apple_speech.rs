use std::ffi::{c_char, c_void, CStr, CString};

use crate::config::AsrConfig;
use crate::error::{AsrError, Result};
use crate::event::AsrEvent;

// ─── C FFI declarations (implemented in Swift KoeAppleSpeech package, resolved at link time) ──

extern "C" {
    /// Returns session generation (>0) on success, 0 on failure.
    fn koe_apple_speech_start_session(
        locale: *const c_char,
        contextual_strings: *const u8,
        contextual_strings_len: u32,
        callback: extern "C" fn(ctx: *mut c_void, event_type: i32, text: *const c_char),
        ctx: *mut c_void,
    ) -> u64;
    fn koe_apple_speech_feed_audio(bytes: *const u8, count: u32, generation: u64);
    fn koe_apple_speech_stop(generation: u64);
    fn koe_apple_speech_cancel(generation: u64);
}

// ─── Event callback trampoline ───────────────────────────────────────

/// C callback that receives events from the Swift layer and forwards them
/// into a tokio mpsc channel. The `ctx` pointer is a leaked
/// `Box<tokio::sync::mpsc::Sender<AsrEvent>>`.
extern "C" fn apple_speech_event_trampoline(
    ctx: *mut c_void,
    event_type: i32,
    text: *const c_char,
) {
    let tx = unsafe { &*(ctx as *const tokio::sync::mpsc::Sender<AsrEvent>) };
    let text_str = if text.is_null() {
        String::new()
    } else {
        unsafe { CStr::from_ptr(text) }
            .to_str()
            .unwrap_or_else(|e| {
                log::warn!("Apple Speech: invalid UTF-8 in event text: {e}");
                ""
            })
            .to_string()
    };
    let event = match event_type {
        0 => AsrEvent::Interim(text_str),
        1 => AsrEvent::Definite(text_str),
        2 => AsrEvent::Final(text_str),
        3 => AsrEvent::Error(text_str),
        4 => AsrEvent::Connected,
        5 => AsrEvent::Closed,
        _ => return,
    };
    if let Err(e) = tx.try_send(event) {
        log::warn!("Apple Speech event dropped: {e}");
    }
}

// ─── Provider ────────────────────────────────────────────────────────

/// Configuration for the Apple Speech ASR provider.
#[derive(Debug, Clone)]
pub struct AppleSpeechConfig {
    /// Locale identifier (e.g. "zh_CN", "en_US")
    pub locale: String,
    /// Dictionary entries to pass as contextual strings for vocabulary bias
    pub contextual_strings: Vec<String>,
}

/// On-device streaming ASR provider using Apple's Speech framework.
///
/// Uses SpeechAnalyzer + SpeechTranscriber (macOS 26+). The actual
/// recognition runs in Swift (KoeAppleSpeech package). This Rust
/// provider bridges to it via C FFI functions exposed by `@_cdecl`.
pub struct AppleSpeechProvider {
    config: AppleSpeechConfig,
    event_rx: Option<tokio::sync::mpsc::Receiver<AsrEvent>>,
    /// Leaked sender pointer passed as callback context.
    /// Reclaimed in close()/drop.
    event_tx_ptr: Option<*mut c_void>,
    /// Session generation returned by the Swift singleton.
    /// Passed to all subsequent FFI calls so stale operations from an old
    /// provider are ignored when a new session has already started.
    session_generation: u64,
}

// Safety: The raw pointer is only accessed from the callback (which is Send)
// and from close()/drop (which takes &mut self).
unsafe impl Send for AppleSpeechProvider {}

impl AppleSpeechProvider {
    pub fn new(config: AppleSpeechConfig) -> Self {
        Self {
            config,
            event_rx: None,
            event_tx_ptr: None,
            session_generation: 0,
        }
    }

    /// Reclaim the leaked sender to avoid memory leak.
    fn reclaim_sender(&mut self) {
        if let Some(ptr) = self.event_tx_ptr.take() {
            unsafe {
                drop(Box::from_raw(
                    ptr as *mut tokio::sync::mpsc::Sender<AsrEvent>,
                ));
            }
        }
    }

    /// Serialize contextual strings as a null-separated byte blob for FFI.
    fn serialize_contextual_strings(strings: &[String]) -> Vec<u8> {
        let mut blob = Vec::new();
        for (i, s) in strings.iter().enumerate() {
            if i > 0 {
                blob.push(0); // null separator
            }
            blob.extend_from_slice(s.as_bytes());
        }
        blob
    }
}

#[async_trait::async_trait]
impl crate::provider::AsrProvider for AppleSpeechProvider {
    async fn connect(&mut self, _config: &AsrConfig) -> Result<()> {
        let locale = CString::new(self.config.locale.clone())
            .map_err(|_| AsrError::Connection("invalid locale string".into()))?;

        let ctx_strings_blob =
            Self::serialize_contextual_strings(&self.config.contextual_strings);

        // Create event channel
        let (tx, rx) = tokio::sync::mpsc::channel::<AsrEvent>(256);
        self.event_rx = Some(rx);

        // Leak sender into a raw pointer for the C callback context
        let tx_box = Box::new(tx);
        let tx_ptr = Box::into_raw(tx_box) as *mut c_void;
        self.event_tx_ptr = Some(tx_ptr);

        let gen = unsafe {
            koe_apple_speech_start_session(
                locale.as_ptr(),
                if ctx_strings_blob.is_empty() {
                    std::ptr::null()
                } else {
                    ctx_strings_blob.as_ptr()
                },
                ctx_strings_blob.len() as u32,
                apple_speech_event_trampoline,
                tx_ptr,
            )
        };
        if gen == 0 {
            // Drain any error events sent by Swift before returning failure
            let detail = self.event_rx.as_mut().and_then(|rx| {
                while let Ok(event) = rx.try_recv() {
                    if let AsrEvent::Error(msg) = event {
                        return Some(msg);
                    }
                }
                None
            });
            self.reclaim_sender();
            self.event_rx = None;
            return Err(AsrError::Connection(
                detail.unwrap_or_else(|| "failed to start Apple Speech session".into()),
            ));
        }
        self.session_generation = gen;

        Ok(())
    }

    async fn send_audio(&mut self, frame: &[u8]) -> Result<()> {
        // Pass raw PCM16 LE bytes directly; Swift side converts to Float32
        unsafe {
            koe_apple_speech_feed_audio(frame.as_ptr(), frame.len() as u32, self.session_generation);
        }
        Ok(())
    }

    async fn finish_input(&mut self) -> Result<()> {
        unsafe {
            koe_apple_speech_stop(self.session_generation);
        }
        Ok(())
    }

    async fn next_event(&mut self) -> Result<AsrEvent> {
        if let Some(ref mut rx) = self.event_rx {
            rx.recv()
                .await
                .ok_or(AsrError::Connection("event channel closed".into()))
        } else {
            Err(AsrError::Connection("not connected".into()))
        }
    }

    async fn close(&mut self) -> Result<()> {
        // SAFETY: koe_apple_speech_cancel() synchronously clears the callback
        // context on the Swift side (under a lock), ensuring no further calls
        // through the callback pointer after this returns.
        // The generation parameter ensures that if a new session has already
        // started on the singleton, this stale cancel is a no-op.
        unsafe {
            koe_apple_speech_cancel(self.session_generation);
        }
        self.event_rx = None;
        self.reclaim_sender();
        Ok(())
    }
}

impl Drop for AppleSpeechProvider {
    fn drop(&mut self) {
        self.reclaim_sender();
    }
}
