use crate::config::AsrConfig;
use crate::error::{AsrError, Result};
use crate::event::AsrEvent;
use crate::provider::AsrProvider;
use base64::Engine;
use bytes::Bytes;
use futures_util::Stream;
use futures_util::StreamExt;
use reqwest::Client;
use std::collections::VecDeque;
use std::pin::Pin;

const DEFAULT_URL: &str = "https://api.xiaomimimo.com/v1/chat/completions";
const DEFAULT_MODEL: &str = "mimo-v2.5-asr";

/// MiMo (Xiaomi) ASR Provider.
///
/// Uses OpenAI-compatible HTTP POST + SSE streaming:
/// 1. Buffer audio during `send_audio()`
/// 2. Encode as base64 WAV data URI on `finish_input()`
/// 3. POST to chat completions endpoint with audio in message content
/// 4. Parse SSE streaming response for intermediate/final results
pub struct MimoAsrProvider {
    client: Option<Client>,
    url: String,
    api_key: String,
    model: String,
    language: String,
    audio_buffer: Vec<u8>,
    pending_events: VecDeque<AsrEvent>,
    response_stream:
        Option<Pin<Box<dyn Stream<Item = std::result::Result<Bytes, reqwest::Error>> + Send>>>,
    finished: bool,
    connected: bool,
}

impl MimoAsrProvider {
    pub fn new() -> Self {
        Self {
            client: None,
            url: String::new(),
            api_key: String::new(),
            model: String::new(),
            language: "auto".to_string(),
            audio_buffer: Vec::new(),
            pending_events: VecDeque::new(),
            response_stream: None,
            finished: false,
            connected: false,
        }
    }
}

impl Default for MimoAsrProvider {
    fn default() -> Self {
        Self::new()
    }
}

/// Wrap raw PCM data (16-bit mono 16kHz) in a WAV container.
fn wrap_wav(pcm: &[u8]) -> Vec<u8> {
    let data_len = pcm.len() as u32;
    let sample_rate: u32 = 16000;
    let num_channels: u16 = 1;
    let bits_per_sample: u16 = 16;
    let byte_rate = sample_rate * num_channels as u32 * bits_per_sample as u32 / 8;
    let block_align = num_channels * bits_per_sample / 8;
    let total_size = 36 + data_len;

    let mut wav = Vec::with_capacity(44 + pcm.len());
    wav.extend_from_slice(b"RIFF");
    wav.extend_from_slice(&total_size.to_le_bytes());
    wav.extend_from_slice(b"WAVE");
    wav.extend_from_slice(b"fmt ");
    wav.extend_from_slice(&16u32.to_le_bytes());
    wav.extend_from_slice(&1u16.to_le_bytes());
    wav.extend_from_slice(&num_channels.to_le_bytes());
    wav.extend_from_slice(&sample_rate.to_le_bytes());
    wav.extend_from_slice(&byte_rate.to_le_bytes());
    wav.extend_from_slice(&block_align.to_le_bytes());
    wav.extend_from_slice(&bits_per_sample.to_le_bytes());
    wav.extend_from_slice(b"data");
    wav.extend_from_slice(&data_len.to_le_bytes());
    wav.extend_from_slice(pcm);
    wav
}

/// Build the OpenAI-compatible JSON request body for MiMo ASR.
fn build_request_body(wav_base64: &str, model: &str, language: &str) -> serde_json::Value {
    serde_json::json!({
        "model": model,
        "messages": [
            {
                "role": "user",
                "content": [
                    {
                        "type": "input_audio",
                        "input_audio": {
                            "data": format!("data:audio/wav;base64,{wav_base64}")
                        }
                    }
                ]
            }
        ],
        "asr_options": {
            "language": language
        }
    })
}

/// Extract transcription text from MiMo API response JSON.
fn extract_text_from_response(json: &serde_json::Value) -> Option<String> {
    json.get("choices")?
        .as_array()?
        .first()?
        .get("message")?
        .get("content")?
        .as_str()
        .map(|s| s.to_string())
        .filter(|s| !s.is_empty())
}

