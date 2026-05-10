use crate::config::AsrConfig;
use crate::error::{AsrError, Result};
use crate::event::AsrEvent;
use crate::provider::AsrProvider;
use flate2::read::GzDecoder;
use flate2::write::GzEncoder;
use flate2::Compression;
use futures_util::{SinkExt, StreamExt};
use serde_json::Value;
use std::io::{Read, Write};
use tokio::time::{timeout, Duration};
use tokio_tungstenite::tungstenite::client::IntoClientRequest;
use tokio_tungstenite::tungstenite::Message;
use tokio_tungstenite::{connect_async, MaybeTlsStream, WebSocketStream};
use uuid::Uuid;

type WsStream = WebSocketStream<MaybeTlsStream<tokio::net::TcpStream>>;

// ─── Binary Protocol Constants ──────────────────────────────────────

const PROTOCOL_VERSION: u8 = 0b0001;
const HEADER_SIZE: u8 = 0b0001; // 1 * 4 = 4 bytes

const MSG_FULL_CLIENT_REQUEST: u8 = 0b0001;
const MSG_AUDIO_ONLY: u8 = 0b0010;
const MSG_FULL_SERVER_RESPONSE: u8 = 0b1001;
const MSG_ERROR: u8 = 0b1111;

const FLAG_NONE: u8 = 0b0000;
const FLAG_LAST_PACKET: u8 = 0b0010;

const SERIAL_NONE: u8 = 0b0000;
const SERIAL_JSON: u8 = 0b0001;

const COMPRESS_GZIP: u8 = 0b0001;

fn build_header(msg_type: u8, flags: u8, serialization: u8, compression: u8) -> [u8; 4] {
    [
        (PROTOCOL_VERSION << 4) | HEADER_SIZE,
        (msg_type << 4) | flags,
        (serialization << 4) | compression,
        0x00,
    ]
}

fn gzip_compress(data: &[u8]) -> Result<Vec<u8>> {
    let mut encoder = GzEncoder::new(Vec::new(), Compression::default());
    encoder
        .write_all(data)
        .map_err(|e| AsrError::Protocol(format!("gzip compress: {e}")))?;
    encoder
        .finish()
        .map_err(|e| AsrError::Protocol(format!("gzip finish: {e}")))
}

fn gzip_decompress(data: &[u8]) -> Result<Vec<u8>> {
    let mut decoder = GzDecoder::new(data);
    let mut buf = Vec::new();
    decoder
        .read_to_end(&mut buf)
        .map_err(|e| AsrError::Protocol(format!("gzip decompress: {e}")))?;
    Ok(buf)
}

fn build_frame(header: [u8; 4], payload: &[u8]) -> Vec<u8> {
    let payload_len = payload.len() as u32;
    let mut frame = Vec::with_capacity(4 + 4 + payload.len());
    frame.extend_from_slice(&header);
    frame.extend_from_slice(&payload_len.to_be_bytes());
    frame.extend_from_slice(payload);
    frame
}

// ─── Provider ───────────────────────────────────────────────────────

/// Doubao streaming ASR provider using the Volcengine binary WebSocket protocol.
///
/// Uses the "双向流式模式（优化版本）" endpoint (bigmodel_async) by default.
/// Protocol: custom binary framing over WebSocket with gzip-compressed payloads.
pub struct DoubaoWsProvider {
    ws: Option<WsStream>,
    connect_id: String,
    logid: Option<String>,
}

impl DoubaoWsProvider {
    pub fn new() -> Self {
        Self {
            ws: None,
            connect_id: Uuid::new_v4().to_string(),
            logid: None,
        }
    }

    /// Returns the connect ID for this session.
    pub fn connect_id(&self) -> &str {
        &self.connect_id
    }

    /// Returns the server-assigned log ID (available after connect).
    pub fn logid(&self) -> Option<&str> {
        self.logid.as_deref()
    }

