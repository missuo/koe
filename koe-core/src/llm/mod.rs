#[cfg(feature = "mlx")]
pub mod mlx;
pub mod openai_compatible;

use crate::errors::Result;

/// Request for LLM text correction.
pub struct CorrectionRequest {
    pub asr_text: String,
    pub dictionary_entries: Vec<String>,
    pub system_prompt: String,
    pub user_prompt: String,
}

/// Trait for LLM correction providers.
#[async_trait::async_trait]
pub trait LlmProvider: Send {
    async fn correct(&self, request: &CorrectionRequest) -> Result<String>;
}
