use super::protocol::{
    build_audio_append, build_audio_commit, build_session_update, build_ws_url, parse_server_event,
    ServerEvent,
};
use crate::config::{AsrConfig, OpenAIRealtimeConfig};
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

pub struct OpenAIRealtimeProvider {
    ws: Option<WsStream>,
    config: Option<OpenAIRealtimeConfig>,
    current_item_id: Option<String>,
    current_interim_text: String,
}

impl OpenAIRealtimeProvider {
    pub fn new() -> Self {
        Self {
            ws: None,
            config: None,
            current_item_id: None,
            current_interim_text: String::new(),
        }
    }

    async fn send_json(&mut self, value: Value) -> Result<()> {
        let payload = serde_json::to_string(&value)
            .map_err(|e| AsrError::Protocol(format!("serialize OpenAI event: {e}")))?;

        if let Some(ws) = self.ws.as_mut() {
            ws.send(Message::Text(payload.into()))
                .await
                .map_err(|e| AsrError::Protocol(format!("send OpenAI event: {e}")))?;
            Ok(())
        } else {
            Err(AsrError::Connection("not connected".into()))
        }
    }

    fn resample_for_openai(
        &self,
        pcm: &[u8],
        config: &OpenAIRealtimeConfig,
    ) -> Result<Vec<u8>> {
        resample_pcm_mono_s16le(
            pcm,
            config.input_sample_rate_hz,
            config.output_sample_rate_hz,
        )
    }

    fn handle_interim_delta(&mut self, item_id: Option<String>, delta: String) -> AsrEvent {
        if let Some(item_id) = item_id {
            if self.current_item_id.as_deref() != Some(item_id.as_str()) {
                self.current_item_id = Some(item_id);
                self.current_interim_text.clear();
            }
        }

        if !delta.is_empty() {
            self.current_interim_text.push_str(&delta);
        }

        AsrEvent::Interim(self.current_interim_text.clone())
    }
}

impl Default for OpenAIRealtimeProvider {
    fn default() -> Self {
        Self::new()
    }
}

impl AsrProvider for OpenAIRealtimeProvider {
    async fn connect(&mut self, config: &AsrConfig) -> Result<()> {
        let provider_config = config
            .openai()
            .ok_or_else(|| AsrError::Connection("OpenAI provider config missing".into()))?;

        if provider_config.api_key.is_empty() {
            return Err(AsrError::Connection(
                "OpenAI API key is required for realtime transcription".into(),
            ));
        }

        let connect_timeout = Duration::from_millis(config.connect_timeout_ms);
        let ws_url = build_ws_url(&provider_config.base_url)?;
        log::info!("connecting to OpenAI Realtime transcription: {ws_url}");

        let mut request = ws_url
            .as_str()
            .into_client_request()
            .map_err(|e| AsrError::Connection(format!("invalid URL: {e}")))?;
        let headers = request.headers_mut();
        headers.insert(
            "Authorization",
            format!("Bearer {}", provider_config.api_key)
                .parse()
                .map_err(|_| AsrError::Connection("invalid OpenAI API key".into()))?,
        );
        headers.insert(
            "OpenAI-Beta",
            "realtime=v1"
                .parse()
                .map_err(|_| AsrError::Connection("invalid OpenAI beta header".into()))?,
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
        self.current_interim_text.clear();
        self.send_json(build_session_update(provider_config)).await?;

        log::info!(
            "OpenAI realtime session configured for model {}",
            provider_config.model
        );
        Ok(())
    }

    async fn send_audio(&mut self, frame: &[u8]) -> Result<()> {
        if self.ws.is_none() {
            return Err(AsrError::Connection("not connected".into()));
        }

        let openai_config = self
            .config
            .clone()
            .ok_or_else(|| AsrError::Connection("OpenAI provider config missing".into()))?;
        let resampled = self.resample_for_openai(frame, &openai_config)?;
        let event = build_audio_append(&STANDARD.encode(resampled));
        self.send_json(event).await
    }

    async fn finish_input(&mut self) -> Result<()> {
        self.send_json(build_audio_commit()).await
    }

    async fn next_event(&mut self) -> Result<AsrEvent> {
        if let Some(ws) = self.ws.as_mut() {
            match ws.next().await {
                Some(Ok(Message::Text(text))) => match parse_server_event(&text)? {
                    ServerEvent::Connected => Ok(AsrEvent::Connected),
                    ServerEvent::AudioCommitted { item_id } => {
                        self.current_item_id = item_id;
                        self.current_interim_text.clear();
                        Ok(AsrEvent::Connected)
                    }
                    ServerEvent::InterimDelta { item_id, delta } => {
                        Ok(self.handle_interim_delta(item_id, delta))
                    }
                    ServerEvent::Completed { item_id, transcript } => {
                        self.current_item_id = item_id;
                        self.current_interim_text.clear();
                        Ok(AsrEvent::Final(transcript))
                    }
                    ServerEvent::Error { message } => Ok(AsrEvent::Error(message)),
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
        self.current_interim_text.clear();
        Ok(())
    }
}

fn resample_pcm_mono_s16le(input: &[u8], input_rate_hz: u32, output_rate_hz: u32) -> Result<Vec<u8>> {
    if input_rate_hz == output_rate_hz || input.is_empty() {
        return Ok(input.to_vec());
    }
    if !input.len().is_multiple_of(2) {
        return Err(AsrError::Protocol(
            "PCM frame length must be a multiple of 2 bytes".into(),
        ));
    }

    let samples: Vec<i16> = input
        .chunks_exact(2)
        .map(|chunk| i16::from_le_bytes([chunk[0], chunk[1]]))
        .collect();

    if samples.len() < 2 {
        return Ok(input.to_vec());
    }

    let output_len =
        (((samples.len() - 1) as u64 * output_rate_hz as u64) / input_rate_hz as u64 + 1) as usize;
    let mut output = Vec::with_capacity(output_len * 2);

    for index in 0..output_len {
        let numerator = index as u64 * input_rate_hz as u64;
        let left_index = (numerator / output_rate_hz as u64) as usize;
        let left_index = left_index.min(samples.len() - 1);
        let right_index = (left_index + 1).min(samples.len() - 1);
        let fraction = (numerator % output_rate_hz as u64) as f32 / output_rate_hz as f32;

        let left = samples[left_index] as f32;
        let right = samples[right_index] as f32;
        let sample = left + (right - left) * fraction;
        output.extend_from_slice(&(sample.round() as i16).to_le_bytes());
    }

    Ok(output)
}
