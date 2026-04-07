use std::ffi::{c_char, c_float, c_int, CStr, CString};
use std::time::Duration;

use crate::errors::{KoeError, Result};
use crate::llm::{CorrectionRequest, LlmProvider};

// ─── C FFI declarations (implemented in Swift KoeMLX package) ───────

extern "C" {
    fn koe_mlx_llm_generate(
        model_path: *const c_char,
        system_prompt: *const c_char,
        user_prompt: *const c_char,
        temperature: c_float,
        top_p: c_float,
        max_tokens: c_int,
    ) -> *mut c_char;
    fn koe_mlx_llm_free_string(ptr: *mut c_char);
}

// ─── Provider ───────────────────────────────────────────────────────

/// Local LLM correction provider using Apple MLX.
///
/// The actual inference runs in Swift (KoeMLX package). This Rust
/// provider bridges to it via C FFI functions exposed by `@_cdecl`.
pub struct MlxLlmProvider {
    model_path: String,
    temperature: f32,
    top_p: f32,
    max_tokens: i32,
    timeout: Duration,
}

impl MlxLlmProvider {
    pub fn new(
        model_path: String,
        temperature: f64,
        top_p: f64,
        max_tokens: u32,
        timeout_ms: u64,
    ) -> Self {
        Self {
            model_path,
            temperature: temperature as f32,
            top_p: top_p as f32,
            max_tokens: max_tokens as i32,
            timeout: Duration::from_millis(timeout_ms),
        }
    }
}

#[async_trait::async_trait]
impl LlmProvider for MlxLlmProvider {
    async fn correct(&self, request: &CorrectionRequest) -> Result<String> {
        let model_path = self.model_path.clone();
        let system_prompt = request.system_prompt.clone();
        let user_prompt = request.user_prompt.clone();
        let temperature = self.temperature;
        let top_p = self.top_p;
        let max_tokens = self.max_tokens;

        let blocking_future = tokio::task::spawn_blocking(move || {
            let c_model = CString::new(model_path)
                .map_err(|_| KoeError::LlmFailed("invalid model path".into()))?;
            let c_sys = CString::new(system_prompt)
                .map_err(|_| KoeError::LlmFailed("invalid system prompt".into()))?;
            let c_user = CString::new(user_prompt)
                .map_err(|_| KoeError::LlmFailed("invalid user prompt".into()))?;

            let ptr = unsafe {
                koe_mlx_llm_generate(
                    c_model.as_ptr(),
                    c_sys.as_ptr(),
                    c_user.as_ptr(),
                    temperature,
                    top_p,
                    max_tokens,
                )
            };

            if ptr.is_null() {
                return Err(KoeError::LlmFailed(
                    "MLX LLM generation returned null".into(),
                ));
            }

            let result = unsafe { CStr::from_ptr(ptr) }
                .to_str()
                .map(|s| s.to_string())
                .map_err(|e| KoeError::LlmFailed(format!("invalid UTF-8 from MLX LLM: {e}")));

            unsafe {
                koe_mlx_llm_free_string(ptr);
            }

            result
        });

        let result = tokio::time::timeout(self.timeout, blocking_future)
            .await
            .map_err(|_| KoeError::LlmTimeout)?
            .map_err(|e| KoeError::LlmFailed(format!("spawn_blocking: {e}")))?;

        // Apply the same output cleaning as the OpenAI provider
        let text = result?;
        let cleaned = text.trim();
        let cleaned = cleaned
            .strip_prefix('"')
            .and_then(|s| s.strip_suffix('"'))
            .unwrap_or(cleaned);
        let cleaned = cleaned
            .strip_prefix('\u{201c}')
            .and_then(|s| s.strip_suffix('\u{201d}'))
            .unwrap_or(cleaned);

        Ok(cleaned.to_string())
    }
}