    fn build_full_client_request(&self, config: &AsrConfig) -> Result<Vec<u8>> {
        let mut request = serde_json::json!({
            "model_name": "bigmodel",
            "enable_itn": config.enable_itn,
            "enable_punc": config.enable_punc,
            "enable_ddc": config.enable_ddc,
            "enable_nonstream": config.enable_nonstream,
            "result_type": "full",
            "show_utterances": true
        });

        if let Some(ref variant) = config.output_zh_variant {
            request["output_zh_variant"] = serde_json::Value::String(variant.clone());
        }
        if let Some(end_window) = config.end_window_size {
            request["end_window_size"] = serde_json::json!(end_window);
        }
        if let Some(force_time) = config.force_to_speech_time {
            request["force_to_speech_time"] = serde_json::json!(force_time);
        }
        if let Some(vad_dur) = config.vad_segment_duration {
            request["vad_segment_duration"] = serde_json::json!(vad_dur);
        }
        if config.enable_accelerate_text {
            request["enable_accelerate_text"] = serde_json::json!(true);
            if let Some(score) = config.accelerate_score {
                request["accelerate_score"] = serde_json::json!(score);
            }
        }

        // Build corpus: hotwords and/or dialog context
        let has_hotwords = !config.hotwords.is_empty();
        let has_context = !config.context_messages.is_empty();
        if has_hotwords || has_context {
            let mut corpus = serde_json::Map::new();

            // Hotwords go into corpus.context as a JSON string
            if has_hotwords {
                let hotwords: Vec<serde_json::Value> = config
                    .hotwords
                    .iter()
                    .map(|w| serde_json::json!({"word": w}))
                    .collect();
                let hotwords_json = serde_json::json!({"hotwords": hotwords});
                corpus.insert(
                    "context".to_string(),
                    serde_json::Value::String(
                        serde_json::to_string(&hotwords_json).unwrap_or_default(),
                    ),
                );
                log::info!(
                    "ASR hotwords: {} entries via corpus.context",
                    config.hotwords.len()
                );
            }

            // Dialog context: overwrites corpus.context when present (hotwords
            // can be embedded in the dialog_ctx if needed in future)
            if has_context {
                let context_data: Vec<serde_json::Value> = config
                    .context_messages
                    .iter()
                    .map(|t| serde_json::json!({"text": t}))
                    .collect();
                let dialog_ctx = serde_json::json!({
                    "context_type": "dialog_ctx",
                    "context_data": context_data
                });
                corpus.insert(
                    "context".to_string(),
                    serde_json::Value::String(
                        serde_json::to_string(&dialog_ctx).unwrap_or_default(),
                    ),
                );
                log::info!(
                    "ASR dialog context: {} messages",
                    config.context_messages.len()
                );
            }

            request["corpus"] = serde_json::Value::Object(corpus);
        }

        let mut audio = serde_json::json!({
            "format": "pcm",
            "codec": "raw",
            "rate": config.sample_rate_hz,
            "bits": 16,
            "channel": 1
        });

        // Language parameter (only for bigmodel_nostream and bigmodel_async with enable_nonstream)
        if let Some(ref lang) = config.language {
            if !lang.is_empty() {
                audio["language"] = serde_json::Value::String(lang.clone());
            }
        }

        let payload_json = serde_json::json!({
            "user": {
                "uid": "koe-asr"
            },
            "audio": audio,
            "request": request
        });

        log::info!(
            "ASR full client request: endpoint={}, resource_id={}, enable_nonstream={}, enable_ddc={}, enable_itn={}, enable_punc={}",
            config.url, config.resource_id, config.enable_nonstream, config.enable_ddc, config.enable_itn, config.enable_punc
        );
        log::debug!(
            "ASR request payload: {}",
            serde_json::to_string_pretty(&payload_json).unwrap_or_default()
        );

        let json_bytes = serde_json::to_vec(&payload_json)
            .map_err(|e| AsrError::Protocol(format!("serialize request: {e}")))?;

        let compressed = gzip_compress(&json_bytes)?;
        let header = build_header(
            MSG_FULL_CLIENT_REQUEST,
            FLAG_NONE,
            SERIAL_JSON,
            COMPRESS_GZIP,
        );
        Ok(build_frame(header, &compressed))
    }

    fn build_audio_frame(data: &[u8], is_last: bool) -> Result<Vec<u8>> {
        let compressed = gzip_compress(data)?;
        let flags = if is_last { FLAG_LAST_PACKET } else { FLAG_NONE };
        let header = build_header(MSG_AUDIO_ONLY, flags, SERIAL_NONE, COMPRESS_GZIP);
        Ok(build_frame(header, &compressed))
    }

