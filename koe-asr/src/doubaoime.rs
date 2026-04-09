use crate::config::AsrConfig;
use crate::error::{AsrError, Result};
use crate::event::AsrEvent;
use crate::provider::AsrProvider;
use futures_util::{SinkExt, StreamExt};
use serde::{Deserialize, Serialize};
use std::path::{Path, PathBuf};
use std::time::{SystemTime, UNIX_EPOCH};
use tokio::time::{timeout, Duration};
use tokio_tungstenite::tungstenite::client::IntoClientRequest;
use tokio_tungstenite::tungstenite::Message;
use tokio_tungstenite::{connect_async, MaybeTlsStream, WebSocketStream};
use uuid::Uuid;

type WsStream = WebSocketStream<MaybeTlsStream<tokio::net::TcpStream>>;

// ─── Constants ─────────────────────────────────────────────────────

const WEBSOCKET_URL: &str = "wss://frontier-audio-ime-ws.doubao.com/ocean/api/v1/ws";
const REGISTER_URL: &str = "https://log.snssdk.com/service/2/device_register/";
const SETTINGS_URL: &str = "https://is.snssdk.com/service/settings/v3/";
const AID: u32 = 401734;
const USER_AGENT: &str = "com.bytedance.android.doubaoime/100102018 (Linux; U; Android 16; en_US; Pixel 7 Pro; Build/BP2A.250605.031.A2; Cronet/TTNetVersion:94cf429a 2025-11-17 QuicVersion:1f89f732 2025-05-08)";

const SAMPLE_RATE: u32 = 16000;
const FRAME_DURATION_MS: u32 = 20;
const SAMPLES_PER_FRAME: usize = (SAMPLE_RATE * FRAME_DURATION_MS / 1000) as usize; // 320
const BYTES_PER_FRAME: usize = SAMPLES_PER_FRAME * 2; // 640
const TOKEN_REFRESH_INTERVAL_MS: u64 = 12 * 60 * 60 * 1000;

// ─── Protobuf Encoding/Decoding ────────────────────────────────────

mod proto {
    /// Frame state for audio packets.
    #[repr(i32)]
    #[derive(Clone, Copy)]
    pub enum FrameState {
        First = 1,
        Middle = 3,
        Last = 9,
    }

    /// Decoded ASR response fields.
    #[derive(Debug, Default)]
    pub struct AsrResponse {
        pub message_type: String,
        pub status_code: i32,
        pub status_message: String,
        pub result_json: String,
    }

    fn write_varint(buf: &mut Vec<u8>, mut val: u64) {
        loop {
            let byte = (val & 0x7F) as u8;
            val >>= 7;
            if val == 0 {
                buf.push(byte);
                break;
            }
            buf.push(byte | 0x80);
        }
    }

    fn write_bytes_field(buf: &mut Vec<u8>, field_num: u32, data: &[u8]) {
        if data.is_empty() {
            return;
        }
        write_varint(buf, ((field_num as u64) << 3) | 2);
        write_varint(buf, data.len() as u64);
        buf.extend_from_slice(data);
    }

    fn write_string_field(buf: &mut Vec<u8>, field_num: u32, val: &str) {
        write_bytes_field(buf, field_num, val.as_bytes());
    }

    fn write_varint_field(buf: &mut Vec<u8>, field_num: u32, val: i32) {
        if val == 0 {
            return;
        }
        write_varint(buf, ((field_num as u64) << 3) | 0);
        write_varint(buf, val as u64);
    }

    /// Encode an AsrRequest protobuf message.
    pub fn encode_asr_request(
        token: &str,
        service_name: &str,
        method_name: &str,
        payload: &str,
        audio_data: &[u8],
        request_id: &str,
        frame_state: Option<FrameState>,
    ) -> Vec<u8> {
        let mut buf = Vec::with_capacity(128 + audio_data.len());
        // field 2: token
        write_string_field(&mut buf, 2, token);
        // field 3: service_name
        write_string_field(&mut buf, 3, service_name);
        // field 5: method_name
        write_string_field(&mut buf, 5, method_name);
        // field 6: payload
        write_string_field(&mut buf, 6, payload);
        // field 7: audio_data
        write_bytes_field(&mut buf, 7, audio_data);
        // field 8: request_id
        write_string_field(&mut buf, 8, request_id);
        // field 9: frame_state (enum = varint)
        if let Some(fs) = frame_state {
            write_varint_field(&mut buf, 9, fs as i32);
        }
        buf
    }

