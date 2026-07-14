use crate::errors::{KoeError, Result};
use serde::{Deserialize, Serialize};
use std::collections::BTreeMap;
use std::path::{Path, PathBuf};

/// Root configuration structure matching ~/.koe/config.yaml
#[derive(Debug, Deserialize, Clone)]
pub struct Config {
    #[serde(default)]
    pub asr: AsrSection,
    #[serde(default)]
    pub llm: LlmSection,
    #[serde(default)]
    pub feedback: FeedbackSection,
    #[serde(default)]
    pub dictionary: DictionarySection,
    #[serde(default)]
    pub hotkey: HotkeySection,
    #[serde(default)]
    pub overlay: OverlaySection,
    #[serde(default = "default_prompt_templates")]
    pub prompt_templates: Vec<PromptTemplate>,
}

/// A named prompt template selectable from the overlay UI.
#[derive(Debug, Deserialize, Serialize, Clone, PartialEq, Eq)]
pub struct PromptTemplate {
    /// Display name shown on the overlay button
    pub name: String,
    /// Whether this template should be shown in the overlay selector
    #[serde(default = "default_true")]
    pub enabled: bool,
    /// Shortcut key number (1-9)
    pub shortcut: u8,
    /// Inline system prompt text (mutually exclusive with system_prompt_path)
    #[serde(default)]
    pub system_prompt: Option<String>,
    /// Path to system prompt file, relative to ~/.koe/ (alternative to inline)
    #[serde(default)]
    pub system_prompt_path: Option<String>,
}

// ─── ASR V2 Configuration ───────────────────────────────────────────

#[derive(Debug, Deserialize, Clone)]
pub struct AsrSection {
    /// Which ASR provider to use: "doubaoime" (default), "doubao", "qwen", "glm", "mimo", "mlx", "sherpa-onnx", "apple-speech"
    #[serde(default = "default_asr_provider")]
    pub provider: String,

    /// DoubaoIME (豆包输入法) free ASR — no API key required
    #[serde(default)]
    pub doubaoime: DoubaoImeAsrConfig,

    /// Doubao (豆包/火山引擎) ASR configuration
    #[serde(default)]
    pub doubao: DoubaoAsrConfig,

    /// Qwen ASR configuration
    #[serde(default)]
    pub qwen: QwenAsrConfig,

    /// MLX local ASR configuration (Apple Silicon only)
    #[serde(default)]
    pub mlx: MlxAsrConfig,

    /// Sherpa-ONNX local ASR configuration (CPU)
    #[serde(rename = "sherpa-onnx", default)]
    pub sherpa_onnx: SherpaOnnxAsrConfig,

    /// Apple Speech local ASR configuration (macOS 26+)
    #[serde(rename = "apple-speech", default)]
    pub apple_speech: AppleSpeechAsrConfig,

    /// GLM (Zhipu) ASR configuration
    #[serde(default)]
    pub glm: GlmAsrConfig,

    /// MiMo (Xiaomi) ASR configuration
    #[serde(default)]
    pub mimo: MimoAsrConfig,
}

#[derive(Debug, Deserialize, Clone)]
pub struct QwenAsrConfig {
    #[serde(default = "default_qwen_url")]
    pub url: String,
    #[serde(default)]
    pub api_key: String,
    #[serde(default = "default_qwen_model")]
    pub model: String,
    #[serde(default = "default_qwen_language")]
    pub language: String,
    #[serde(default = "default_connect_timeout")]
    pub connect_timeout_ms: u64,
    #[serde(default = "default_final_wait_timeout")]
    pub final_wait_timeout_ms: u64,
    /// Custom HTTP headers for WebSocket connection
    #[serde(default)]
    pub headers: std::collections::HashMap<String, String>,
}

impl Default for QwenAsrConfig {
    fn default() -> Self {
        Self {
            url: default_qwen_url(),
            api_key: String::new(),
            model: default_qwen_model(),
            language: default_qwen_language(),
            connect_timeout_ms: default_connect_timeout(),
            final_wait_timeout_ms: default_final_wait_timeout(),
            headers: std::collections::HashMap::new(),
        }
    }
}

#[derive(Debug, Deserialize, Clone)]
pub struct DoubaoImeAsrConfig {
    /// Path to credential cache file (relative to ~/.koe/ or absolute)
    #[serde(default = "default_doubaoime_credential_path")]
    pub credential_path: String,
    #[serde(default = "default_connect_timeout")]
    pub connect_timeout_ms: u64,
    #[serde(default = "default_final_wait_timeout")]
    pub final_wait_timeout_ms: u64,
}

impl Default for DoubaoImeAsrConfig {
    fn default() -> Self {
        Self {
            credential_path: default_doubaoime_credential_path(),
            connect_timeout_ms: default_connect_timeout(),
            final_wait_timeout_ms: default_final_wait_timeout(),
        }
    }
}

#[derive(Debug, Deserialize, Clone)]
pub struct DoubaoAsrConfig {
    #[serde(default = "default_asr_url")]
    pub url: String,
    /// X-Api-Key for new console auth (takes precedence over app_key + access_key)
    #[serde(default)]
    pub api_key: String,
    #[serde(default)]
    pub app_key: String,
    #[serde(default)]
    pub access_key: String,
    #[serde(default = "default_resource_id")]
    pub resource_id: String,
    #[serde(default = "default_connect_timeout")]
    pub connect_timeout_ms: u64,
    #[serde(default = "default_final_wait_timeout")]
    pub final_wait_timeout_ms: u64,
    #[serde(default = "default_true")]
    pub enable_ddc: bool,
    #[serde(default = "default_true")]
    pub enable_itn: bool,
    #[serde(default = "default_true")]
    pub enable_punc: bool,
    #[serde(default = "default_true")]
    pub enable_nonstream: bool,
    /// Language code (e.g. "zh-CN", "en-US", "ja-JP"). Empty = auto (中英文 + 方言)
    #[serde(default)]
    pub language: Option<String>,
    /// Forced endpoint time in ms (min 200, server default 800)
    #[serde(default, deserialize_with = "deserialize_option_u32_lenient")]
    pub end_window_size: Option<u32>,
    /// Audio must exceed this duration (ms) before endpoint detection kicks in
    #[serde(default, deserialize_with = "deserialize_option_u32_lenient")]
    pub force_to_speech_time: Option<u32>,
    /// Max silence for semantic segmentation (ms, default 3000)
    #[serde(default, deserialize_with = "deserialize_option_u32_lenient")]
    pub vad_segment_duration: Option<u32>,
    /// Output traditional Chinese: "traditional", "tw", or "hk"
    #[serde(default, deserialize_with = "deserialize_option_string_lenient")]
    pub output_zh_variant: Option<String>,
    /// Enable first-character return acceleration
    #[serde(default)]
    pub enable_accelerate_text: bool,
    /// Acceleration score (0-20, higher = faster first char)
    #[serde(default, deserialize_with = "deserialize_option_u32_lenient")]
    pub accelerate_score: Option<u32>,
    /// Custom HTTP headers for WebSocket connection
    #[serde(default)]
    pub headers: std::collections::HashMap<String, String>,
}

#[derive(Debug, Deserialize, Clone)]
pub struct MlxAsrConfig {
    /// Model directory name under ~/.koe/models/mlx/
    #[serde(default = "default_mlx_model")]
    pub model: String,
    /// Delay preset: "realtime", "agent", "subtitle"
    #[serde(default = "default_mlx_delay_preset")]
    pub delay_preset: String,
    /// Language: "auto", "zh", "en"
    #[serde(default = "default_mlx_language")]
    pub language: String,
}

impl Default for MlxAsrConfig {
    fn default() -> Self {
        Self {
            model: default_mlx_model(),
            delay_preset: default_mlx_delay_preset(),
            language: default_mlx_language(),
        }
    }
}

#[derive(Debug, Deserialize, Clone)]
pub struct SherpaOnnxAsrConfig {
    /// Model directory name under ~/.koe/models/sherpa-onnx/
    #[serde(default = "default_sherpa_onnx_model")]
    pub model: String,
    /// Number of threads for inference (default: 2)
    #[serde(default = "default_sherpa_onnx_num_threads")]
    pub num_threads: i32,
    /// Hotwords score boost (default: 1.5)
    #[serde(default = "default_sherpa_onnx_hotwords_score")]
    pub hotwords_score: f32,
    /// Trailing silence for endpoint detection in seconds (default: 1.2)
    #[serde(default = "default_sherpa_onnx_endpoint_silence")]
    pub endpoint_silence: f32,
}

impl Default for SherpaOnnxAsrConfig {
    fn default() -> Self {
        Self {
            model: default_sherpa_onnx_model(),
            num_threads: default_sherpa_onnx_num_threads(),
            hotwords_score: default_sherpa_onnx_hotwords_score(),
            endpoint_silence: default_sherpa_onnx_endpoint_silence(),
        }
    }
}

#[derive(Debug, Deserialize, Clone)]
pub struct AppleSpeechAsrConfig {
    /// Locale identifier (e.g. "zh_CN", "en_US")
    #[serde(default = "default_apple_speech_locale")]
    pub locale: String,
}

impl Default for AppleSpeechAsrConfig {
    fn default() -> Self {
        Self {
            locale: default_apple_speech_locale(),
        }
    }
}

fn default_apple_speech_locale() -> String {
    "zh_CN".to_string()
}

#[derive(Debug, Deserialize, Clone)]
pub struct GlmAsrConfig {
    #[serde(default = "default_glm_url")]
    pub url: String,
    #[serde(default)]
    pub api_key: String,
    #[serde(default = "default_glm_model")]
    pub model: String,
    /// ASR hint / prompt for guiding recognition
    #[serde(default)]
    pub prompt: Option<String>,
    #[serde(default = "default_connect_timeout")]
    pub connect_timeout_ms: u64,
    #[serde(default = "default_final_wait_timeout")]
    pub final_wait_timeout_ms: u64,
}

impl Default for GlmAsrConfig {
    fn default() -> Self {
        Self {
            url: default_glm_url(),
            api_key: String::new(),
            model: default_glm_model(),
            prompt: None,
            connect_timeout_ms: default_connect_timeout(),
            final_wait_timeout_ms: default_final_wait_timeout(),
        }
    }
}

