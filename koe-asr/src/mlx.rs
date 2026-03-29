use std::ffi::{c_char, c_void, CStr, CString};

use crate::config::AsrConfig;
use crate::error::{AsrError, Result};
use crate::event::AsrEvent;

// ─── C FFI declarations (implemented in Swift KoeMLX package, resolved at link time) ──

#[allow(dead_code)]
extern "C" {
    fn koe_mlx_load_model(model_path: *const c_char) -> i32;
    fn koe_mlx_start_session(
        language: *const c_char,
        delay_preset: *const c_char,
        callback: extern "C" fn(ctx: *mut c_void, event_type: i32, text: *const c_char),
        ctx: *mut c_void,
    ) -> i32;
    fn koe_mlx_feed_audio(samples: *const f32, count: u32);
    fn koe_mlx_stop();
    fn koe_mlx_cancel();
    fn koe_mlx_unload_model();
}

// ─── Event callback trampoline ───────────────────────────────────────

/// C callback that receives events from the Swift layer and forwards them
/// into a tokio mpsc channel. The `ctx` pointer is a leaked
/// `Box<tokio::sync::mpsc::Sender<AsrEvent>>`.
extern "C" fn mlx_event_trampoline(ctx: *mut c_void, event_type: i32, text: *const c_char) {
    let tx = unsafe { &*(ctx as *const tokio::sync::mpsc::Sender<AsrEvent>) };
    let text_str = if text.is_null() {
        String::new()
    } else {
        unsafe { CStr::from_ptr(text) }
            .to_str()
            .unwrap_or("")
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
    let _ = tx.try_send(event);
}

// ─── Provider ────────────────────────────────────────────────────────

/// Configuration for the MLX ASR provider.
#[derive(Debug, Clone)]
pub struct MlxConfig {
    /// Local model path (e.g. ~/.koe/models/mlx/Qwen3-ASR-0.6B-4bit)
    pub model_path: String,
    /// Language: "auto", "zh", "en"
    pub language: String,
    /// Delay preset: "realtime", "agent", "subtitle"
    pub delay_preset: String,
}

/// Local streaming ASR provider using Apple MLX.
///
/// The actual MLX inference runs in Swift (KoeMLX package). This Rust
/// provider bridges to it via C FFI functions exposed by `@_cdecl`.
pub struct MlxProvider {
    config: MlxConfig,
    event_rx: Option<tokio::sync::mpsc::Receiver<AsrEvent>>,
    /// Leaked sender pointer passed as callback context.
    /// Reclaimed in close()/drop.
    event_tx_ptr: Option<*mut c_void>,
}

// Safety: The raw pointer is only accessed from the callback (which is Send)
// and from close()/drop (which takes &mut self).
unsafe impl Send for MlxProvider {}

impl MlxProvider {
    pub fn new(config: MlxConfig) -> Self {
        Self {
            config,
            event_rx: None,
            event_tx_ptr: None,
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
}

#[async_trait::async_trait]
impl crate::provider::AsrProvider for MlxProvider {
    // Local provider: configuration is passed via `new()`, not through AsrConfig.
    // The `_config` parameter is unused here.
    async fn connect(&mut self, _config: &AsrConfig) -> Result<()> {
        let model_path = CString::new(self.config.model_path.clone())
            .map_err(|_| AsrError::Connection("invalid model path".into()))?;

        let ret = unsafe { koe_mlx_load_model(model_path.as_ptr()) };
        if ret != 0 {
            return Err(AsrError::Connection(format!(
                "failed to load MLX model (code {ret}): {}",
                self.config.model_path
            )));
        }

        // Create event channel
        let (tx, rx) = tokio::sync::mpsc::channel::<AsrEvent>(256);
        self.event_rx = Some(rx);

        // Leak sender into a raw pointer for the C callback context
        let tx_box = Box::new(tx);
        let tx_ptr = Box::into_raw(tx_box) as *mut c_void;
        self.event_tx_ptr = Some(tx_ptr);

        // Start streaming session
        let language = CString::new(self.config.language.clone()).unwrap_or_default();
        let delay_preset = CString::new(self.config.delay_preset.clone()).unwrap_or_default();

        let ret = unsafe {
            koe_mlx_start_session(
                language.as_ptr(),
                delay_preset.as_ptr(),
                mlx_event_trampoline,
                tx_ptr,
            )
        };
        if ret != 0 {
            self.reclaim_sender();
            return Err(AsrError::Connection(format!(
                "failed to start MLX session (code {ret})"
            )));
        }

        Ok(())
    }

    async fn send_audio(&mut self, frame: &[u8]) -> Result<()> {
        let samples: Vec<f32> = frame
            .chunks_exact(2)
            .map(|c| i16::from_le_bytes([c[0], c[1]]) as f32 / 32768.0)
            .collect();

        unsafe {
            koe_mlx_feed_audio(samples.as_ptr(), samples.len() as u32);
        }
        Ok(())
    }

    async fn finish_input(&mut self) -> Result<()> {
        unsafe {
            koe_mlx_stop();
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
        unsafe {
            koe_mlx_cancel();
        }
        self.event_rx = None;
        self.reclaim_sender();
        Ok(())
    }
}

impl Drop for MlxProvider {
    fn drop(&mut self) {
        self.reclaim_sender();
    }
}