    fn parse_server_response(data: &[u8]) -> Result<ServerMessage> {
        if data.len() < 4 {
            return Err(AsrError::Protocol("frame too short".into()));
        }

        let msg_type = (data[1] >> 4) & 0x0F;
        let flags = data[1] & 0x0F;
        let serialization = (data[2] >> 4) & 0x0F;
        let compression = data[2] & 0x0F;

        match msg_type {
            MSG_FULL_SERVER_RESPONSE => {
                let has_sequence = (flags & 0b0001) != 0;
                let is_last = (flags & 0b0010) != 0;

                let header_bytes = ((data[0] & 0x0F) as usize) * 4;
                let mut offset = header_bytes;

                if has_sequence {
                    if data.len() < offset + 4 {
                        return Err(AsrError::Protocol("missing sequence".into()));
                    }
                    offset += 4;
                }

                if data.len() < offset + 4 {
                    return Err(AsrError::Protocol("missing payload size".into()));
                }
                let payload_size = u32::from_be_bytes([
                    data[offset],
                    data[offset + 1],
                    data[offset + 2],
                    data[offset + 3],
                ]) as usize;
                offset += 4;

                if data.len() < offset + payload_size {
                    return Err(AsrError::Protocol("incomplete payload".into()));
                }
                let payload_bytes = &data[offset..offset + payload_size];

                let json_bytes = if compression == COMPRESS_GZIP {
                    gzip_decompress(payload_bytes)?
                } else {
                    payload_bytes.to_vec()
                };

                let json: Value = if serialization == SERIAL_JSON {
                    serde_json::from_slice(&json_bytes)
                        .map_err(|e| AsrError::Protocol(format!("parse JSON: {e}")))?
                } else {
                    Value::Null
                };

                Ok(ServerMessage::Response { json, is_last })
            }
            MSG_ERROR => {
                let header_bytes = ((data[0] & 0x0F) as usize) * 4;
                let mut offset = header_bytes;

                let error_code = if data.len() >= offset + 4 {
                    let code = u32::from_be_bytes([
                        data[offset],
                        data[offset + 1],
                        data[offset + 2],
                        data[offset + 3],
                    ]);
                    offset += 4;
                    code
                } else {
                    0
                };

                let error_msg = if data.len() >= offset + 4 {
                    let msg_size = u32::from_be_bytes([
                        data[offset],
                        data[offset + 1],
                        data[offset + 2],
                        data[offset + 3],
                    ]) as usize;
                    offset += 4;
                    if data.len() >= offset + msg_size {
                        String::from_utf8_lossy(&data[offset..offset + msg_size]).to_string()
                    } else {
                        String::new()
                    }
                } else {
                    String::new()
                };

                Ok(ServerMessage::Error {
                    code: error_code,
                    message: error_msg,
                })
            }
            _ => Err(AsrError::Protocol(format!(
                "unknown message type: {msg_type:#06b}"
            ))),
        }
    }
}

impl Default for DoubaoWsProvider {
    fn default() -> Self {
        Self::new()
    }
}

enum ServerMessage {
    Response { json: Value, is_last: bool },
    Error { code: u32, message: String },
}

#[async_trait::async_trait]
impl AsrProvider for DoubaoWsProvider {
    async fn connect(&mut self, config: &AsrConfig) -> Result<()> {
        let connect_timeout = Duration::from_millis(config.connect_timeout_ms);

        log::info!(
            "connecting to ASR: {} (connect_id={})",
            config.url,
            self.connect_id
        );

        let mut request = config
            .url
            .as_str()
            .into_client_request()
            .map_err(|e| AsrError::Connection(format!("invalid URL: {e}")))?;

        if config.custom_headers.is_empty() {
            let headers = request.headers_mut();

            if !config.api_key.is_empty() {
                // New console auth: single X-Api-Key
                headers.insert(
                    "X-Api-Key",
                    config
                        .api_key
                        .parse()
                        .map_err(|_| AsrError::Connection("invalid api_key".into()))?,
                );
            } else {
                // Legacy auth: X-Api-App-Key + X-Api-Access-Key
                headers.insert(
                    "X-Api-App-Key",
                    config
                        .app_key
                        .parse()
                        .map_err(|_| AsrError::Connection("invalid app_key".into()))?,
                );
                headers.insert(
                    "X-Api-Access-Key",
                    config
                        .access_key
                        .parse()
                        .map_err(|_| AsrError::Connection("invalid access_key".into()))?,
                );
            }

            headers.insert(
                "X-Api-Resource-Id",
                config
                    .resource_id
                    .parse()
                    .map_err(|_| AsrError::Connection("invalid resource_id".into()))?,
            );
            headers.insert(
                "X-Api-Connect-Id",
                self.connect_id
                    .parse()
                    .map_err(|_| AsrError::Connection("invalid connect_id".into()))?,
            );
            headers.insert(
                "X-Api-Request-Id",
                self.connect_id
                    .parse()
                    .map_err(|_| AsrError::Connection("invalid request_id".into()))?,
            );
            headers.insert(
                "X-Api-Sequence",
                "-1".parse()
                    .map_err(|_| AsrError::Connection("invalid sequence".into()))?,
            );
        } else {
            let headers = request.headers_mut();
            for (key, value) in &config.custom_headers {
                let header_name: tokio_tungstenite::tungstenite::http::HeaderName = key
                    .parse()
                    .map_err(|_| AsrError::Connection(format!("invalid header name: {key}")))?;
                headers.insert(
                    header_name,
                    value.parse().map_err(|_| {
                        AsrError::Connection(format!("invalid header value for {key}"))
                    })?,
                );
            }
        }

        let (ws_stream, response) = timeout(connect_timeout, async {
            connect_async(request)
                .await
                .map_err(|e| AsrError::Connection(e.to_string()))
        })
        .await
        .map_err(|_| AsrError::Connection("connection timed out".into()))??;

        if let Some(logid) = response.headers().get("X-Tt-Logid") {
            if let Ok(s) = logid.to_str() {
                self.logid = Some(s.to_string());
                log::info!("ASR logid: {s}");
            }
        }

        self.ws = Some(ws_stream);

        let full_request = self.build_full_client_request(config)?;
        if let Some(ref mut ws) = self.ws {
            ws.send(Message::Binary(full_request))
                .await
                .map_err(|e| AsrError::Connection(format!("send full request: {e}")))?;
        }

        log::info!("ASR connected, full client request sent");
        Ok(())
    }

