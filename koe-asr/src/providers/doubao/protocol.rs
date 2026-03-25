use crate::config::{AsrConfig, DoubaoConfig};
use crate::error::{AsrError, Result};
use flate2::read::GzDecoder;
use flate2::write::GzEncoder;
use flate2::Compression;
use serde_json::Value;
use std::io::{Read, Write};

const PROTOCOL_VERSION: u8 = 0b0001;
const HEADER_SIZE: u8 = 0b0001;

const MSG_FULL_CLIENT_REQUEST: u8 = 0b0001;
const MSG_AUDIO_ONLY: u8 = 0b0010;
const MSG_FULL_SERVER_RESPONSE: u8 = 0b1001;
const MSG_ERROR: u8 = 0b1111;

const FLAG_NONE: u8 = 0b0000;
const FLAG_LAST_PACKET: u8 = 0b0010;

const SERIAL_NONE: u8 = 0b0000;
const SERIAL_JSON: u8 = 0b0001;

const COMPRESS_GZIP: u8 = 0b0001;

pub enum ServerMessage {
    Response { json: Value, is_last: bool },
    Error { code: u32, message: String },
}

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

pub fn build_full_client_request(
    session_config: &AsrConfig,
    provider_config: &DoubaoConfig,
) -> Result<Vec<u8>> {
    let mut request = serde_json::json!({
        "model_name": "bigmodel",
        "enable_itn": provider_config.enable_itn,
        "enable_punc": provider_config.enable_punc,
        "enable_ddc": provider_config.enable_ddc,
        "enable_nonstream": provider_config.enable_nonstream,
        "result_type": "full",
        "show_utterances": true
    });

    if !session_config.hotwords.is_empty() {
        let hotwords: Vec<serde_json::Value> = session_config
            .hotwords
            .iter()
            .map(|word| serde_json::json!({ "word": word }))
            .collect();
        let hotwords_json = serde_json::json!({ "hotwords": hotwords });
        let context_str = serde_json::to_string(&hotwords_json).unwrap_or_default();
        request["corpus"] = serde_json::json!({
            "context": context_str
        });
        log::info!(
            "ASR hotwords: {} entries via corpus.context",
            session_config.hotwords.len()
        );
    }

    let payload_json = serde_json::json!({
        "user": {
            "uid": "koe-asr"
        },
        "audio": {
            "format": "pcm",
            "codec": "raw",
            "rate": provider_config.sample_rate_hz,
            "bits": 16,
            "channel": 1
        },
        "request": request
    });

    log::info!(
        "ASR full client request: endpoint={}, resource_id={}, enable_nonstream={}, enable_ddc={}, enable_itn={}, enable_punc={}",
        provider_config.url,
        provider_config.resource_id,
        provider_config.enable_nonstream,
        provider_config.enable_ddc,
        provider_config.enable_itn,
        provider_config.enable_punc
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

pub fn build_audio_frame(data: &[u8], is_last: bool) -> Result<Vec<u8>> {
    let compressed = gzip_compress(data)?;
    let flags = if is_last { FLAG_LAST_PACKET } else { FLAG_NONE };
    let header = build_header(MSG_AUDIO_ONLY, flags, SERIAL_NONE, COMPRESS_GZIP);
    Ok(build_frame(header, &compressed))
}

pub fn parse_server_response(data: &[u8]) -> Result<ServerMessage> {
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
