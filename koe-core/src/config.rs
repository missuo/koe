use crate::errors::{KoeError, Result};
use serde::Deserialize;
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
}

// ─── ASR V2 Configuration ───────────────────────────────────────────

#[derive(Debug, Deserialize, Clone)]
pub struct AsrSection {
    /// Which ASR provider to use: "doubao" (default), future: "openai", etc.
    #[serde(default = "default_asr_provider")]
    pub provider: String,

    /// Doubao (豆包/火山引擎) ASR configuration
    #[serde(default)]
    pub doubao: DoubaoAsrConfig,
}

#[derive(Debug, Deserialize, Clone)]
pub struct DoubaoAsrConfig {
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

// ─── Other Sections (unchanged) ─────────────────────────────────────

#[derive(Debug, Deserialize, Clone)]
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

#[derive(Debug, Deserialize, Clone, Copy)]
#[serde(rename_all = "snake_case")]
pub enum LlmMaxTokenParameter {
    MaxTokens,
    MaxCompletionTokens,
}

#[derive(Debug, Deserialize, Clone)]
pub struct FeedbackSection {
    #[serde(default = "default_true")]
    pub start_sound: bool,
    #[serde(default = "default_true")]
    pub stop_sound: bool,
    #[serde(default = "default_true")]
    pub error_sound: bool,
}

#[derive(Debug, Deserialize, Clone)]
pub struct DictionarySection {
    #[serde(default = "default_dictionary_path")]
    pub path: String,
}

#[derive(Debug, Deserialize, Clone)]
pub struct HotkeySection {
    /// Trigger key for voice input.
    /// Options: "fn", "left_option", "right_option", "left_command", "right_command", "left_control", "right_control"
    /// Default: "fn"
    #[serde(default = "default_trigger_key")]
    pub trigger_key: String,

    /// Cancel key for aborting the current voice input session.
    /// Options: "fn", "left_option", "right_option", "left_command", "right_command", "left_control", "right_control"
    /// Default: "left_option"
    #[serde(default = "default_cancel_key")]
    pub cancel_key: String,
}

/// Resolved hotkey parameters for the native side
#[derive(Debug, Clone, Copy)]
pub struct HotkeyParams {
    /// Primary key code (from Carbon Events)
    pub key_code: u16,
    /// Alternative key code (e.g. 179 for Globe key), 0 if none
    pub alt_key_code: u16,
    /// Modifier flag to check (e.g. NSEventModifierFlagFunction = 0x800000)
    pub modifier_flag: u64,
}

/// Resolved trigger/cancel hotkey parameters for the native side.
#[derive(Debug, Clone, Copy)]
pub struct ResolvedHotkeyConfig {
    pub trigger: HotkeyParams,
    pub cancel: HotkeyParams,
}

impl HotkeySection {
    pub fn normalized_keys(&self) -> (String, String) {
        let trigger_key = self.normalized_trigger_key();
        let cancel_key = self.normalized_cancel_key(&trigger_key);
        (trigger_key, cancel_key)
    }

    /// Resolve the configured trigger/cancel hotkeys into concrete key codes
    /// and modifier flags. If both hotkeys are configured to the same key,
    /// keep the trigger key and fall back the cancel key to a distinct default.
    pub fn resolve(&self) -> ResolvedHotkeyConfig {
        let (trigger_key, cancel_key) = self.normalized_keys();
        ResolvedHotkeyConfig {
            trigger: Self::resolve_key(&trigger_key),
            cancel: Self::resolve_key(&cancel_key),
        }
    }

    fn normalized_trigger_key(&self) -> String {
        Self::normalize_trigger_key_name(&self.trigger_key)
    }

    fn normalized_cancel_key(&self, trigger_key: &str) -> String {
        let cancel_key = Self::normalize_cancel_key_name(&self.cancel_key);
        if cancel_key == trigger_key {
            default_cancel_key_for_trigger(trigger_key).into()
        } else {
            cancel_key
        }
    }

    fn normalize_trigger_key_name(value: &str) -> String {
        match value {
            "left_option" | "right_option" | "left_command" | "right_command" | "left_control" | "right_control" | "fn" => value.into(),
            _ => default_trigger_key(),
        }
    }

    fn normalize_cancel_key_name(value: &str) -> String {
        match value {
            "left_option" | "right_option" | "left_command" | "right_command" | "left_control" | "right_control" | "fn" => value.into(),
            _ => default_cancel_key(),
        }
    }