#[derive(Debug, Deserialize, Clone)]
pub struct MimoAsrConfig {
    #[serde(default = "default_mimo_url")]
    pub url: String,
    #[serde(default)]
    pub api_key: String,
    #[serde(default = "default_mimo_model")]
    pub model: String,
    /// Language code: "auto" (default), "zh-CN", "en-US", etc.
    #[serde(default = "default_mimo_language")]
    pub language: String,
    #[serde(default = "default_connect_timeout")]
    pub connect_timeout_ms: u64,
    #[serde(default = "default_final_wait_timeout")]
    pub final_wait_timeout_ms: u64,
}

impl Default for MimoAsrConfig {
    fn default() -> Self {
        Self {
            url: default_mimo_url(),
            api_key: String::new(),
            model: default_mimo_model(),
            language: default_mimo_language(),
            connect_timeout_ms: default_connect_timeout(),
            final_wait_timeout_ms: default_final_wait_timeout(),
        }
    }
}

// ─── Other Sections (unchanged) ─────────────────────────────────────

#[derive(Debug, Deserialize, Clone)]
pub struct LlmSection {
    #[serde(default = "default_true")]
    pub enabled: bool,
    #[serde(default = "default_false")]
    pub prompt_templates_enabled: bool,
    /// Active LLM profile id.
    #[serde(default = "default_llm_active_profile")]
    pub active_profile: String,
    /// Saved LLM profiles keyed by stable profile id.
    #[serde(default = "default_llm_profiles")]
    pub profiles: BTreeMap<String, LlmProfileConfig>,
    #[serde(default)]
    pub temperature: f64,
    #[serde(default = "default_top_p")]
    pub top_p: f64,
    #[serde(default = "default_llm_timeout")]
    pub timeout_ms: u64,
    #[serde(default = "default_max_output_tokens")]
    pub max_output_tokens: u32,
    #[serde(default = "default_dictionary_max_candidates")]
    pub dictionary_max_candidates: usize,
    #[serde(default = "default_system_prompt_path")]
    pub system_prompt_path: String,
    #[serde(default = "default_user_prompt_path")]
    pub user_prompt_path: String,
}

#[derive(Debug, Deserialize, Serialize, Clone)]
pub struct LlmProfilesPayload {
    pub active_profile: String,
    pub profiles: BTreeMap<String, LlmProfileConfig>,
}

#[derive(Debug, Deserialize, Serialize, Clone, Copy, Default, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum LlmApiProtocol {
    #[default]
    OpenaiChat,
    OpenaiResponses,
    AnthropicMessages,
}

impl LlmApiProtocol {
    pub fn default_endpoint_path(self) -> &'static str {
        match self {
            Self::OpenaiChat => "/chat/completions",
            Self::OpenaiResponses => "/responses",
            Self::AnthropicMessages => "/messages",
        }
    }
}

#[derive(Debug, Deserialize, Serialize, Clone)]
pub struct LlmProfileConfig {
    #[serde(default)]
    pub name: String,
    /// LLM provider: "openai", "anthropic", "apfel", or "mlx". "apfel" is
    /// tracked separately so the UI can show Apple Foundation Models defaults.
    #[serde(default = "default_llm_provider")]
    pub provider: String,
    /// Wire protocol used by this remote profile. Existing profiles without
    /// this field continue to use OpenAI Chat Completions.
    #[serde(default)]
    pub api_protocol: LlmApiProtocol,
    #[serde(default)]
    pub base_url: String,
    #[serde(default)]
    pub api_key: String,
    #[serde(default)]
    pub model: String,
    /// Relative API path appended to `base_url`. The legacy
    /// `chat_completions_path` key is accepted for migration.
    #[serde(default, alias = "chat_completions_path")]
    pub endpoint_path: String,
    #[serde(default = "default_llm_max_token_parameter")]
    pub max_token_parameter: LlmMaxTokenParameter,
    #[serde(default)]
    pub no_reasoning_control: LlmNoReasoningControl,
    /// MLX local LLM configuration (Apple Silicon only).
    #[serde(default)]
    pub mlx: MlxLlmConfig,
}

#[derive(Debug, Deserialize, Serialize, Clone)]
pub struct LlmProfileRuntimeConfig {
    pub id: String,
    pub name: String,
    pub provider: String,
    #[serde(default)]
    pub api_protocol: LlmApiProtocol,
    pub base_url: String,
    pub api_key: String,
    pub model: String,
    #[serde(default, alias = "chat_completions_path")]
    pub endpoint_path: String,
    pub max_token_parameter: LlmMaxTokenParameter,
    pub no_reasoning_control: LlmNoReasoningControl,
    pub mlx: MlxLlmConfig,
}

impl LlmSection {
    pub fn active_profile_config(&self) -> Result<LlmProfileRuntimeConfig> {
        let profile = self.profiles.get(&self.active_profile).ok_or_else(|| {
            KoeError::Config(format!("LLM profile not found: {}", self.active_profile))
        })?;
        Ok(profile.to_runtime_config(&self.active_profile))
    }

    pub fn profiles_payload(&self) -> LlmProfilesPayload {
        LlmProfilesPayload {
            active_profile: self.active_profile.clone(),
            profiles: self.profiles.clone(),
        }
    }
}

impl LlmProfileConfig {
    pub fn to_runtime_config(&self, id: &str) -> LlmProfileRuntimeConfig {
        LlmProfileRuntimeConfig {
            id: id.to_string(),
            name: if self.name.is_empty() {
                id.to_string()
            } else {
                self.name.clone()
            },
            provider: self.provider.clone(),
            api_protocol: self.api_protocol,
            base_url: self.base_url.clone(),
            api_key: self.api_key.clone(),
            model: self.model.clone(),
            endpoint_path: self.endpoint_path.clone(),
            max_token_parameter: self.max_token_parameter,
            no_reasoning_control: self.no_reasoning_control,
            mlx: self.mlx.clone(),
        }
    }
}

impl LlmProfileRuntimeConfig {
    pub fn effective_api_protocol(&self) -> LlmApiProtocol {
        match self.provider.as_str() {
            "anthropic" => LlmApiProtocol::AnthropicMessages,
            "apfel" => LlmApiProtocol::OpenaiChat,
            _ => self.api_protocol,
        }
    }

    pub fn effective_endpoint_path(&self) -> &str {
        let configured = self.endpoint_path.trim();
        if configured.is_empty() {
            self.effective_api_protocol().default_endpoint_path()
        } else {
            configured
        }
    }

    pub fn is_ready(&self) -> bool {
        match self.provider.as_str() {
            "mlx" => !self.mlx.model.is_empty(),
            _ => !self.base_url.is_empty() && !self.model.is_empty(),
        }
    }
}

#[derive(Debug, Deserialize, Serialize, Clone)]
pub struct MlxLlmConfig {
    /// Model directory name under ~/.koe/models/
    #[serde(default = "default_mlx_llm_model")]
    pub model: String,
}

impl Default for MlxLlmConfig {
    fn default() -> Self {
        Self {
            model: default_mlx_llm_model(),
        }
    }
}

impl Default for LlmProfileConfig {
    fn default() -> Self {
        Self {
            name: String::new(),
            provider: default_llm_provider(),
            api_protocol: LlmApiProtocol::default(),
            base_url: String::new(),
            api_key: String::new(),
            model: String::new(),
            endpoint_path: String::new(),
            max_token_parameter: default_llm_max_token_parameter(),
            no_reasoning_control: LlmNoReasoningControl::default(),
            mlx: MlxLlmConfig::default(),
        }
    }
}

#[derive(Debug, Deserialize, Serialize, Clone, Copy)]
#[serde(rename_all = "snake_case")]
pub enum LlmMaxTokenParameter {
    MaxTokens,
    MaxCompletionTokens,
}

#[derive(Debug, Deserialize, Serialize, Clone, Copy, Default)]
#[serde(rename_all = "snake_case")]
pub enum LlmNoReasoningControl {
    #[default]
    ReasoningEffort,
    Thinking,
    None,
}

#[derive(Debug, Deserialize, Clone)]
pub struct FeedbackSection {
    #[serde(default)]
    pub start_sound: bool,
    #[serde(default)]
    pub stop_sound: bool,
    #[serde(default)]
    pub error_sound: bool,
    /// Mute system audio output for the duration of a recording (opt-in, default off).
    #[serde(default)]
    pub mute_system_output: bool,
}

#[derive(Debug, Deserialize, Clone)]
pub struct DictionarySection {
    #[serde(default = "default_dictionary_path")]
    pub path: String,
}

#[derive(Debug, Deserialize, Clone)]
pub struct OverlaySection {
    #[serde(default = "default_overlay_font_family")]
    pub font_family: String,
    #[serde(default = "default_overlay_font_size")]
    pub font_size: u16,
    #[serde(default = "default_overlay_bottom_margin")]
    pub bottom_margin: u16,
    #[serde(default = "default_overlay_limit_visible_lines")]
    pub limit_visible_lines: bool,
    #[serde(default = "default_overlay_max_visible_lines")]
    pub max_visible_lines: u16,
}

/// Deserialize a YAML value that can be either a string ("fn") or an integer (96)
/// into a String. This is needed because YAML `trigger_key: 96` is parsed as an
/// integer, not a string, and serde_yaml won't auto-convert int → String.
fn deserialize_string_or_int<'de, D>(deserializer: D) -> std::result::Result<String, D::Error>
where
    D: serde::Deserializer<'de>,
{
    struct StringOrInt;
    impl<'de> serde::de::Visitor<'de> for StringOrInt {
        type Value = String;
        fn expecting(&self, formatter: &mut std::fmt::Formatter) -> std::fmt::Result {
            formatter.write_str("a string or integer")
        }
        fn visit_str<E: serde::de::Error>(self, v: &str) -> std::result::Result<String, E> {
            Ok(v.to_string())
        }
        fn visit_i64<E: serde::de::Error>(self, v: i64) -> std::result::Result<String, E> {
            Ok(v.to_string())
        }
        fn visit_u64<E: serde::de::Error>(self, v: u64) -> std::result::Result<String, E> {
            Ok(v.to_string())
        }
    }
    deserializer.deserialize_any(StringOrInt)
}

#[derive(Debug, Deserialize, Clone)]
pub struct HotkeySection {
    /// Trigger key for voice input.
    /// Options: "fn", "left_option", "right_option", "left_command", "right_command", "left_control", "right_control"
    /// Or a raw keycode number (e.g. 122 for F1) for non-modifier keys.
    /// Default: "fn"
    #[serde(
        default = "default_trigger_key",
        deserialize_with = "deserialize_string_or_int"
    )]
    pub trigger_key: String,

    /// Legacy field kept only so older configs still deserialize cleanly.
    /// Runtime no longer exposes or resolves a separate cancel hotkey.
    #[serde(default, deserialize_with = "deserialize_string_or_int")]
    pub cancel_key: String,

    /// Trigger mode: "hold" (press-and-hold, default), "toggle" (tap to
    /// start/stop), or "double_tap" (double-tap to start, single-tap to stop).
    #[serde(default = "default_trigger_mode")]
    pub trigger_mode: String,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum HotkeyMatchKind {
    ModifierOnly = 0,
    KeyDown = 1,
}

