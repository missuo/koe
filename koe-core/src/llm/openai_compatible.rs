use crate::config::{LlmMaxTokenParameter, LlmNoReasoningControl, LlmProfileRuntimeConfig};
use crate::errors::{KoeError, Result};
use crate::llm::{CorrectionRequest, LlmProvider};
use reqwest::Client;
use serde_json::{json, Value};
use std::time::{Duration, Instant};
use urlencoding::encode;

pub const LLM_HTTP_POOL_IDLE_TIMEOUT: Duration = Duration::from_secs(90);

/// LLM provider compatible with the OpenAI chat completions API.
pub struct OpenAiCompatibleProvider {
    client: Client,
    base_url: String,
    chat_completions_path: String,
    api_key: String,
    model: String,
    temperature: f64,
    top_p: f64,
    max_output_tokens: u32,
    max_token_parameter: LlmMaxTokenParameter,
    no_reasoning_control: LlmNoReasoningControl,
}

impl OpenAiCompatibleProvider {
    #[allow(clippy::too_many_arguments)]
    pub fn new(
        client: Client,
        base_url: String,
        chat_completions_path: String,
        api_key: String,
        model: String,
        temperature: f64,
        top_p: f64,
        max_output_tokens: u32,
        max_token_parameter: LlmMaxTokenParameter,
        no_reasoning_control: LlmNoReasoningControl,
    ) -> Self {
        Self {
            client,
            base_url,
            chat_completions_path,
            api_key,
            model,
            temperature,
            top_p,
            max_output_tokens,
            max_token_parameter,
            no_reasoning_control,
        }
    }