    /// Decode an AsrResponse protobuf message.
    pub fn decode_asr_response(data: &[u8]) -> super::Result<AsrResponse> {
        use super::AsrError;

        let mut resp = AsrResponse::default();
        let mut offset = 0;
        let len = data.len();

        while offset < len {
            let (tag, new_offset) = read_varint(data, offset)?;
            offset = new_offset;
            let field_num = (tag >> 3) as u32;
            let wire_type = (tag & 0x07) as u8;

            match wire_type {
                // varint
                0 => {
                    let (val, new_offset) = read_varint(data, offset)?;
                    offset = new_offset;
                    match field_num {
                        5 => resp.status_code = val as i32,
                        9 => {} // unknown_field_9, ignore
                        _ => {}
                    }
                }
                // length-delimited
                2 => {
                    let (field_len, new_offset) = read_varint(data, offset)?;
                    offset = new_offset;
                    let field_len = field_len as usize;
                    if offset + field_len > len {
                        return Err(AsrError::Protocol("protobuf: truncated field".into()));
                    }
                    let field_data = &data[offset..offset + field_len];
                    offset += field_len;
                    match field_num {
                        1 => {} // request_id, skip
                        2 => {} // task_id, skip
                        3 => {} // service_name, skip
                        4 => {
                            resp.message_type = String::from_utf8_lossy(field_data).into_owned();
                        }
                        6 => {
                            resp.status_message = String::from_utf8_lossy(field_data).into_owned();
                        }
                        7 => {
                            resp.result_json = String::from_utf8_lossy(field_data).into_owned();
                        }
                        _ => {} // skip unknown fields
                    }
                }
                // fixed64
                1 => {
                    if offset + 8 > len {
                        return Err(AsrError::Protocol("protobuf: truncated fixed64".into()));
                    }
                    offset += 8;
                }
                // fixed32
                5 => {
                    if offset + 4 > len {
                        return Err(AsrError::Protocol("protobuf: truncated fixed32".into()));
                    }
                    offset += 4;
                }
                _ => {
                    return Err(AsrError::Protocol(format!(
                        "protobuf: unknown wire type {wire_type}"
                    )));
                }
            }
        }
        Ok(resp)
    }

    fn read_varint(data: &[u8], mut offset: usize) -> super::Result<(u64, usize)> {
        use super::AsrError;
        let mut result: u64 = 0;
        let mut shift = 0;
        loop {
            if offset >= data.len() {
                return Err(AsrError::Protocol("protobuf: truncated varint".into()));
            }
            let byte = data[offset];
            offset += 1;
            result |= ((byte & 0x7F) as u64) << shift;
            if byte & 0x80 == 0 {
                return Ok((result, offset));
            }
            shift += 7;
            if shift >= 64 {
                return Err(AsrError::Protocol("protobuf: varint too long".into()));
            }
        }
    }
}

// ─── Device Registration ───────────────────────────────────────────

#[derive(Debug, Clone, Serialize, Deserialize)]
struct DeviceCredentials {
    device_id: String,
    install_id: String,
    cdid: String,
    openudid: String,
    clientudid: String,
    #[serde(default)]
    token: String,
    #[serde(default)]
    token_updated_at_ms: u64,
}

fn unix_timestamp_ms() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_millis() as u64
}

fn should_refresh_token(creds: &DeviceCredentials) -> bool {
    if creds.token.is_empty() || creds.token_updated_at_ms == 0 {
        return true;
    }

    unix_timestamp_ms().saturating_sub(creds.token_updated_at_ms) >= TOKEN_REFRESH_INTERVAL_MS
}

fn generate_cdid() -> String {
    Uuid::new_v4().to_string()
}

fn generate_openudid() -> String {
    use std::fmt::Write;
    let bytes: [u8; 8] = rand_bytes();
    let mut s = String::with_capacity(16);
    for b in &bytes {
        let _ = write!(s, "{b:02x}");
    }
    s
}

