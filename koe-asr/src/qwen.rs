use crate::config::AsrConfig;
use crate::error::{AsrError, Result};
use crate::event::AsrEvent;
use crate::provider::AsrProvider;
use futures_util::{SinkExt, StreamExt};
use serde::Serialize;
use std::collections::VecDeque;
use tokio::time::{timeout, Duration};
use tokio_tungstenite::tungstenite::client::IntoClientRequest;
use tokio_tungstenite::tungstenite::Message;
use tokio_tungstenite::{connect_async, MaybeTlsStream, WebSocketStream};
use uuid::Uuid;

type WsStream = WebSocketStream<MaybeTlsStream<tokio::net::TcpStream>>;

const SESSION_EVENT_TIMEOUT: Duration = Duration::from_secs(5);

// VAD (Voice Activity Detection) parameters
// threshold: 0.0-1.0, higher = stricter, reduces false triggers from ambient noise
const VAD_THRESHOLD: f32 = 0.5;
// silence_duration_ms: duration of silence before speech is considered ended
const VAD_SILENCE_DURATION_MS: u32 = 400;
// prefix_padding_ms: audio retained before speech onset to capture the beginning
const VAD_PREFIX_PADDING_MS: u32 = 100;

/// Qwen DashScope Realtime ASR Provider (Qwen-ASR-Realtime)
///
/// Protocol follows the Qwen WebSocket Realtime API:
/// 1. Wait for `session.created` after connection
/// 2. Send `session.update` with configuration
/// 3. Append Base64-encoded audio via `input_audio_buffer.append`
/// 4. Send `session.finish` when audio ends
pub struct QwenAsrProvider {
    ws: Option<WsStream>,
    input_finished: bool,
    pending_events: VecDeque<AsrEvent>,
}

impl QwenAsrProvider {
    pub fn new() -> Self {
        Self {
            ws: None,
            input_finished: false,
            pending_events: VecDeque::new(),
        }
    }

    fn build_session_update(config: &AsrConfig) -> ClientEvent {
        let language = config.language.clone().unwrap_or_else(|| "zh".to_string());
        ClientEvent {
            event_id: format!("event_{}", Uuid::new_v4()),
            event_type: "session.update".to_string(),
            audio: None,
            session: Some(serde_json::json!({
                "modalities": ["text"],
                "input_audio_format": "pcm",
                "sample_rate": config.sample_rate_hz,
                "input_audio_transcription": {
                    "model": config.app_key,
                    "language": language,
                },
                "turn_detection": {
                    "type": "server_vad",
                    "threshold": VAD_THRESHOLD,
                    "silence_duration_ms": VAD_SILENCE_DURATION_MS,
                    "prefix_padding_ms": VAD_PREFIX_PADDING_MS,
                }
            })),
        }
    }

    fn build_audio_append(audio_data: &[u8]) -> ClientEvent {
        use base64::{Engine, engine::general_purpose::STANDARD};
        ClientEvent {
            event_id: format!("event_{}", Uuid::new_v4()),
            event_type: "input_audio_buffer.append".to_string(),
            audio: Some(STANDARD.encode(audio_data)),
            session: None,
        }
    }

    fn build_session_finish() -> ClientEvent {
        ClientEvent {
            event_id: format!("event_{}", Uuid::new_v4()),
            event_type: "session.finish".to_string(),
            audio: None,
            session: None,
        }
    }

