use super::protocol::{
    build_audio_append, build_audio_commit, build_session_finish, build_session_update,
    build_ws_url, parse_server_event, ServerEvent,
};
use crate::config::{AsrConfig, QwenRealtimeConfig};
use crate::error::{AsrError, Result};
use crate::event::AsrEvent;
use crate::provider::AsrProvider;
use base64::engine::general_purpose::STANDARD;
use base64::Engine;
use futures_util::{SinkExt, StreamExt};
use serde_json::Value;
use tokio::time::{timeout, Duration};
use tokio_tungstenite::tungstenite::client::IntoClientRequest;
use tokio_tungstenite::tungstenite::Message;
use tokio_tungstenite::{connect_async, MaybeTlsStream, WebSocketStream};

type WsStream = WebSocketStream<MaybeTlsStream<tokio::net::TcpStream>>;

pub struct QwenRealtimeProvider {
    ws: Option<WsStream>,
    config: Option<QwenRealtimeConfig>,
    current_item_id: Option<String>,
}

impl QwenRealtimeProvider {
    pub fn new() -> Self {
        Self {
            ws: None,
            config: None,
            current_item_id: None,
        }
    }

    async fn send_json(&mut self, value: Value) -> Result<()> {
        let payload = serde_json::to_string(&value)
            .map_err(|e| AsrError::Protocol(format!("serialize Qwen event: {e}")))?;

        if let Some(ws) = self.ws.as_mut() {
            ws.send(Message::Text(payload.into()))
                .await
                .map_err(|e| AsrError::Protocol(format!("send Qwen event: {e}")))?;
            Ok(())
        } else {
            Err(AsrError::Connection("not connected".into()))
        }
    }
}

impl Default for QwenRealtimeProvider {
    fn default() -> Self {
        Self::new()
    }
}

impl AsrProvider for QwenRealtimeProvider {
    async fn connect(&mut self, config: &AsrConfig) -> Result<()> {
        let provider_config = config
            .qwen()
            .ok_or_else(|| AsrError::Connection("Qwen provider config missing".into()))?;

        if provider_config.api_key.is_empty() {
            return Err(AsrError::Connection(
                "Qwen API key is required for realtime transcription".into(),
            ));
        }

        let connect_timeout = Duration::from_millis(config.connect_timeout_ms);
        let ws_url = build_ws_url(&provider_config.base_url, &provider_config.model)?;
        log::info!("connecting to Qwen Realtime transcription: {ws_url}");

        let mut request = ws_url
            .as_str()
            .into_client_request()
            .map_err(|e| AsrError::Connection(format!("invalid URL: {e}")))?;
        let headers = request.headers_mut();
        headers.insert(
            "Authorization",
            format!("bearer {}", provider_config.api_key)
                .parse()
                .map_err(|_| AsrError::Connection("invalid Qwen API key".into()))?,
        );

        let (ws_stream, _) = timeout(connect_timeout, async {
            connect_async(request)
                .await
                .map_err(|e| AsrError::Connection(e.to_string()))
        })
        .await
        .map_err(|_| AsrError::Connection("connection timed out".into()))??;

        self.ws = Some(ws_stream);
        self.config = Some(provider_config.clone());
        self.current_item_id = None;
        self.send_json(build_session_update(config, provider_config)).await?;

        log::info!(
            "Qwen realtime session configured for model {}",
            provider_config.model
        );
        Ok(())
    }

    async fn send_audio(&mut self, frame: &[u8]) -> Result<()> {
        if self.ws.is_none() {
            return Err(AsrError::Connection("not connected".into()));
        }

        let event = build_audio_append(&STANDARD.encode(frame));
        self.send_json(event).await
    }

    async fn finish_input(&mut self) -> Result<()> {
        self.send_json(build_audio_commit()).await?;
        self.send_json(build_session_finish()).await
    }

    async fn next_event(&mut self) -> Result<AsrEvent> {
        if let Some(ws) = self.ws.as_mut() {
            match ws.next().await {
                Some(Ok(Message::Text(text))) => match parse_server_event(&text)? {
                    ServerEvent::Connected => Ok(AsrEvent::Connected),
                    ServerEvent::AudioCommitted { item_id } => {
                        self.current_item_id = item_id;
                        Ok(AsrEvent::Connected)
                    }
                    ServerEvent::InterimText { item_id, text, stash } => {
                        self.current_item_id = item_id;
                        Ok(AsrEvent::Interim(format!("{text}{stash}")))
                    }
                    ServerEvent::Completed { item_id, transcript } => {
                        self.current_item_id = item_id;
                        Ok(AsrEvent::Final(transcript))
                    }
                    ServerEvent::Error { message } => Ok(AsrEvent::Error(message)),
                    ServerEvent::Finished => Ok(AsrEvent::Closed),
                    ServerEvent::Ignore => Ok(AsrEvent::Interim(String::new())),
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
        self.config = None;
        self.current_item_id = None;
        Ok(())
    }
}