/// Resolved hotkey parameters for the native side
#[derive(Debug, Clone, Copy)]
pub struct HotkeyParams {
    /// Primary key code (from Carbon Events)
    pub key_code: u16,
    /// Alternative key code (e.g. 179 for Globe key), 0 if none
    pub alt_key_code: u16,
    /// Modifier flag to check. For modifier-only hotkeys this is the key-state
    /// flag to observe on flagsChanged. For keyDown hotkeys this is the exact
    /// generic modifier mask required alongside the main key code.
    pub modifier_flag: u64,
    /// Whether this hotkey is modifier-only or should be matched on keyDown/up.
    pub match_kind: HotkeyMatchKind,
}

impl HotkeySection {
    /// Resolve the configured trigger hotkey into concrete key codes and
    /// modifier flags for the native side.
    pub fn resolve(&self) -> HotkeyParams {
        Self::resolve_key(&self.normalized_trigger_key())
    }

    pub fn normalized_trigger_key(&self) -> String {
        Self::normalize_trigger_key_name(&self.trigger_key)
    }

    fn normalize_trigger_key_name(value: &str) -> String {
        match value {
            "left_option" | "right_option" | "left_command" | "right_command" | "left_control"
            | "right_control" | "fn" => value.into(),
            _ if Self::parse_raw_keycode(value).is_some() => {
                Self::parse_raw_keycode(value).unwrap().to_string()
            }
            _ if Self::parse_hotkey_combo(value).is_some() => {
                Self::parse_hotkey_combo(value).unwrap().normalized_value
            }
            _ => default_trigger_key(),
        }
    }

    /// Try to parse a string as a raw keycode (u16).
    /// Supports decimal (e.g. "122") and hex with 0x prefix (e.g. "0x7a").
    fn parse_raw_keycode(value: &str) -> Option<u16> {
        let trimmed = value.trim();
        if let Some(hex) = trimmed
            .strip_prefix("0x")
            .or_else(|| trimmed.strip_prefix("0X"))
        {
            u16::from_str_radix(hex, 16).ok()
        } else {
            trimmed.parse::<u16>().ok()
        }
    }

    fn parse_hotkey_combo(value: &str) -> Option<ParsedHotkeyCombo> {
        if !value.contains('+') {
            return None;
        }

        let mut key_code = None;
        let mut modifier_mask = 0_u64;

        for raw_token in value.split('+') {
            let token = raw_token.trim().to_ascii_lowercase();
            if token.is_empty() {
                return None;
            }

            if let Some(flag) = Self::combo_modifier_flag(&token) {
                modifier_mask |= flag;
                continue;
            }

            if key_code.is_some() {
                return None;
            }
            key_code = Self::parse_raw_keycode(&token);
            if key_code.is_none() {
                return None;
            }
        }

        let key_code = key_code?;
        if modifier_mask == 0 {
            return None;
        }

        let mut parts: Vec<String> = Self::combo_modifier_tokens_from_mask(modifier_mask)
            .into_iter()
            .map(|token| token.to_string())
            .collect();
        parts.push(key_code.to_string());

        Some(ParsedHotkeyCombo {
            key_code,
            modifier_mask,
            normalized_value: parts.join("+"),
        })
    }

    fn combo_modifier_flag(token: &str) -> Option<u64> {
        match token {
            "command" | "cmd" => Some(0x0010_0000),
            "option" | "alt" => Some(0x0008_0000),
            "control" | "ctrl" => Some(0x0004_0000),
            "shift" => Some(0x0002_0000),
            "fn" | "function" | "globe" => Some(0x0080_0000),
            _ => None,
        }
    }

    fn combo_modifier_tokens_from_mask(mask: u64) -> Vec<&'static str> {
        let ordered = [
            ("command", 0x0010_0000_u64),
            ("option", 0x0008_0000_u64),
            ("control", 0x0004_0000_u64),
            ("shift", 0x0002_0000_u64),
            ("fn", 0x0080_0000_u64),
        ];

        ordered
            .into_iter()
            .filter_map(|(token, flag)| ((mask & flag) != 0).then_some(token))
            .collect()
    }

    fn resolve_key(key: &str) -> HotkeyParams {
        match key {
            "left_option" => HotkeyParams {
                key_code: 58, // kVK_Option
                alt_key_code: 0,
                modifier_flag: 0x00000020, // NX_DEVICELALTKEYMASK
                match_kind: HotkeyMatchKind::ModifierOnly,
            },
            "right_option" => HotkeyParams {
                key_code: 61, // kVK_RightOption
                alt_key_code: 0,
                modifier_flag: 0x00000040, // NX_DEVICERALTKEYMASK
                match_kind: HotkeyMatchKind::ModifierOnly,
            },
            "left_command" => HotkeyParams {
                key_code: 55, // kVK_Command
                alt_key_code: 0,
                modifier_flag: 0x00000008, // NX_DEVICELCMDKEYMASK
                match_kind: HotkeyMatchKind::ModifierOnly,
            },
            "right_command" => HotkeyParams {
                key_code: 54, // kVK_RightCommand
                alt_key_code: 0,
                modifier_flag: 0x00000010, // NX_DEVICERCMDKEYMASK
                match_kind: HotkeyMatchKind::ModifierOnly,
            },
            "left_control" => HotkeyParams {
                key_code: 59, // kVK_Control
                alt_key_code: 0,
                modifier_flag: 0x00000001, // NX_DEVICELCTLKEYMASK
                match_kind: HotkeyMatchKind::ModifierOnly,
            },
            "right_control" => HotkeyParams {
                key_code: 62, // kVK_RightControl
                alt_key_code: 0,
                modifier_flag: 0x00002000, // NX_DEVICERCTLKEYMASK
                match_kind: HotkeyMatchKind::ModifierOnly,
            },
            _ if Self::parse_hotkey_combo(key).is_some() => {
                let combo = Self::parse_hotkey_combo(key).unwrap();
                HotkeyParams {
                    key_code: combo.key_code,
                    alt_key_code: 0,
                    modifier_flag: combo.modifier_mask,
                    match_kind: HotkeyMatchKind::KeyDown,
                }
            }
            // Raw keycode (non-modifier key, detected via keyDown/keyUp)
            _ if Self::parse_raw_keycode(key).is_some() => {
                let code = Self::parse_raw_keycode(key).unwrap();
                HotkeyParams {
                    key_code: code,
                    alt_key_code: 0,
                    modifier_flag: 0,
                    match_kind: HotkeyMatchKind::KeyDown,
                }
            }
            // "fn" or anything else defaults to Fn/Globe
            _ => HotkeyParams {
                key_code: 63,              // kVK_Function (Fn)
                alt_key_code: 179,         // Globe key on newer keyboards
                modifier_flag: 0x00800000, // NSEventModifierFlagFunction
                match_kind: HotkeyMatchKind::ModifierOnly,
            },
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
struct ParsedHotkeyCombo {
    key_code: u16,
    modifier_mask: u64,
    normalized_value: String,
}

// ─── Defaults ───────────────────────────────────────────────────────

fn default_asr_provider() -> String {
    "doubaoime".into()
}
fn default_doubaoime_credential_path() -> String {
    "doubaoime_credentials.json".into()
}
fn default_qwen_url() -> String {
    "wss://dashscope.aliyuncs.com/api-ws/v1/realtime".into()
}
fn default_qwen_model() -> String {
    "qwen3-asr-flash-realtime".into()
}
fn default_qwen_language() -> String {
    "zh".into()
}
fn default_mlx_model() -> String {
    "mlx/Qwen3-ASR-0.6B-4bit".into()
}
fn default_mlx_delay_preset() -> String {
    "realtime".into()
}
fn default_mlx_language() -> String {
    "auto".into()
}
fn default_sherpa_onnx_model() -> String {
    "sherpa-onnx/bilingual-zh-en".into()
}
fn default_sherpa_onnx_num_threads() -> i32 {
    2
}
fn default_sherpa_onnx_hotwords_score() -> f32 {
    1.5
}
fn default_sherpa_onnx_endpoint_silence() -> f32 {
    1.2
}
fn default_glm_url() -> String {
    "https://open.bigmodel.cn/api/paas/v4/audio/transcriptions".into()
}
fn default_glm_model() -> String {
    "glm-asr-2512".into()
}
fn default_mimo_url() -> String {
    "https://api.xiaomimimo.com/v1/chat/completions".into()
}
fn default_mimo_model() -> String {
    "mimo-v2.5-asr".into()
}
fn default_mimo_language() -> String {
    "auto".into()
}
fn deserialize_option_u32_lenient<'de, D>(
    deserializer: D,
) -> std::result::Result<Option<u32>, D::Error>
where
    D: serde::Deserializer<'de>,
{
    use serde::Deserialize;
    let val = serde_yaml::Value::deserialize(deserializer)?;
    match val {
        serde_yaml::Value::Null => Ok(None),
        serde_yaml::Value::Number(n) => Ok(n.as_u64().map(|v| v as u32)),
        serde_yaml::Value::String(s) if s.trim().is_empty() => Ok(None),
        serde_yaml::Value::String(s) => s
            .trim()
            .parse::<u32>()
            .map(Some)
            .map_err(serde::de::Error::custom),
        _ => Ok(None),
    }
}

fn deserialize_option_string_lenient<'de, D>(
    deserializer: D,
) -> std::result::Result<Option<String>, D::Error>
where
    D: serde::Deserializer<'de>,
{
    use serde::Deserialize;
    let val = Option::<String>::deserialize(deserializer)?;
    Ok(val.filter(|s| !s.trim().is_empty()))
}

