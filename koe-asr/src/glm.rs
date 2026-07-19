use crate::config::AsrConfig;
use crate::error::{AsrError, Result};
use crate::event::AsrEvent;
use crate::provider::AsrProvider;
use futures_util::StreamExt;
use reqwest::Client;
use std::collections::VecDeque;

const DEFAULT_URL: &str = "https://open.bigmodel.cn/api/paas/v4/audio/transcriptions";
const DEFAULT_MODEL: &str = "glm-asr-1";

/// GLM (Zhipu) ASR Provider.
///
/// Uses HTTP POST + SSE streaming (same approach as Voxt):
/// 1. Buffer audio during `send_audio()`
/// 2. Upload complete WAV file on `finish_input()`
/// 3. Parse SSE streaming response for intermediate/final results
pub struct GlmAsrProvider {
    client: Option<Client>,
    url: String,
    api_key: String,
    model: String,
    prompt: Option<String>,
    audio_buffer: Vec<u8>,
    pending_events: VecDeque<AsrEvent>,
    response_stream:
        Option<Pin<Box<dyn Stream<Item = std::result::Result<Bytes, reqwest::Error>> + Send>>>,
    finished: bool,
    connected: bool,
    /// SSE line-reassembly buffer. Must persist across next_event() calls:
    /// one read can carry several SSE lines and next_event() returns on the
    /// first interim, so a local buffer would drop the unprocessed remainder.
    line_buffer: String,
    /// Last interim delivered. Persists across next_event() calls to dedupe
    /// repeats and to synthesize the Final event at stream end.
    last_text: String,
}

use bytes::Bytes;
use futures_util::Stream;
use std::pin::Pin;

impl GlmAsrProvider {
    pub fn new() -> Self {
        Self {
            client: None,
            url: String::new(),
            api_key: String::new(),
            model: String::new(),
            prompt: None,
            audio_buffer: Vec::new(),
            pending_events: VecDeque::new(),
            response_stream: None,
            finished: false,
            connected: false,
            line_buffer: String::new(),
            last_text: String::new(),
        }
    }
}