fn generate_clientudid() -> String {
    Uuid::new_v4().to_string()
}

fn rand_bytes<const N: usize>() -> [u8; N] {
    let mut buf = [0u8; N];
    // Use a simple PRNG seeded from system time for device ID generation.
    // This doesn't need cryptographic randomness.
    let seed = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_nanos();
    let mut state = seed;
    for byte in &mut buf {
        state = state.wrapping_mul(6364136223846793005).wrapping_add(1);
        *byte = (state >> 33) as u8;
    }
    buf
}

fn load_credentials(path: &Path) -> Option<DeviceCredentials> {
    let data = std::fs::read_to_string(path).ok()?;
    serde_json::from_str(&data).ok()
}

fn save_credentials(path: &Path, creds: &DeviceCredentials) -> Result<()> {
    if let Some(parent) = path.parent() {
        std::fs::create_dir_all(parent)
            .map_err(|e| AsrError::Connection(format!("create credential dir: {e}")))?;
    }
    let json = serde_json::to_string_pretty(creds)
        .map_err(|e| AsrError::Connection(format!("serialize credentials: {e}")))?;
    std::fs::write(path, json)
        .map_err(|e| AsrError::Connection(format!("write credentials: {e}")))?;
    Ok(())
}

fn build_register_body(cdid: &str, openudid: &str, clientudid: &str) -> serde_json::Value {
    serde_json::json!({
        "magic_tag": "ss_app_log",
        "header": {
            "device_id": 0,
            "install_id": 0,
            "aid": AID,
            "app_name": "oime",
            "version_code": 100102018,
            "version_name": "1.1.2",
            "manifest_version_code": 100102018,
            "update_version_code": 100102018,
            "channel": "official",
            "package": "com.bytedance.android.doubaoime",
            "device_platform": "android",
            "os": "android",
            "os_api": "34",
            "os_version": "16",
            "device_type": "Pixel 7 Pro",
            "device_brand": "google",
            "device_model": "Pixel 7 Pro",
            "resolution": "1080*2400",
            "dpi": "420",
            "language": "zh",
            "timezone": 8,
            "access": "wifi",
            "rom": "UP1A.231005.007",
            "rom_version": "UP1A.231005.007",
            "region": "CN",
            "tz_name": "Asia/Shanghai",
            "tz_offset": 28800,
            "sim_region": "cn",
            "carrier_region": "cn",
            "cpu_abi": "arm64-v8a",
            "build_serial": "unknown",
            "not_request_sender": 0,
            "sig_hash": "",
            "google_aid": "",
            "mc": "",
            "serial_number": "",
            "openudid": openudid,
            "clientudid": clientudid,
            "cdid": cdid
        },
        "_gen_time": SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap_or_default()
            .as_millis() as u64
    })
}

fn build_register_params(cdid: &str) -> Vec<(&'static str, String)> {
    vec![
        ("device_platform", "android".into()),
        ("os", "android".into()),
        ("ssmix", "a".into()),
        (
            "_rticket",
            format!(
                "{}",
                SystemTime::now()
                    .duration_since(UNIX_EPOCH)
                    .unwrap_or_default()
                    .as_millis()
            ),
        ),
        ("cdid", cdid.into()),
        ("channel", "official".into()),
        ("aid", AID.to_string()),
        ("app_name", "oime".into()),
        ("version_code", "100102018".into()),
        ("version_name", "1.1.2".into()),
        ("manifest_version_code", "100102018".into()),
        ("update_version_code", "100102018".into()),
        ("resolution", "1080*2400".into()),
        ("dpi", "420".into()),
        ("device_type", "Pixel 7 Pro".into()),
        ("device_brand", "google".into()),
        ("language", "zh".into()),
        ("os_api", "34".into()),
        ("os_version", "16".into()),
        ("ac", "wifi".into()),
    ]
}

