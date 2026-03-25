use crate::errors::{KoeError, Result};
use serde::{Deserialize, Serialize};
use serde_yaml::Value;
use std::path::{Path, PathBuf};

/// Root configuration structure matching ~/.koe/config.yaml
#[derive(Debug, Deserialize, Serialize, Clone)]
pub struct Config {
    #[serde(default = "default_config_version")]
    pub version: u32,
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
}

#[derive(Debug, Deserialize, Serialize, Clone)]
pub struct AsrSection {
    #[serde(default)]
    pub provider: AsrProviderKind,
    #[serde(default = "default_connect_timeout")]
    pub connect_timeout_ms: u64,
    #[serde(default = "default_final_wait_timeout")]
    pub final_wait_timeout_ms: u64,
    #[serde(default)]
    pub doubao: DoubaoAsrSection,
    #[serde(default)]
    pub openai: OpenAIAsrSection,
    #[serde(default)]
    pub qwen: QwenAsrSection,
}

#[derive(Debug, Deserialize, Serialize, Clone, Copy, PartialEq, Eq)]
pub enum AsrProviderKind {
    #[serde(rename = "doubao")]
    Doubao,
    #[serde(rename = "openai")]
    OpenAI,
    #[serde(rename = "qwen")]
    Qwen,
}

#[derive(Debug, Deserialize, Serialize, Clone)]
pub struct DoubaoAsrSection {
    #[serde(default = "default_asr_url")]
    pub url: String,
    #[serde(default)]
    pub app_key: String,
    #[serde(default)]
    pub access_key: String,
    #[serde(default = "default_resource_id")]
    pub resource_id: String,
    #[serde(default = "default_true")]
    pub enable_ddc: bool,
    #[serde(default = "default_true")]
    pub enable_itn: bool,
    #[serde(default = "default_true")]
    pub enable_punc: bool,
    #[serde(default = "default_true")]
    pub enable_nonstream: bool,
}

#[derive(Debug, Deserialize, Serialize, Clone)]
pub struct OpenAIAsrSection {
    #[serde(default = "default_openai_asr_base_url")]
    pub base_url: String,
    #[serde(default)]
    pub api_key: String,
    #[serde(default = "default_openai_asr_model")]
    pub model: String,
    #[serde(default)]
    pub language: String,
    #[serde(default)]
    pub prompt: String,
}

#[derive(Debug, Deserialize, Serialize, Clone)]
pub struct QwenAsrSection {
    #[serde(default = "default_qwen_asr_base_url")]
    pub base_url: String,
    #[serde(default)]
    pub api_key: String,
    #[serde(default = "default_qwen_asr_model")]
    pub model: String,
    #[serde(default)]
    pub language: String,
}

#[derive(Debug, Deserialize, Serialize, Clone)]
pub struct LlmSection {
    #[serde(default = "default_true")]
    pub enabled: bool,
    #[serde(default)]
    pub base_url: String,
    #[serde(default)]
    pub api_key: String,
    #[serde(default)]
    pub model: String,
    #[serde(default)]
    pub temperature: f64,
    #[serde(default = "default_top_p")]
    pub top_p: f64,
    #[serde(default = "default_llm_timeout")]
    pub timeout_ms: u64,
    #[serde(default = "default_max_output_tokens")]
    pub max_output_tokens: u32,
    #[serde(default = "default_llm_max_token_parameter")]
    pub max_token_parameter: LlmMaxTokenParameter,
    #[serde(default = "default_dictionary_max_candidates")]
    pub dictionary_max_candidates: usize,
    #[serde(default = "default_system_prompt_path")]
    pub system_prompt_path: String,
    #[serde(default = "default_user_prompt_path")]
    pub user_prompt_path: String,
}

#[derive(Debug, Deserialize, Serialize, Clone, Copy)]
#[serde(rename_all = "snake_case")]
pub enum LlmMaxTokenParameter {
    MaxTokens,
    MaxCompletionTokens,
}

#[derive(Debug, Deserialize, Serialize, Clone)]
pub struct FeedbackSection {
    #[serde(default = "default_false")]
    pub start_sound: bool,
    #[serde(default = "default_false")]
    pub stop_sound: bool,
    #[serde(default = "default_false")]
    pub error_sound: bool,
}