/// Parse a single SSE line from MiMo streaming response.
fn parse_sse_line(line: &str) -> Option<AsrEvent> {
    let trimmed = line.trim();
    if trimmed.is_empty() {
        return None;
    }

    let data = if let Some(rest) = trimmed.strip_prefix("data:") {
        rest.trim()
    } else {
        trimmed
    };

    if data == "[DONE]" {
        return None;
    }

    if let Ok(json) = serde_json::from_str::<serde_json::Value>(data) {
        // Check for error
        if let Some(error) = json.get("error") {
            let msg = error
                .get("message")
                .and_then(|m| m.as_str())
                .unwrap_or("Unknown error");
            return Some(AsrEvent::Error(msg.to_string()));
        }

        // Extract text from choices[0].delta.content (streaming) or choices[0].message.content
        let text = json
            .get("choices")
            .and_then(|c| c.as_array())
            .and_then(|a| a.first())
            .and_then(|c| {
                // Streaming: delta.content
                c.get("delta")
                    .and_then(|d| d.get("content"))
                    .and_then(|v| v.as_str())
                    // Non-streaming: message.content
                    .or_else(|| {
                        c.get("message")
                            .and_then(|m| m.get("content"))
                            .and_then(|v| v.as_str())
                    })
            });

        if let Some(text) = text {
            if !text.is_empty() {
                return Some(AsrEvent::Interim(text.to_string()));
            }
        }
    }

    None
}

#[async_trait::async_trait]
impl AsrProvider for MimoAsrProvider {
    async fn connect(&mut self, config: &AsrConfig) -> Result<()> {
        if config.api_key.is_empty() && config.access_key.is_empty() {
            return Err(AsrError::Connection("API key is required".into()));
        }

        self.api_key = if !config.api_key.is_empty() {
            config.api_key.clone()
        } else {
            config.access_key.clone()
        };

        self.url = if config.url.is_empty() {
            DEFAULT_URL.to_string()
        } else {
            config.url.clone()
        };

        self.model = if config.app_key.is_empty() {
            DEFAULT_MODEL.to_string()
        } else {
            config.app_key.clone()
        };

        self.language = config
            .language
            .clone()
            .unwrap_or_else(|| "auto".to_string());

        self.client = Some(
            Client::builder()
                .timeout(std::time::Duration::from_secs(120))
                .build()
                .map_err(|e| AsrError::Connection(format!("failed to create HTTP client: {e}")))?,
        );

        self.connected = true;
        log::info!(
            "[MiMo ASR] Configured: url={}, model={}",
            self.url,
            self.model
        );

        self.pending_events.push_back(AsrEvent::Connected);
        Ok(())
    }

    async fn send_audio(&mut self, frame: &[u8]) -> Result<()> {
        if !self.connected {
            return Err(AsrError::Connection("not connected".into()));
        }
        self.audio_buffer.extend_from_slice(frame);
        log::debug!(
            "[MiMo ASR] Buffered audio: {} bytes (total: {})",
            frame.len(),
            self.audio_buffer.len()
        );
        Ok(())
    }