async fn register_device(http: &reqwest::Client) -> Result<DeviceCredentials> {
    let cdid = generate_cdid();
    let openudid = generate_openudid();
    let clientudid = generate_clientudid();

    let body = build_register_body(&cdid, &openudid, &clientudid);
    let params = build_register_params(&cdid);

    log::info!("[DoubaoIME] Registering device...");

    let resp = http
        .post(REGISTER_URL)
        .header("User-Agent", USER_AGENT)
        .query(&params)
        .json(&body)
        .send()
        .await
        .map_err(|e| AsrError::Connection(format!("device register request: {e}")))?;

    let status = resp.status();
    let resp_text = resp
        .text()
        .await
        .map_err(|e| AsrError::Connection(format!("device register read body: {e}")))?;

    if !status.is_success() {
        return Err(AsrError::Connection(format!(
            "device register HTTP {status}: {resp_text}"
        )));
    }

    let resp_json: serde_json::Value = serde_json::from_str(&resp_text)
        .map_err(|e| AsrError::Connection(format!("device register parse JSON: {e}")))?;

    let device_id = resp_json
        .get("device_id")
        .and_then(|v| v.as_u64())
        .filter(|&id| id != 0)
        .map(|id| id.to_string())
        .or_else(|| {
            resp_json
                .get("device_id_str")
                .and_then(|v| v.as_str())
                .filter(|s| !s.is_empty() && *s != "0")
                .map(|s| s.to_string())
        })
        .ok_or_else(|| AsrError::Connection("device register: no device_id".into()))?;

    let install_id = resp_json
        .get("install_id")
        .and_then(|v| v.as_u64())
        .map(|id| id.to_string())
        .unwrap_or_default();

    log::info!("[DoubaoIME] Device registered: device_id={device_id}");

    Ok(DeviceCredentials {
        device_id,
        install_id,
        cdid,
        openudid,
        clientudid,
        token: String::new(),
        token_updated_at_ms: 0,
    })
}

async fn get_asr_token(http: &reqwest::Client, device_id: &str, cdid: &str) -> Result<String> {
    use md5::{Digest, Md5};

    let body_str = "body=null";
    let mut hasher = Md5::new();
    hasher.update(body_str.as_bytes());
    let x_ss_stub = format!("{:X}", hasher.finalize());

    let aid_str = AID.to_string();
    let rticket = format!(
        "{}",
        SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap_or_default()
            .as_millis()
    );
    let params = vec![
        ("device_platform", "android"),
        ("os", "android"),
        ("ssmix", "a"),
        ("channel", "official"),
        ("aid", aid_str.as_str()),
        ("app_name", "oime"),
        ("version_code", "100102018"),
        ("version_name", "1.1.2"),
        ("device_id", device_id),
        ("cdid", cdid),
        ("_rticket", rticket.as_str()),
    ];

    log::info!("[DoubaoIME] Fetching ASR token...");

    let resp = http
        .post(SETTINGS_URL)
        .header("User-Agent", USER_AGENT)
        .header("x-ss-stub", &x_ss_stub)
        .query(&params)
        .body(body_str)
        .send()
        .await
        .map_err(|e| AsrError::Connection(format!("settings request: {e}")))?;

    let status = resp.status();
    let resp_text = resp
        .text()
        .await
        .map_err(|e| AsrError::Connection(format!("settings read body: {e}")))?;

    if !status.is_success() {
        return Err(AsrError::Connection(format!(
            "settings HTTP {status}: {resp_text}"
        )));
    }

    let resp_json: serde_json::Value = serde_json::from_str(&resp_text)
        .map_err(|e| AsrError::Connection(format!("settings parse JSON: {e}")))?;

    let token = resp_json
        .get("data")
        .and_then(|d| d.get("settings"))
        .and_then(|s| s.get("asr_config"))
        .and_then(|a| a.get("app_key"))
        .and_then(|k| k.as_str())
        .ok_or_else(|| AsrError::Connection("settings: no asr_config.app_key".into()))?
        .to_string();

    log::info!("[DoubaoIME] ASR token acquired");
    Ok(token)
}

