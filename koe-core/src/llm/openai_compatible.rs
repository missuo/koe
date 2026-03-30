use crate::config::LlmMaxTokenParameter;
use crate::errors::{KoeError, Result};
use crate::llm::{CorrectionRequest, LlmProvider};
use reqwest::Client;
use serde_json::{json, Value};
use std::time::Duration;
use urlencoding::encode;

pub const LLM_HTTP_POOL_IDLE_TIMEOUT: Duration = Duration::from_secs(90);

/// LLM provider compatible with the OpenAI chat completions API.
pub struct OpenAiCompatibleProvider {
    client: Client,
    base_url: String,
    api_key: String,
    model: String,
    temperature: f64,
    top_p: f64,
    max_output_tokens: u32,
    max_token_parameter: LlmMaxTokenParameter,
}

impl OpenAiCompatibleProvider {
    #[allow(clippy::too_many_arguments)]
    pub fn new(
        client: Client,
        base_url: String,
        api_key: String,
        model: String,
        temperature: f64,
        top_p: f64,
        max_output_tokens: u32,
        max_token_parameter: LlmMaxTokenParameter,
    ) -> Self {
        Self {
            client,
            base_url,
            api_key,
            model,
            temperature,
            top_p,
            max_output_tokens,
            max_token_parameter,
        }
    }

    pub async fn warmup(&self) -> Result<()> {
        let model = encode(&self.model);
        let url = format!("{}/models/{}", self.base_url.trim_end_matches('/'), model);

        log::debug!("LLM warmup request to {url}");

        let response = self
            .client
            .get(&url)
            .header("Authorization", format!("Bearer {}", self.api_key))
            .send()
            .await
            .map_err(|e| {
                if e.is_timeout() {
                    KoeError::LlmTimeout
                } else {
                    KoeError::LlmFailed(e.to_string())
                }
            })?;

        let status = response.status();
        match response.bytes().await {
            Ok(_) => {
                if !status.is_success() {
                    log::debug!("LLM warmup completed with HTTP {status}");
                }
                Ok(())
            }
            Err(e) => Err(KoeError::LlmFailed(format!(
                "warmup read response body: {e}"
            ))),
        }
    }
}

pub fn build_http_client(timeout_ms: u64) -> std::result::Result<Client, reqwest::Error> {
    Client::builder()
        .timeout(Duration::from_millis(timeout_ms))
        .pool_idle_timeout(LLM_HTTP_POOL_IDLE_TIMEOUT)
        .pool_max_idle_per_host(2)
        .tcp_keepalive(Some(Duration::from_secs(30)))
        .http2_keep_alive_interval(Duration::from_secs(30))
        .http2_keep_alive_timeout(Duration::from_secs(30))
        .http2_keep_alive_while_idle(true)
        .build()
}

impl LlmProvider for OpenAiCompatibleProvider {
    async fn correct(&self, request: &CorrectionRequest) -> Result<String> {
        let url = format!("{}/chat/completions", self.base_url.trim_end_matches('/'));

        let mut body = json!({
            "model": self.model,
            "temperature": self.temperature,
            "top_p": self.top_p,
            "messages": [
                {
                    "role": "system",
                    "content": request.system_prompt,
                },
                {
                    "role": "user",
                    "content": request.user_prompt,
                }
            ]
        });
        let token_field_name = match self.max_token_parameter {
            LlmMaxTokenParameter::MaxTokens => "max_tokens",
            LlmMaxTokenParameter::MaxCompletionTokens => "max_completion_tokens",
        };
        body[token_field_name] = json!(self.max_output_tokens);
        if matches!(
            self.max_token_parameter,
            LlmMaxTokenParameter::MaxCompletionTokens
        ) {
            body["reasoning_effort"] = json!("none");
        }

        log::debug!("LLM request to {url}");

        let response = self
            .client
            .post(&url)
            .header("Authorization", format!("Bearer {}", self.api_key))
            .header("Content-Type", "application/json")
            .json(&body)
            .send()
            .await
            .map_err(|e| {
                if e.is_timeout() {
                    KoeError::LlmTimeout
                } else {
                    KoeError::LlmFailed(e.to_string())
                }
            })?;

        if !response.status().is_success() {
            let status = response.status();
            let text = response.text().await.unwrap_or_default();
            return Err(KoeError::LlmFailed(format!("HTTP {status}: {text}")));
        }

        let json: Value = response
            .json()
            .await
            .map_err(|e| KoeError::LlmFailed(format!("parse response: {e}")))?;

        let content = json
            .get("choices")
            .and_then(|c| c.get(0))
            .and_then(|c| c.get("message"))
            .and_then(|m| m.get("content"))
            .and_then(|c| c.as_str())
            .ok_or_else(|| KoeError::LlmFailed("missing content in response".into()))?;

        // Basic output cleaning: trim whitespace, remove wrapping quotes
        let cleaned = content.trim();
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