#[derive(Debug, Deserialize, Serialize, Clone)]
pub struct DictionarySection {
    #[serde(default = "default_dictionary_path")]
    pub path: String,
}

#[derive(Debug, Deserialize, Serialize, Clone)]
pub struct HotkeySection {
    /// Trigger key for voice input.
    /// Options: "fn", "left_option", "right_option", "left_command", "right_command"
    /// Default: "fn"
    #[serde(default = "default_trigger_key")]
    pub trigger_key: String,
}

#[derive(Debug, Clone, Copy)]
pub struct HotkeyParams {
    pub key_code: u16,
    pub alt_key_code: u16,
    pub modifier_flag: u64,
}

impl HotkeySection {
    pub fn resolve(&self) -> HotkeyParams {
        match self.trigger_key.as_str() {
            "left_option" => HotkeyParams {
                key_code: 58,
                alt_key_code: 0,
                modifier_flag: 0x00080000,
            },
            "right_option" => HotkeyParams {
                key_code: 61,
                alt_key_code: 0,
                modifier_flag: 0x00080000,
            },
            "left_command" => HotkeyParams {
                key_code: 55,
                alt_key_code: 0,
                modifier_flag: 0x00100000,
            },
            "right_command" => HotkeyParams {
                key_code: 54,
                alt_key_code: 0,
                modifier_flag: 0x00100000,
            },
            _ => HotkeyParams {
                key_code: 63,
                alt_key_code: 179,
                modifier_flag: 0x00800000,
            },
        }
    }
}

#[derive(Debug, Deserialize, Clone)]
struct LegacyConfig {
    #[serde(default)]
    pub asr: LegacyAsrSection,
    #[serde(default)]
    pub llm: LlmSection,
    #[serde(default)]
    pub feedback: FeedbackSection,
    #[serde(default)]
    pub dictionary: DictionarySection,
    #[serde(default)]
    pub hotkey: HotkeySection,
}

#[derive(Debug, Deserialize, Clone, Default)]
struct LegacyAsrSection {
    #[serde(default = "default_asr_url")]
    pub url: String,
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
}

impl From<LegacyConfig> for Config {
    fn from(value: LegacyConfig) -> Self {
        Self {
            version: default_config_version(),
            asr: AsrSection {
                provider: AsrProviderKind::Doubao,
                connect_timeout_ms: value.asr.connect_timeout_ms,
                final_wait_timeout_ms: value.asr.final_wait_timeout_ms,
                doubao: DoubaoAsrSection {
                    url: value.asr.url,
                    app_key: value.asr.app_key,
                    access_key: value.asr.access_key,
                    resource_id: value.asr.resource_id,
                    enable_ddc: value.asr.enable_ddc,
                    enable_itn: value.asr.enable_itn,
                    enable_punc: value.asr.enable_punc,
                    enable_nonstream: value.asr.enable_nonstream,
                },
                openai: OpenAIAsrSection::default(),
                qwen: QwenAsrSection::default(),
            },
            llm: value.llm,
            feedback: value.feedback,
            dictionary: value.dictionary,
            hotkey: value.hotkey,
        }
    }
}