async fn ensure_credentials(credential_path: &Path) -> Result<DeviceCredentials> {
    let http = reqwest::Client::new();
    let mut creds = if let Some(creds) = load_credentials(credential_path) {
        if !creds.device_id.is_empty() {
            creds
        } else {
            register_device(&http).await?
        }
    } else {
        register_device(&http).await?
    };

    if !should_refresh_token(&creds) {
        log::info!(
            "[DoubaoIME] Using cached credentials (device_id={}, token_age={}s)",
            creds.device_id,
            unix_timestamp_ms()
                .saturating_sub(creds.token_updated_at_ms)
                / 1000
        );
        return Ok(creds);
    }

    log::info!(
        "[DoubaoIME] Refreshing ASR token for device_id={}",
        creds.device_id
    );

    match get_asr_token(&http, &creds.device_id, &creds.cdid).await {
        Ok(token) => {
            creds.token = token;
            creds.token_updated_at_ms = unix_timestamp_ms();
            save_credentials(credential_path, &creds)?;
            log::info!(
                "[DoubaoIME] Credentials saved to {}",
                credential_path.display()
            );
            Ok(creds)
        }
        Err(err) => {
            if !creds.token.is_empty() {
                log::warn!(
                    "[DoubaoIME] Token refresh failed, falling back to cached token: {err}"
                );
                Ok(creds)
            } else {
                Err(err)
            }
        }
    }
}

// ─── Opus Encoder ──────────────────────────────────────────────────

struct OpusEncoder {
    encoder: audiopus::coder::Encoder,
}

impl OpusEncoder {
    fn new() -> Result<Self> {
        let encoder = audiopus::coder::Encoder::new(
            audiopus::SampleRate::Hz16000,
            audiopus::Channels::Mono,
            audiopus::Application::Audio,
        )
        .map_err(|e| AsrError::Protocol(format!("opus encoder init: {e}")))?;

        Ok(Self { encoder })
    }

    fn encode_frame(&mut self, pcm: &[u8]) -> Result<Vec<u8>> {
        // PCM is 16-bit mono, so samples = bytes / 2
        let samples = pcm.len() / 2;
        // Reinterpret as i16 slice
        let pcm_i16: &[i16] =
            unsafe { std::slice::from_raw_parts(pcm.as_ptr() as *const i16, samples) };

        let mut output = vec![0u8; 4000]; // max opus frame size
        let encoded_len = self
            .encoder
            .encode(pcm_i16, &mut output)
            .map_err(|e| AsrError::Protocol(format!("opus encode: {e}")))?;

        output.truncate(encoded_len);
        Ok(output)
    }
}

// ─── Session Config ────────────────────────────────────────────────

fn build_session_config(device_id: &str) -> String {
    let config = serde_json::json!({
        "audio_info": {
            "channel": 1,
            "format": "speech_opus",
            "sample_rate": SAMPLE_RATE
        },
        "enable_punctuation": true,
        "enable_speech_rejection": false,
        "extra": {
            "app_name": "com.android.chrome",
            "cell_compress_rate": 8,
            "did": device_id,
            "enable_asr_threepass": true,
            "enable_asr_twopass": true,
            "input_mode": "tool"
        }
    });
    serde_json::to_string(&config).unwrap_or_default()
}

// ─── Provider ──────────────────────────────────────────────────────

/// Doubao Input Method streaming ASR provider.
///
/// Uses the free Doubao IME ASR service with protobuf over WebSocket.
/// Audio is encoded as Opus before sending. Device registration is
/// automatic on first use; credentials are cached to disk.
pub struct DoubaoImeProvider {
    ws: Option<WsStream>,
    request_id: String,
    token: String,
    device_id: String,
    opus_encoder: Option<OpusEncoder>,
    pcm_buffer: Vec<u8>,
    frame_index: u32,
    timestamp_ms: u64,
    session_finished: bool,
    /// Accumulated text from completed VAD segments.
    confirmed_text: String,
    /// Raw text from the most recent API response (current segment only,
    /// without the `confirmed_text` prefix). Used to detect segment resets
    /// when the API suddenly returns much shorter text.
    last_segment_text: String,
}

impl DoubaoImeProvider {
    pub fn new() -> Self {
        Self {
            ws: None,
            request_id: Uuid::new_v4().to_string(),
            token: String::new(),
            device_id: String::new(),
            opus_encoder: None,
            pcm_buffer: Vec::new(),
            frame_index: 0,
            timestamp_ms: 0,
            session_finished: false,
            confirmed_text: String::new(),
            last_segment_text: String::new(),
        }
    }