    async fn send_audio(&mut self, frame: &[u8]) -> Result<()> {
        let binary_frame = Self::build_audio_frame(frame, false)?;
        if let Some(ref mut ws) = self.ws {
            ws.send(Message::Binary(binary_frame))
                .await
                .map_err(|e| AsrError::Protocol(format!("send audio: {e}")))?;
        }
        Ok(())
    }

    async fn finish_input(&mut self) -> Result<()> {
        let last_frame = Self::build_audio_frame(&[], true)?;
        if let Some(ref mut ws) = self.ws {
            ws.send(Message::Binary(last_frame))
                .await
                .map_err(|e| AsrError::Protocol(format!("send finish: {e}")))?;
        }
        log::debug!("ASR finish signal sent (last packet)");
        Ok(())
    }

    async fn next_event(&mut self) -> Result<AsrEvent> {
        let ws = self
            .ws
            .as_mut()
            .ok_or_else(|| AsrError::Connection("not connected".into()))?;

        loop {
            match ws.next().await {
                Some(Ok(Message::Binary(data))) => match Self::parse_server_response(&data)? {
                    ServerMessage::Response { json, is_last } => {
                        let text = json
                            .get("result")
                            .and_then(|r| r.get("text"))
                            .and_then(|t| t.as_str())
                            .unwrap_or("")
                            .to_string();

                        let has_definite = json
                            .get("result")
                            .and_then(|r| r.get("utterances"))
                            .and_then(|u| u.as_array())
                            .map(|utterances| {
                                utterances.iter().any(|u| {
                                    u.get("definite").and_then(|d| d.as_bool()).unwrap_or(false)
                                })
                            })
                            .unwrap_or(false);

                        if is_last {
                            return Ok(AsrEvent::Final(text));
                        } else if has_definite {
                            return Ok(AsrEvent::Definite(text));
                        } else {
                            return Ok(AsrEvent::Interim(text));
                        }
                    }
                    ServerMessage::Error { code, message } => {
                        log::error!(
                            "ASR error: code={code}, message={message}, logid={:?}",
                            self.logid
                        );
                        return Err(AsrError::Protocol(format!(
                            "server error {code}: {message}"
                        )));
                    }
                },
                Some(Ok(Message::Close(frame))) => {
                    let reason = frame
                        .as_ref()
                        .map(|f| format!("code={}, reason={:?}", f.code, f.reason));
                    return Ok(AsrEvent::Closed(reason));
                }
                Some(Ok(frame)) => {
                    log::debug!("[Doubao ASR] Skipping frame: {:?}", frame);
                }
                Some(Err(e)) => return Err(AsrError::Protocol(e.to_string())),
                None => return Ok(AsrEvent::Closed(Some("WebSocket stream ended".into()))),
            }
        }
    }

    async fn close(&mut self) -> Result<()> {
        if let Some(mut ws) = self.ws.take() {
            let _ = ws.close(None).await;
        }
        log::debug!(
            "ASR connection closed (connect_id={}, logid={:?})",
            self.connect_id,
            self.logid
        );
        Ok(())
    }
}