fn default_asr_url() -> String {
    "wss://openspeech.bytedance.com/api/v3/sauc/bigmodel_async".into()
}
fn default_resource_id() -> String {
    "volc.seedasr.sauc.duration".into()
}
fn default_connect_timeout() -> u64 {
    3000
}
fn default_final_wait_timeout() -> u64 {
    5000
}
fn default_true() -> bool {
    true
}
fn default_false() -> bool {
    false
}
fn default_top_p() -> f64 {
    1.0
}
fn default_llm_timeout() -> u64 {
    8000
}
fn default_max_output_tokens() -> u32 {
    1024
}
fn default_dictionary_max_candidates() -> usize {
    0
}
fn default_llm_max_token_parameter() -> LlmMaxTokenParameter {
    LlmMaxTokenParameter::MaxCompletionTokens
}
fn default_llm_provider() -> String {
    "openai".into()
}
fn default_llm_active_profile() -> String {
    "openai".into()
}
fn default_llm_profiles() -> BTreeMap<String, LlmProfileConfig> {
    let mut profiles = BTreeMap::new();
    profiles.insert(
        "apfel".into(),
        LlmProfileConfig {
            name: "APFEL".into(),
            provider: "apfel".into(),
            api_protocol: LlmApiProtocol::OpenaiChat,
            base_url: "http://127.0.0.1:11434/v1".into(),
            api_key: String::new(),
            model: "apple-foundationmodel".into(),
            endpoint_path: "/chat/completions".into(),
            max_token_parameter: LlmMaxTokenParameter::MaxTokens,
            no_reasoning_control: LlmNoReasoningControl::None,
            mlx: MlxLlmConfig::default(),
        },
    );
    profiles.insert(
        "mlx".into(),
        LlmProfileConfig {
            name: "MLX (Apple Silicon)".into(),
            provider: "mlx".into(),
            api_protocol: LlmApiProtocol::OpenaiChat,
            base_url: String::new(),
            api_key: String::new(),
            model: String::new(),
            endpoint_path: String::new(),
            max_token_parameter: LlmMaxTokenParameter::MaxTokens,
            no_reasoning_control: LlmNoReasoningControl::None,
            mlx: MlxLlmConfig::default(),
        },
    );
    profiles.insert(
        "openai".into(),
        LlmProfileConfig {
            name: "OpenAI Chat Completions".into(),
            provider: "openai".into(),
            api_protocol: LlmApiProtocol::OpenaiChat,
            base_url: "https://api.openai.com/v1".into(),
            api_key: String::new(),
            model: "gpt-5.4-nano".into(),
            endpoint_path: "/chat/completions".into(),
            max_token_parameter: LlmMaxTokenParameter::MaxCompletionTokens,
            no_reasoning_control: LlmNoReasoningControl::None,
            mlx: MlxLlmConfig::default(),
        },
    );
    profiles.insert(
        "openai-responses".into(),
        LlmProfileConfig {
            name: "OpenAI Responses".into(),
            provider: "openai".into(),
            api_protocol: LlmApiProtocol::OpenaiResponses,
            base_url: "https://api.openai.com/v1".into(),
            api_key: String::new(),
            model: "gpt-5.4-nano".into(),
            endpoint_path: "/responses".into(),
            max_token_parameter: LlmMaxTokenParameter::MaxCompletionTokens,
            no_reasoning_control: LlmNoReasoningControl::None,
            mlx: MlxLlmConfig::default(),
        },
    );
    profiles.insert(
        "anthropic".into(),
        LlmProfileConfig {
            name: "Anthropic Messages".into(),
            provider: "anthropic".into(),
            api_protocol: LlmApiProtocol::AnthropicMessages,
            base_url: "https://api.anthropic.com/v1".into(),
            api_key: String::new(),
            model: String::new(),
            endpoint_path: "/messages".into(),
            max_token_parameter: LlmMaxTokenParameter::MaxTokens,
            no_reasoning_control: LlmNoReasoningControl::None,
            mlx: MlxLlmConfig::default(),
        },
    );
    profiles
}
fn default_mlx_llm_model() -> String {
    "mlx/Qwen3-0.6B-4bit".into()
}
fn default_dictionary_path() -> String {
    "dictionary.txt".into()
}
fn default_system_prompt_path() -> String {
    "system_prompt.txt".into()
}
fn default_trigger_key() -> String {
    "fn".into()
}

fn default_trigger_mode() -> String {
    "hold".into()
}

fn default_user_prompt_path() -> String {
    "user_prompt.txt".into()
}

fn default_overlay_font_family() -> String {
    "system".to_string()
}

fn default_overlay_font_size() -> u16 {
    13
}

fn default_overlay_bottom_margin() -> u16 {
    10
}

fn default_overlay_limit_visible_lines() -> bool {
    true
}

fn default_overlay_max_visible_lines() -> u16 {
    3
}

fn default_translate_to_english_prompt_template() -> PromptTemplate {
    PromptTemplate {
        name: "翻译英文".into(),
        enabled: true,
        shortcut: 1,
        system_prompt: Some(
            "将用户的语音输入翻译为流畅的英文。保持原意，不要添加额外内容。只输出翻译结果。".into(),
        ),
        system_prompt_path: None,
    }
}

fn default_prompt_templates() -> Vec<PromptTemplate> {
    vec![default_translate_to_english_prompt_template()]
}

fn legacy_default_prompt_templates() -> Vec<PromptTemplate> {
    vec![
        default_translate_to_english_prompt_template(),
        PromptTemplate {
            name: "繁体中文".into(),
            enabled: true,
            shortcut: 2,
            system_prompt: Some(
                "将用户的语音输入翻译为流畅的繁体中文。保持原意，不要添加额外内容。只输出翻译结果。"
                    .into(),
            ),
            system_prompt_path: None,
        },
        PromptTemplate {
            name: "推文风格".into(),
            enabled: true,
            shortcut: 3,
            system_prompt: Some(
                "将用户的语音输入改写为适合发 Twitter/X 的简短推文。280字符以内，可适当加emoji。只输出推文内容。"
                    .into(),
            ),
            system_prompt_path: None,
        },
        PromptTemplate {
            name: "小红书".into(),
            enabled: true,
            shortcut: 4,
            system_prompt: Some(
                "将用户的语音输入改写为适合小红书的帖子风格。加上合适的emoji和标题，语气活泼亲切。只输出帖子内容。"
                    .into(),
            ),
            system_prompt_path: None,
        },
        PromptTemplate {
            name: "优化技术名词".into(),
            enabled: true,
            shortcut: 5,
            system_prompt: Some(
                "将用户的语音输入中包含的技术相关名词进行校正。保持原意，不要添加额外内容。只输出校正之后的结果。"
                    .into(),
            ),
            system_prompt_path: None,
        },
    ]
}

impl Default for Config {
    fn default() -> Self {
        serde_yaml::from_str("{}").unwrap()
    }
}
impl Default for AsrSection {
    fn default() -> Self {
        serde_yaml::from_str("{}").unwrap()
    }
}
impl Default for DoubaoAsrConfig {
    fn default() -> Self {
        serde_yaml::from_str("{}").unwrap()
    }
}
impl Default for LlmSection {
    fn default() -> Self {
        serde_yaml::from_str("{}").unwrap()
    }
}
impl Default for FeedbackSection {
    fn default() -> Self {
        serde_yaml::from_str("{}").unwrap()
    }
}
impl Default for DictionarySection {
    fn default() -> Self {
        serde_yaml::from_str("{}").unwrap()
    }
}
impl Default for OverlaySection {
    fn default() -> Self {
        serde_yaml::from_str("{}").unwrap()
    }
}
impl Default for HotkeySection {
    fn default() -> Self {
        serde_yaml::from_str("{}").unwrap()
    }
}

// ─── Config Directory ───────────────────────────────────────────────

/// Returns ~/.koe/
pub fn config_dir() -> PathBuf {
    let home = std::env::var("HOME").unwrap_or_else(|_| "/tmp".into());
    PathBuf::from(home).join(".koe")
}

/// Returns ~/.koe/config.yaml
pub fn config_path() -> PathBuf {
    config_dir().join("config.yaml")
}

/// Resolve a path relative to config dir.
fn resolve_path(p: &str) -> PathBuf {
    let path = Path::new(p);
    if path.is_absolute() {
        path.to_path_buf()
    } else {
        config_dir().join(path)
    }
}

impl PromptTemplate {
    /// Resolve the system prompt: inline text takes priority, then file path.
    pub fn resolve_system_prompt(&self) -> Option<String> {
        if let Some(ref text) = self.system_prompt {
            let trimmed = text.trim();
            if !trimmed.is_empty() {
                return Some(trimmed.to_string());
            }
        }
        if let Some(ref path) = self.system_prompt_path {
            let resolved = resolve_path(path);
            if let Ok(content) = std::fs::read_to_string(&resolved) {
                let trimmed = content.trim().to_string();
                if !trimmed.is_empty() {
                    return Some(trimmed);
                }
            }
        }
        None
    }
}

/// Resolve a model directory path.
/// Absolute paths are used directly; relative paths are resolved under ~/.koe/models/.
pub fn resolve_model_dir(model: &str) -> PathBuf {
    let path = Path::new(model);
    if path.is_absolute() {
        path.to_path_buf()
    } else {
        crate::model_manager::models_dir().join(model)
    }
}

/// Resolve dictionary path (relative to config dir).
pub fn resolve_dictionary_path(config: &Config) -> PathBuf {
    resolve_path(&config.dictionary.path)
}

/// Resolve system prompt path (relative to config dir).
pub fn resolve_system_prompt_path(config: &Config) -> PathBuf {
    resolve_path(&config.llm.system_prompt_path)
}

/// Resolve user prompt path (relative to config dir).
pub fn resolve_user_prompt_path(config: &Config) -> PathBuf {
    resolve_path(&config.llm.user_prompt_path)
}

// ─── Environment Variable Substitution ──────────────────────────────

/// Replace ${VAR_NAME} patterns with environment variable values.
///
/// Performs a single, non-recursive pass: each `${VAR}` token in the
/// *original* input is replaced exactly once.  Substituted values are
/// appended verbatim and never re-scanned, which prevents:
/// - infinite loops when a value contains `${...}` (including self-references)
/// - silent corruption of API keys or paths that happen to contain `${`
fn substitute_env_vars(input: &str) -> String {
    let mut result = String::with_capacity(input.len());
    let mut rest = input;
    while let Some(start) = rest.find("${") {
        let end = match rest[start + 2..].find('}') {
            Some(pos) => start + 2 + pos,
            None => break, // no closing brace; copy remainder verbatim below
        };
        let var_name = &rest[start + 2..end];
        let value = std::env::var(var_name).unwrap_or_default();
        result.push_str(&rest[..start]);
        result.push_str(&value); // value is NOT rescanned
        rest = &rest[end + 1..];
    }
    result.push_str(rest);
    result
}

// ─── V1 → V2 Config Migration ──────────────────────────────────────