    async fn send_protobuf(&mut self, data: Vec<u8>) -> Result<()> {
        if let Some(ref mut ws) = self.ws {
            ws.send(Message::Binary(data))
                .await
                .map_err(|e| AsrError::Protocol(format!("send protobuf: {e}")))?;
        }
        Ok(())
    }

    async fn recv_response(&mut self) -> Result<proto::AsrResponse> {
        let ws = self
            .ws
            .as_mut()
            .ok_or_else(|| AsrError::Connection("not connected".into()))?;

        loop {
            match ws.next().await {
                Some(Ok(Message::Binary(data))) => {
                    return proto::decode_asr_response(&data);
                }
                Some(Ok(Message::Close(_))) => {
                    return Err(AsrError::Connection("connection closed".into()));
                }
                Some(Ok(_)) => {
                    // Skip non-binary frames
                    continue;
                }
                Some(Err(e)) => return Err(AsrError::Protocol(e.to_string())),
                None => return Err(AsrError::Connection("connection closed".into())),
            }
        }
    }

    fn send_opus_frame(
        &mut self,
        pcm_data: &[u8],
        frame_state: proto::FrameState,
    ) -> Result<Vec<u8>> {
        let encoder = self
            .opus_encoder
            .as_mut()
            .ok_or_else(|| AsrError::Protocol("opus encoder not initialized".into()))?;

        let opus_data = encoder.encode_frame(pcm_data)?;

        let metadata = serde_json::json!({
            "extra": {},
            "timestamp_ms": self.timestamp_ms
        });

        let msg = proto::encode_asr_request(
            "",
            "ASR",
            "TaskRequest",
            &serde_json::to_string(&metadata).unwrap_or_default(),
            &opus_data,
            &self.request_id,
            Some(frame_state),
        );

        self.frame_index += 1;
        self.timestamp_ms += FRAME_DURATION_MS as u64;

        Ok(msg)
    }
}

impl Default for DoubaoImeProvider {
    fn default() -> Self {
        Self::new()
    }
}

#[async_trait::async_trait]
impl AsrProvider for DoubaoImeProvider {
    async fn connect(&mut self, config: &AsrConfig) -> Result<()> {
        let connect_timeout = Duration::from_millis(config.connect_timeout_ms);

        // Determine credential path
        let credential_path = config
            .custom_headers
            .get("credential_path")
            .filter(|p| !p.is_empty())
            .map(PathBuf::from)
            .unwrap_or_else(|| {
                let home = std::env::var("HOME").unwrap_or_else(|_| "/tmp".into());
                PathBuf::from(home)
                    .join(".koe")
                    .join("doubaoime_credentials.json")
            });

        // Ensure we have valid credentials
        let creds = ensure_credentials(&credential_path).await?;
        self.token = creds.token.clone();
        self.device_id = creds.device_id.clone();

        // Initialize Opus encoder
        self.opus_encoder = Some(OpusEncoder::new()?);
        self.pcm_buffer.clear();
        self.frame_index = 0;
        self.confirmed_text.clear();
        self.last_segment_text.clear();
        self.timestamp_ms = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap_or_default()
            .as_millis() as u64;
        self.session_finished = false;

        // Connect WebSocket
        let ws_url = format!("{WEBSOCKET_URL}?aid={AID}&device_id={}", self.device_id);
        log::info!(
            "[DoubaoIME] Connecting to WebSocket: {}",
            ws_url.split('?').next().unwrap_or(&ws_url)
        );

        let mut request = ws_url
            .as_str()
            .into_client_request()
            .map_err(|e| AsrError::Connection(format!("invalid URL: {e}")))?;

        {
            let headers = request.headers_mut();
            headers.insert(
                "User-Agent",
                USER_AGENT
                    .parse()
                    .map_err(|_| AsrError::Connection("invalid user-agent".into()))?,
            );
            headers.insert(
                "proto-version",
                "v2".parse()
                    .map_err(|_| AsrError::Connection("invalid header".into()))?,
            );
            headers.insert(
                "x-custom-keepalive",
                "true"
                    .parse()
                    .map_err(|_| AsrError::Connection("invalid header".into()))?,
            );
        }

        let (ws_stream, _response) = timeout(connect_timeout, async {
            connect_async(request)
                .await
                .map_err(|e| AsrError::Connection(e.to_string()))
        })
        .await
        .map_err(|_| AsrError::Connection("connection timed out".into()))??;

        self.ws = Some(ws_stream);
        log::info!("[DoubaoIME] WebSocket connected");

        // StartTask
        let start_task = proto::encode_asr_request(
            &self.token,
            "ASR",
            "StartTask",
            "",
            &[],
            &self.request_id,
            None,
        );
        self.send_protobuf(start_task).await?;

        let resp = self.recv_response().await?;
        if resp.message_type == "TaskFailed" {
            return Err(AsrError::Connection(format!(
                "StartTask failed: {}",
                resp.status_message
            )));
        }
        log::info!("[DoubaoIME] TaskStarted");

        // StartSession
        let session_config = build_session_config(&self.device_id);
        let start_session = proto::encode_asr_request(
            &self.token,
            "ASR",
            "StartSession",
            &session_config,
            &[],
            &self.request_id,
            None,
        );
        self.send_protobuf(start_session).await?;

        let resp = self.recv_response().await?;
        if resp.message_type == "SessionFailed" {
            return Err(AsrError::Connection(format!(
                "StartSession failed: {}",
                resp.status_message
            )));
        }
        log::info!("[DoubaoIME] SessionStarted");

        Ok(())
    }