    fn parse_server_event(&mut self, text: &str) -> Result<Vec<AsrEvent>> {
        log::debug!("[Qwen ASR] Received: {}", text);

        let raw_json: serde_json::Value = serde_json::from_str(text)
            .map_err(|e| AsrError::Protocol(format!("parse server event: {e}")))?;

        let event_type = raw_json
            .get("type")
            .and_then(|t| t.as_str())
            .unwrap_or("unknown");

        let mut events = Vec::new();

        match event_type {
            "session.created" => {
                log::info!("[Qwen ASR] Session created");
            }
            "session.updated" => {
                log::info!("[Qwen ASR] Session updated");
                events.push(AsrEvent::Connected);
            }
            "input_audio_buffer.speech_started" => {
                log::debug!("[Qwen ASR] Speech started");
            }
            "input_audio_buffer.speech_stopped" => {
                log::debug!("[Qwen ASR] Speech stopped");
            }
            "input_audio_buffer.committed" => {
                log::debug!("[Qwen ASR] Audio buffer committed");
            }
            "conversation.item.created" => {
                log::debug!("[Qwen ASR] Conversation item created");
            }
            "conversation.item.input_audio_transcription.text" => {
                let text = raw_json.get("text").and_then(|v| v.as_str()).unwrap_or("");
                let stash = raw_json.get("stash").and_then(|v| v.as_str()).unwrap_or("");
                let preview = format!("{text}{stash}");
                if !preview.is_empty() {
                    events.push(AsrEvent::Interim(preview));
                }
            }
            "conversation.item.input_audio_transcription.completed" => {
                let transcript = raw_json
                    .get("transcript")
                    .and_then(|v| v.as_str())
                    .or_else(|| {
                        raw_json
                            .get("item")
                            .and_then(|i| i.get("content"))
                            .and_then(|c| c.as_array())
                            .and_then(|arr| arr.first())
                            .and_then(|content| content.get("transcript"))
                            .and_then(|v| v.as_str())
                    })
                    .unwrap_or("");

                if !transcript.is_empty() {
                    log::info!("[Qwen ASR] Final: {}", transcript);
                    events.push(AsrEvent::Definite(transcript.to_string()));
                    events.push(AsrEvent::Final(transcript.to_string()));
                }
            }
            "session.finished" => {
                log::info!("[Qwen ASR] Session finished");
                events.push(AsrEvent::Closed);
            }
            "error" => {
                let error_msg = raw_json
                    .get("error")
                    .and_then(|e| e.get("message"))
                    .and_then(|m| m.as_str())
                    .unwrap_or("Unknown error");
                log::error!("[Qwen ASR] Error: {}", error_msg);
                events.push(AsrEvent::Error(error_msg.to_string()));
            }
            other => {
                log::debug!("[Qwen ASR] Ignoring event type: {}", other);
            }
        }

        Ok(events)
    }

    async fn read_text_event(ws: &mut WsStream, timeout_duration: Duration) -> Result<String> {
        match timeout(timeout_duration, ws.next()).await {
            Ok(Some(Ok(Message::Text(text)))) => Ok(text.to_string()),
            Ok(Some(Ok(Message::Close(frame)))) => Err(AsrError::Connection(format!(
                "connection closed unexpectedly: {:?}",
                frame
            ))),
            Ok(Some(Ok(_))) => Err(AsrError::Connection(
                "expected text message from server".into(),
            )),
            Ok(Some(Err(e))) => Err(AsrError::Connection(format!("WebSocket error: {e}"))),
            Ok(None) => Err(AsrError::Connection("connection closed".into())),
            Err(_) => Err(AsrError::Connection(
                "timeout waiting for server event".into(),
            )),
        }
    }

    async fn send_client_event(&mut self, event: ClientEvent) -> Result<()> {
        let msg_text = serde_json::to_string(&event)
            .map_err(|e| AsrError::Protocol(format!("serialize client event: {e}")))?;

        if let Some(ref mut ws) = self.ws {
            ws.send(Message::Text(msg_text))
                .await
                .map_err(|e| AsrError::Protocol(format!("send client event: {e}")))?;
            Ok(())
        } else {
            Err(AsrError::Connection("not connected".into()))
        }
    }
}

impl Default for QwenAsrProvider {
    fn default() -> Self {
        Self::new()
    }
}

