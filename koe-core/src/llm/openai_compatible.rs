use crate::config::{
    LlmApiProtocol, LlmMaxTokenParameter, LlmNoReasoningControl, LlmProfileRuntimeConfig,
};
use crate::errors::{KoeError, Result};
use crate::llm::{CorrectionRequest, LlmProvider};
use reqwest::{Client, RequestBuilder};
use serde_json::{json, Value};
use std::time::{Duration, Instant};
use urlencoding::encode;

pub const LLM_HTTP_POOL_IDLE_TIMEOUT: Duration = Duration::from_secs(90);

/// Remote LLM provider supporting OpenAI Chat Completions, OpenAI Responses,
/// and Anthropic Messages wire protocols.
pub struct OpenAiCompatibleProvider {
    client: Client,
    profile: LlmProfileRuntimeConfig,
    temperature: f64,
    top_p: f64,
    max_output_tokens: u32,
}

impl OpenAiCompatibleProvider {
    pub fn from_profile(
        client: Client,
        profile: LlmProfileRuntimeConfig,
        temperature: f64,
        top_p: f64,
        max_output_tokens: u32,
    ) -> Self {
        Self {
            client,
            profile,
            temperature,
            top_p,
            max_output_tokens,
        }
    }

    pub async fn warmup(&self) -> Result<()> {
        let model = encode(&self.profile.model);
        let url = format!(
            "{}/models/{}",
            self.profile.base_url.trim_end_matches('/'),
            model
        );

        log::debug!("LLM warmup request to {url}");

        let builder = authenticate_request(self.client.get(&url), &self.profile);
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

fn authentication_headers(profile: &LlmProfileRuntimeConfig) -> Vec<(&'static str, String)> {
    let mut headers = Vec::new();
    if profile.effective_api_protocol() == LlmApiProtocol::AnthropicMessages {
        headers.push(("anthropic-version", "2023-06-01".into()));
        if !profile.api_key.is_empty() {
            headers.push(("x-api-key", profile.api_key.clone()));
        }
    } else if !profile.api_key.is_empty() {
        headers.push(("Authorization", format!("Bearer {}", profile.api_key)));
    }
    headers
}

fn authenticate_request(
    mut builder: RequestBuilder,
    profile: &LlmProfileRuntimeConfig,
) -> RequestBuilder {
    for (name, value) in authentication_headers(profile) {
        builder = builder.header(name, value);
    }
    builder
}

fn build_endpoint_url(base_url: &str, endpoint_path: &str, protocol: LlmApiProtocol) -> String {
    let base = base_url.trim_end_matches('/');
    let normalized_path = endpoint_path.trim();
    let effective_path = if normalized_path.is_empty() {
        protocol.default_endpoint_path()
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
    let profile = LlmProfileRuntimeConfig {
        id: String::new(),
        name: String::new(),
        provider: "openai".into(),
        api_protocol: LlmApiProtocol::OpenaiChat,
        base_url: base_url.into(),
        api_key: api_key.into(),
        model: String::new(),
        endpoint_path: String::new(),
        max_token_parameter: LlmMaxTokenParameter::MaxCompletionTokens,
        no_reasoning_control: LlmNoReasoningControl::None,
        mlx: Default::default(),
    };
    list_models_for_profile(client, &profile).await
}

pub async fn list_models_for_profile(
    client: Client,
    profile: &LlmProfileRuntimeConfig,
) -> Result<Vec<String>> {
    let mut url = build_models_url(&profile.base_url);
    if profile.effective_api_protocol() == LlmApiProtocol::AnthropicMessages {
        url.push_str("?limit=1000");
    }
    log::debug!("LLM models request to {url}");

    let builder = authenticate_request(client.get(&url), profile);
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
    let llm = OpenAiCompatibleProvider::from_profile(
        client,
        profile.clone(),
        temperature,
        top_p,
        max_output_tokens,
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

    // Legacy/non-reasoning Chat endpoints commonly accept sampling controls.
    // Reasoning models use max_completion_tokens and frequently reject these
    // fields, so omit them there to keep the common request compatible across
    // the full OpenAI model family.
    if matches!(profile.max_token_parameter, LlmMaxTokenParameter::MaxTokens) {
        body["temperature"] = json!(temperature);
        body["top_p"] = json!(top_p);
    }
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

pub fn build_responses_body(
    profile: &LlmProfileRuntimeConfig,
    max_output_tokens: u32,
    request: &CorrectionRequest,
) -> Value {
    let mut body = json!({
        "model": profile.model,
        "instructions": request.system_prompt,
        "input": request.user_prompt,
        "max_output_tokens": max_output_tokens,
        // Correction requests are independent and contain user dictation;
        // do not retain server-side response state by default.
        "store": false,
    });
    if matches!(
        profile.no_reasoning_control,
        LlmNoReasoningControl::ReasoningEffort
    ) {
        body["reasoning"] = json!({"effort": "none"});
    }
    body
}

pub fn build_anthropic_messages_body(
    profile: &LlmProfileRuntimeConfig,
    temperature: f64,
    max_output_tokens: u32,
    request: &CorrectionRequest,
) -> Value {
    let mut body = json!({
        "model": profile.model,
        "max_tokens": max_output_tokens,
        "system": request.system_prompt,
        "messages": [{
            "role": "user",
            "content": request.user_prompt,
        }],
    });
    // Anthropic recommends changing temperature or top_p, not both. Use the
    // user-facing temperature control and leave top_p at the API default.
    if temperature.is_finite() && (0.0..=1.0).contains(&temperature) {
        body["temperature"] = json!(temperature);
    }
    body
}

fn build_request_body(
    profile: &LlmProfileRuntimeConfig,
    temperature: f64,
    top_p: f64,
    max_output_tokens: u32,
    request: &CorrectionRequest,
) -> Value {
    match profile.effective_api_protocol() {
        LlmApiProtocol::OpenaiChat => {
            build_chat_completion_body(profile, temperature, top_p, max_output_tokens, request)
        }
        LlmApiProtocol::OpenaiResponses => {
            build_responses_body(profile, max_output_tokens, request)
        }
        LlmApiProtocol::AnthropicMessages => {
            build_anthropic_messages_body(profile, temperature, max_output_tokens, request)
        }
    }
}

fn text_from_content_part(part: &Value) -> Option<&str> {
    part.get("text")
        .and_then(|text| {
            text.as_str()
                .or_else(|| text.get("value").and_then(Value::as_str))
        })
        .or_else(|| part.get("content").and_then(Value::as_str))
}

fn collect_text_parts(parts: &[Value], accepted_types: &[&str]) -> String {
    parts
        .iter()
        .filter(|part| {
            part.get("type")
                .and_then(Value::as_str)
                .is_none_or(|kind| accepted_types.contains(&kind))
        })
        .filter_map(text_from_content_part)
        .collect::<Vec<_>>()
        .join("")
}

fn clean_response_content(content: &str) -> Result<String> {
    let content = crate::llm::strip_reasoning(content);
    let cleaned = content.trim();
    let cleaned = cleaned
        .strip_prefix('"')
        .and_then(|s| s.strip_suffix('"'))
        .unwrap_or(cleaned);
    let cleaned = cleaned
        .strip_prefix('\u{201c}')
        .and_then(|s| s.strip_suffix('\u{201d}'))
        .unwrap_or(cleaned);
    if cleaned.trim().is_empty() {
        return Err(KoeError::LlmFailed("empty content in response".into()));
    }
    Ok(cleaned.to_string())
}

fn parse_chat_response(json: &Value) -> Result<String> {
    let choice = json.get("choices").and_then(|choices| choices.get(0));
    if choice
        .and_then(|item| item.get("finish_reason"))
        .and_then(Value::as_str)
        == Some("length")
    {
        log::warn!("LLM Chat response reached max tokens; validating returned content");
    }
    let content = choice
        .and_then(|item| item.get("message"))
        .and_then(|message| message.get("content"))
        .ok_or_else(|| KoeError::LlmFailed("missing content in Chat response".into()))?;
    let text = if let Some(text) = content.as_str() {
        text.to_string()
    } else if let Some(parts) = content.as_array() {
        collect_text_parts(parts, &["text", "output_text"])
    } else {
        String::new()
    };
    clean_response_content(&text)
}

fn parse_responses_response(json: &Value) -> Result<String> {
    if json.get("status").and_then(Value::as_str) == Some("failed") {
        let message = json
            .pointer("/error/message")
            .and_then(Value::as_str)
            .unwrap_or("Responses API returned failed status");
        return Err(KoeError::LlmFailed(message.into()));
    }
    if json.get("status").and_then(Value::as_str) == Some("incomplete") {
        log::warn!("LLM Responses result is incomplete; validating returned content");
    }

    let mut text = json
        .get("output_text")
        .and_then(Value::as_str)
        .unwrap_or_default()
        .to_string();
    if text.is_empty() {
        let output = json
            .get("output")
            .and_then(Value::as_array)
            .ok_or_else(|| KoeError::LlmFailed("missing output in Responses response".into()))?;
        let mut chunks = Vec::new();
        for item in output {
            if item.get("type").and_then(Value::as_str) != Some("message") {
                continue;
            }
            if let Some(parts) = item.get("content").and_then(Value::as_array) {
                let chunk = collect_text_parts(parts, &["output_text", "text"]);
                if !chunk.is_empty() {
                    chunks.push(chunk);
                }
            }
        }
        text = chunks.join("");
    }
    clean_response_content(&text)
}

fn parse_anthropic_response(json: &Value) -> Result<String> {
    if json.get("stop_reason").and_then(Value::as_str) == Some("max_tokens") {
        log::warn!("Anthropic Messages response reached max_tokens; validating returned content");
    }
    let content = json
        .get("content")
        .ok_or_else(|| KoeError::LlmFailed("missing content in Anthropic response".into()))?;
    let text = if let Some(text) = content.as_str() {
        text.to_string()
    } else if let Some(parts) = content.as_array() {
        collect_text_parts(parts, &["text"])
    } else {
        String::new()
    };
    clean_response_content(&text)
}

fn parse_protocol_response(protocol: LlmApiProtocol, json: &Value) -> Result<String> {
    match protocol {
        LlmApiProtocol::OpenaiChat => parse_chat_response(json),
        LlmApiProtocol::OpenaiResponses => parse_responses_response(json),
        LlmApiProtocol::AnthropicMessages => parse_anthropic_response(json),
    }
}

#[async_trait::async_trait]
impl LlmProvider for OpenAiCompatibleProvider {
    async fn correct(&self, request: &CorrectionRequest) -> Result<String> {
        let protocol = self.profile.effective_api_protocol();
        let url = build_endpoint_url(
            &self.profile.base_url,
            self.profile.effective_endpoint_path(),
            protocol,
        );
        let body = build_request_body(
            &self.profile,
            self.temperature,
            self.top_p,
            self.max_output_tokens,
            request,
        );

        log::debug!("LLM request to {url}");

        let builder = self
            .client
            .post(&url)
            .header("Content-Type", "application/json")
            .json(&body);
        let builder = authenticate_request(builder, &self.profile);
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
        parse_protocol_response(protocol, &json)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::config::{
        LlmApiProtocol, LlmMaxTokenParameter, LlmNoReasoningControl, LlmProfileRuntimeConfig,
    };

    fn request() -> CorrectionRequest {
        CorrectionRequest {
            asr_text: "raw".into(),
            dictionary_entries: vec![],
            system_prompt: "system".into(),
            user_prompt: "user".into(),
        }
    }

    fn profile(protocol: LlmApiProtocol) -> LlmProfileRuntimeConfig {
        LlmProfileRuntimeConfig {
            id: "test".into(),
            name: "Test".into(),
            provider: if protocol == LlmApiProtocol::AnthropicMessages {
                "anthropic".into()
            } else {
                "openai".into()
            },
            api_protocol: protocol,
            base_url: "https://example.com/v1".into(),
            api_key: "secret".into(),
            model: "test-model".into(),
            endpoint_path: protocol.default_endpoint_path().into(),
            max_token_parameter: LlmMaxTokenParameter::MaxCompletionTokens,
            no_reasoning_control: LlmNoReasoningControl::None,
            mlx: Default::default(),
        }
    }

    #[test]
    fn apfel_body_uses_max_tokens_without_reasoning_controls() {
        let profile = LlmProfileRuntimeConfig {
            id: "apfel".into(),
            name: "APFEL".into(),
            provider: "apfel".into(),
            api_protocol: LlmApiProtocol::OpenaiChat,
            base_url: "http://127.0.0.1:11434/v1".into(),
            api_key: "".into(),
            model: "apple-foundationmodel".into(),
            endpoint_path: "/chat/completions".into(),
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
            api_protocol: LlmApiProtocol::OpenaiChat,
            base_url: "https://api.openai.com/v1".into(),
            api_key: "sk-test".into(),
            model: "gpt-5.4-nano".into(),
            endpoint_path: "/chat/completions".into(),
            max_token_parameter: LlmMaxTokenParameter::MaxCompletionTokens,
            no_reasoning_control: LlmNoReasoningControl::ReasoningEffort,
            mlx: Default::default(),
        };

        let body = build_chat_completion_body(&profile, 0.0, 1.0, 1024, &request());

        assert_eq!(body["model"], "gpt-5.4-nano");
        assert_eq!(body["max_completion_tokens"], 1024);
        assert_eq!(body["reasoning_effort"], "none");
        assert!(body.get("max_tokens").is_none());
        assert!(body.get("temperature").is_none());
        assert!(body.get("top_p").is_none());
    }

    #[test]
    fn endpoint_url_avoids_double_slashes() {
        let url = build_endpoint_url(
            "https://api.openai.com/v1/",
            "/chat/completions",
            LlmApiProtocol::OpenaiChat,
        );
        assert_eq!(url, "https://api.openai.com/v1/chat/completions");
    }

    #[test]
    fn endpoint_url_uses_protocol_default_for_empty_path() {
        let url = build_endpoint_url(
            "https://api.openai.com/v1",
            "",
            LlmApiProtocol::OpenaiResponses,
        );
        assert_eq!(url, "https://api.openai.com/v1/responses");
    }

    #[test]
    fn responses_body_uses_native_fields_and_disables_storage() {
        let profile = profile(LlmApiProtocol::OpenaiResponses);
        let body = build_responses_body(&profile, 2048, &request());

        assert_eq!(body["model"], "test-model");
        assert_eq!(body["instructions"], "system");
        assert_eq!(body["input"], "user");
        assert_eq!(body["max_output_tokens"], 2048);
        assert_eq!(body["store"], false);
        assert!(body.get("messages").is_none());
        assert!(body.get("temperature").is_none());
    }

    #[test]
    fn anthropic_body_uses_system_and_messages_api_fields() {
        let profile = profile(LlmApiProtocol::AnthropicMessages);
        let body = build_anthropic_messages_body(&profile, 0.2, 2048, &request());

        assert_eq!(body["model"], "test-model");
        assert_eq!(body["system"], "system");
        assert_eq!(body["messages"][0]["role"], "user");
        assert_eq!(body["messages"][0]["content"], "user");
        assert_eq!(body["max_tokens"], 2048);
        assert_eq!(body["temperature"], 0.2);
        assert!(body.get("top_p").is_none());
    }

    #[test]
    fn openai_and_anthropic_use_protocol_specific_authentication() {
        let openai = profile(LlmApiProtocol::OpenaiResponses);
        assert_eq!(
            authentication_headers(&openai),
            vec![("Authorization", "Bearer secret".into())]
        );

        let anthropic = profile(LlmApiProtocol::AnthropicMessages);
        assert_eq!(
            authentication_headers(&anthropic),
            vec![
                ("anthropic-version", "2023-06-01".into()),
                ("x-api-key", "secret".into()),
            ]
        );
    }

    #[test]
    fn parses_chat_string_and_content_parts() {
        let string = json!({"choices": [{"message": {"content": " corrected "}}]});
        assert_eq!(parse_chat_response(&string).unwrap(), "corrected");

        let parts = json!({"choices": [{"message": {"content": [
            {"type": "text", "text": "first "},
            {"type": "output_text", "text": "second"}
        ]}}]});
        assert_eq!(parse_chat_response(&parts).unwrap(), "first second");
    }

    #[test]
    fn parses_responses_output_and_ignores_reasoning_items() {
        let response = json!({
            "status": "completed",
            "output": [
                {"type": "reasoning", "summary": []},
                {"type": "message", "content": [
                    {"type": "output_text", "text": "corrected text", "annotations": []}
                ]}
            ]
        });
        assert_eq!(
            parse_responses_response(&response).unwrap(),
            "corrected text"
        );
    }

    #[test]
    fn parses_anthropic_text_blocks_and_ignores_thinking() {
        let response = json!({
            "stop_reason": "end_turn",
            "content": [
                {"type": "thinking", "thinking": "hidden"},
                {"type": "text", "text": "corrected text"}
            ]
        });
        assert_eq!(
            parse_anthropic_response(&response).unwrap(),
            "corrected text"
        );
    }

    #[test]
    fn all_protocols_reject_missing_visible_text() {
        let chat = json!({"choices": [{"message": {"content": []}}]});
        let responses = json!({"status": "completed", "output": []});
        let anthropic = json!({"content": [{"type": "thinking", "thinking": "hidden"}]});
        assert!(parse_chat_response(&chat).is_err());
        assert!(parse_responses_response(&responses).is_err());
        assert!(parse_anthropic_response(&anthropic).is_err());
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