    async fn send_audio(&mut self, frame: &[u8]) -> Result<()> {
        self.pcm_buffer.extend_from_slice(frame);

        // Encode and send complete frames
        while self.pcm_buffer.len() >= BYTES_PER_FRAME {
            let pcm_frame: Vec<u8> = self.pcm_buffer.drain(..BYTES_PER_FRAME).collect();

            let frame_state = if self.frame_index == 0 {
                proto::FrameState::First
            } else {
                proto::FrameState::Middle
            };

            let msg = self.send_opus_frame(&pcm_frame, frame_state)?;
            self.send_protobuf(msg).await?;
        }

        Ok(())
    }

    async fn finish_input(&mut self) -> Result<()> {
        // Flush remaining PCM buffer
        if !self.pcm_buffer.is_empty() {
            let mut last_frame = std::mem::take(&mut self.pcm_buffer);
            // Pad to full frame
            if last_frame.len() < BYTES_PER_FRAME {
                last_frame.resize(BYTES_PER_FRAME, 0);
            }
            let msg = self.send_opus_frame(&last_frame, proto::FrameState::Last)?;
            self.send_protobuf(msg).await?;
        } else if self.frame_index > 0 {
            // Send a silent last frame
            let silent = vec![0u8; BYTES_PER_FRAME];
            let msg = self.send_opus_frame(&silent, proto::FrameState::Last)?;
            self.send_protobuf(msg).await?;
        }

        // FinishSession
        let finish = proto::encode_asr_request(
            &self.token,
            "ASR",
            "FinishSession",
            "",
            &[],
            &self.request_id,
            None,
        );
        self.send_protobuf(finish).await?;
        log::debug!("[DoubaoIME] FinishSession sent");

        Ok(())
    }