    async fn finish_input(&mut self) -> Result<()> {
        if self.finished {
            return Ok(());
        }
        self.finished = true;

        if self.audio_buffer.is_empty() {
            log::warn!("[MiMo ASR] No audio data to send");
            self.pending_events
                .push_back(AsrEvent::Final(String::new()));
            return Ok(());
        }

        let client = self
            .client
            .as_ref()
            .ok_or_else(|| AsrError::Connection("not connected".into()))?;

        // Build WAV from buffered PCM and encode as base64 data URI
        let wav_data = wrap_wav(&self.audio_buffer);
        let b64 = base64::engine::general_purpose::STANDARD.encode(&wav_data);
        log::info!(
            "[MiMo ASR] Uploading audio: {} bytes PCM → {} bytes WAV (base64: {} chars)",
            self.audio_buffer.len(),
            wav_data.len(),
            b64.len()
        );

        let body = build_request_body(&b64, &self.model, &self.language);

        log::info!(
            "[MiMo ASR] Request: url={}, model={}, language={}",
            self.url,
            self.model,
            self.language
        );

        let response = client
            .post(&self.url)
            .header("api-key", &self.api_key)
            .header("Content-Type", "application/json")
            .header("Accept", "text/event-stream, application/json, text/plain")
            .json(&body)
            .send()
            .await
            .map_err(|e| AsrError::Connection(format!("HTTP request failed: {e}")))?;

        let status = response.status();
        if !status.is_success() {
            let body = response
                .text()
                .await
                .unwrap_or_else(|_| "failed to read response body".into());
            return Err(AsrError::Protocol(format!("HTTP {status}: {body}")));
        }

        log::info!("[MiMo ASR] HTTP response: {}, streaming SSE...", status);

        self.response_stream = Some(Box::pin(response.bytes_stream()));
        self.pending_events.push_back(AsrEvent::Connected);

        Ok(())
    }

    async fn next_event(&mut self) -> Result<AsrEvent> {
        if let Some(event) = self.pending_events.pop_front() {
            return Ok(event);
        }

        if !self.finished {
            loop {
                tokio::time::sleep(std::time::Duration::from_millis(50)).await;
                if self.finished {
                    break;
                }
                if self.pending_events.front().is_some() {
                    return Ok(self.pending_events.pop_front().unwrap());
                }
            }
        }

        let stream = match self.response_stream.as_mut() {
            Some(s) => s,
            None => {
                return Ok(AsrEvent::Closed(None));
            }
        };

        let mut line_buffer = String::new();
        let mut last_text = String::new();

        loop {
            match stream.next().await {
                Some(Ok(chunk)) => {
                    let text = String::from_utf8_lossy(&chunk);
                    line_buffer.push_str(&text);

                    while let Some(newline_pos) = line_buffer.find('\n') {
                        let line = line_buffer[..newline_pos].to_string();
                        line_buffer = line_buffer[newline_pos + 1..].to_string();

                        let trimmed = line.trim();
                        if trimmed.is_empty() {
                            continue;
                        }

                        let data = if let Some(rest) = trimmed.strip_prefix("data:") {
                            rest.trim()
                        } else {
                            trimmed
                        };

                        if data == "[DONE]" {
                            if !last_text.is_empty() {
                                log::info!("[MiMo ASR] Final: {}", last_text);
                                return Ok(AsrEvent::Final(last_text));
                            }
                            return Ok(AsrEvent::Closed(None));
                        }

                        if let Some(event) = parse_sse_line(&line) {
                            match &event {
                                AsrEvent::Interim(text) => {
                                    if text != &last_text {
                                        log::debug!("[MiMo ASR] Interim: {}", text);
                                        last_text = text.clone();
                                        return Ok(event);
                                    }
                                }
                                AsrEvent::Error(_) => {
                                    return Ok(event);
                                }
                                _ => {}
                            }
                        }
                    }
                }
                Some(Err(e)) => {
                    return Err(AsrError::Protocol(format!("stream error: {e}")));
                }
                None => {
                    if !last_text.is_empty() {
                        log::info!("[MiMo ASR] Final: {}", last_text);
                        return Ok(AsrEvent::Final(last_text));
                    }
                    return Ok(AsrEvent::Closed(None));
                }
            }
        }
    }

