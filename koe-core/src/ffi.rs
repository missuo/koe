use std::ffi::{c_char, c_int, CStr, CString};
use std::sync::Mutex;

/// Session mode: Hold (long press) or Toggle (tap)
#[repr(C)]
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum SPSessionMode {
    Hold = 0,
    Toggle = 1,
}

/// Context passed when beginning a session
#[repr(C)]
pub struct SPSessionContext {
    pub mode: SPSessionMode,
    /// Frontmost app bundle ID (UTF-8 C string, nullable)
    pub frontmost_bundle_id: *const c_char,
    /// Frontmost app PID
    pub frontmost_pid: c_int,
}

/// Callback function types that Obj-C registers with Rust
#[repr(C)]
pub struct SPCallbacks {
    /// Called when a session is ready (recording can begin)
    pub on_session_ready: Option<extern "C" fn()>,
    /// Called when a session encounters an error
    /// message is a UTF-8 C string, caller must NOT free it
    pub on_session_error: Option<extern "C" fn(message: *const c_char)>,
    /// Called for non-fatal warnings that should be shown to the user
    /// message is a UTF-8 C string, caller must NOT free it
    pub on_session_warning: Option<extern "C" fn(message: *const c_char)>,
    /// Called when the final corrected text is ready
    /// text is a UTF-8 C string, caller must NOT free it
    pub on_final_text_ready: Option<extern "C" fn(text: *const c_char)>,
    /// Called for log events
    /// level: 0=error, 1=warn, 2=info, 3=debug
    pub on_log_event: Option<extern "C" fn(level: c_int, message: *const c_char)>,
    /// Called when session state changes (for status bar updates)
    /// state is a UTF-8 C string representing the state name
    pub on_state_changed: Option<extern "C" fn(state: *const c_char)>,
}

static CALLBACKS: Mutex<Option<SPCallbacks>> = Mutex::new(None);

pub fn register_callbacks(callbacks: SPCallbacks) {
    let mut cb = CALLBACKS.lock().unwrap();
    *cb = Some(callbacks);
}

pub fn invoke_session_ready() {
    let cb = CALLBACKS.lock().unwrap();
    if let Some(ref cbs) = *cb {
        if let Some(f) = cbs.on_session_ready {
            f();
        }
    }
}

pub fn invoke_session_error(message: &str) {
    let cb = CALLBACKS.lock().unwrap();
    if let Some(ref cbs) = *cb {
        if let Some(f) = cbs.on_session_error {
            let c_msg = CString::new(message).unwrap_or_default();
            f(c_msg.as_ptr());
        }
    }
}

pub fn invoke_session_warning(message: &str) {
    let cb = CALLBACKS.lock().unwrap();
    if let Some(ref cbs) = *cb {
        if let Some(f) = cbs.on_session_warning {
            let c_msg = CString::new(message).unwrap_or_default();
            f(c_msg.as_ptr());
        }
    }
}

pub fn invoke_final_text_ready(text: &str) {
    let cb = CALLBACKS.lock().unwrap();
    if let Some(ref cbs) = *cb {
        if let Some(f) = cbs.on_final_text_ready {
            let c_text = CString::new(text).unwrap_or_default();
            f(c_text.as_ptr());
        }
    }
}

pub fn invoke_log_event(level: i32, message: &str) {
    let cb = CALLBACKS.lock().unwrap();
    if let Some(ref cbs) = *cb {
        if let Some(f) = cbs.on_log_event {
            let c_msg = CString::new(message).unwrap_or_default();
            f(level as c_int, c_msg.as_ptr());
        }
    }
}

pub fn invoke_state_changed(state: &str) {
    let cb = CALLBACKS.lock().unwrap();
    if let Some(ref cbs) = *cb {
        if let Some(f) = cbs.on_state_changed {
            let c_state = CString::new(state).unwrap_or_default();
            f(c_state.as_ptr());
        }
    }
}

/// Feedback configuration exposed to the Obj-C layer
#[repr(C)]
#[derive(Debug, Clone, Copy)]
pub struct SPFeedbackConfig {
    pub start_sound: bool,
    pub stop_sound: bool,
    pub error_sound: bool,
}

/// Hotkey configuration exposed to the Obj-C layer
#[repr(C)]
#[derive(Debug, Clone, Copy)]
pub struct SPHotkeyConfig {
    /// Primary key code (e.g. 63 for Fn, 58 for Left Option)
    pub key_code: u16,
    /// Alternative key code (e.g. 179 for Globe key), 0 if none
    pub alt_key_code: u16,
    /// Modifier flag to check (e.g. 0x800000 for Fn)
    pub modifier_flag: u64,
}

/// Helper to convert a C string pointer to a Rust &str
///
/// # Safety
/// The pointer must be valid and null-terminated UTF-8.
pub unsafe fn cstr_to_str<'a>(ptr: *const c_char) -> Option<&'a str> {
    if ptr.is_null() {
        return None;
    }
    unsafe { CStr::from_ptr(ptr) }.to_str().ok()
}