/// V1 ASR fields that indicate the old flat format.
const V1_ASR_KEYS: &[&str] = &[
    "api_key",
    "app_key",
    "access_key",
    "url",
    "resource_id",
    "connect_timeout_ms",
    "final_wait_timeout_ms",
    "enable_ddc",
    "enable_itn",
    "enable_punc",
    "enable_nonstream",
];

/// Check if the config file uses V1 ASR format (flat fields under `asr:`)
/// and migrate it to V2 format (provider-based) in place.
fn migrate_config_v1_to_v2(path: &Path) -> Result<bool> {
    let raw = std::fs::read_to_string(path)
        .map_err(|e| KoeError::Config(format!("read {}: {e}", path.display())))?;

    let doc: serde_yaml::Value = serde_yaml::from_str(&raw)
        .map_err(|e| KoeError::Config(format!("parse {}: {e}", path.display())))?;

    let asr = match doc.get("asr") {
        Some(v) => v,
        None => return Ok(false),
    };

    let asr_map = match asr.as_mapping() {
        Some(m) => m,
        None => return Ok(false),
    };

    // If `asr` already has a `provider` key, it's already V2
    if asr_map.contains_key(serde_yaml::Value::String("provider".into())) {
        return Ok(false);
    }

    // If `asr` has a `doubao` key, it's already V2 (just missing provider field, which defaults)
    if asr_map.contains_key(serde_yaml::Value::String("doubao".into())) {
        return Ok(false);
    }

    // Check if any V1-specific key exists
    let has_v1_keys = V1_ASR_KEYS
        .iter()
        .any(|k| asr_map.contains_key(serde_yaml::Value::String((*k).into())));

    if !has_v1_keys {
        return Ok(false);
    }

    log::info!("detected V1 ASR config, migrating to V2 format...");

    // Extract V1 fields into a new doubao sub-mapping
    let mut doubao_map = serde_yaml::Mapping::new();
    let mut new_asr_map = serde_yaml::Mapping::new();

    new_asr_map.insert(
        serde_yaml::Value::String("provider".into()),
        serde_yaml::Value::String("doubao".into()),
    );

    for (key, value) in asr_map {
        let key_str = key.as_str().unwrap_or("");
        if V1_ASR_KEYS.contains(&key_str) {
            doubao_map.insert(key.clone(), value.clone());
        } else {
            // Preserve any unknown keys at the asr level
            new_asr_map.insert(key.clone(), value.clone());
        }
    }

    new_asr_map.insert(
        serde_yaml::Value::String("doubao".into()),
        serde_yaml::Value::Mapping(doubao_map),
    );

    // Rebuild the full document
    let mut new_doc = match doc.as_mapping() {
        Some(m) => m.clone(),
        None => return Ok(false),
    };
    new_doc.insert(
        serde_yaml::Value::String("asr".into()),
        serde_yaml::Value::Mapping(new_asr_map),
    );

    // Write back with a header comment
    let yaml_str = serde_yaml::to_string(&serde_yaml::Value::Mapping(new_doc))
        .map_err(|e| KoeError::Config(format!("serialize migrated config: {e}")))?;

    let output = format!(
        "# Koe - Voice Input Tool Configuration\n\
         # ~/.koe/config.yaml\n\
         # Migrated to V2 format (multi-provider ASR)\n\n\
         {yaml_str}"
    );

    atomic_write_file(path, &output)?;

    log::info!("config migrated to V2 format successfully");
    Ok(true)
}

/// Ensure hotkey config persisted on disk uses the normalized trigger key.
/// The legacy `hotkey.cancel_key` field is ignored at runtime and no longer
/// written back to disk.
fn normalize_hotkey_config(path: &Path, config: &Config) -> Result<bool> {
    let raw = std::fs::read_to_string(path)
        .map_err(|e| KoeError::Config(format!("read {}: {e}", path.display())))?;

    let mut doc: serde_yaml::Value = serde_yaml::from_str(&raw)
        .map_err(|e| KoeError::Config(format!("parse {}: {e}", path.display())))?;

    let doc_map = match doc.as_mapping_mut() {
        Some(map) => map,
        None => return Ok(false),
    };

    let normalized_trigger = config.hotkey.normalized_trigger_key();
    let hotkey_key = serde_yaml::Value::String("hotkey".into());

    let hotkey_value = doc_map
        .entry(hotkey_key)
        .or_insert_with(|| serde_yaml::Value::Mapping(serde_yaml::Mapping::new()));

    let hotkey_map = match hotkey_value.as_mapping_mut() {
        Some(map) => map,
        None => return Ok(false),
    };

    let trigger_key = serde_yaml::Value::String("trigger_key".into());
    let stored_trigger = hotkey_map.get(&trigger_key).and_then(|v| v.as_str());

    if stored_trigger == Some(normalized_trigger.as_str()) {
        return Ok(false);
    }

    hotkey_map.insert(trigger_key, serde_yaml::Value::String(normalized_trigger));

    let yaml_str = serde_yaml::to_string(&doc)
        .map_err(|e| KoeError::Config(format!("serialize normalized config: {e}")))?;

    let output = format!(
        "# Koe - Voice Input Tool Configuration\n\
         # ~/.koe/config.yaml\n\n\
         {yaml_str}"
    );

    atomic_write_file(path, &output)?;

    log::info!("normalized hotkey config on disk");
    Ok(true)
}

/// Replace the previous bundled template set with the new minimal default,
/// but only when the user still has the legacy built-in templates unchanged.
fn normalize_prompt_templates_config(path: &Path, config: &Config) -> Result<bool> {
    if config.prompt_templates != legacy_default_prompt_templates() {
        return Ok(false);
    }

    let raw = std::fs::read_to_string(path)
        .map_err(|e| KoeError::Config(format!("read {}: {e}", path.display())))?;

    let mut doc: serde_yaml::Value = serde_yaml::from_str(&raw)
        .map_err(|e| KoeError::Config(format!("parse {}: {e}", path.display())))?;

    let doc_map = match doc.as_mapping_mut() {
        Some(map) => map,
        None => return Ok(false),
    };

    let yaml_templates = serde_yaml::to_value(default_prompt_templates())
        .map_err(|e| KoeError::Config(format!("serialize prompt templates: {e}")))?;

    doc_map.insert(
        serde_yaml::Value::String("prompt_templates".into()),
        yaml_templates,
    );

    let yaml_str = serde_yaml::to_string(&doc)
        .map_err(|e| KoeError::Config(format!("serialize normalized config: {e}")))?;

    let output = format!(
        "# Koe - Voice Input Tool Configuration\n\
         # ~/.koe/config.yaml\n\n\
         {yaml_str}"
    );

    atomic_write_file(path, &output)?;

    log::info!("normalized legacy prompt templates on disk");
    Ok(true)
}

// ─── Load & Ensure ─────────────────────────────────────────────────

/// Load config from ~/.koe/config.yaml.
/// Automatically migrates V1 config to V2 if needed.
/// Performs environment variable substitution before parsing.
pub fn load_config() -> Result<Config> {
    let path = config_path();

    if !path.exists() {
        return Err(KoeError::Config(format!(
            "config file not found: {}",
            path.display()
        )));
    }

    // Attempt V1 → V2 migration before loading
    match migrate_config_v1_to_v2(&path) {
        Ok(true) => log::info!("config file migrated from V1 to V2"),
        Ok(false) => {}
        Err(e) => log::warn!("config migration check failed (will try loading as-is): {e}"),
    }

    let raw = std::fs::read_to_string(&path)
        .map_err(|e| KoeError::Config(format!("read {}: {e}", path.display())))?;

    let substituted = substitute_env_vars(&raw);

    let mut config: Config = serde_yaml::from_str(&substituted)
        .map_err(|e| KoeError::Config(format!("parse {}: {e}", path.display())))?;

    match normalize_prompt_templates_config(&path, &config) {
        Ok(true) => {
            log::info!("config file updated with minimal default prompt templates");
            let raw = std::fs::read_to_string(&path)
                .map_err(|e| KoeError::Config(format!("read {}: {e}", path.display())))?;
            let substituted = substitute_env_vars(&raw);
            config = serde_yaml::from_str(&substituted)
                .map_err(|e| KoeError::Config(format!("parse {}: {e}", path.display())))?;
        }
        Ok(false) => {}
        Err(e) => log::warn!("prompt templates normalization failed: {e}"),
    }

    match normalize_hotkey_config(&path, &config) {
        Ok(true) => log::info!("config file updated with normalized hotkey settings"),
        Ok(false) => {}
        Err(e) => log::warn!("hotkey config normalization failed: {e}"),
    }

    Ok(config)
}

/// Ensure ~/.koe/ exists with default config.yaml and dictionary.txt.
/// Returns true if files were created (first launch).
pub fn ensure_defaults() -> Result<bool> {
    let dir = config_dir();
    let config_file = config_path();
    let dict_file = dir.join("dictionary.txt");
    let system_prompt_file = dir.join("system_prompt.txt");
    let user_prompt_file = dir.join("user_prompt.txt");

    let mut created = false;

    if !dir.exists() {
        std::fs::create_dir_all(&dir)
            .map_err(|e| KoeError::Config(format!("create {}: {e}", dir.display())))?;
        created = true;
    }

    let defaults: &[(&std::path::Path, &str)] = &[
        (&config_file, DEFAULT_CONFIG_YAML),
        (&dict_file, DEFAULT_DICTIONARY_TXT),
        (&system_prompt_file, DEFAULT_SYSTEM_PROMPT),
        (&user_prompt_file, DEFAULT_USER_PROMPT),
    ];

    for (path, content) in defaults {
        if !path.exists() {
            std::fs::write(path, content)
                .map_err(|e| KoeError::Config(format!("write {}: {e}", path.display())))?;
            log::info!("created default: {}", path.display());
            created = true;
        }
    }

    // Install default model manifests into ~/.koe/models/
    let models_dir = crate::model_manager::models_dir();
    for (rel_path, content) in DEFAULT_MANIFESTS {
        let manifest_dir = models_dir.join(rel_path);
        let manifest_file = manifest_dir.join(".koe-manifest.json");
        if !manifest_file.exists() {
            std::fs::create_dir_all(&manifest_dir)
                .map_err(|e| KoeError::Config(format!("create {}: {e}", manifest_dir.display())))?;
            std::fs::write(&manifest_file, content)
                .map_err(|e| KoeError::Config(format!("write {}: {e}", manifest_file.display())))?;
            log::info!("installed manifest: {}", manifest_file.display());
            created = true;
        }
    }

    Ok(created)
}