impl Default for GlmAsrProvider {
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

/// Extract text from a JSON value, searching common fields.
fn extract_text_from_json(json: &serde_json::Value) -> Option<String> {
    // Try preferred keys
    for key in &[
        "text",
        "delta",
        "transcript",
        "result_text",
        "content",
        "utterance",
    ] {
        if let Some(val) = json.get(key).and_then(|v| v.as_str()) {
            if !val.is_empty() {
                return Some(val.to_string());
            }
        }
    }
    // Try nested in "results" array
    if let Some(results) = json.get("results").and_then(|r| r.as_array()) {
        if let Some(first) = results.first() {
            if let Some(text) = first.get("text").and_then(|v| v.as_str()) {
                if !text.is_empty() {
                    return Some(text.to_string());
                }
            }
        }
    }
    None
}

/// Parse a single SSE line and return an AsrEvent if applicable.
fn parse_sse_line(line: &str) -> Option<AsrEvent> {
    let trimmed = line.trim();
    if trimmed.is_empty() {
        return None;
    }

    // Extract data after "data:" prefix
    let data = if let Some(rest) = trimmed.strip_prefix("data:") {
        rest.trim()
    } else {
        trimmed
    };

    // Stream end marker
    if data == "[DONE]" {
        return None; // Will be handled by caller
    }

    // Try JSON parse
    if let Ok(json) = serde_json::from_str::<serde_json::Value>(data) {
        if let Some(text) = extract_text_from_json(&json) {
            return Some(AsrEvent::Interim(text));
        }
        // Check for error
        if let Some(error) = json.get("error") {
            let msg = error
                .get("message")
                .and_then(|m| m.as_str())
                .unwrap_or("Unknown error");
            return Some(AsrEvent::Error(msg.to_string()));
        }
    }

    None
}

#[async_trait::async_trait]
impl AsrProvider for GlmAsrProvider {
    async fn connect(&mut self, config: &AsrConfig) -> Result<()> {
        if config.access_key.is_empty() && config.api_key.is_empty() {
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

        self.prompt = config.language.clone(); // Reuse language field for prompt

        self.client = Some(
            Client::builder()
                .timeout(std::time::Duration::from_secs(120))
                .build()
                .map_err(|e| AsrError::Connection(format!("failed to create HTTP client: {e}")))?,
        );

        self.connected = true;
        log::info!(
            "[GLM ASR] Configured: url={}, model={}",
            self.url,
            self.model
        );

        // HTTP approach has no persistent connection, emit Connected immediately
        self.pending_events.push_back(AsrEvent::Connected);

        Ok(())
    }

    async fn send_audio(&mut self, frame: &[u8]) -> Result<()> {
        if !self.connected {
            return Err(AsrError::Connection("not connected".into()));
        }
        self.audio_buffer.extend_from_slice(frame);
        log::debug!(
            "[GLM ASR] Buffered audio: {} bytes (total: {})",
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
            log::warn!("[GLM ASR] No audio data to send");
            self.pending_events
                .push_back(AsrEvent::Final(String::new()));
            return Ok(());
        }

        let client = self
            .client
            .as_ref()
            .ok_or_else(|| AsrError::Connection("not connected".into()))?;

        // Build WAV from buffered PCM
        let wav_data = wrap_wav(&self.audio_buffer);
        log::info!(
            "[GLM ASR] Uploading audio: {} bytes PCM → {} bytes WAV",
            self.audio_buffer.len(),
            wav_data.len()
        );

        // Build multipart form
        let model_part = reqwest::multipart::Part::text(self.model.clone())
            .mime_str("text/plain")
            .map_err(|e| AsrError::Protocol(format!("model part: {e}")))?;

        let file_part = reqwest::multipart::Part::bytes(wav_data)
            .file_name("audio.wav")
            .mime_str("audio/wav")
            .map_err(|e| AsrError::Protocol(format!("file part: {e}")))?;

        let stream_part = reqwest::multipart::Part::text("true".to_string())
            .mime_str("text/plain")
            .map_err(|e| AsrError::Protocol(format!("stream part: {e}")))?;

        let mut form = reqwest::multipart::Form::new()
            .part("model", model_part)
            .part("file", file_part)
            .part("stream", stream_part);

        log::info!("[GLM ASR] Request: url={}, model={}", self.url, self.model);

        if let Some(ref prompt) = self.prompt {
            if !prompt.is_empty() {
                let prompt_part = reqwest::multipart::Part::text(prompt.clone())
                    .mime_str("text/plain")
                    .map_err(|e| AsrError::Protocol(format!("prompt part: {e}")))?;
                form = form.part("prompt", prompt_part);
            }
        }

        let response = client
            .post(&self.url)
            .header("Authorization", format!("Bearer {}", self.api_key))
            .header("Accept", "text/event-stream, application/json, text/plain")
            .multipart(form)
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

        log::info!("[GLM ASR] HTTP response: {}, streaming SSE...", status);

        // Store response stream for next_event()
        self.response_stream = Some(Box::pin(response.bytes_stream()));
        self.line_buffer.clear();
        self.last_text.clear();
        self.pending_events.push_back(AsrEvent::Connected);

        Ok(())
    }

    async fn next_event(&mut self) -> Result<AsrEvent> {
        if let Some(event) = self.pending_events.pop_front() {
            return Ok(event);
        }

        // If not finished yet, wait for audio to complete
        // The native code may call next_event() while audio is still being captured
        if !self.finished {
            // Block until finish_input() is called and stream is ready
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

        loop {
            let chunk = match self.response_stream.as_mut() {
                Some(stream) => stream.next().await,
                None => return Ok(AsrEvent::Closed(None)),
            };
            match chunk {
                Some(Ok(chunk)) => {
                    let text = String::from_utf8_lossy(&chunk);
                    self.line_buffer.push_str(&text);

                    // Process complete lines
                    while let Some(newline_pos) = self.line_buffer.find('\n') {
                        let line = self.line_buffer[..newline_pos].to_string();
                        self.line_buffer = self.line_buffer[newline_pos + 1..].to_string();

                        let trimmed = line.trim();
                        if trimmed.is_empty() {
                            continue;
                        }

                        // Extract data portion
                        let data = if let Some(rest) = trimmed.strip_prefix("data:") {
                            rest.trim()
                        } else {
                            trimmed
                        };

                        // Stream end marker
                        if data == "[DONE]" {
                            if !self.last_text.is_empty() {
                                let final_text = std::mem::take(&mut self.last_text);
                                log::info!("[GLM ASR] Final: {}", final_text);
                                return Ok(AsrEvent::Final(final_text));
                            }
                            return Ok(AsrEvent::Closed(None));
                        }

                        // Parse JSON for text delta
                        if let Some(event) = parse_sse_line(&line) {
                            match &event {
                                AsrEvent::Interim(text) => {
                                    if text != &self.last_text {
                                        log::debug!("[GLM ASR] Interim: {}", text);
                                        self.last_text = text.clone();
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
                    // Stream ended
                    if !self.last_text.is_empty() {
                        let final_text = std::mem::take(&mut self.last_text);
                        log::info!("[GLM ASR] Final: {}", final_text);
                        return Ok(AsrEvent::Final(final_text));
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
        self.line_buffer.clear();
        self.last_text.clear();
        self.connected = false;
        Ok(())
    }
}