    pub async fn warmup(&self) -> Result<()> {
        let model = encode(&self.model);
        let url = format!("{}/models/{}", self.base_url.trim_end_matches('/'), model);

        log::debug!("LLM warmup request to {url}");

        let mut builder = self.client.get(&url);
        if !self.api_key.is_empty() {
            builder = builder.header("Authorization", format!("Bearer {}", self.api_key));
        }
        let response = builder.send().await.map_err(|e| {
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

fn build_chat_completions_url(base_url: &str, chat_completions_path: &str) -> String {
    let base = base_url.trim_end_matches('/');
    let normalized_path = chat_completions_path.trim();
    let effective_path = if normalized_path.is_empty() {
        "/chat/completions"
    } else {
        normalized_path
    };
    let path = effective_path.trim_start_matches('/');
    format!("{base}/{path}")
}

fn build_models_url(base_url: &str) -> String {
    let base = base_url.trim_end_matches('/');
    format!("{base}/models")
}

fn parse_model_ids(response: &Value) -> Result<Vec<String>> {
    let data = response
        .get("data")
        .and_then(|value| value.as_array())
        .ok_or_else(|| KoeError::LlmFailed("missing data array in /models response".into()))?;

    let mut ids = Vec::new();
    for item in data {
        let Some(id) = item.get("id").and_then(|value| value.as_str()) else {
            continue;
        };
        let trimmed = id.trim();
        if trimmed.is_empty() {
            continue;
        }
        if !ids.iter().any(|existing| existing == trimmed) {
            ids.push(trimmed.to_string());
        }
    }
    Ok(ids)
}

pub async fn list_models(client: Client, base_url: &str, api_key: &str) -> Result<Vec<String>> {
    let url = build_models_url(base_url);
    log::debug!("LLM models request to {url}");

    let mut builder = client.get(&url);
    if !api_key.is_empty() {
        builder = builder.header("Authorization", format!("Bearer {}", api_key));
    }
    let response = builder.send().await.map_err(|e| {
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
        .map_err(|e| KoeError::LlmFailed(format!("parse /models response: {e}")))?;
    parse_model_ids(&json)
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

/// Test LLM connection using the exact same `correct()` code path as runtime.
/// Always returns elapsed time — even on timeout/error.
pub async fn test_correction(
    client: Client,
    profile: &LlmProfileRuntimeConfig,
    temperature: f64,
    top_p: f64,
    max_output_tokens: u32,
    system_prompt: &str,
    user_prompt: &str,
) -> (Result<String>, Duration) {
    let llm = OpenAiCompatibleProvider::new(
        client,
        profile.base_url.clone(),
        profile.chat_completions_path.clone(),
        profile.api_key.clone(),
        profile.model.clone(),
        temperature,
        top_p,
        max_output_tokens,
        profile.max_token_parameter,
        profile.no_reasoning_control,
    );

    let request = CorrectionRequest {
        asr_text: String::new(),
        dictionary_entries: vec![],
        system_prompt: system_prompt.to_string(),
        user_prompt: user_prompt.to_string(),
    };

    let start = Instant::now();
    let result = llm.correct(&request).await;
    (result, start.elapsed())
}

pub fn build_chat_completion_body(
    profile: &LlmProfileRuntimeConfig,
    temperature: f64,
    top_p: f64,
    max_output_tokens: u32,
    request: &CorrectionRequest,
) -> Value {
    let mut body = json!({
        "model": profile.model,
        "temperature": temperature,
        "top_p": top_p,
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
    let token_field_name = match profile.max_token_parameter {
        LlmMaxTokenParameter::MaxTokens => "max_tokens",
        LlmMaxTokenParameter::MaxCompletionTokens => "max_completion_tokens",
    };
    body[token_field_name] = json!(max_output_tokens);
    match profile.no_reasoning_control {
        LlmNoReasoningControl::ReasoningEffort => {
            if matches!(
                profile.max_token_parameter,
                LlmMaxTokenParameter::MaxCompletionTokens
            ) {
                body["reasoning_effort"] = json!("none");
            }
        }
        LlmNoReasoningControl::Thinking => {
            body["thinking"] = json!({"type": "disabled"});
        }
        LlmNoReasoningControl::None => {}
    }
    body
}

#[async_trait::async_trait]
impl LlmProvider for OpenAiCompatibleProvider {
    async fn correct(&self, request: &CorrectionRequest) -> Result<String> {
        let url = build_chat_completions_url(&self.base_url, &self.chat_completions_path);

        let profile = LlmProfileRuntimeConfig {
            id: String::new(),
            name: String::new(),
            provider: "openai".into(),
            base_url: self.base_url.clone(),
            api_key: self.api_key.clone(),
            model: self.model.clone(),
            chat_completions_path: self.chat_completions_path.clone(),
            max_token_parameter: self.max_token_parameter,
            no_reasoning_control: self.no_reasoning_control,
            mlx: Default::default(),
        };
        let body = build_chat_completion_body(
            &profile,
            self.temperature,
            self.top_p,
            self.max_output_tokens,
            request,
        );

        log::debug!("LLM request to {url}");

        let mut builder = self
            .client
            .post(&url)
            .header("Content-Type", "application/json")
            .json(&body);
        if !self.api_key.is_empty() {
            builder = builder.header("Authorization", format!("Bearer {}", self.api_key));
        }
        let response = builder.send().await.map_err(|e| {
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

#[cfg(test)]
mod tests {
    use super::*;
    use crate::config::{LlmMaxTokenParameter, LlmNoReasoningControl, LlmProfileRuntimeConfig};

    fn request() -> CorrectionRequest {
        CorrectionRequest {
            asr_text: "raw".into(),
            dictionary_entries: vec![],
            system_prompt: "system".into(),
            user_prompt: "user".into(),
        }
    }

    #[test]
    fn apfel_body_uses_max_tokens_without_reasoning_controls() {
        let profile = LlmProfileRuntimeConfig {
            id: "apfel".into(),
            name: "APFEL".into(),
            provider: "openai".into(),
            base_url: "http://127.0.0.1:11434/v1".into(),
            api_key: "".into(),
            model: "apple-foundationmodel".into(),
            chat_completions_path: "/chat/completions".into(),
            max_token_parameter: LlmMaxTokenParameter::MaxTokens,
            no_reasoning_control: LlmNoReasoningControl::None,
            mlx: Default::default(),
        };

        let body = build_chat_completion_body(&profile, 0.0, 1.0, 1024, &request());

        assert_eq!(body["model"], "apple-foundationmodel");
        assert_eq!(body["max_tokens"], 1024);
        assert!(body.get("max_completion_tokens").is_none());
        assert!(body.get("reasoning_effort").is_none());
        assert!(body.get("thinking").is_none());
    }

    #[test]
    fn openai_body_keeps_max_completion_tokens_and_reasoning_control() {
        let profile = LlmProfileRuntimeConfig {
            id: "openai".into(),
            name: "OpenAI".into(),
            provider: "openai".into(),
            base_url: "https://api.openai.com/v1".into(),
            api_key: "sk-test".into(),
            model: "gpt-5.4-nano".into(),
            chat_completions_path: "/chat/completions".into(),
            max_token_parameter: LlmMaxTokenParameter::MaxCompletionTokens,
            no_reasoning_control: LlmNoReasoningControl::ReasoningEffort,
            mlx: Default::default(),
        };

        let body = build_chat_completion_body(&profile, 0.0, 1.0, 1024, &request());

        assert_eq!(body["model"], "gpt-5.4-nano");
        assert_eq!(body["max_completion_tokens"], 1024);
        assert_eq!(body["reasoning_effort"], "none");
        assert!(body.get("max_tokens").is_none());
    }

    #[test]
    fn chat_completion_url_avoids_double_slashes() {
        let url = build_chat_completions_url("https://api.openai.com/v1/", "/chat/completions");
        assert_eq!(url, "https://api.openai.com/v1/chat/completions");
    }

    #[test]
    fn chat_completion_url_accepts_path_without_leading_slash() {
        let url = build_chat_completions_url("https://api.openai.com/v1", "chat/completions");
        assert_eq!(url, "https://api.openai.com/v1/chat/completions");
    }

    #[test]
    fn parse_model_ids_accepts_standard_openai_response() {
        let json = serde_json::json!({
            "data": [
                {"id": "gpt-5.4-mini"},
                {"id": "gpt-5.4-nano"}
            ]
        });
        let ids = parse_model_ids(&json).unwrap();
        assert_eq!(ids, vec!["gpt-5.4-mini", "gpt-5.4-nano"]);
    }

    #[test]
    fn parse_model_ids_allows_empty_data() {
        let json = serde_json::json!({
            "data": []
        });
        let ids = parse_model_ids(&json).unwrap();
        assert!(ids.is_empty());
    }

    #[test]
    fn parse_model_ids_rejects_missing_data() {
        let json = serde_json::json!({
            "object": "list"
        });
        let err = parse_model_ids(&json).unwrap_err();
        assert!(err
            .to_string()
            .contains("missing data array in /models response"));
    }
}