// ─── Key-path Get / Set ────────────────────────────────────────────

/// Get a config value by dot-separated key path (e.g. `"asr.doubao.app_key"`).
/// Returns an empty string if the key is not found.
pub fn config_get(key_path: &str) -> Result<String> {
    let path = config_path();
    let raw = std::fs::read_to_string(&path)
        .map_err(|e| KoeError::Config(format!("read {}: {e}", path.display())))?;
    let root: serde_yaml::Value = serde_yaml::from_str(&raw)
        .map_err(|e| KoeError::Config(format!("parse {}: {e}", path.display())))?;

    let mut current = &root;
    for part in key_path.split('.') {
        let key = serde_yaml::Value::String(part.to_string());
        match current.as_mapping().and_then(|m| m.get(&key)) {
            Some(v) => current = v,
            None => return Ok(String::new()),
        }
    }

    let s = match current {
        serde_yaml::Value::String(s) => s.clone(),
        serde_yaml::Value::Bool(b) => b.to_string(),
        serde_yaml::Value::Number(n) => n.to_string(),
        _ => String::new(),
    };
    Ok(s)
}

/// Get a config value by dot-separated key path as JSON.
/// Unlike [`config_get`], this preserves non-scalar values (maps, sequences).
/// Returns an empty string if the key is not found.
pub fn config_get_json(key_path: &str) -> Result<String> {
    let path = config_path();
    let raw = std::fs::read_to_string(&path)
        .map_err(|e| KoeError::Config(format!("read {}: {e}", path.display())))?;
    let root: serde_yaml::Value = serde_yaml::from_str(&raw)
        .map_err(|e| KoeError::Config(format!("parse {}: {e}", path.display())))?;

    let mut current = &root;
    for part in key_path.split('.') {
        let key = serde_yaml::Value::String(part.to_string());
        match current.as_mapping().and_then(|m| m.get(&key)) {
            Some(v) => current = v,
            None => return Ok(String::new()),
        }
    }

    serde_json::to_string(current)
        .map_err(|e| KoeError::Config(format!("encode {key_path} to JSON: {e}")))
}

/// Write serialized YAML to config.yaml atomically.
pub fn atomic_write_config(data: &str) -> Result<()> {
    atomic_write_file(&config_path(), data)
}

/// Write data to a file atomically: write to a temp sibling, then rename.
fn atomic_write_file(path: &Path, data: &str) -> Result<()> {
    let tmp = path.with_extension("yaml.tmp");
    std::fs::write(&tmp, data)
        .map_err(|e| KoeError::Config(format!("write {}: {e}", tmp.display())))?;
    std::fs::rename(&tmp, path).map_err(|e| {
        KoeError::Config(format!(
            "rename {} -> {}: {e}",
            tmp.display(),
            path.display()
        ))
    })?;
    Ok(())
}

/// Set a config value by dot-separated key path. Reads, modifies, and writes back.
/// Creates intermediate mappings as needed. Infers YAML type from the string value.
pub fn config_set(key_path: &str, value: &str) -> Result<()> {
    let path = config_path();
    let raw = std::fs::read_to_string(&path).unwrap_or_default();
    let mut root: serde_yaml::Value = if raw.trim().is_empty() {
        serde_yaml::Value::Mapping(serde_yaml::Mapping::new())
    } else {
        serde_yaml::from_str(&raw)
            .map_err(|e| KoeError::Config(format!("parse {}: {e}", path.display())))?
    };

    let parts: Vec<&str> = key_path.split('.').collect();
    let (sections, leaf_slice) = parts.split_at(parts.len() - 1);
    let leaf = leaf_slice[0];

    let parent = navigate_to_parent(&mut root, sections);
    parent.insert(
        serde_yaml::Value::String(leaf.to_string()),
        yaml_value_from_str(value),
    );

    let serialized =
        serde_yaml::to_string(&root).map_err(|e| KoeError::Config(format!("serialize: {e}")))?;
    atomic_write_file(&path, &serialized)?;

    Ok(())
}

pub fn llm_profiles_payload() -> Result<LlmProfilesPayload> {
    Ok(load_config()?.llm.profiles_payload())
}

pub fn save_llm_profiles_payload(payload: &LlmProfilesPayload) -> Result<()> {
    let path = config_path();
    let raw = std::fs::read_to_string(&path).unwrap_or_default();
    let mut root: serde_yaml::Value = if raw.trim().is_empty() {
        serde_yaml::Value::Mapping(serde_yaml::Mapping::new())
    } else {
        serde_yaml::from_str(&raw)
            .map_err(|e| KoeError::Config(format!("parse {}: {e}", path.display())))?
    };

    let llm_map = navigate_to_parent(&mut root, &["llm"]);
    llm_map.insert(
        serde_yaml::Value::String("active_profile".into()),
        serde_yaml::Value::String(payload.active_profile.clone()),
    );
    let profiles_value = serde_yaml::to_value(&payload.profiles)
        .map_err(|e| KoeError::Config(format!("serialize LLM profiles: {e}")))?;
    llm_map.insert(serde_yaml::Value::String("profiles".into()), profiles_value);

    let serialized =
        serde_yaml::to_string(&root).map_err(|e| KoeError::Config(format!("serialize: {e}")))?;
    atomic_write_file(&path, &serialized)?;

    Ok(())
}

/// Recursively navigate into nested YAML mappings by path segments, creating
/// intermediate mappings as needed. Returns a mutable ref to the final mapping.
fn navigate_to_parent<'a>(
    node: &'a mut serde_yaml::Value,
    sections: &[&str],
) -> &'a mut serde_yaml::Mapping {
    if !node.is_mapping() {
        *node = serde_yaml::Value::Mapping(serde_yaml::Mapping::new());
    }
    if sections.is_empty() {
        return node.as_mapping_mut().unwrap();
    }
    let (first, rest) = sections.split_first().unwrap();
    let key = serde_yaml::Value::String(first.to_string());
    let map = node.as_mapping_mut().unwrap();
    let child = map
        .entry(key)
        .or_insert_with(|| serde_yaml::Value::Mapping(serde_yaml::Mapping::new()));
    navigate_to_parent(child, rest)
}

/// Infer YAML scalar type from a string value.
fn yaml_value_from_str(s: &str) -> serde_yaml::Value {
    match s {
        "true" => serde_yaml::Value::Bool(true),
        "false" => serde_yaml::Value::Bool(false),
        _ => match s.parse::<i64>() {
            Ok(n) => serde_yaml::Value::Number(n.into()),
            Err(_) => serde_yaml::Value::String(s.to_string()),
        },
    }
}

const DEFAULT_CONFIG_YAML: &str = r#"# Koe - Voice Input Tool Configuration
# ~/.koe/config.yaml

asr:
  # ASR provider: "doubaoime" (default, free), "doubao", "qwen", "glm", "mimo", "apple-speech", "mlx", "sherpa-onnx"
  provider: "doubaoime"

  # DoubaoIME (豆包输入法) free ASR — no API key required, auto device registration
  doubaoime:
    credential_path: "doubaoime_credentials.json"  # relative to ~/.koe/
    connect_timeout_ms: 3000
    final_wait_timeout_ms: 5000

  # Doubao (豆包) Streaming ASR 2.0 (优化版双向流式)
  doubao:
    url: "wss://openspeech.bytedance.com/api/v3/sauc/bigmodel_async"
    api_key: ""          # X-Api-Key (新版控制台, 优先使用)
    app_key: ""          # X-Api-App-Key (旧版控制台 App ID)
    access_key: ""       # X-Api-Access-Key (旧版控制台 Access Token)
    resource_id: "volc.seedasr.sauc.duration"
    connect_timeout_ms: 3000
    final_wait_timeout_ms: 5000
    enable_ddc: true     # 语义顺滑 (去除口语重复/语气词)
    enable_itn: true     # 文本规范化 (数字、日期等)
    enable_punc: true    # 自动标点
    enable_nonstream: true  # 二遍识别 (流式+非流式, 提升准确率)
    # language: ""       # 语言代码: zh-CN, en-US, ja-JP 等, 空=自动(中英文+方言)
    # end_window_size: 800       # 强制判停时间(ms), 最小200
    # force_to_speech_time: 1000 # 音频超过该时长才判停(ms)
    # vad_segment_duration: 3000 # 语义切句最大静音阈值(ms)
    # output_zh_variant: ""      # 繁体输出: traditional/tw/hk
    # enable_accelerate_text: false  # 首字返回加速
    # accelerate_score: 0        # 加速程度 0-20
    # headers:           # custom HTTP headers for WebSocket connection
    #   X-Custom-Header: "value"

  # Qwen (Aliyun DashScope) Realtime ASR
  qwen:
    url: "wss://dashscope.aliyuncs.com/api-ws/v1/realtime"
    api_key: ""
    model: "qwen3-asr-flash-realtime"
    language: "zh"
    connect_timeout_ms: 3000
    final_wait_timeout_ms: 5000
    # headers:           # custom HTTP headers for WebSocket connection
    #   X-Custom-Header: "value"

  # GLM (Zhipu/智谱) ASR — HTTP POST + SSE streaming
  glm:
    url: "https://open.bigmodel.cn/api/paas/v4/audio/transcriptions"
    api_key: ""          # 从 https://bigmodel.cn/usercenter/proj-mgmt/apikeys 获取
    model: "glm-asr-2512"  # glm-asr-2512 | glm-asr-1

  # MiMo (Xiaomi/小米) ASR — OpenAI-compatible HTTP POST + SSE streaming
  mimo:
    url: "https://api.xiaomimimo.com/v1/chat/completions"
    api_key: ""          # 从 https://platform.xiaomimimo.com 获取
    model: "mimo-v2.5-asr"
    language: "auto"     # auto | zh-CN | en-US | ja-JP 等

  # Apple Speech local ASR (macOS 26+, zero-config, no model download)
  apple-speech:
    locale: "zh_CN"                 # zh_CN | en_US | en_GB | ja_JP | ko_KR

  # MLX local ASR (Apple Silicon only)
  mlx:
    model: "mlx/Qwen3-ASR-0.6B-4bit"       # relative to ~/.koe/models/, or absolute path
    delay_preset: "realtime"    # realtime | agent | subtitle
    language: "auto"            # auto | zh | en

  # Sherpa-ONNX local ASR (CPU)
  sherpa-onnx:
    model: "sherpa-onnx/bilingual-zh-en"    # relative to ~/.koe/models/, or absolute path
    num_threads: 2
    hotwords_score: 1.5         # dictionary term boost
    endpoint_silence: 1.2       # trailing silence for sentence boundary (seconds)

