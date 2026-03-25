/// Unified configuration for an ASR session.
#[derive(Debug, Clone)]
pub struct AsrConfig {
    /// Connection timeout in milliseconds.
    pub connect_timeout_ms: u64,
    /// Timeout waiting for final ASR result after finish signal.
    pub final_wait_timeout_ms: u64,
    /// Optional hotwords. Providers can ignore this if unsupported.
    pub hotwords: Vec<String>,
    /// Provider-specific runtime configuration.
    pub provider: ProviderConfig,
}

impl AsrConfig {
    pub fn provider_kind(&self) -> AsrProviderKind {
        match self.provider {
            ProviderConfig::Doubao(_) => AsrProviderKind::Doubao,
            ProviderConfig::OpenAI(_) => AsrProviderKind::OpenAI,
            ProviderConfig::Qwen(_) => AsrProviderKind::Qwen,
        }
    }

    pub fn doubao(&self) -> Option<&DoubaoConfig> {
        match &self.provider {
            ProviderConfig::Doubao(config) => Some(config),
            ProviderConfig::OpenAI(_) | ProviderConfig::Qwen(_) => None,
        }
    }

    pub fn openai(&self) -> Option<&OpenAIRealtimeConfig> {
        match &self.provider {
            ProviderConfig::Doubao(_) | ProviderConfig::Qwen(_) => None,
            ProviderConfig::OpenAI(config) => Some(config),
        }
    }

    pub fn qwen(&self) -> Option<&QwenRealtimeConfig> {
        match &self.provider {
            ProviderConfig::Qwen(config) => Some(config),
            ProviderConfig::Doubao(_) | ProviderConfig::OpenAI(_) => None,
        }
    }
}

impl Default for AsrConfig {
    fn default() -> Self {
        Self {
            connect_timeout_ms: 3000,
            final_wait_timeout_ms: 5000,
            hotwords: Vec::new(),
            provider: ProviderConfig::Doubao(DoubaoConfig::default()),
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum AsrProviderKind {
    Doubao,
    OpenAI,
    Qwen,
}

#[derive(Debug, Clone)]
pub enum ProviderConfig {
    Doubao(DoubaoConfig),
    OpenAI(OpenAIRealtimeConfig),
    Qwen(QwenRealtimeConfig),
}

#[derive(Debug, Clone)]
pub struct DoubaoConfig {
    pub url: String,
    pub app_key: String,
    pub access_key: String,
    pub resource_id: String,
    pub sample_rate_hz: u32,
    pub enable_ddc: bool,
    pub enable_itn: bool,
    pub enable_punc: bool,
    pub enable_nonstream: bool,
}

impl Default for DoubaoConfig {
    fn default() -> Self {
        Self {
            url: "wss://openspeech.bytedance.com/api/v3/sauc/bigmodel_async".into(),
            app_key: String::new(),
            access_key: String::new(),
            resource_id: "volc.seedasr.sauc.duration".into(),
            sample_rate_hz: 16000,
            enable_ddc: true,
            enable_itn: true,
            enable_punc: true,
            enable_nonstream: true,
        }
    }
}

#[derive(Debug, Clone)]
pub struct OpenAIRealtimeConfig {
    pub base_url: String,
    pub api_key: String,
    pub model: String,
    pub language: String,
    pub prompt: String,
    /// Input format produced by the native capture layer.
    pub input_sample_rate_hz: u32,
    /// OpenAI Realtime transcription requires audio/pcm at 24 kHz.
    pub output_sample_rate_hz: u32,
}

impl Default for OpenAIRealtimeConfig {
    fn default() -> Self {
        Self {
            base_url: "https://api.openai.com/v1".into(),
            api_key: String::new(),
            model: "gpt-4o-transcribe".into(),
            language: String::new(),
            prompt: String::new(),
            input_sample_rate_hz: 16000,
            output_sample_rate_hz: 24000,
        }
    }
}

#[derive(Debug, Clone)]
pub struct QwenRealtimeConfig {
    pub base_url: String,
    pub api_key: String,
    pub model: String,
    pub language: String,
    pub sample_rate_hz: u32,
}

impl Default for QwenRealtimeConfig {
    fn default() -> Self {
        Self {
            base_url: "wss://dashscope-intl.aliyuncs.com/api-ws/v1/realtime".into(),
            api_key: String::new(),
            model: "qwen3-asr-flash-realtime".into(),
            language: String::new(),
            sample_rate_hz: 16000,
        }
    }
}
