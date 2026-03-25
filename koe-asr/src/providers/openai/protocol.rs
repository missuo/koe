use crate::config::OpenAIRealtimeConfig;
use crate::error::{AsrError, Result};
use serde_json::{json, Value};

pub enum ServerEvent {
    Connected,
    AudioCommitted { item_id: Option<String> },
    InterimDelta { item_id: Option<String>, delta: String },
    Completed { item_id: Option<String>, transcript: String },
    Error { message: String },
    Ignore,
}

pub fn build_ws_url(base_url: &str) -> Result<String> {
    let mut url = base_url.trim_end_matches('/').to_string();
    if !url.ends_with("/realtime") {
        url.push_str("/realtime");
    }

    if let Some(rest) = url.strip_prefix("https://") {
        url = format!("wss://{rest}");
    } else if let Some(rest) = url.strip_prefix("http://") {
        url = format!("ws://{rest}");
    }

    if url.contains('?') {
        if !url.contains("intent=") {
            url.push_str("&intent=transcription");
        }
    } else {
        url.push_str("?intent=transcription");
    }

    Ok(url)
}

pub fn build_session_update(config: &OpenAIRealtimeConfig) -> Value {
    let mut transcription = json!({
        "model": config.model,
    });

    if !config.language.is_empty() {
        transcription["language"] = Value::String(config.language.clone());
    }
    if !config.prompt.is_empty() {
        transcription["prompt"] = Value::String(config.prompt.clone());
    }

    json!({
        "type": "session.update",
        "session": {
            "type": "transcription",
            "audio": {
                "input": {
                    "format": {
                        "type": "audio/pcm",
                        "rate": config.output_sample_rate_hz,
                    },
                    "transcription": transcription,
                    "turn_detection": Value::Null
                }
            }
        }
    })
}

pub fn build_audio_append(audio_base64: &str) -> Value {
    json!({
        "type": "input_audio_buffer.append",
        "audio": audio_base64
    })
}

pub fn build_audio_commit() -> Value {
    json!({
        "type": "input_audio_buffer.commit"
    })
}

pub fn parse_server_event(raw: &str) -> Result<ServerEvent> {
    let json: Value = serde_json::from_str(raw)
        .map_err(|e| AsrError::Protocol(format!("parse OpenAI event: {e}")))?;
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
        "conversation.item.input_audio_transcription.delta" => Ok(ServerEvent::InterimDelta {
            item_id: item_id(),
            delta: json
                .get("delta")
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
        "conversation.item.input_audio_transcription.failed" => Ok(ServerEvent::Error {
            message: extract_error_message(&json).unwrap_or_else(|| {
                "OpenAI transcription failed without an error message".to_string()
            }),
        }),
        "error" => Ok(ServerEvent::Error {
            message: extract_error_message(&json)
                .unwrap_or_else(|| "OpenAI Realtime returned an error".to_string()),
        }),
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