    async fn close(&mut self) -> Result<()> {
        self.client = None;
        self.response_stream = None;
        self.audio_buffer.clear();
        self.pending_events.clear();
        self.connected = false;
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn mimo_provider_creation() {
        let provider = MimoAsrProvider::new();
        assert!(provider.api_key.is_empty());
        assert!(provider.url.is_empty());
        assert!(provider.model.is_empty());
        assert_eq!(provider.language, "auto");
        assert!(!provider.connected);
        assert!(!provider.finished);
    }

    #[test]
    fn wrap_wav_produces_valid_header() {
        let pcm = vec![0u8; 100];
        let wav = wrap_wav(&pcm);

        // RIFF header
        assert_eq!(&wav[0..4], b"RIFF");
        // WAVE format
        assert_eq!(&wav[8..12], b"WAVE");
        // fmt chunk
        assert_eq!(&wav[12..16], b"fmt ");
        // data chunk
        assert_eq!(&wav[36..40], b"data");

        // data size = 100
        let data_size = u32::from_le_bytes([wav[40], wav[41], wav[42], wav[43]]);
        assert_eq!(data_size, 100);

        // total file size = 36 + 100 = 136
        let file_size = u32::from_le_bytes([wav[4], wav[5], wav[6], wav[7]]);
        assert_eq!(file_size, 136);

        // sample rate = 16000
        let sample_rate = u32::from_le_bytes([wav[24], wav[25], wav[26], wav[27]]);
        assert_eq!(sample_rate, 16000);

        // PCM data preserved
        assert_eq!(&wav[44..144], &[0u8; 100]);
    }

    #[test]
    fn build_request_body_structure() {
        let body = build_request_body("AAAA", "mimo-v2.5-asr", "auto");

        assert_eq!(body["model"], "mimo-v2.5-asr");
        assert_eq!(body["asr_options"]["language"], "auto");

        let messages = body["messages"].as_array().unwrap();
        assert_eq!(messages.len(), 1);
        assert_eq!(messages[0]["role"], "user");

        let content = messages[0]["content"].as_array().unwrap();
        assert_eq!(content.len(), 1);
        assert_eq!(content[0]["type"], "input_audio");
        assert_eq!(
            content[0]["input_audio"]["data"],
            "data:audio/wav;base64,AAAA"
        );
    }

    #[test]
    fn extract_text_from_response_finds_content() {
        let json = serde_json::json!({
            "id": "test-id",
            "choices": [{
                "finish_reason": "stop",
                "index": 0,
                "message": {
                    "content": "Hello world",
                    "role": "assistant"
                }
            }]
        });
        assert_eq!(
            extract_text_from_response(&json),
            Some("Hello world".to_string())
        );
    }

    #[test]
    fn extract_text_from_response_empty_content() {
        let json = serde_json::json!({
            "choices": [{
                "message": {
                    "content": "",
                    "role": "assistant"
                }
            }]
        });
        assert_eq!(extract_text_from_response(&json), None);
    }

    #[test]
    fn extract_text_from_response_missing_choices() {
        let json = serde_json::json!({"id": "test"});
        assert_eq!(extract_text_from_response(&json), None);
    }

    #[test]
    fn parse_sse_line_streaming_delta() {
        let line = r#"data: {"choices":[{"delta":{"content":"你好"}}]}"#;
        let event = parse_sse_line(line);
        assert!(matches!(event, Some(AsrEvent::Interim(ref t)) if t == "你好"));
    }

    #[test]
    fn parse_sse_line_non_streaming_message() {
        let line = r#"data: {"choices":[{"message":{"content":"完整文本"}}]}"#;
        let event = parse_sse_line(line);
        assert!(matches!(event, Some(AsrEvent::Interim(ref t)) if t == "完整文本"));
    }

    #[test]
    fn parse_sse_line_done_marker() {
        let event = parse_sse_line("data: [DONE]");
        assert!(event.is_none());
    }

    #[test]
    fn parse_sse_line_empty() {
        assert!(parse_sse_line("").is_none());
        assert!(parse_sse_line("   ").is_none());
    }

    #[test]
    fn parse_sse_line_error() {
        let line = r#"data: {"error":{"message":"Invalid API key"}}"#;
        let event = parse_sse_line(line);
        assert!(matches!(event, Some(AsrEvent::Error(ref m)) if m == "Invalid API key"));
    }

    #[test]
    fn parse_sse_line_no_data_prefix() {
        let line = r#"{"choices":[{"delta":{"content":"test"}}]}"#;
        let event = parse_sse_line(line);
        assert!(matches!(event, Some(AsrEvent::Interim(ref t)) if t == "test"));
    }

    #[tokio::test]
    async fn mimo_connect_requires_api_key() {
        let config = AsrConfig::default();
        let mut provider = MimoAsrProvider::new();
        let result = provider.connect(&config).await;
        assert!(result.is_err());
    }

    #[tokio::test]
    async fn mimo_connect_succeeds_with_key() {
        let config = AsrConfig {
            api_key: "test-key".to_string(),
            url: String::new(),
            ..Default::default()
        };
        let mut provider = MimoAsrProvider::new();
        let result = provider.connect(&config).await;
        assert!(result.is_ok());
        assert!(provider.connected);
        assert_eq!(provider.api_key, "test-key");
        assert_eq!(provider.url, DEFAULT_URL);
        assert_eq!(provider.model, DEFAULT_MODEL);
    }

    #[tokio::test]
    async fn mimo_connect_uses_custom_url_and_model() {
        let config = AsrConfig {
            api_key: "key".to_string(),
            url: "https://custom.api.com/v1/chat/completions".to_string(),
            app_key: "custom-model".to_string(),
            language: Some("zh-CN".to_string()),
            ..Default::default()
        };
        let mut provider = MimoAsrProvider::new();
        provider.connect(&config).await.unwrap();
        assert_eq!(provider.url, "https://custom.api.com/v1/chat/completions");
        assert_eq!(provider.model, "custom-model");
        assert_eq!(provider.language, "zh-CN");
    }

    #[tokio::test]
    async fn mimo_send_audio_before_connect_fails() {
        let mut provider = MimoAsrProvider::new();
        let result = provider.send_audio(&[0u8; 100]).await;
        assert!(result.is_err());
    }

    #[tokio::test]
    async fn mimo_send_audio_buffers_data() {
        let config = AsrConfig {
            api_key: "key".to_string(),
            ..Default::default()
        };
        let mut provider = MimoAsrProvider::new();
        provider.connect(&config).await.unwrap();

        provider.send_audio(&[1u8; 100]).await.unwrap();
        provider.send_audio(&[2u8; 50]).await.unwrap();

        assert_eq!(provider.audio_buffer.len(), 150);
        assert_eq!(&provider.audio_buffer[..100], &[1u8; 100]);
        assert_eq!(&provider.audio_buffer[100..], &[2u8; 50]);
    }

    #[tokio::test]
    async fn mimo_finish_input_empty_audio_emits_final() {
        let config = AsrConfig {
            api_key: "key".to_string(),
            ..Default::default()
        };
        let mut provider = MimoAsrProvider::new();
        provider.connect(&config).await.unwrap();

        // Drain the Connected event from connect()
        let connected = provider.next_event().await.unwrap();
        assert!(matches!(connected, AsrEvent::Connected));

        provider.finish_input().await.unwrap();
        assert!(provider.finished);

        let event = provider.next_event().await.unwrap();
        assert!(matches!(event, AsrEvent::Final(ref t) if t.is_empty()));
    }

    #[tokio::test]
    async fn mimo_close_resets_state() {
        let config = AsrConfig {
            api_key: "key".to_string(),
            ..Default::default()
        };
        let mut provider = MimoAsrProvider::new();
        provider.connect(&config).await.unwrap();
        provider.send_audio(&[0u8; 100]).await.unwrap();

        provider.close().await.unwrap();

        assert!(!provider.connected);
        assert!(provider.client.is_none());
        assert!(provider.audio_buffer.is_empty());
        assert!(provider.pending_events.is_empty());
    }
}