#[async_trait::async_trait]
impl AsrProvider for QwenAsrProvider {
    async fn connect(&mut self, config: &AsrConfig) -> Result<()> {
        let api_key = config.access_key.clone();
        if api_key.is_empty() {
            return Err(AsrError::Connection("api_key is required".into()));
        }

        let ws_url = format!("{}?model={}", config.url, config.app_key);
        log::info!("Connecting to Qwen ASR: {}", ws_url);

        let mut request = ws_url
            .into_client_request()
            .map_err(|e| AsrError::Connection(format!("invalid URL: {e}")))?;

        request.headers_mut().insert(
            "Authorization",
            format!("Bearer {}", api_key)
                .parse()
                .map_err(|_| AsrError::Connection("invalid api_key".into()))?,
        );

        let (ws_stream, response) =
            timeout(Duration::from_millis(config.connect_timeout_ms), async {
                connect_async(request)
                    .await
                    .map_err(|e| AsrError::Connection(e.to_string()))
            })
            .await
            .map_err(|_| AsrError::Connection("connection timed out".into()))??;

        log::info!("[Qwen ASR] WebSocket connected: {}", response.status());
        self.ws = Some(ws_stream);

        if let Some(ref mut ws) = self.ws {
            let created_text = Self::read_text_event(ws, SESSION_EVENT_TIMEOUT).await?;
            let created_json: serde_json::Value = serde_json::from_str(&created_text)
                .map_err(|e| AsrError::Protocol(format!("parse session.created: {e}")))?;
            let created_type = created_json
                .get("type")
                .and_then(|v| v.as_str())
                .unwrap_or("unknown");

            if created_type != "session.created" {
                let error_message = created_json
                    .get("error")
                    .and_then(|e| e.get("message"))
                    .and_then(|m| m.as_str())
                    .unwrap_or("expected session.created event");
                return Err(AsrError::Connection(error_message.to_string()));
            }
        }

        self.send_client_event(Self::build_session_update(config))
            .await?;

        loop {
            let event = self.next_event().await?;
            match event {
                AsrEvent::Connected => break,
                AsrEvent::Error(msg) => return Err(AsrError::Protocol(msg)),
                AsrEvent::Closed => {
                    return Err(AsrError::Connection(
                        "connection closed before session.updated".into(),
                    ))
                }
                AsrEvent::Interim(_) | AsrEvent::Definite(_) | AsrEvent::Final(_) => {
                    log::debug!("[Qwen ASR] Received transcript before session.updated");
                }
            }
        }

        log::info!("Qwen ASR connected and configured");
        Ok(())
    }

    async fn send_audio(&mut self, frame: &[u8]) -> Result<()> {
        if frame.is_empty() {
            return Ok(());
        }

        self.send_client_event(Self::build_audio_append(frame))
            .await
    }

    async fn finish_input(&mut self) -> Result<()> {
        if self.input_finished {
            return Ok(());
        }

        self.input_finished = true;
        self.send_client_event(Self::build_session_finish()).await
    }

    async fn next_event(&mut self) -> Result<AsrEvent> {
        if let Some(event) = self.pending_events.pop_front() {
            return Ok(event);
        }

        if let Some(ref mut ws) = self.ws {
            match ws.next().await {
                Some(Ok(Message::Text(text))) => {
                    let events = self.parse_server_event(&text)?;
                    self.pending_events.extend(events);
                    Ok(self
                        .pending_events
                        .pop_front()
                        .unwrap_or_else(|| AsrEvent::Interim(String::new())))
                }
                Some(Ok(Message::Close(_))) => Ok(AsrEvent::Closed),
                Some(Ok(Message::Binary(data))) => {
                    log::debug!(
                        "[Qwen ASR] Ignoring binary message ({} bytes)",
                        data.len()
                    );
                    Ok(AsrEvent::Interim(String::new()))
                }
                Some(Ok(_)) => Ok(AsrEvent::Interim(String::new())),
                Some(Err(e)) => Err(AsrError::Protocol(e.to_string())),
                None => Ok(AsrEvent::Closed),
            }
        } else {
            Err(AsrError::Connection("not connected".into()))
        }
    }

    async fn close(&mut self) -> Result<()> {
        if let Some(mut ws) = self.ws.take() {
            let _ = ws.close(None).await;
        }
        Ok(())
    }
}

#[derive(Serialize)]
struct ClientEvent {
    #[serde(rename = "event_id")]
    event_id: String,
    #[serde(rename = "type")]
    event_type: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    audio: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    session: Option<serde_json::Value>,
}