llm:
  enabled: true        # set to false to skip LLM correction entirely
  prompt_templates_enabled: false  # show rewrite template buttons above the overlay after transcription
  active_profile: "openai"
  temperature: 0
  top_p: 1
  timeout_ms: 8000
  max_output_tokens: 1024
  dictionary_max_candidates: 0             # 0 = send all entries to LLM
  system_prompt_path: "system_prompt.txt"  # relative to ~/.koe/
  user_prompt_path: "user_prompt.txt"      # relative to ~/.koe/
  profiles:
    openai:
      name: "OpenAI Chat Completions"
      provider: "openai"
      api_protocol: "openai_chat"
      base_url: "https://api.openai.com/v1"
      api_key: ""          # or use ${LLM_API_KEY}
      model: "gpt-5.4-nano"
      endpoint_path: "/chat/completions"  # relative path appended to base_url
      max_token_parameter: "max_completion_tokens"
      no_reasoning_control: "none"
    openai-responses:
      name: "OpenAI Responses"
      provider: "openai"
      api_protocol: "openai_responses"
      base_url: "https://api.openai.com/v1"
      api_key: ""          # or use ${LLM_API_KEY}
      model: "gpt-5.4-nano"
      endpoint_path: "/responses"
      max_token_parameter: "max_completion_tokens"
      no_reasoning_control: "none"
    anthropic:
      name: "Anthropic Messages"
      provider: "anthropic"
      api_protocol: "anthropic_messages"
      base_url: "https://api.anthropic.com/v1"
      api_key: ""          # or use ${ANTHROPIC_API_KEY}
      model: ""            # choose any text-capable model from /models
      endpoint_path: "/messages"
      max_token_parameter: "max_tokens"
      no_reasoning_control: "none"
    apfel:
      name: "APFEL"
      provider: "apfel"
      api_protocol: "openai_chat"
      base_url: "http://127.0.0.1:11434/v1"
      api_key: ""           # optional; leave blank to send no Authorization header
      model: "apple-foundationmodel"
      endpoint_path: "/chat/completions"  # customize for non-standard OpenAI-compatible endpoints
      max_token_parameter: "max_tokens"
      no_reasoning_control: "none"
    mlx:
      name: "MLX (Apple Silicon)"
      provider: "mlx"
      mlx:
        model: "mlx/Qwen3-0.6B-4bit"      # relative to ~/.koe/models/, or absolute path

feedback:
  start_sound: false
  stop_sound: false
  error_sound: false
  mute_system_output: false

dictionary:
  path: "dictionary.txt"  # relative to ~/.koe/

hotkey:
  # 触发键：fn | left_option | right_option | left_command | right_command | left_control | right_control
  # 也可以填 macOS keycode 数字来使用非修饰键，例如 122 (F1)、120 (F2)、99 (F3) 等
  trigger_key: "fn"
  trigger_mode: "hold"                 # hold | toggle | double_tap

overlay:
  font_family: "system"
  font_size: 13
  bottom_margin: 10
  limit_visible_lines: true
  max_visible_lines: 3

prompt_templates:
  - name: "翻译英文"
    enabled: true
    shortcut: 1
    system_prompt: "将用户的语音输入翻译为流畅的英文。保持原意，不要添加额外内容。只输出翻译结果。"

# 实验性功能（默认全部关闭）
experimental:
  # ASR 识别完成后立即粘贴原始文本，LLM 修正返回后再原位替换。
  # 仅在焦点、光标和已粘贴文本均未变化、且目标应用支持辅助功能文本替换时
  # 才会替换；无法安全替换时保留原文，修正版进入剪贴板。
  paste_asr_first: false
"#;

const DEFAULT_DICTIONARY_TXT: &str = r#"# Koe User Dictionary
# One term per line. These terms are prioritized during LLM correction.
# Lines starting with # are comments.

"#;

const DEFAULT_SYSTEM_PROMPT: &str = include_str!("default_system_prompt.txt");

const DEFAULT_USER_PROMPT: &str = include_str!("default_user_prompt.txt");

/// Default model manifests: (relative_path, json_content).
/// relative_path maps to ~/.koe/models/<relative_path>/.koe-manifest.json
macro_rules! manifest {
    ($path:literal) => {
        ($path, include_str!(concat!("manifests/", $path, ".json")))
    };
}
const DEFAULT_MANIFESTS: &[(&str, &str)] = &[
    manifest!("mlx/Qwen3-ASR-0.6B-4bit"),
    manifest!("mlx/Qwen3-ASR-1.7B-4bit"),
    manifest!("mlx/Qwen3-0.6B-4bit"),
    manifest!("mlx/Qwen3-1.7B-4bit"),
    manifest!("sherpa-onnx/bilingual-zh-en"),
    manifest!("sherpa-onnx/multilingual-8lang"),
    manifest!("sherpa-onnx/zh-xlarge"),
];

#[cfg(test)]
mod tests {
    use super::*;
    use std::ffi::{OsStr, OsString};
    use std::fs;
    use std::time::{SystemTime, UNIX_EPOCH};

    fn temp_config_path(name: &str) -> PathBuf {
        let nonce = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap()
            .as_nanos();
        std::env::temp_dir().join(format!("koe-{name}-{nonce}.yaml"))
    }

    #[test]
    fn normalized_keys_invalid_trigger_falls_back_to_fn() {
        let h = HotkeySection {
            trigger_key: "nonexistent".into(),
            cancel_key: "left_option".into(),
            trigger_mode: "hold".into(),
        };
        assert_eq!(h.normalized_trigger_key(), "fn");
    }

    #[test]
    fn normalize_hotkey_config_normalizes_trigger_only() {
        let path = temp_config_path("hotkey-config");
        fs::write(&path, "hotkey:\n  trigger_key: 0x7A\n").unwrap();

        let config = Config {
            hotkey: HotkeySection {
                trigger_key: "0x7A".into(),
                cancel_key: "".into(),
                trigger_mode: "hold".into(),
            },
            ..Config::default()
        };

        let changed = normalize_hotkey_config(&path, &config).unwrap();
        let output = fs::read_to_string(&path).unwrap();
        let doc: serde_yaml::Value = serde_yaml::from_str(&output).unwrap();
        let hotkey = doc.get("hotkey").and_then(|v| v.as_mapping()).unwrap();
        let trigger = hotkey
            .get(serde_yaml::Value::String("trigger_key".into()))
            .and_then(|v| v.as_str())
            .unwrap();

        assert!(changed);
        assert_eq!(trigger, "122");
        assert!(!output.contains("cancel_key:"));

        let _ = fs::remove_file(path);
    }

    #[test]
    fn normalized_keys_canonicalize_combo() {
        let h = HotkeySection {
            trigger_key: "shift+cmd+49".into(),
            cancel_key: "command+shift+49".into(),
            trigger_mode: "hold".into(),
        };
        assert_eq!(h.normalized_trigger_key(), "command+shift+49");
    }

    #[test]
    fn resolve_combo_hotkey_uses_keydown_match_kind() {
        let h = HotkeySection {
            trigger_key: "cmd+shift+49".into(),
            cancel_key: "option+53".into(),
            trigger_mode: "hold".into(),
        };
        let resolved = h.resolve();

        assert_eq!(resolved.key_code, 49);
        assert_eq!(resolved.alt_key_code, 0);
        assert_eq!(resolved.modifier_flag, 0x0010_0000 | 0x0002_0000);
        assert_eq!(resolved.match_kind, HotkeyMatchKind::KeyDown);
    }

    #[test]
    fn config_default_includes_single_translation_template() {
        let config = Config::default();
        assert_eq!(config.prompt_templates, default_prompt_templates());
        assert_eq!(config.overlay.font_family, "system");
        assert_eq!(config.overlay.font_size, 13);
        assert_eq!(config.overlay.bottom_margin, 10);
        assert!(config.overlay.limit_visible_lines);
        assert_eq!(config.overlay.max_visible_lines, 3);
    }

    #[test]
    fn normalize_prompt_templates_config_replaces_legacy_defaults() {
        let path = temp_config_path("prompt-templates");
        let mut doc = serde_yaml::Mapping::new();
        doc.insert(
            serde_yaml::Value::String("prompt_templates".into()),
            serde_yaml::to_value(legacy_default_prompt_templates()).unwrap(),
        );
        fs::write(
            &path,
            serde_yaml::to_string(&serde_yaml::Value::Mapping(doc)).unwrap(),
        )
        .unwrap();

        let config = Config {
            prompt_templates: legacy_default_prompt_templates(),
            ..Config::default()
        };

        let changed = normalize_prompt_templates_config(&path, &config).unwrap();
        let output = fs::read_to_string(&path).unwrap();
        let doc: serde_yaml::Value = serde_yaml::from_str(&output).unwrap();
        let stored_templates: Vec<PromptTemplate> =
            serde_yaml::from_value(doc.get("prompt_templates").cloned().unwrap()).unwrap();

        assert!(changed);
        assert_eq!(stored_templates, default_prompt_templates());

        let _ = fs::remove_file(path);
    }

    #[test]
    fn default_llm_config_includes_all_remote_protocols_and_local_profiles() {
        let llm = LlmSection::default();

        assert_eq!(llm.active_profile, "openai");
        assert!(llm.profiles.contains_key("openai"));
        assert!(llm.profiles.contains_key("openai-responses"));
        assert!(llm.profiles.contains_key("anthropic"));
        assert!(llm.profiles.contains_key("apfel"));
        assert!(llm.profiles.contains_key("mlx"));

        let apfel = llm.profiles.get("apfel").unwrap();
        assert_eq!(apfel.provider, "apfel");
        assert_eq!(apfel.base_url, "http://127.0.0.1:11434/v1");
        assert_eq!(apfel.api_key, "");
        assert_eq!(apfel.model, "apple-foundationmodel");
        assert_eq!(apfel.endpoint_path, "/chat/completions");
        assert_eq!(apfel.api_protocol, LlmApiProtocol::OpenaiChat);
        assert!(matches!(
            apfel.max_token_parameter,
            LlmMaxTokenParameter::MaxTokens
        ));
        assert!(matches!(
            apfel.no_reasoning_control,
            LlmNoReasoningControl::None
        ));
    }