    async fn next_event(&mut self) -> Result<AsrEvent> {
        if self.session_finished {
            return Ok(AsrEvent::Closed);
        }

        let ws = self
            .ws
            .as_mut()
            .ok_or_else(|| AsrError::Connection("not connected".into()))?;

        // NOTE: No inner loop here — each call processes exactly one WS message
        // and returns immediately. This is critical for tokio::select! in the
        // caller: an inner loop would block send_audio from running while we
        // wait for the next non-heartbeat message.
        match ws.next().await {
            Some(Ok(Message::Binary(data))) => {
                let resp = proto::decode_asr_response(&data)?;

                log::debug!(
                    "[DoubaoIME] Response: type={:?}, status={}, msg={:?}, result_json_len={}",
                    resp.message_type,
                    resp.status_code,
                    resp.status_message,
                    resp.result_json.len()
                );
                if !resp.result_json.is_empty() {
                    log::debug!("[DoubaoIME] result_json: {}", resp.result_json);
                }

                // Handle control messages
                match resp.message_type.as_str() {
                    "TaskStarted" | "SessionStarted" => {
                        return Ok(AsrEvent::Connected);
                    }
                    "TaskFailed" | "SessionFailed" => {
                        self.session_finished = true;
                        return Ok(AsrEvent::Error(resp.status_message));
                    }
                    "SessionFinished" => {
                        self.session_finished = true;
                        return Ok(AsrEvent::Closed);
                    }
                    _ => {}
                }

                // Parse result_json
                if resp.result_json.is_empty() {
                    return Ok(AsrEvent::Connected); // no-op event for heartbeat
                }

                let json: serde_json::Value = match serde_json::from_str(&resp.result_json) {
                    Ok(v) => v,
                    Err(_) => return Ok(AsrEvent::Connected),
                };

                // Check if results exist
                let results = match json.get("results") {
                    Some(serde_json::Value::Array(arr)) => arr,
                    _ => return Ok(AsrEvent::Connected), // heartbeat
                };

                // Check for VAD start
                if json
                    .get("extra")
                    .and_then(|e| e.get("vad_start"))
                    .and_then(|v| v.as_bool())
                    .unwrap_or(false)
                {
                    return Ok(AsrEvent::Connected); // VAD start, no text yet
                }

                // Extract text from all results (segments) by concatenating,
                // and use the LAST result's flags for event type determination.
                // The results array may contain multiple segments: earlier ones
                // are already confirmed, the last one is the active segment.
                let mut text = String::new();
                let mut is_interim = true;
                let mut is_vad_finished = false;
                let mut nonstream_result = false;

                for r in results {
                    if let Some(t) = r.get("text").and_then(|t| t.as_str()) {
                        if !t.is_empty() {
                            text.push_str(t);
                        }
                    }
                    // Track flags from the last result (most recent segment)
                    is_interim = r
                        .get("is_interim")
                        .and_then(|v| v.as_bool())
                        .unwrap_or(true);
                    is_vad_finished = r
                        .get("is_vad_finished")
                        .and_then(|v| v.as_bool())
                        .unwrap_or(false);
                    nonstream_result = r
                        .get("extra")
                        .and_then(|e| e.get("nonstream_result"))
                        .and_then(|v| v.as_bool())
                        .unwrap_or(false);
                }

                if text.is_empty() {
                    return Ok(AsrEvent::Connected); // empty result
                }

                // ── Segment-reset detection ──────────────────────────
                // The API resets text when a new VAD segment begins.
                // Detect this by checking if the text suddenly became
                // much shorter than what we had, and isn't a prefix of
                // the previous text (which would indicate a correction).
                if !self.last_segment_text.is_empty()
                    && text.len() < self.last_segment_text.len() / 2
                    && !self.last_segment_text.starts_with(&text)
                {
                    // New segment started — save previous segment text.
                    log::info!(
                        "[DoubaoIME] Segment reset detected ({} -> {} chars), \
                         preserving previous segment",
                        self.last_segment_text.len(),
                        text.len(),
                    );
                    self.confirmed_text.push_str(&self.last_segment_text);
                }

                // Track raw segment text for next comparison.
                self.last_segment_text = text.clone();

                // Prepend confirmed text from earlier segments.
                let full = if self.confirmed_text.is_empty() {
                    text
                } else {
                    format!("{}{}", self.confirmed_text, text)
                };

                // Non-streaming (third-pass) or definite (second-pass) result
                if nonstream_result || (!is_interim && is_vad_finished) {
                    log::info!("[DoubaoIME] Final: {full}");
                    return Ok(AsrEvent::Final(full));
                }

                if !is_interim {
                    return Ok(AsrEvent::Definite(full));
                }

                // Interim
                Ok(AsrEvent::Interim(full))
            }
            Some(Ok(Message::Close(_))) => {
                self.session_finished = true;
                Ok(AsrEvent::Closed)
            }
            Some(Ok(_)) => Ok(AsrEvent::Connected), // skip non-binary frames
            Some(Err(e)) => Err(AsrError::Protocol(e.to_string())),
            None => {
                self.session_finished = true;
                Ok(AsrEvent::Closed)
            }
        }
    }

    async fn close(&mut self) -> Result<()> {
        if let Some(mut ws) = self.ws.take() {
            let _ = ws.close(None).await;
        }
        self.opus_encoder = None;
        self.session_finished = true;
        log::debug!("[DoubaoIME] Connection closed");
        Ok(())
    }
}