    fn resolve_key(key: &str) -> HotkeyParams {
        match key {
            "left_option" => HotkeyParams {
                key_code: 58,       // kVK_Option
                alt_key_code: 0,
                modifier_flag: 0x00000020,  // NX_DEVICELALTKEYMASK
            },
            "right_option" => HotkeyParams {
                key_code: 61,       // kVK_RightOption
                alt_key_code: 0,
                modifier_flag: 0x00000040,  // NX_DEVICERALTKEYMASK
            },
            "left_command" => HotkeyParams {
                key_code: 55,       // kVK_Command
                alt_key_code: 0,
                modifier_flag: 0x00000008,  // NX_DEVICELCMDKEYMASK
            },
            "right_command" => HotkeyParams {
                key_code: 54,       // kVK_RightCommand
                alt_key_code: 0,
                modifier_flag: 0x00000010,  // NX_DEVICERCMDKEYMASK
            },
            "left_control" => HotkeyParams {
                key_code: 59,       // kVK_Control
                alt_key_code: 0,
                modifier_flag: 0x00000001,  // NX_DEVICELCTLKEYMASK
            },
            "right_control" => HotkeyParams {
                key_code: 62,       // kVK_RightControl
                alt_key_code: 0,
                modifier_flag: 0x00002000,  // NX_DEVICERCTLKEYMASK
            },
            // "fn" or anything else defaults to Fn/Globe
            _ => HotkeyParams {
                key_code: 63,       // kVK_Function (Fn)
                alt_key_code: 179,  // Globe key on newer keyboards
                modifier_flag: 0x00800000,  // NSEventModifierFlagFunction
            },
        }
    }
}

// ─── Defaults ───────────────────────────────────────────────────────

fn default_asr_provider() -> String {
    "doubao".into()
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

fn default_cancel_key() -> String {
    "left_option".into()
}

fn default_cancel_key_for_trigger(trigger_key: &str) -> &'static str {
    match trigger_key {
        "fn" => "left_option",
        "left_option" => "right_option",
        "right_option" => "left_command",
        "left_command" => "right_command",
        "right_command" => "left_control",
        "left_control" => "right_control",
        "right_control" => "fn",
        _ => "left_option",
    }
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
fn substitute_env_vars(input: &str) -> String {
    let mut result = input.to_string();
    // Simple regex-free approach
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

// ─── V1 → V2 Config Migration ──────────────────────────────────────

/// V1 ASR fields that indicate the old flat format.
const V1_ASR_KEYS: &[&str] = &[
    "app_key", "access_key", "url", "resource_id",
    "connect_timeout_ms", "final_wait_timeout_ms",
    "enable_ddc", "enable_itn", "enable_punc", "enable_nonstream",
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
    if asr_map.contains_key(&serde_yaml::Value::String("provider".into())) {
        return Ok(false);
    }

    // If `asr` has a `doubao` key, it's already V2 (just missing provider field, which defaults)
    if asr_map.contains_key(&serde_yaml::Value::String("doubao".into())) {
        return Ok(false);
    }

    // Check if any V1-specific key exists
    let has_v1_keys = V1_ASR_KEYS.iter().any(|k| {
        asr_map.contains_key(&serde_yaml::Value::String((*k).into()))
    });

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

    std::fs::write(path, &output)
        .map_err(|e| KoeError::Config(format!("write migrated config {}: {e}", path.display())))?;

    log::info!("config migrated to V2 format successfully");
    Ok(true)
}

/// Ensure hotkey config persisted on disk includes both trigger and cancel keys.
/// This backfills `hotkey.cancel_key` for older configs and normalizes duplicate
/// trigger/cancel combinations into a valid persisted config.
fn normalize_hotkey_config(path: &Path, config: &Config) -> Result<bool> {
    let raw = std::fs::read_to_string(path)
        .map_err(|e| KoeError::Config(format!("read {}: {e}", path.display())))?;

    let mut doc: serde_yaml::Value = serde_yaml::from_str(&raw)
        .map_err(|e| KoeError::Config(format!("parse {}: {e}", path.display())))?;

    let doc_map = match doc.as_mapping_mut() {
        Some(map) => map,
        None => return Ok(false),
    };

    let (normalized_trigger, normalized_cancel) = config.hotkey.normalized_keys();
    let hotkey_key = serde_yaml::Value::String("hotkey".into());

    let hotkey_value = doc_map.entry(hotkey_key).or_insert_with(|| {
        serde_yaml::Value::Mapping(serde_yaml::Mapping::new())
    });

    let hotkey_map = match hotkey_value.as_mapping_mut() {
        Some(map) => map,
        None => return Ok(false),
    };

    let trigger_key = serde_yaml::Value::String("trigger_key".into());
    let cancel_key = serde_yaml::Value::String("cancel_key".into());

    let stored_trigger = hotkey_map.get(&trigger_key).and_then(|v| v.as_str());
    let stored_cancel = hotkey_map.get(&cancel_key).and_then(|v| v.as_str());

    if stored_trigger == Some(normalized_trigger.as_str())
        && stored_cancel == Some(normalized_cancel.as_str())
    {
        return Ok(false);
    }

    hotkey_map.insert(trigger_key, serde_yaml::Value::String(normalized_trigger));
    hotkey_map.insert(cancel_key, serde_yaml::Value::String(normalized_cancel));

    let yaml_str = serde_yaml::to_string(&doc)
        .map_err(|e| KoeError::Config(format!("serialize normalized config: {e}")))?;

    let output = format!(
        "# Koe - Voice Input Tool Configuration\n\
         # ~/.koe/config.yaml\n\n\
         {yaml_str}"
    );

    std::fs::write(path, &output)
        .map_err(|e| KoeError::Config(format!("write normalized config {}: {e}", path.display())))?;

    log::info!("normalized hotkey config on disk");
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

    let config: Config = serde_yaml::from_str(&substituted)
        .map_err(|e| KoeError::Config(format!("parse {}: {e}", path.display())))?;

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

    Ok(created)
}

const DEFAULT_CONFIG_YAML: &str = r#"# Koe - Voice Input Tool Configuration
# ~/.koe/config.yaml

asr:
  # ASR provider: "doubao" (default)
  provider: "doubao"

  # Doubao (豆包) Streaming ASR 2.0 (优化版双向流式)
  doubao:
    url: "wss://openspeech.bytedance.com/api/v3/sauc/bigmodel_async"
    app_key: ""          # X-Api-App-Key (火山引擎 App ID)
    access_key: ""       # X-Api-Access-Key (火山引擎 Access Token)
    resource_id: "volc.seedasr.sauc.duration"
    connect_timeout_ms: 3000
    final_wait_timeout_ms: 5000
    enable_ddc: true     # 语义顺滑 (去除口语重复/语气词)
    enable_itn: true     # 文本规范化 (数字、日期等)
    enable_punc: true    # 自动标点
    enable_nonstream: true  # 二遍识别 (流式+非流式, 提升准确率)

llm:
  enabled: true        # set to false to skip LLM correction entirely
  # OpenAI-compatible endpoint for text correction
  base_url: "https://api.openai.com/v1"
  api_key: ""          # or use ${LLM_API_KEY}
  model: "gpt-5.4-nano"
  temperature: 0
  top_p: 1
  timeout_ms: 8000
  max_output_tokens: 1024
  max_token_parameter: "max_completion_tokens"  # use "max_tokens" for older model endpoints
  dictionary_max_candidates: 0             # 0 = send all entries to LLM
  system_prompt_path: "system_prompt.txt"  # relative to ~/.koe/
  user_prompt_path: "user_prompt.txt"      # relative to ~/.koe/

feedback:
  start_sound: false
  stop_sound: false
  error_sound: false

dictionary:
  path: "dictionary.txt"  # relative to ~/.koe/

hotkey:
  # 触发键：fn | left_option | right_option | left_command | right_command | left_control | right_control
  trigger_key: "fn"
  # 取消键：fn | left_option | right_option | left_command | right_command | left_control | right_control（不能与触发键重复）
  cancel_key: "left_option"
"#;

const DEFAULT_DICTIONARY_TXT: &str = r#"# Koe User Dictionary
# One term per line. These terms are prioritized during LLM correction.
# Lines starting with # are comments.

"#;

const DEFAULT_SYSTEM_PROMPT: &str = include_str!("default_system_prompt.txt");

const DEFAULT_USER_PROMPT: &str = include_str!("default_user_prompt.txt");

#[cfg(test)]
mod tests {
    use super::*;
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
    fn normalize_hotkey_config_backfills_missing_cancel_key() {
        let path = temp_config_path("hotkey-config");
        fs::write(
            &path,
            "hotkey:\n  trigger_key: left_option\n",
        )
        .unwrap();

        let config = Config {
            hotkey: HotkeySection {
                trigger_key: "left_option".into(),
                cancel_key: "".into(),
            },
            ..Config::default()
        };

        let changed = normalize_hotkey_config(&path, &config).unwrap();
        let output = fs::read_to_string(&path).unwrap();

        assert!(changed);
        assert!(output.contains("trigger_key: left_option"));
        assert!(output.contains("cancel_key: right_option"));

        let _ = fs::remove_file(path);
    }

    #[test]
    fn default_cancel_key_cycles_through_all_keys() {
        assert_eq!(default_cancel_key_for_trigger("fn"), "left_option");
        assert_eq!(default_cancel_key_for_trigger("left_option"), "right_option");
        assert_eq!(default_cancel_key_for_trigger("right_option"), "left_command");
        assert_eq!(default_cancel_key_for_trigger("left_command"), "right_command");
        assert_eq!(default_cancel_key_for_trigger("right_command"), "left_control");
        assert_eq!(default_cancel_key_for_trigger("left_control"), "right_control");
        assert_eq!(default_cancel_key_for_trigger("right_control"), "fn");
    }

    #[test]
    fn default_cancel_key_falls_back_for_unknown() {
        assert_eq!(default_cancel_key_for_trigger("unknown"), "left_option");
    }
}
