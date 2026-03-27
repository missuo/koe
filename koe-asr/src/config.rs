/// Configuration for an ASR session.
#[derive(Debug, Clone)]
pub struct AsrConfig {
    /// WebSocket endpoint URL
    pub url: String,
    /// X-Api-App-Key (App ID from Volcengine console)
    pub app_key: String,
    /// X-Api-Access-Key (Access Token from Volcengine console) or API Key for Aliyun
    pub access_key: String,
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
    /// Language code for ASR (e.g. "zh", "en") - used by Aliyun Qwen ASR
    pub language: Option<String>,
}

impl Default for AsrConfig {
    fn default() -> Self {
        Self {
            url: "wss://openspeech.bytedance.com/api/v3/sauc/bigmodel_async".into(),
            app_key: String::new(),
            access_key: String::new(),
            resource_id: "volc.seedasr.sauc.duration".into(),
            sample_rate_hz: 16000,
            connect_timeout_ms: 3000,
            final_wait_timeout_ms: 5000,
            enable_ddc: true,
            enable_itn: true,
            enable_punc: true,
            enable_nonstream: true,
            hotwords: Vec::new(),
            language: Some("zh".to_string()),
        }
    }
}