fn default_config_version() -> u32 {
    2
}
fn default_asr_url() -> String {
    "wss://openspeech.bytedance.com/api/v3/sauc/bigmodel_async".into()
}
fn default_resource_id() -> String {
    "volc.seedasr.sauc.duration".into()
}
fn default_openai_asr_base_url() -> String {
    "https://api.openai.com/v1".into()
}
fn default_openai_asr_model() -> String {
    "gpt-4o-transcribe".into()
}
fn default_qwen_asr_base_url() -> String {
    "wss://dashscope-intl.aliyuncs.com/api-ws/v1/realtime".into()
}
fn default_qwen_asr_model() -> String {
    "qwen3-asr-flash-realtime".into()
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
fn default_dictionary_path() -> String {
    "dictionary.txt".into()
}
fn default_system_prompt_path() -> String {
    "system_prompt.txt".into()
}
fn default_trigger_key() -> String {
    "fn".into()
}
fn default_user_prompt_path() -> String {
    "user_prompt.txt".into()
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
impl Default for AsrProviderKind {
    fn default() -> Self {
        Self::Doubao
    }
}
impl Default for DoubaoAsrSection {
    fn default() -> Self {
        serde_yaml::from_str("{}").unwrap()
    }
}
impl Default for OpenAIAsrSection {
    fn default() -> Self {
        serde_yaml::from_str("{}").unwrap()
    }
}
impl Default for QwenAsrSection {
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
impl Default for HotkeySection {
    fn default() -> Self {
        serde_yaml::from_str("{}").unwrap()
    }
}

pub fn config_dir() -> PathBuf {
    let home = std::env::var("HOME").unwrap_or_else(|_| "/tmp".into());
    PathBuf::from(home).join(".koe")
}

pub fn config_path() -> PathBuf {
    config_dir().join("config.yaml")
}

fn resolve_path(p: &str) -> PathBuf {
    let path = Path::new(p);
    if path.is_absolute() {
        path.to_path_buf()
    } else {
        config_dir().join(path)
    }
}

pub fn resolve_dictionary_path(config: &Config) -> PathBuf {
    resolve_path(&config.dictionary.path)
}

pub fn resolve_system_prompt_path(config: &Config) -> PathBuf {
    resolve_path(&config.llm.system_prompt_path)
}

pub fn resolve_user_prompt_path(config: &Config) -> PathBuf {
    resolve_path(&config.llm.user_prompt_path)
}

fn substitute_env_vars(input: &str) -> String {
    let mut result = input.to_string();
    loop {
        let start = match result.find("${") {
            Some(pos) => pos,
            None => break,
        };
        let end = match result[start + 2..].find('}') {
            Some(pos) => start + 2 + pos,
            None => break,
        };
        let var_name = &result[start + 2..end];
        let value = std::env::var(var_name).unwrap_or_default();
        result = format!("{}{}{}", &result[..start], value, &result[end + 1..]);
    }
    result
}

fn substitute_string(value: &mut String) {
    *value = substitute_env_vars(value);
}

fn substitute_config_env_vars(config: &mut Config) {
    substitute_string(&mut config.asr.doubao.url);
    substitute_string(&mut config.asr.doubao.app_key);
    substitute_string(&mut config.asr.doubao.access_key);
    substitute_string(&mut config.asr.doubao.resource_id);

    substitute_string(&mut config.asr.openai.base_url);
    substitute_string(&mut config.asr.openai.api_key);
    substitute_string(&mut config.asr.openai.model);
    substitute_string(&mut config.asr.openai.language);
    substitute_string(&mut config.asr.openai.prompt);

    substitute_string(&mut config.asr.qwen.base_url);
    substitute_string(&mut config.asr.qwen.api_key);
    substitute_string(&mut config.asr.qwen.model);
    substitute_string(&mut config.asr.qwen.language);

    substitute_string(&mut config.llm.base_url);
    substitute_string(&mut config.llm.api_key);
    substitute_string(&mut config.llm.model);
    substitute_string(&mut config.llm.system_prompt_path);
    substitute_string(&mut config.llm.user_prompt_path);
    substitute_string(&mut config.dictionary.path);
    substitute_string(&mut config.hotkey.trigger_key);
}

fn is_legacy_asr_config(root: &Value) -> bool {
    let Some(asr) = root.get("asr").and_then(Value::as_mapping) else {
        return false;
    };

    let has_provider_key = asr.contains_key(Value::String("provider".into()))
        || asr.contains_key(Value::String("doubao".into()))
        || asr.contains_key(Value::String("openai".into()))
        || asr.contains_key(Value::String("qwen".into()));

    let has_legacy_key = asr.contains_key(Value::String("url".into()))
        || asr.contains_key(Value::String("app_key".into()))
        || asr.contains_key(Value::String("access_key".into()))
        || asr.contains_key(Value::String("resource_id".into()));

    !has_provider_key && has_legacy_key
}

fn write_migrated_config(path: &Path, original_raw: &str, config: &Config) -> Result<()> {
    let backup_path = path.with_file_name("config.v1.backup.yaml");
    if !backup_path.exists() {
        std::fs::write(&backup_path, original_raw).map_err(|e| {
            KoeError::Config(format!("write backup {}: {e}", backup_path.display()))
        })?;
        log::info!("backed up legacy config to {}", backup_path.display());
    }

    let mut serialized = serde_yaml::to_string(config)
        .map_err(|e| KoeError::Config(format!("serialize migrated config: {e}")))?;
    if let Some(stripped) = serialized.strip_prefix("---\n") {
        serialized = stripped.to_string();
    }

    std::fs::write(path, serialized)
        .map_err(|e| KoeError::Config(format!("write migrated {}: {e}", path.display())))?;
    log::info!("migrated config.yaml to version {}", config.version);
    Ok(())
}

pub fn load_config() -> Result<Config> {
    let path = config_path();
    if !path.exists() {
        return Err(KoeError::Config(format!(
            "config file not found: {}",
            path.display()
        )));
    }

    let raw = std::fs::read_to_string(&path)
        .map_err(|e| KoeError::Config(format!("read {}: {e}", path.display())))?;
    let yaml_value: Value = serde_yaml::from_str(&raw)
        .map_err(|e| KoeError::Config(format!("parse {}: {e}", path.display())))?;

    let config = if is_legacy_asr_config(&yaml_value) {
        let legacy: LegacyConfig = serde_yaml::from_str(&raw)
            .map_err(|e| KoeError::Config(format!("parse legacy {}: {e}", path.display())))?;
        let migrated = Config::from(legacy);
        write_migrated_config(&path, &raw, &migrated)?;
        migrated
    } else {
        serde_yaml::from_str::<Config>(&raw)
            .map_err(|e| KoeError::Config(format!("parse {}: {e}", path.display())))?
    };

    let mut resolved = config;
    substitute_config_env_vars(&mut resolved);
    Ok(resolved)
}

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

    Ok(created)
}

const DEFAULT_CONFIG_YAML: &str = r#"# Koe - Voice Input Tool Configuration
# ~/.koe/config.yaml

version: 2

asr:
  provider: "doubao"  # doubao | openai | qwen
  connect_timeout_ms: 3000
  final_wait_timeout_ms: 5000

  doubao:
    url: "wss://openspeech.bytedance.com/api/v3/sauc/bigmodel_async"
    app_key: ""          # X-Api-App-Key (火山引擎 App ID)
    access_key: ""       # X-Api-Access-Key (火山引擎 Access Token)
    resource_id: "volc.seedasr.sauc.duration"
    enable_ddc: true
    enable_itn: true
    enable_punc: true
    enable_nonstream: true

  openai:
    base_url: "https://api.openai.com/v1"
    api_key: ""          # or use ${OPENAI_API_KEY}
    model: "gpt-4o-transcribe"
    language: ""
    prompt: ""

  qwen:
    base_url: "wss://dashscope-intl.aliyuncs.com/api-ws/v1/realtime"
    api_key: ""          # or use ${QWEN_API_KEY}
    model: "qwen3-asr-flash-realtime"
    language: ""

llm:
  enabled: true
  base_url: "https://api.openai.com/v1"
  api_key: ""
  model: "gpt-5.4-nano"
  temperature: 0
  top_p: 1
  timeout_ms: 8000
  max_output_tokens: 1024
  max_token_parameter: "max_completion_tokens"
  dictionary_max_candidates: 0
  system_prompt_path: "system_prompt.txt"
  user_prompt_path: "user_prompt.txt"

feedback:
  start_sound: false
  stop_sound: false
  error_sound: false

dictionary:
  path: "dictionary.txt"

hotkey:
  trigger_key: "fn"
"#;

const DEFAULT_DICTIONARY_TXT: &str = r#"# Koe User Dictionary
# One term per line. These terms are prioritized during LLM correction.
# Lines starting with # are comments.

"#;

const DEFAULT_SYSTEM_PROMPT: &str = include_str!("default_system_prompt.txt");
const DEFAULT_USER_PROMPT: &str = include_str!("default_user_prompt.txt");
