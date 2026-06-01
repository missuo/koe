use std::collections::HashMap;

/// Configuration for an ASR session.
#[derive(Debug, Clone)]
pub struct AsrConfig {
    /// WebSocket endpoint URL
    pub url: String,
    /// X-Api-App-Key (App ID from Volcengine console) — old console auth
    pub app_key: String,
    /// X-Api-Access-Key (Access Token from Volcengine console) or API Key for Qwen
    pub access_key: String,
    /// X-Api-Key (new console auth, single key replaces app_key + access_key)
    pub api_key: String,
    /// X-Api-Resource-Id (e.g. "volc.bigasr.sauc.duration")
    pub resource_id: String,
    /// Audio sample rate in Hz (default: 16000)
    pub sample_rate_hz: u32,
    /// Connection timeout in milliseconds (default: 3000)
    pub connect_timeout_ms: u64,
    /// Timeout waiting for final ASR result after finish signal (default: 5000)
    pub final_wait_timeout_ms: u64,
    /// Enable DDC (disfluency removal / smoothing)
    pub enable_ddc: bool,
    /// Enable ITN (inverse text normalization)
    pub enable_itn: bool,
    /// Enable automatic punctuation
    pub enable_punc: bool,
    /// Enable two-pass recognition (streaming + non-streaming re-recognition)
    pub enable_nonstream: bool,
    /// Hotwords for improved recognition accuracy
    pub hotwords: Vec<String>,
    /// Language code for ASR (e.g. "zh-CN", "en-US", "ja-JP")
    pub language: Option<String>,
    /// Custom HTTP headers for WebSocket connection
    pub custom_headers: HashMap<String, String>,
    /// Forced endpoint time in ms (min 200, server default 800)
    pub end_window_size: Option<u32>,
    /// Audio must exceed this duration (ms) before endpoint detection kicks in
    pub force_to_speech_time: Option<u32>,
    /// Max silence threshold for semantic segmentation (ms, default 3000)
    pub vad_segment_duration: Option<u32>,
    /// Output traditional Chinese variant: "traditional", "tw", or "hk"
    pub output_zh_variant: Option<String>,
    /// Enable first-character return acceleration
    pub enable_accelerate_text: bool,
    /// Acceleration score (0-20, higher = faster first character)
    pub accelerate_score: Option<u32>,
    /// Dialog context messages for improved recognition
    pub context_messages: Vec<String>,
}

impl Default for AsrConfig {
    fn default() -> Self {
        Self {
            url: "wss://openspeech.bytedance.com/api/v3/sauc/bigmodel_async".into(),
            app_key: String::new(),
            access_key: String::new(),
            api_key: String::new(),
            resource_id: "volc.seedasr.sauc.duration".into(),
            sample_rate_hz: 16000,
            connect_timeout_ms: 3000,
            final_wait_timeout_ms: 5000,
            enable_ddc: true,
            enable_itn: true,
            enable_punc: true,
            enable_nonstream: true,
            hotwords: Vec::new(),
            language: Some("zh-CN".to_string()),
            custom_headers: HashMap::new(),
            end_window_size: None,
            force_to_speech_time: None,
            vad_segment_duration: None,
            output_zh_variant: None,
            enable_accelerate_text: false,
            accelerate_score: None,
            context_messages: Vec::new(),
        }
    }
}
