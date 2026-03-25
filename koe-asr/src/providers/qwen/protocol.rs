use crate::config::{AsrConfig, QwenRealtimeConfig};
use crate::error::{AsrError, Result};
use serde_json::{json, Value};
use uuid::Uuid;

pub enum ServerEvent {
    Connected,
    AudioCommitted { item_id: Option<String> },
    InterimText {
        item_id: Option<String>,
        text: String,
        stash: String,
    },
    Completed { item_id: Option<String>, transcript: String },
    Error { message: String },
    Finished,
    Ignore,
}

fn event_id() -> String {
    format!("event_{}", Uuid::new_v4().simple())
}

pub fn build_ws_url(base_url: &str, model: &str) -> Result<String> {
    let mut url = base_url.trim_end_matches('/').to_string();

    if let Some(rest) = url.strip_prefix("https://") {
        url = format!("wss://{rest}");
    } else if let Some(rest) = url.strip_prefix("http://") {
        url = format!("ws://{rest}");
    }

    if url.contains('?') {
        if !url.contains("model=") {
            url.push_str("&model=");
            url.push_str(model);
        }
    } else {
        url.push_str("?model=");
        url.push_str(model);
    }

    Ok(url)
}

pub fn build_session_update(session_config: &AsrConfig, provider_config: &QwenRealtimeConfig) -> Value {
    let mut transcription = json!({});
    if !provider_config.language.is_empty() {
        transcription["language"] = Value::String(provider_config.language.clone());
    }
    if !session_config.hotwords.is_empty() {
        transcription["corpus"] = json!({
            "text": session_config.hotwords.join("\n")
        });
    }

    json!({
        "event_id": event_id(),
        "type": "session.update",
        "session": {
            "input_audio_format": "pcm",
            "sample_rate": provider_config.sample_rate_hz,
            "input_audio_transcription": transcription,
            "turn_detection": Value::Null
        }
    })
}

pub fn build_audio_append(audio_base64: &str) -> Value {
    json!({
        "event_id": event_id(),
        "type": "input_audio_buffer.append",
        "audio": audio_base64
    })
}

pub fn build_audio_commit() -> Value {
    json!({
        "event_id": event_id(),
        "type": "input_audio_buffer.commit"
    })
}

pub fn build_session_finish() -> Value {
    json!({
        "event_id": event_id(),
        "type": "session.finish"
    })
}

pub fn parse_server_event(raw: &str) -> Result<ServerEvent> {
    let json: Value = serde_json::from_str(raw)
        .map_err(|e| AsrError::Protocol(format!("parse Qwen event: {e}")))?;
    let event_type = json
        .get("type")
        .and_then(Value::as_str)
        .unwrap_or_default();

    let item_id = || {
        json.get("item_id")
            .and_then(Value::as_str)
            .map(ToString::to_string)
    };

    match event_type {
        "session.created" | "session.updated" => Ok(ServerEvent::Connected),
        "input_audio_buffer.committed" => Ok(ServerEvent::AudioCommitted { item_id: item_id() }),
        "conversation.item.input_audio_transcription.text" => Ok(ServerEvent::InterimText {
            item_id: item_id(),
            text: json
                .get("text")
                .and_then(Value::as_str)
                .unwrap_or_default()
                .to_string(),
            stash: json
                .get("stash")
                .and_then(Value::as_str)
                .unwrap_or_default()
                .to_string(),
        }),
        "conversation.item.input_audio_transcription.completed" => Ok(ServerEvent::Completed {
            item_id: item_id(),
            transcript: json
                .get("transcript")
                .and_then(Value::as_str)
                .unwrap_or_default()
                .to_string(),
        }),
        "conversation.item.input_audio_transcription.failed" | "error" => Ok(ServerEvent::Error {
            message: extract_error_message(&json)
                .unwrap_or_else(|| "Qwen Realtime returned an error".to_string()),
        }),
        "session.finished" => Ok(ServerEvent::Finished),
        _ => Ok(ServerEvent::Ignore),
    }
}

fn extract_error_message(json: &Value) -> Option<String> {
    json.get("error")
        .and_then(Value::as_object)
        .and_then(|error| error.get("message"))
        .and_then(Value::as_str)
        .map(ToString::to_string)
        .or_else(|| {
            json.get("message")
                .and_then(Value::as_str)
                .map(ToString::to_string)
        })
}
