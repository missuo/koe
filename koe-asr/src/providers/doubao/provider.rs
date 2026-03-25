use super::protocol::{build_audio_frame, build_full_client_request, parse_server_response, ServerMessage};
use crate::config::AsrConfig;
use crate::error::{AsrError, Result};
use crate::event::AsrEvent;
use crate::provider::AsrProvider;
use futures_util::{SinkExt, StreamExt};
use tokio::time::{timeout, Duration};
use tokio_tungstenite::tungstenite::client::IntoClientRequest;
use tokio_tungstenite::tungstenite::Message;
use tokio_tungstenite::{connect_async, MaybeTlsStream, WebSocketStream};
use uuid::Uuid;

type WsStream = WebSocketStream<MaybeTlsStream<tokio::net::TcpStream>>;

/// Doubao streaming ASR provider using Volcengine's binary WebSocket protocol.
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

    pub fn connect_id(&self) -> &str {
        &self.connect_id
    }

    pub fn logid(&self) -> Option<&str> {
        self.logid.as_deref()
    }
}

impl Default for DoubaoWsProvider {
    fn default() -> Self {
        Self::new()
    }
}

impl AsrProvider for DoubaoWsProvider {
    async fn connect(&mut self, config: &AsrConfig) -> Result<()> {
        let provider_config = config
            .doubao()
            .ok_or_else(|| AsrError::Connection("Doubao provider config missing".into()))?;
        let connect_timeout = Duration::from_millis(config.connect_timeout_ms);

        log::info!(
            "connecting to ASR: {} (connect_id={})",
            provider_config.url,
            self.connect_id
        );

        let mut request = provider_config
            .url
            .as_str()
            .into_client_request()
            .map_err(|e| AsrError::Connection(format!("invalid URL: {e}")))?;

        let headers = request.headers_mut();
        headers.insert(
            "X-Api-App-Key",
            provider_config
                .app_key
                .parse()
                .map_err(|_| AsrError::Connection("invalid app_key".into()))?,
        );
        headers.insert(
            "X-Api-Access-Key",
            provider_config
                .access_key
                .parse()
                .map_err(|_| AsrError::Connection("invalid access_key".into()))?,
        );
        headers.insert(
            "X-Api-Resource-Id",
            provider_config
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

        let (ws_stream, response) = timeout(connect_timeout, async {
            connect_async(request)
                .await
                .map_err(|e| AsrError::Connection(e.to_string()))
        })
        .await
        .map_err(|_| AsrError::Connection("connection timed out".into()))??;

        if let Some(logid) = response.headers().get("X-Tt-Logid") {
            if let Ok(value) = logid.to_str() {
                self.logid = Some(value.to_string());
                log::info!("ASR logid: {value}");
            }
        }

        self.ws = Some(ws_stream);

        let full_request = build_full_client_request(config, provider_config)?;
        if let Some(ws) = self.ws.as_mut() {
            ws.send(Message::Binary(full_request.into()))
                .await
                .map_err(|e| AsrError::Connection(format!("send full request: {e}")))?;
        }

        log::info!("ASR connected, full client request sent");
        Ok(())
    }

    async fn send_audio(&mut self, frame: &[u8]) -> Result<()> {
        let binary_frame = build_audio_frame(frame, false)?;
        if let Some(ws) = self.ws.as_mut() {
            ws.send(Message::Binary(binary_frame.into()))
                .await
                .map_err(|e| AsrError::Protocol(format!("send audio: {e}")))?;
        }
        Ok(())
    }

    async fn finish_input(&mut self) -> Result<()> {
        let last_frame = build_audio_frame(&[], true)?;
        if let Some(ws) = self.ws.as_mut() {
            ws.send(Message::Binary(last_frame.into()))
                .await
                .map_err(|e| AsrError::Protocol(format!("send finish: {e}")))?;
        }
        log::debug!("ASR finish signal sent (last packet)");
        Ok(())
    }

    async fn next_event(&mut self) -> Result<AsrEvent> {
        if let Some(ws) = self.ws.as_mut() {
            match ws.next().await {
                Some(Ok(Message::Binary(data))) => match parse_server_response(&data)? {
                    ServerMessage::Response { json, is_last } => {
                        let text = json
                            .get("result")
                            .and_then(|result| result.get("text"))
                            .and_then(|text| text.as_str())
                            .unwrap_or("")
                            .to_string();

                        let has_definite = json
                            .get("result")
                            .and_then(|result| result.get("utterances"))
                            .and_then(|utterances| utterances.as_array())
                            .map(|utterances| {
                                utterances.iter().any(|utterance| {
                                    utterance
                                        .get("definite")
                                        .and_then(|value| value.as_bool())
                                        .unwrap_or(false)
                                })
                            })
                            .unwrap_or(false);

                        if is_last {
                            Ok(AsrEvent::Final(text))
                        } else if has_definite {
                            Ok(AsrEvent::Definite(text))
                        } else {
                            Ok(AsrEvent::Interim(text))
                        }
                    }
                    ServerMessage::Error { code, message } => {
                        log::error!(
                            "ASR error: code={code}, message={message}, logid={:?}",
                            self.logid
                        );
                        Err(AsrError::Protocol(format!(
                            "server error {code}: {message}"
                        )))
                    }
                },
                Some(Ok(Message::Close(_))) => Ok(AsrEvent::Closed),
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
        log::debug!(
            "ASR connection closed (connect_id={}, logid={:?})",
            self.connect_id,
            self.logid
        );
        Ok(())
    }
}