    #[test]
    fn active_profile_config_resolves_apfel_profile() {
        let llm = LlmSection {
            active_profile: "apfel".into(),
            ..LlmSection::default()
        };

        let active = llm.active_profile_config().unwrap();

        assert_eq!(active.id, "apfel");
        assert_eq!(active.provider, "apfel");
        assert_eq!(active.base_url, "http://127.0.0.1:11434/v1");
        assert_eq!(active.api_key, "");
        assert_eq!(active.model, "apple-foundationmodel");
        assert_eq!(active.endpoint_path, "/chat/completions");
        assert_eq!(active.effective_api_protocol(), LlmApiProtocol::OpenaiChat);
        assert!(active.is_ready());
    }

    #[test]
    fn legacy_profile_defaults_to_chat_and_accepts_legacy_path_key() {
        let profile: LlmProfileRuntimeConfig = serde_json::from_value(serde_json::json!({
            "id": "openai",
            "name": "OpenAI",
            "provider": "openai",
            "base_url": "https://api.openai.com/v1",
            "api_key": "",
            "model": "gpt-5.4-nano",
            "chat_completions_path": "/custom/chat",
            "max_token_parameter": "max_completion_tokens",
            "no_reasoning_control": "reasoning_effort",
            "mlx": {"model": "mlx/Qwen3-0.6B-4bit"}
        }))
        .unwrap();

        assert_eq!(profile.effective_api_protocol(), LlmApiProtocol::OpenaiChat);
        assert_eq!(profile.effective_endpoint_path(), "/custom/chat");
    }

    #[test]
    fn empty_endpoint_uses_each_protocol_default() {
        for (protocol, expected) in [
            (LlmApiProtocol::OpenaiChat, "/chat/completions"),
            (LlmApiProtocol::OpenaiResponses, "/responses"),
            (LlmApiProtocol::AnthropicMessages, "/messages"),
        ] {
            let profile = LlmProfileRuntimeConfig {
                id: "test".into(),
                name: "Test".into(),
                provider: "openai".into(),
                api_protocol: protocol,
                base_url: "https://example.com/v1".into(),
                api_key: String::new(),
                model: "model".into(),
                endpoint_path: String::new(),
                max_token_parameter: LlmMaxTokenParameter::MaxCompletionTokens,
                no_reasoning_control: LlmNoReasoningControl::None,
                mlx: Default::default(),
            };
            assert_eq!(profile.effective_endpoint_path(), expected);
        }
    }

    #[test]
    fn mlx_profile_requires_model() {
        let mut llm = LlmSection {
            active_profile: "mlx".into(),
            ..LlmSection::default()
        };
        let active = llm.active_profile_config().unwrap();
        assert!(active.is_ready());

        llm.profiles.get_mut("mlx").unwrap().mlx.model.clear();
        let active = llm.active_profile_config().unwrap();
        assert!(!active.is_ready());
    }

    // Environment variables are process-global, so every test that mutates one
    // shares this lock for its full duration. Poison-tolerant so one failing
    // test does not cascade into the others.
    static PROCESS_ENV_LOCK: std::sync::Mutex<()> = std::sync::Mutex::new(());

    struct EnvVarGuard {
        key: &'static str,
        original: Option<OsString>,
    }

    impl EnvVarGuard {
        fn new(key: &'static str) -> Self {
            Self {
                key,
                original: std::env::var_os(key),
            }
        }

        fn set(&self, value: impl AsRef<OsStr>) {
            // SAFETY: process-global environment mutation is serialized by
            // PROCESS_ENV_LOCK in every test that creates this guard.
            unsafe { std::env::set_var(self.key, value) };
        }

        fn remove(&self) {
            // SAFETY: see set().
            unsafe { std::env::remove_var(self.key) };
        }
    }

    impl Drop for EnvVarGuard {
        fn drop(&mut self) {
            // SAFETY: the lock guard outlives this value in each test, so the
            // original value is restored while mutation remains serialized.
            unsafe {
                match &self.original {
                    Some(value) => std::env::set_var(self.key, value),
                    None => std::env::remove_var(self.key),
                }
            }
        }
    }

    #[test]
    fn config_set_error_and_success() {
        let _env_lock = PROCESS_ENV_LOCK.lock().unwrap_or_else(|e| e.into_inner());
        let home = EnvVarGuard::new("HOME");

        // --- corrupted YAML should fail ---
        let tmp1 = std::env::temp_dir().join(format!(
            "koe-test-bad-{}",
            SystemTime::now()
                .duration_since(UNIX_EPOCH)
                .unwrap()
                .as_nanos()
        ));
        let koe_dir1 = tmp1.join(".koe");
        fs::create_dir_all(&koe_dir1).unwrap();
        fs::write(koe_dir1.join("config.yaml"), "{{{{invalid yaml").unwrap();

        home.set(&tmp1);
        let bad_result = config_set("test.key", "value");
        let _ = fs::remove_dir_all(&tmp1);
        assert!(
            bad_result.is_err(),
            "config_set should fail on corrupted YAML"
        );

        // --- valid YAML should succeed ---
        let tmp2 = std::env::temp_dir().join(format!(
            "koe-test-ok-{}",
            SystemTime::now()
                .duration_since(UNIX_EPOCH)
                .unwrap()
                .as_nanos()
        ));
        let koe_dir2 = tmp2.join(".koe");
        fs::create_dir_all(&koe_dir2).unwrap();
        fs::write(koe_dir2.join("config.yaml"), "asr:\n  provider: doubao\n").unwrap();

        home.set(&tmp2);
        let ok_result = config_set("llm.enabled", "true");

        assert!(ok_result.is_ok(), "config_set should succeed on valid YAML");
        let content = fs::read_to_string(koe_dir2.join("config.yaml")).unwrap();
        assert!(content.contains("enabled: true"));
        let _ = fs::remove_dir_all(&tmp2);
    }

    // ─── substitute_env_vars tests ────────────────────────────────────

    #[test]
    fn substitute_env_vars_replaces_known_var() {
        let _env_lock = PROCESS_ENV_LOCK.lock().unwrap_or_else(|e| e.into_inner());
        let variable = EnvVarGuard::new("KOE_TEST_API_KEY");
        variable.set("sk-test-123");
        let result = substitute_env_vars("api_key: ${KOE_TEST_API_KEY}");
        assert_eq!(result, "api_key: sk-test-123");
    }

    #[test]
    fn substitute_env_vars_no_rescan_prevents_infinite_loop() {
        let _env_lock = PROCESS_ENV_LOCK.lock().unwrap_or_else(|e| e.into_inner());
        let variable = EnvVarGuard::new("KOE_TEST_SELF_REF");
        // If the value itself contains "${...}", it must NOT be re-expanded.
        variable.set("${KOE_TEST_SELF_REF}");
        // Should return quickly and produce the literal value, not loop forever.
        let result = substitute_env_vars("key: ${KOE_TEST_SELF_REF}");
        assert_eq!(result, "key: ${KOE_TEST_SELF_REF}");
    }

    #[test]
    fn substitute_env_vars_value_with_dollar_brace_not_re_expanded() {
        let _env_lock = PROCESS_ENV_LOCK.lock().unwrap_or_else(|e| e.into_inner());
        let inner = EnvVarGuard::new("KOE_TEST_INNER");
        let outer = EnvVarGuard::new("KOE_TEST_OUTER");
        // A value that contains a different ${VAR} reference must not be resolved.
        inner.set("hello");
        outer.set("${KOE_TEST_INNER}");
        let result = substitute_env_vars("v: ${KOE_TEST_OUTER}");
        // Should equal the literal value of OUTER, not the expanded inner.
        assert_eq!(result, "v: ${KOE_TEST_INNER}");
    }

    #[test]
    fn substitute_env_vars_missing_var_becomes_empty() {
        let _env_lock = PROCESS_ENV_LOCK.lock().unwrap_or_else(|e| e.into_inner());
        let variable = EnvVarGuard::new("KOE_TEST_MISSING_VAR_XYZ");
        // Ensure an unset var is replaced with ""
        variable.remove();
        let result = substitute_env_vars("key: ${KOE_TEST_MISSING_VAR_XYZ}");
        assert_eq!(result, "key: ");
    }

    #[test]
    fn substitute_env_vars_no_closing_brace_left_verbatim() {
        let result = substitute_env_vars("key: ${UNCLOSED");
        assert_eq!(result, "key: ${UNCLOSED");
    }

    #[test]
    fn substitute_env_vars_multiple_vars_in_one_string() {
        let _env_lock = PROCESS_ENV_LOCK.lock().unwrap_or_else(|e| e.into_inner());
        let host = EnvVarGuard::new("KOE_TEST_HOST");
        let port = EnvVarGuard::new("KOE_TEST_PORT");
        host.set("localhost");
        port.set("8080");
        let result = substitute_env_vars("url: http://${KOE_TEST_HOST}:${KOE_TEST_PORT}/v1");
        assert_eq!(result, "url: http://localhost:8080/v1");
    }

    // Mutates HOME; serialized with every other environment-mutating test.
    #[test]
    fn config_bool_round_trip_and_isolation() {
        let _env_lock = PROCESS_ENV_LOCK.lock().unwrap_or_else(|e| e.into_inner());
        let home = EnvVarGuard::new("HOME");

        let tmp = std::env::temp_dir().join(format!(
            "koe-test-bool-{}",
            SystemTime::now()
                .duration_since(UNIX_EPOCH)
                .unwrap()
                .as_nanos()
        ));
        let koe_dir = tmp.join(".koe");
        fs::create_dir_all(&koe_dir).unwrap();
        fs::write(koe_dir.join("config.yaml"), "").unwrap();

        home.set(&tmp);

        // Write two bool keys.
        config_set("asr.doubao.enable_accelerate_text", "true").unwrap();
        config_set("llm.prompt_templates_enabled", "true").unwrap();

        // Both round-trip as the exact string "true".
        assert_eq!(
            config_get("asr.doubao.enable_accelerate_text").unwrap(),
            "true",
            "asr.doubao.enable_accelerate_text should be \"true\""
        );
        assert_eq!(
            config_get("llm.prompt_templates_enabled").unwrap(),
            "true",
            "llm.prompt_templates_enabled should be \"true\""
        );

        // Setting an unrelated third key must not clobber the first two.
        config_set("asr.provider", "doubao").unwrap();

        assert_eq!(
            config_get("asr.doubao.enable_accelerate_text").unwrap(),
            "true",
            "asr.doubao.enable_accelerate_text should still be \"true\" after sibling write"
        );
        assert_eq!(
            config_get("llm.prompt_templates_enabled").unwrap(),
            "true",
            "llm.prompt_templates_enabled should still be \"true\" after sibling write"
        );

        let _ = fs::remove_dir_all(&tmp);
    }
}
