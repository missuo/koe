pub mod audio_buffer;
pub mod config;
pub mod dictionary;
pub mod errors;
pub mod ffi;
pub mod llm;
pub mod model_manager;
pub mod prompt;
pub mod session;
pub mod telemetry;

use crate::config::Config;
use crate::ffi::{
    cstr_to_str, invoke_asr_final_text, invoke_final_text_ready, invoke_interim_text,
    invoke_rewrite_text_ready, invoke_session_error, invoke_session_ready, invoke_session_warning,
    invoke_state_changed, SPCallbacks, SPFeedbackConfig, SPHotkeyConfig, SPSessionContext,
    SPSessionMode,
};
#[cfg(feature = "mlx")]
use crate::llm::mlx::MlxLlmProvider;
use crate::llm::openai_compatible::{
    build_http_client, OpenAiCompatibleProvider, LLM_HTTP_POOL_IDLE_TIMEOUT,
};
use crate::llm::{CorrectionRequest, LlmProvider};
use crate::session::{Session, SessionState};
#[cfg(feature = "apple-speech")]
use koe_asr::{AppleSpeechConfig, AppleSpeechProvider};
use koe_asr::{
    AsrConfig, AsrEvent, AsrProvider, DoubaoImeProvider, DoubaoWsProvider, QwenAsrProvider,
    TranscriptAggregator,
};
#[cfg(feature = "mlx")]
use koe_asr::{MlxConfig, MlxProvider};
#[cfg(feature = "sherpa-onnx")]
use koe_asr::{SherpaOnnxConfig, SherpaOnnxProvider};
use reqwest::Client;

use std::collections::HashSet;
use std::ffi::c_char;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};
use std::time::Instant;
use tokio::runtime::Runtime;
use tokio::sync::mpsc;
use tokio::time::{timeout, Duration};

const LLM_WARMUP_SAFETY_MARGIN: Duration = Duration::from_secs(20);
const LLM_WARMUP_TTL: Duration =
    match LLM_HTTP_POOL_IDLE_TIMEOUT.checked_sub(LLM_WARMUP_SAFETY_MARGIN) {
        Some(duration) => duration,
        None => Duration::from_secs(0),
    };

#[derive(Default)]
struct LlmWarmupState {
    in_flight: bool,
    last_touched: Option<Instant>,
}

/// Global core state
struct Core {
    runtime: Runtime,
    audio_tx: Option<mpsc::Sender<Vec<u8>>>,
    session: Arc<Mutex<Option<Session>>>,
    cancelled: Arc<AtomicBool>,
    config: Config,
    dictionary: Vec<String>,
    system_prompt: String,
    user_prompt_template: String,
    llm_http_client: Client,
    llm_warmup_state: Arc<Mutex<LlmWarmupState>>,
    /// Session token from the most recent sp_core_session_begin call.
    /// Used by sp_core_rewrite_with_template to route callbacks.
    current_session_token: u64,
}

static CORE: Mutex<Option<Core>> = Mutex::new(None);

fn llm_http_client_needs_reload(current: &Config, next: &Config) -> bool {
    current.llm.timeout_ms != next.llm.timeout_ms
}

// ─── FFI Entry Points ───────────────────────────────────────────────

/// Initialize the core. Must be called once before any other function.
/// `config_path` is reserved for future use (currently loads from ~/.koe/config.yaml).
///
/// # Safety
/// `config_path` must be a valid null-terminated C string or null.
#[no_mangle]
pub unsafe extern "C" fn sp_core_create(config_path: *const c_char) -> i32 {
    telemetry::init_logging();

    let _config_path = unsafe { cstr_to_str(config_path) };
    log::info!("sp_core_create called");

    // Ensure ~/.koe/ exists with default config and dictionary
    match config::ensure_defaults() {
        Ok(true) => log::info!("created default config files in ~/.koe/"),
        Ok(false) => {}
        Err(e) => log::warn!("ensure_defaults failed: {e}"),
    }

    // Load config
    let cfg = match config::load_config() {
        Ok(c) => c,
        Err(e) => {
            log::warn!("failed to load config, using defaults: {e}");
            Config::default()
        }
    };

    // Load dictionary
    let dict_path = config::resolve_dictionary_path(&cfg);
    let dictionary = match dictionary::load_dictionary(&dict_path) {
        Ok(d) => d,
        Err(e) => {
            log::warn!("failed to load dictionary: {e}");
            vec![]
        }
    };

    // Load prompts
    let system_prompt = prompt::load_system_prompt(&config::resolve_system_prompt_path(&cfg));
    let user_prompt_template =
        prompt::load_user_prompt_template(&config::resolve_user_prompt_path(&cfg));

    let runtime = match Runtime::new() {
        Ok(rt) => rt,
        Err(e) => {
            log::error!("failed to create tokio runtime: {e}");
            return -1;
        }
    };
    let llm_http_client = match build_http_client(cfg.llm.timeout_ms) {
        Ok(client) => client,
        Err(e) => {
            log::error!("failed to create LLM HTTP client: {e}");
            return -1;
        }
    };

    let core = Core {
        runtime,
        audio_tx: None,
        session: Arc::new(Mutex::new(None)),
        cancelled: Arc::new(AtomicBool::new(false)),
        config: cfg,
        dictionary,
        system_prompt,
        user_prompt_template,
        llm_http_client,
        llm_warmup_state: Arc::new(Mutex::new(LlmWarmupState::default())),
        current_session_token: 0,
    };

    let mut global = CORE.lock().unwrap();
    *global = Some(core);

    log::info!("core initialized");
    0
}

/// Shut down the core and release all resources.
#[no_mangle]
pub extern "C" fn sp_core_destroy() {
    log::info!("sp_core_destroy called");
    let mut global = CORE.lock().unwrap();
    *global = None;
}

/// Register callbacks from the Obj-C side.
#[no_mangle]
pub extern "C" fn sp_core_register_callbacks(callbacks: SPCallbacks) {
    ffi::register_callbacks(callbacks);
}

/// Reload configuration and dictionary from disk.
/// Takes effect on the next session.
#[no_mangle]
pub extern "C" fn sp_core_reload_config() -> i32 {
    log::info!("sp_core_reload_config called");

    let cfg = match config::load_config() {
        Ok(c) => c,
        Err(e) => {
            log::error!("reload config failed: {e}");
            return -1;
        }
    };

    let dict_path = config::resolve_dictionary_path(&cfg);
    let dictionary = match dictionary::load_dictionary(&dict_path) {
        Ok(d) => d,
        Err(e) => {
            log::warn!("reload dictionary failed: {e}");
            vec![]
        }
    };

    let system_prompt = prompt::load_system_prompt(&config::resolve_system_prompt_path(&cfg));
    let user_prompt_template =
        prompt::load_user_prompt_template(&config::resolve_user_prompt_path(&cfg));

    let mut global = CORE.lock().unwrap();
    if let Some(ref mut core) = *global {
        if llm_http_client_needs_reload(&core.config, &cfg) {
            let llm_http_client = match build_http_client(cfg.llm.timeout_ms) {
                Ok(client) => client,
                Err(e) => {
                    log::error!("reload HTTP client failed: {e}");
                    return -1;
                }
            };
            core.llm_http_client = llm_http_client;
            log::info!("LLM HTTP client reloaded after timeout_ms change");
        }
        core.config = cfg;
        core.dictionary = dictionary;
        core.system_prompt = system_prompt;
        core.user_prompt_template = user_prompt_template;
        log::info!("config, dictionary, prompts, and HTTP client reloaded as needed");
    }

    0
}

/// Begin a new voice input session.
#[no_mangle]
pub extern "C" fn sp_core_session_begin(context: SPSessionContext) -> i32 {
    let bundle_id = unsafe { cstr_to_str(context.frontmost_bundle_id) }.map(|s| s.to_string());

    log::info!(
        "sp_core_session_begin: mode={:?}, app={:?}, pid={}",
        context.mode,
        bundle_id,
        context.frontmost_pid,
    );

    let mut global = CORE.lock().unwrap();
    let core = match global.as_mut() {
        Some(c) => c,
        None => {
            log::error!("core not initialized");
            return -1;
        }
    };

    // Hot-reload: re-read config, dictionary, and prompts at session start
    // Files are tiny so overhead is negligible — no need to manually Reload Config
    if let Ok(new_cfg) = config::load_config() {
        let dict_path = config::resolve_dictionary_path(&new_cfg);
        if let Ok(d) = dictionary::load_dictionary(&dict_path) {
            core.dictionary = d;
        }
        core.system_prompt =
            prompt::load_system_prompt(&config::resolve_system_prompt_path(&new_cfg));
        core.user_prompt_template =
            prompt::load_user_prompt_template(&config::resolve_user_prompt_path(&new_cfg));
        if llm_http_client_needs_reload(&core.config, &new_cfg) {
            match build_http_client(new_cfg.llm.timeout_ms) {
                Ok(client) => {
                    core.llm_http_client = client;
                    log::info!("LLM HTTP client reloaded at session start after timeout_ms change");
                }
                Err(e) => {
                    log::warn!("failed to reload LLM HTTP client at session start: {e}");
                }
            }
        }
        core.config = new_cfg;
    }

    // Create session
    let session = Session::new(context.mode, bundle_id, context.frontmost_pid);
    let session_id = session.id.clone();
    let session_token = context.session_token;
    core.current_session_token = session_token;
    let mode = context.mode;

    // Abort any still-running old session: signal its cancelled flag and close
    // its audio channel.  The old task holds its own Arc clones and will see the
    // cancellation; its cleanup_session writes to the OLD Arc, not the new one.
    core.cancelled.store(true, Ordering::SeqCst);
    core.audio_tx = None;

    // Create fresh per-session Arcs so old and new tasks are fully isolated
    core.cancelled = Arc::new(AtomicBool::new(false));
    core.session = Arc::new(Mutex::new(None));

    // Audio channel for new session
    let (audio_tx, audio_rx) = mpsc::channel::<Vec<u8>>(1024);
    core.audio_tx = Some(audio_tx);

    let cancelled = core.cancelled.clone();
    let session_arc = core.session.clone();
    {
        let mut s = session_arc.lock().unwrap();
        *s = Some(session);
    }

    // Capture config for the async task
    let cfg = &core.config;
    let asr_provider_name = cfg.asr.provider.clone();

    // Build provider-specific AsrConfig and create the provider instance.
    //
    // Previously, the provider was created inside run_session. It is now
    // created here so that local providers (e.g. mlx) can receive their
    // typed config via the constructor, while cloud providers (doubao, qwen)
    // continue to receive config via connect(&AsrConfig).
    //
    // Provider lifecycle is unchanged:
    //
    //   Before:
    //     sp_core_session_begin()
    //       → runtime.spawn(async move {
    //           run_session(...)
    //             → new()              // created here
    //             → connect()
    //             → send_audio() ...
    //             → close()
    //             → function returns, provider dropped
    //         })
    //
    //   After:
    //     sp_core_session_begin()
    //       → new()                    // created here (moved earlier)
    //       → runtime.spawn(async move {  // ownership transferred via move
    //           run_session(..., asr)
    //             → connect()
    //             → send_audio() ...
    //             → close()
    //             → function returns, provider dropped (same as before)
    //         })
    //
    // - Created once per session: sp_core_session_begin is called once per
    //   voice input session, so the provider is created exactly once.
    // - Drop timing unchanged: ownership moves into the async closure, then
    //   into run_session; the provider is dropped when run_session returns.
    // - The only difference: new() now runs in a sync context instead of an
    //   async context, but new() only initializes struct fields with no async
    //   operations, so this has no effect.
    let (asr_config, asr): (AsrConfig, Box<dyn AsrProvider>) = match asr_provider_name.as_str() {
        "doubaoime" => {
            let ime = &cfg.asr.doubaoime;
            let credential_path = if std::path::Path::new(&ime.credential_path).is_absolute() {
                ime.credential_path.clone()
            } else {
                config::config_dir()
                    .join(&ime.credential_path)
                    .to_string_lossy()
                    .to_string()
            };
            let mut custom_headers = std::collections::HashMap::new();
            custom_headers.insert("credential_path".to_string(), credential_path);
            let config = AsrConfig {
                url: String::new(),
                app_key: String::new(),
                access_key: String::new(),
                resource_id: String::new(),
                sample_rate_hz: 16000,
                connect_timeout_ms: ime.connect_timeout_ms,
                final_wait_timeout_ms: ime.final_wait_timeout_ms,
                enable_ddc: false,
                enable_itn: false,
                enable_punc: true,
                enable_nonstream: false,
                hotwords: Vec::new(),
                language: Some("zh".to_string()),
                custom_headers,
            };
            (config, Box::new(DoubaoImeProvider::new()))
        }
        "qwen" => {
            let qwen = &cfg.asr.qwen;
            let config = AsrConfig {
                url: qwen.url.clone(),
                app_key: qwen.model.clone(),
                access_key: qwen.api_key.clone(),
                resource_id: String::new(),
                sample_rate_hz: 16000,
                connect_timeout_ms: qwen.connect_timeout_ms,
                final_wait_timeout_ms: qwen.final_wait_timeout_ms,
                enable_ddc: false,
                enable_itn: false,
                enable_punc: false,
                enable_nonstream: false,
                hotwords: Vec::new(),
                language: Some(qwen.language.clone()),
                custom_headers: qwen.headers.clone(),
            };
            (config, Box::new(QwenAsrProvider::new()))
        }
        #[cfg(feature = "mlx")]
        "mlx" => {
            let mlx = &cfg.asr.mlx;
            let model_path = config::resolve_model_dir(&mlx.model)
                .to_string_lossy()
                .to_string();
            let mlx_config = MlxConfig {
                model_path,
                language: mlx.language.clone(),
                delay_preset: mlx.delay_preset.clone(),
            };
            (AsrConfig::default(), Box::new(MlxProvider::new(mlx_config)))
        }
        #[cfg(feature = "sherpa-onnx")]
        "sherpa-onnx" => {
            let s = &cfg.asr.sherpa_onnx;
            let model_dir = config::resolve_model_dir(&s.model);
            let sherpa_config = SherpaOnnxConfig {
                model_dir,
                num_threads: s.num_threads,
                hotwords: core.dictionary.clone(),
                hotwords_score: s.hotwords_score,
                endpoint_silence: s.endpoint_silence,
            };
            (
                AsrConfig::default(),
                Box::new(SherpaOnnxProvider::new(sherpa_config)),
            )
        }
        #[cfg(feature = "apple-speech")]
        "apple-speech" => {
            let as_cfg = &cfg.asr.apple_speech;
            let apple_config = AppleSpeechConfig {
                locale: as_cfg.locale.clone(),
                contextual_strings: core.dictionary.clone(),
            };
            (
                AsrConfig::default(),
                Box::new(AppleSpeechProvider::new(apple_config)),
            )
        }
        _ => {
            let doubao = &cfg.asr.doubao;
            let config = AsrConfig {
                url: doubao.url.clone(),
                app_key: doubao.app_key.clone(),
                access_key: doubao.access_key.clone(),
                resource_id: doubao.resource_id.clone(),
                sample_rate_hz: 16000,
                connect_timeout_ms: doubao.connect_timeout_ms,
                final_wait_timeout_ms: doubao.final_wait_timeout_ms,
                enable_ddc: doubao.enable_ddc,
                enable_itn: doubao.enable_itn,
                enable_punc: doubao.enable_punc,
                enable_nonstream: doubao.enable_nonstream,
                hotwords: core.dictionary.clone(),
                language: Some("zh".to_string()),
                custom_headers: doubao.headers.clone(),
            };
            (config, Box::new(DoubaoWsProvider::new()))
        }
    };
    let llm_config = cfg.llm.clone();
    let llm_http_client = core.llm_http_client.clone();
    let llm_warmup_state = core.llm_warmup_state.clone();
    let dictionary = core.dictionary.clone();
    let dictionary_max_candidates = cfg.llm.dictionary_max_candidates;
    let system_prompt = core.system_prompt.clone();
    let user_prompt_template = core.user_prompt_template.clone();

    start_llm_warmup_if_needed(
        &core.runtime,
        &session_id,
        &llm_config,
        llm_http_client.clone(),
        llm_warmup_state.clone(),
    );

    // Spawn the session task
    core.runtime.spawn(async move {
        run_session(
            session_arc,
            session_id,
            session_token,
            mode,
            audio_rx,
            asr_config,
            asr_provider_name,
            asr,
            llm_config,
            llm_http_client,
            llm_warmup_state,
            dictionary,
            dictionary_max_candidates,
            system_prompt,
            user_prompt_template,
            cancelled,
        )
        .await;
    });

    0
}

/// Push an audio frame into the current session.
///
/// # Safety
/// `frame` must point to at least `len` valid bytes.
#[no_mangle]
pub unsafe extern "C" fn sp_core_push_audio(frame: *const u8, len: u32, _timestamp: u64) -> i32 {
    if frame.is_null() || len == 0 {
        return -1;
    }

    let data = unsafe { std::slice::from_raw_parts(frame, len as usize) }.to_vec();

    let global = CORE.lock().unwrap();
    if let Some(ref core) = *global {
        if let Some(ref tx) = core.audio_tx {
            if tx.try_send(data).is_err() {
                log::warn!("audio channel full, frame dropped");
            }
        }
    }
    0
}

/// End the current session (user released hotkey or tapped again).
#[no_mangle]
pub extern "C" fn sp_core_session_end() -> i32 {
    log::info!("sp_core_session_end called");

    let mut global = CORE.lock().unwrap();
    if let Some(ref mut core) = *global {
        // Drop the audio sender to signal the session task
        core.audio_tx = None;
    }
    0
}

/// Cancel the current session. No text will be output.
#[no_mangle]
pub extern "C" fn sp_core_session_cancel() -> i32 {
    log::info!("sp_core_session_cancel called");

    let mut global = CORE.lock().unwrap();
    if let Some(ref mut core) = *global {
        // Set cancelled flag so the session task aborts without output
        core.cancelled.store(true, Ordering::SeqCst);
        // Drop the audio sender to unblock the session task
        core.audio_tx = None;
    }
    0
}

fn validate_prompt_templates(
    templates: &[config::PromptTemplate],
) -> std::result::Result<(), String> {
    if templates.len() > 9 {
        return Err("Prompt templates are limited to 9 entries.".into());
    }

    let mut used_shortcuts = HashSet::new();
    for (index, template) in templates.iter().enumerate() {
        let template_label = if template.name.trim().is_empty() {
            format!("Template #{}", index + 1)
        } else {
            format!("Template '{}'", template.name.trim())
        };

        if !(1..=9).contains(&template.shortcut) {
            return Err(format!(
                "{template_label} uses invalid shortcut {}. Shortcuts must be between 1 and 9.",
                template.shortcut
            ));
        }
        if !used_shortcuts.insert(template.shortcut) {
            return Err(format!(
                "Duplicate template shortcut {} detected. Each template needs a unique shortcut.",
                template.shortcut
            ));
        }
        if template.resolve_system_prompt().is_none() {
            return Err(format!("{template_label} needs a non-empty prompt."));
        }
    }

    Ok(())
}

/// Return prompt templates as JSON array.
/// Each entry mirrors config::PromptTemplate for lossless round-tripping.
/// Caller must free with sp_core_free_string().
#[no_mangle]
pub extern "C" fn sp_core_get_prompt_templates_json() -> *mut c_char {
    let global = CORE.lock().unwrap();
    if let Some(ref core) = *global {
        let json =
            serde_json::to_string(&core.config.prompt_templates).unwrap_or_else(|_| "[]".into());
        CString::new(json).unwrap_or_default().into_raw()
    } else {
        CString::new("[]").unwrap_or_default().into_raw()
    }
}

/// Set prompt templates from a JSON array string.
/// Each entry: {"name":"...", "shortcut":N, "system_prompt":"..."}
/// Writes to config.yaml and reloads config.
///
/// # Safety
/// `json_str` must be a valid null-terminated C string.
#[no_mangle]
pub unsafe extern "C" fn sp_core_set_prompt_templates_json(json_str: *const c_char) -> i32 {
    let json = match unsafe { cstr_to_str(json_str) } {
        Some(s) => s,
        None => return -1,
    };

    let templates: Vec<config::PromptTemplate> = match serde_json::from_str(json) {
        Ok(t) => t,
        Err(e) => {
            log::error!("sp_core_set_prompt_templates_json: parse error: {e}");
            return -1;
        }
    };
    if let Err(message) = validate_prompt_templates(&templates) {
        log::error!("sp_core_set_prompt_templates_json: validation error: {message}");
        return -1;
    }

    // Update config file
    let path = config::config_path();
    let raw = std::fs::read_to_string(&path).unwrap_or_default();
    let mut root: serde_yaml::Value = if raw.trim().is_empty() {
        serde_yaml::Value::Mapping(serde_yaml::Mapping::new())
    } else {
        match serde_yaml::from_str(&raw) {
            Ok(v) => v,
            Err(e) => {
                log::error!("sp_core_set_prompt_templates_json: yaml parse error: {e}");
                return -1;
            }
        }
    };

    // Serialize templates to YAML value
    let yaml_templates = match serde_yaml::to_value(&templates) {
        Ok(v) => v,
        Err(e) => {
            log::error!("sp_core_set_prompt_templates_json: serialize error: {e}");
            return -1;
        }
    };

    if let Some(mapping) = root.as_mapping_mut() {
        mapping.insert(
            serde_yaml::Value::String("prompt_templates".into()),
            yaml_templates,
        );
    }

    let serialized = match serde_yaml::to_string(&root) {
        Ok(s) => s,
        Err(e) => {
            log::error!("sp_core_set_prompt_templates_json: serialize error: {e}");
            return -1;
        }
    };

    if let Err(e) = config::atomic_write_config(&serialized) {
        log::error!("sp_core_set_prompt_templates_json: write error: {e}");
        return -1;
    }

    // Reload config in core
    let mut global = CORE.lock().unwrap();
    if let Some(ref mut core) = *global {
        match config::load_config() {
            Ok(cfg) => core.config = cfg,
            Err(e) => log::error!("sp_core_set_prompt_templates_json: reload error: {e}"),
        }
    }

    0
}

/// Rewrite ASR text using a specific prompt template.
/// template_index is 0-based into the prompt_templates array.
/// The rewrite runs asynchronously; result delivered via on_rewrite_text_ready callback.
///
/// # Safety
/// `asr_text_ptr` must be a valid null-terminated C string.
#[no_mangle]
pub unsafe extern "C" fn sp_core_rewrite_with_template(
    template_index: i32,
    asr_text_ptr: *const c_char,
) -> i32 {
    let asr_text = match unsafe { cstr_to_str(asr_text_ptr) } {
        Some(s) => s.to_string(),
        None => return -1,
    };

    let global = CORE.lock().unwrap();
    let core = match global.as_ref() {
        Some(c) => c,
        None => return -1,
    };

    let idx = template_index as usize;
    let template = match core.config.prompt_templates.get(idx) {
        Some(t) => t.clone(),
        None => {
            log::error!("sp_core_rewrite_with_template: invalid index {idx}");
            return -1;
        }
    };

    let template_system_prompt = match template.resolve_system_prompt() {
        Some(p) => p,
        None => {
            log::error!(
                "sp_core_rewrite_with_template: no system prompt for template '{}'",
                template.name
            );
            return -1;
        }
    };

    // Gather LLM config and dependencies
    let llm_config = core.config.llm.clone();
    let dictionary = core.dictionary.clone();
    let user_prompt_template = core.user_prompt_template.clone();
    let llm_http_client = core.llm_http_client.clone();
    let session_token = core.current_session_token;
    let runtime_handle = core.runtime.handle().clone();

    drop(global); // Release lock before spawning

    runtime_handle.spawn(async move {
        log::info!(
            "rewrite: using template '{}' with {} chars of ASR text",
            template.name,
            asr_text.len()
        );

        let active_profile = match llm_config.active_profile_config() {
            Ok(p) => p,
            Err(e) => {
                log::error!("rewrite: failed to resolve active profile: {e}");
                invoke_session_warning(session_token, &format!("Rewrite failed: {e}"));
                invoke_rewrite_text_ready(session_token, &asr_text);
                return;
            }
        };

        let llm: Box<dyn LlmProvider> = match active_profile.provider.as_str() {
            #[cfg(feature = "mlx")]
            "mlx" => {
                let model_path = config::resolve_model_dir(&active_profile.mlx.model)
                    .to_string_lossy()
                    .to_string();
                Box::new(MlxLlmProvider::new(
                    model_path,
                    llm_config.temperature,
                    llm_config.top_p,
                    llm_config.max_output_tokens,
                    llm_config.timeout_ms,
                ))
            }
            _ => Box::new(OpenAiCompatibleProvider::new(
                llm_http_client,
                active_profile.base_url.clone(),
                active_profile.api_key.clone(),
                active_profile.model.clone(),
                llm_config.temperature,
                llm_config.top_p,
                llm_config.max_output_tokens,
                active_profile.max_token_parameter,
                active_profile.no_reasoning_control,
            )),
        };

        let candidates = prompt::filter_dictionary_candidates(
            &dictionary,
            &asr_text,
            llm_config.dictionary_max_candidates,
        );
        let user_prompt =
            prompt::render_user_prompt(&user_prompt_template, &asr_text, &candidates, &[]);

        let request = CorrectionRequest {
            asr_text: asr_text.clone(),
            dictionary_entries: candidates,
            system_prompt: template_system_prompt,
            user_prompt,
        };

        match llm.correct(&request).await {
            Ok(result) => {
                log::info!(
                    "rewrite: template '{}' produced {} chars",
                    template.name,
                    result.len()
                );
                invoke_rewrite_text_ready(session_token, &result);
            }
            Err(e) => {
                log::error!("rewrite: template '{}' failed: {e}", template.name);
                invoke_session_warning(session_token, &format!("Rewrite failed: {e}"));
                // Fall back to original ASR text
                invoke_rewrite_text_ready(session_token, &asr_text);
            }
        }
    });

    0
}

/// Query current feedback configuration.
#[no_mangle]
pub extern "C" fn sp_core_get_feedback_config() -> SPFeedbackConfig {
    let global = CORE.lock().unwrap();
    if let Some(ref core) = *global {
        SPFeedbackConfig {
            start_sound: core.config.feedback.start_sound,
            stop_sound: core.config.feedback.stop_sound,
            error_sound: core.config.feedback.error_sound,
        }
    } else {
        SPFeedbackConfig {
            start_sound: false,
            stop_sound: false,
            error_sound: false,
        }
    }
}

/// Query current hotkey configuration.
/// Returns key codes and modifier flags for the configured trigger key.
#[no_mangle]
pub extern "C" fn sp_core_get_hotkey_config() -> SPHotkeyConfig {
    let global = CORE.lock().unwrap();
    if let Some(ref core) = *global {
        let params = core.config.hotkey.resolve();
        let trigger_mode: u8 = if core.config.hotkey.trigger_mode == "toggle" {
            1
        } else {
            0
        };
        SPHotkeyConfig {
            trigger_key_code: params.key_code,
            trigger_alt_key_code: params.alt_key_code,
            trigger_modifier_flag: params.modifier_flag,
            trigger_match_kind: params.match_kind as u8,
            trigger_mode,
        }
    } else {
        SPHotkeyConfig {
            trigger_key_code: 63,
            trigger_alt_key_code: 179,
            trigger_modifier_flag: 0x00800000,
            trigger_match_kind: 0,
            trigger_mode: 0,
        }
    }
}

// ─── Session Task ───────────────────────────────────────────────────

#[allow(clippy::too_many_arguments)]
async fn run_session(
    session_arc: Arc<Mutex<Option<Session>>>,
    session_id: String,
    session_token: u64,
    mode: SPSessionMode,
    mut audio_rx: mpsc::Receiver<Vec<u8>>,
    asr_config: AsrConfig,
    asr_provider: String,
    mut asr: Box<dyn AsrProvider>,
    llm_config: config::LlmSection,
    llm_http_client: Client,
    llm_warmup_state: Arc<Mutex<LlmWarmupState>>,
    dictionary: Vec<String>,
    dictionary_max_candidates: usize,
    system_prompt: String,
    user_prompt_template: String,
    cancelled: Arc<AtomicBool>,
) {
    let final_wait_timeout_ms = asr_config.final_wait_timeout_ms;

    // Transition to recording immediately so the user can start speaking
    // while ASR connects.  Audio frames are buffered in the mpsc channel
    // (capacity 1024) and drained once the connection is established.
    let recording_state = match mode {
        SPSessionMode::Hold => SessionState::RecordingHold,
        SPSessionMode::Toggle => SessionState::RecordingToggle,
    };
    {
        let mut s = session_arc.lock().unwrap();
        if let Some(ref mut session) = *s {
            let _ = session.transition(recording_state);
        }
    }
    invoke_state_changed(session_token, &recording_state.to_string());
    invoke_session_ready(session_token);

    // --- Connect ASR ---
    log::info!("[{session_id}] Using ASR provider: {asr_provider}");
    if let Err(e) = asr.connect(&asr_config).await {
        log::error!("[{session_id}] ASR connection failed: {e}");
        invoke_session_error(session_token, &e.to_string());
        invoke_state_changed(session_token, "failed");
        cleanup_session(&session_arc);
        return;
    }

    // --- Stream audio to ASR + collect results ---
    let mut aggregator = TranscriptAggregator::new();
    let mut asr_done = false;
    let mut asr_error: Option<String> = None;

    // Stream audio frames until the channel is closed (session_end drops the sender)
    loop {
        tokio::select! {
            frame = audio_rx.recv() => {
                match frame {
                    Some(data) => {
                        if let Err(e) = asr.send_audio(&data).await {
                            log::error!("[{session_id}] ASR send error: {e}");
                            asr_error = Some(format!("ASR send error: {e}"));
                            break;
                        }
                    }
                    None => {
                        // Channel closed: session ended
                        log::info!("[{session_id}] audio stream ended, sending finish");
                        let _ = asr.finish_input().await;
                        break;
                    }
                }
            }
            event = asr.next_event() => {
                match event {
                    Ok(AsrEvent::Interim(text)) => {
                        if !text.is_empty() {
                            aggregator.update_interim(&text);
                            invoke_interim_text(session_token,&text);
                        }
                    }
                    Ok(AsrEvent::Definite(text)) => {
                        aggregator.update_definite(&text);
                        invoke_interim_text(session_token, aggregator.best_text());
                    }
                    Ok(AsrEvent::Final(text)) => {
                        aggregator.update_final(&text);
                        invoke_interim_text(session_token, aggregator.best_text());
                    }
                    Ok(AsrEvent::Closed) => {
                        asr_done = true;
                        break;
                    }
                    Ok(AsrEvent::Error(msg)) => {
                        log::error!("[{session_id}] ASR error event: {msg}");
                        asr_error = Some(msg);
                        break;
                    }
                    Ok(AsrEvent::Connected) => {}
                    Err(e) => {
                        log::error!("[{session_id}] ASR read error: {e}");
                        asr_error = Some(format!("ASR error: {e}"));
                        break;
                    }
                }
            }
        }
    }

    // --- Check if cancelled ---
    if cancelled.load(Ordering::SeqCst) {
        log::info!("[{session_id}] session cancelled by user");
        let _ = asr.close().await;
        invoke_state_changed(session_token, "cancelled");
        cleanup_session(&session_arc);
        invoke_state_changed(session_token, "idle");
        return;
    }

    // --- Finalize ASR ---
    {
        let mut s = session_arc.lock().unwrap();
        if let Some(ref mut session) = *s {
            let _ = session.transition(SessionState::FinalizingAsr);
        }
    }
    invoke_state_changed(session_token, "finalizing_asr");

    // Wait for final result if we haven't received one yet
    if !aggregator.has_final_result() && !asr_done {
        let wait_result = timeout(
            Duration::from_millis(final_wait_timeout_ms),
            wait_for_final(session_token, asr.as_mut(), &mut aggregator),
        )
        .await;

        match wait_result {
            Ok(Some(err_msg)) => {
                asr_error.get_or_insert(err_msg);
            }
            Ok(None) => {}
            Err(_) => {
                log::warn!("[{session_id}] ASR final result timed out");
            }
        }
    }

    let _ = asr.close().await;

    // If ASR reported an error, fail the session even if partial text was accumulated.
    // Continuing with truncated/unconfirmed text would paste garbage into the user's app.
    if let Some(error_msg) = asr_error {
        log::warn!("[{session_id}] ASR failed (discarding partial text): {error_msg}");
        invoke_session_error(session_token, &error_msg);
        invoke_state_changed(session_token, "failed");
        cleanup_session(&session_arc);
        return;
    }

    let asr_text = aggregator.best_text().to_string();
    if asr_text.is_empty() {
        // A silent recording is a valid no-op, not a user-visible failure.
        // Exit quietly so the app returns to idle without error sounds or alerts.
        log::info!(
            "[{session_id}] no ASR text available: treating silent recording as empty result"
        );
        cleanup_session(&session_arc);
        invoke_state_changed(session_token, "idle");
        return;
    }

    let interim_history = aggregator.interim_history(10).to_vec();
    log::info!(
        "[{session_id}] ASR result: {} chars, {} interim revisions",
        asr_text.len(),
        interim_history.len(),
    );

    // Store ASR text in session
    {
        let mut s = session_arc.lock().unwrap();
        if let Some(ref mut session) = *s {
            session.asr_text = Some(asr_text.clone());
        }
    }

    // Notify ObjC of the final ASR text so the overlay can display it
    // during the LLM correction phase.
    invoke_asr_final_text(session_token, &asr_text);

    // --- LLM Correction ---
    // Check cancellation before the (potentially slow) LLM call so that an
    // aborted old session exits quickly when a new session has started.
    if cancelled.load(Ordering::SeqCst) {
        log::info!("[{session_id}] session cancelled before LLM correction");
        invoke_state_changed(session_token, "cancelled");
        cleanup_session(&session_arc);
        invoke_state_changed(session_token, "idle");
        return;
    }

    let llm_enabled = llm_is_ready(&llm_config);

    let final_text = if llm_enabled {
        {
            let mut s = session_arc.lock().unwrap();
            if let Some(ref mut session) = *s {
                let _ = session.transition(SessionState::Correcting);
            }
        }
        invoke_state_changed(session_token, "correcting");

        let active_profile = llm_config
            .active_profile_config()
            .expect("llm_is_ready checked the active LLM profile");

        let llm: Box<dyn LlmProvider> = match active_profile.provider.as_str() {
            #[cfg(feature = "mlx")]
            "mlx" => {
                let model_path = config::resolve_model_dir(&active_profile.mlx.model)
                    .to_string_lossy()
                    .to_string();
                log::info!("[{session_id}] using MLX LLM provider: {model_path}");
                Box::new(MlxLlmProvider::new(
                    model_path,
                    llm_config.temperature,
                    llm_config.top_p,
                    llm_config.max_output_tokens,
                    llm_config.timeout_ms,
                ))
            }
            _ => Box::new(OpenAiCompatibleProvider::new(
                llm_http_client,
                active_profile.base_url,
                active_profile.api_key,
                active_profile.model,
                llm_config.temperature,
                llm_config.top_p,
                llm_config.max_output_tokens,
                active_profile.max_token_parameter,
                active_profile.no_reasoning_control,
            )),
        };

        // Filter dictionary candidates for prompt
        let candidates =
            prompt::filter_dictionary_candidates(&dictionary, &asr_text, dictionary_max_candidates);

        log::info!(
            "[{session_id}] LLM request — asr_text_len: {}",
            asr_text.len()
        );
        log::debug!("[{session_id}] LLM request — asr_text: \"{}\"", asr_text);
        // Skip interim history for local LLM — small models don't benefit from it
        // and it increases prompt length / inference time.
        let history = if active_profile.provider == "mlx" {
            &[][..]
        } else {
            &interim_history[..]
        };

        log::info!(
            "[{session_id}] LLM request — {} dictionary entries, {} interim revisions",
            candidates.len(),
            history.len()
        );

        let user_prompt =
            prompt::render_user_prompt(&user_prompt_template, &asr_text, &candidates, history);
        log::debug!("[{session_id}] LLM user prompt:\n{}", user_prompt);

        let request = CorrectionRequest {
            asr_text: asr_text.clone(),
            dictionary_entries: candidates,
            system_prompt,
            user_prompt,
        };

        match llm.correct(&request).await {
            Ok(corrected) => {
                mark_llm_connection_touched(&llm_warmup_state);
                log::info!("[{session_id}] LLM corrected: {} chars", corrected.len());
                corrected
            }
            Err(e) => {
                log::warn!("[{session_id}] LLM failed, falling back to ASR text: {e}");
                invoke_session_warning(session_token, &format!("LLM correction failed: {e}"));
                asr_text
            }
        }
    } else {
        if !llm_config.enabled {
            log::info!("[{session_id}] LLM disabled, using raw ASR text");
        } else {
            log::info!("[{session_id}] LLM not configured, using raw ASR text");
        }
        asr_text
    };

    // Check cancellation after LLM (which may have taken seconds) to avoid
    // pasting stale text from an aborted session into the new session's window.
    if cancelled.load(Ordering::SeqCst) {
        log::info!("[{session_id}] session cancelled after LLM correction");
        invoke_state_changed(session_token, "cancelled");
        cleanup_session(&session_arc);
        invoke_state_changed(session_token, "idle");
        return;
    }

    // Store corrected text
    {
        let mut s = session_arc.lock().unwrap();
        if let Some(ref mut session) = *s {
            session.corrected_text = Some(final_text.clone());
            let _ = session.transition(SessionState::PreparingPaste);
        }
    }
    invoke_state_changed(session_token, "preparing_paste");

    // --- Deliver result to Obj-C ---
    // The Obj-C side owns all state transitions from here (pasting → idle).
    // Rust must NOT emit completed/idle state changes — they would be
    // dispatched to the main queue and overwrite the pasting state that
    // Obj-C sets in the final-text callback.
    invoke_final_text_ready(session_token, &final_text);

    {
        let mut s = session_arc.lock().unwrap();
        if let Some(ref mut session) = *s {
            let _ = session.transition(SessionState::Completed);
        }
    }
    log::info!("[{session_id}] session completed (text delivered)");
    cleanup_session(&session_arc);
}

async fn wait_for_final(
    session_token: u64,
    asr: &mut dyn AsrProvider,
    aggregator: &mut TranscriptAggregator,
) -> Option<String> {
    loop {
        match asr.next_event().await {
            Ok(AsrEvent::Final(text)) => {
                aggregator.update_final(&text);
                invoke_interim_text(session_token, aggregator.best_text());
                return None;
            }
            Ok(AsrEvent::Interim(text)) => {
                if !text.is_empty() {
                    aggregator.update_interim(&text);
                    invoke_interim_text(session_token, &text);
                }
            }
            Ok(AsrEvent::Definite(text)) => {
                aggregator.update_definite(&text);
                invoke_interim_text(session_token, aggregator.best_text());
            }
            Ok(AsrEvent::Closed) => return None,
            Ok(AsrEvent::Error(msg)) => {
                log::error!("ASR error in wait_for_final: {msg}");
                return Some(msg);
            }
            Ok(_) => {}
            Err(e) => {
                log::error!("ASR read error in wait_for_final: {e}");
                return Some(format!("ASR error: {e}"));
            }
        }
    }
}

fn cleanup_session(session_arc: &Arc<Mutex<Option<Session>>>) {
    let mut s = session_arc.lock().unwrap();
    *s = None;
}

fn llm_is_ready(cfg: &config::LlmSection) -> bool {
    if !cfg.enabled {
        return false;
    }
    cfg.active_profile_config()
        .map(|profile| profile.is_ready())
        .unwrap_or(false)
}

fn start_llm_warmup_if_needed(
    runtime: &Runtime,
    session_id: &str,
    llm_config: &config::LlmSection,
    llm_http_client: Client,
    llm_warmup_state: Arc<Mutex<LlmWarmupState>>,
) {
    if !llm_is_ready(llm_config) {
        return;
    }
    let active_profile = match llm_config.active_profile_config() {
        Ok(profile) => profile,
        Err(err) => {
            log::debug!("[{session_id}] skipping LLM warmup; active profile failed: {err}");
            return;
        }
    };

    // Local MLX provider doesn't need HTTP warmup
    if active_profile.provider == "mlx" {
        return;
    }

    {
        let mut state = llm_warmup_state.lock().unwrap();
        if state.in_flight {
            log::debug!("[{session_id}] skipping LLM warmup; already in flight");
            return;
        }
        if state
            .last_touched
            .is_some_and(|instant| instant.elapsed() < LLM_WARMUP_TTL)
        {
            log::debug!("[{session_id}] skipping LLM warmup; connection recently used");
            return;
        }
        state.in_flight = true;
    }

    let warmup_session_id = session_id.to_string();
    let warmup_cfg = llm_config.clone();
    runtime.spawn(async move {
        log::info!("[{warmup_session_id}] starting LLM warmup");
        let warmup_profile = match warmup_cfg.active_profile_config() {
            Ok(profile) => profile,
            Err(err) => {
                log::debug!("[{warmup_session_id}] LLM warmup profile failed: {err}");
                let mut state = llm_warmup_state.lock().unwrap();
                state.in_flight = false;
                return;
            }
        };
        let llm = OpenAiCompatibleProvider::new(
            llm_http_client,
            warmup_profile.base_url,
            warmup_profile.api_key,
            warmup_profile.model,
            warmup_cfg.temperature,
            warmup_cfg.top_p,
            warmup_cfg.max_output_tokens,
            warmup_profile.max_token_parameter,
            warmup_profile.no_reasoning_control,
        );

        let warmup_ok = match llm.warmup().await {
            Ok(()) => {
                log::info!("[{warmup_session_id}] LLM warmup completed");
                true
            }
            Err(err) => {
                log::debug!("[{warmup_session_id}] LLM warmup failed: {err}");
                false
            }
        };

        let mut state = llm_warmup_state.lock().unwrap();
        state.in_flight = false;
        if warmup_ok {
            state.last_touched = Some(Instant::now());
        }
    });
}

fn mark_llm_connection_touched(llm_warmup_state: &Arc<Mutex<LlmWarmupState>>) {
    let mut state = llm_warmup_state.lock().unwrap();
    state.last_touched = Some(Instant::now());
}

// ─── Model Manager FFI ─────────────────────────────────────────────

use std::collections::HashMap;
use std::ffi::{c_void, CString};
use tokio_util::sync::CancellationToken;

/// Progress callback for model downloads.
pub type ModelProgressCallback = extern "C" fn(
    ctx: *mut c_void,
    file_index: u32,
    file_count: u32,
    bytes_downloaded: u64,
    bytes_total: u64,
    filename: *const c_char,
);

/// Status callback for model downloads.
/// status: 0=started, 1=completed, 2=error, 3=cancelled
pub type ModelStatusCallback = extern "C" fn(ctx: *mut c_void, status: i32, message: *const c_char);

struct ModelCallbackCtx {
    ctx: *mut c_void,
    progress_cb: ModelProgressCallback,
    status_cb: ModelStatusCallback,
}
unsafe impl Send for ModelCallbackCtx {}
unsafe impl Sync for ModelCallbackCtx {}

static MODEL_DOWNLOADS: std::sync::Mutex<Option<HashMap<String, CancellationToken>>> =
    std::sync::Mutex::new(None);

/// Return JSON array of supported local provider names (e.g. ["mlx","sherpa-onnx"]).
/// Caller must free the returned string with sp_core_free_string().
#[no_mangle]
pub extern "C" fn sp_core_supported_local_providers() -> *mut c_char {
    let providers = model_manager::supported_providers();
    let json_str = serde_json::to_string(providers).unwrap_or_else(|_| "[]".to_string());
    CString::new(json_str).unwrap_or_default().into_raw()
}

/// Return JSON array of supported LLM provider names (e.g. ["openai","mlx"]).
/// Caller must free the returned string with sp_core_free_string().
#[no_mangle]
pub extern "C" fn sp_core_supported_llm_providers() -> *mut c_char {
    let providers = llm::supported_providers();
    let json_str = serde_json::to_string(providers).unwrap_or_else(|_| "[]".to_string());
    CString::new(json_str).unwrap_or_default().into_raw()
}

/// Scan all models and return JSON array.
/// Caller must free the returned string with sp_core_free_string().
#[no_mangle]
pub extern "C" fn sp_core_scan_models_json() -> *mut c_char {
    let models = model_manager::scan_supported_models();
    let json: Vec<serde_json::Value> = models
        .iter()
        .map(|m| {
            let rel_path = m
                .path
                .strip_prefix(model_manager::models_dir())
                .unwrap_or(&m.path);
            serde_json::json!({
                "path": rel_path.to_string_lossy(),
                "provider": m.manifest.provider,
                "mode": m.manifest.mode.as_deref().unwrap_or(""),
                "description": m.manifest.description,
                "repo": m.manifest.repo,
                "total_size": m.manifest.files.iter().map(|f| f.size).sum::<u64>(),
                "status": model_manager::model_status(&m.path, model_manager::VerifyMode::CacheOnly) as i32,
            })
        })
        .collect();
    let json_str = serde_json::to_string(&json).unwrap_or_else(|_| "[]".to_string());
    CString::new(json_str).unwrap_or_default().into_raw()
}

/// Get a config value by dot-separated key path (e.g. "asr.doubao.app_key").
/// Returns a heap-allocated C string that must be freed with sp_core_free_string().
/// Returns an empty string if the key is not found.
///
/// # Safety
/// `key_path` must be a valid null-terminated C string.
#[no_mangle]
pub unsafe extern "C" fn sp_config_get(key_path: *const c_char) -> *mut c_char {
    let key = match unsafe { cstr_to_str(key_path) } {
        Some(s) => s,
        None => return CString::new("").unwrap().into_raw(),
    };
    match config::config_get(key) {
        Ok(value) => CString::new(value).unwrap_or_default().into_raw(),
        Err(e) => {
            log::error!("sp_config_get({key}): {e}");
            CString::new("").unwrap().into_raw()
        }
    }
}

/// Set a config value by dot-separated key path. Reads, modifies, and writes config.yaml.
/// Returns 0 on success, -1 on error.
///
/// # Safety
/// `key_path` and `value` must be valid null-terminated C strings.
#[no_mangle]
pub unsafe extern "C" fn sp_config_set(key_path: *const c_char, value: *const c_char) -> i32 {
    let key = match unsafe { cstr_to_str(key_path) } {
        Some(s) => s,
        None => return -1,
    };
    let val = match unsafe { cstr_to_str(value) } {
        Some(s) => s,
        None => return -1,
    };
    match config::config_set(key, val) {
        Ok(()) => 0,
        Err(e) => {
            log::error!("sp_config_set({key}): {e}");
            -1
        }
    }
}

/// Returns the resolved trigger hotkey name after normalization and dedup.
/// The caller must free the returned string with sp_core_free_string().
#[no_mangle]
pub extern "C" fn sp_config_resolved_trigger_key() -> *mut c_char {
    let key = match config::load_config() {
        Ok(cfg) => cfg.hotkey.normalized_trigger_key(),
        Err(_) => "fn".into(),
    };
    CString::new(key).unwrap_or_default().into_raw()
}

/// Test LLM connection using the exact same `correct()` code path as runtime.
///
/// Accepts wizard-editable fields as parameters (user may not have saved yet);
/// reads everything else (temperature, top_p, timeout_ms, prompts, dictionary)
/// from config/disk, exactly as the runtime does.
///
/// Returns a heap-allocated JSON string:
///   `{"success": true,  "elapsed_ms": 2345, "message": "..."}`
///   `{"success": false, "elapsed_ms": 8000, "message": "..."}`
///
/// # Safety
/// All pointer parameters must be valid null-terminated C strings.
/// Caller must free the returned pointer with `sp_core_free_string()`.
#[no_mangle]
pub unsafe extern "C" fn sp_llm_test(
    base_url: *const c_char,
    api_key: *const c_char,
    model: *const c_char,
    max_token_param: *const c_char,
) -> *mut c_char {
    let base_url = unsafe { cstr_to_str(base_url) }
        .unwrap_or_default()
        .to_string();
    let api_key = unsafe { cstr_to_str(api_key) }
        .unwrap_or_default()
        .to_string();
    let model = unsafe { cstr_to_str(model) }
        .unwrap_or_default()
        .to_string();
    let max_token_param_str = unsafe { cstr_to_str(max_token_param) }.unwrap_or_default();
    let max_token_parameter = if max_token_param_str == "max_tokens" {
        config::LlmMaxTokenParameter::MaxTokens
    } else {
        config::LlmMaxTokenParameter::MaxCompletionTokens
    };

    // Load config from disk for remaining parameters (same as runtime hot-reload)
    let cfg = config::load_config().unwrap_or_default();

    let profile = config::LlmProfileRuntimeConfig {
        id: "test".into(),
        name: "Test".into(),
        provider: "openai".into(),
        base_url,
        api_key,
        model,
        max_token_parameter,
        no_reasoning_control: config::LlmNoReasoningControl::ReasoningEffort,
        mlx: Default::default(),
    };

    // Load prompts and dictionary from disk (same paths as runtime)
    let system_prompt = prompt::load_system_prompt(&config::resolve_system_prompt_path(&cfg));
    let user_prompt_template =
        prompt::load_user_prompt_template(&config::resolve_user_prompt_path(&cfg));

    let dict_path = config::resolve_dictionary_path(&cfg);
    let dictionary = dictionary::load_dictionary(&dict_path).unwrap_or_default();
    let candidates =
        prompt::filter_dictionary_candidates(&dictionary, "", cfg.llm.dictionary_max_candidates);

    // Render user prompt from template with test content
    let test_asr = "so umm i installed this program called koe on my computer and like, \
                     i wanna know, you know, how much CPU and memory its using basically";
    let user_prompt = prompt::render_user_prompt(&user_prompt_template, test_asr, &candidates, &[]);

    // Build HTTP client with the configured timeout
    let client = match build_http_client(cfg.llm.timeout_ms) {
        Ok(c) => c,
        Err(e) => {
            let json = serde_json::json!({
                "success": false,
                "elapsed_ms": 0,
                "message": format!("Failed to create HTTP client: {e}"),
            });
            return CString::new(json.to_string())
                .unwrap_or_default()
                .into_raw();
        }
    };

    // Run the test on a temporary tokio runtime (blocking)
    let rt = match Runtime::new() {
        Ok(rt) => rt,
        Err(e) => {
            let json = serde_json::json!({
                "success": false,
                "elapsed_ms": 0,
                "message": format!("Failed to create async runtime: {e}"),
            });
            return CString::new(json.to_string())
                .unwrap_or_default()
                .into_raw();
        }
    };

    let (result, elapsed) = rt.block_on(llm::openai_compatible::test_correction(
        client,
        &profile,
        cfg.llm.temperature,
        cfg.llm.top_p,
        cfg.llm.max_output_tokens,
        &system_prompt,
        &user_prompt,
    ));
    let elapsed_ms = elapsed.as_millis() as u64;

    let json = match result {
        Ok(_corrected) => serde_json::json!({
            "success": true,
            "elapsed_ms": elapsed_ms,
            "message": "Connection successful!",
        }),
        Err(e) => serde_json::json!({
            "success": false,
            "elapsed_ms": elapsed_ms,
            "message": format!("{e}"),
        }),
    };

    CString::new(json.to_string())
        .unwrap_or_default()
        .into_raw()
}

/// Return the active LLM profile id and saved profile map as JSON.
#[no_mangle]
pub extern "C" fn sp_llm_profiles_json() -> *mut c_char {
    let json = match config::llm_profiles_payload() {
        Ok(payload) => serde_json::to_string(&payload).unwrap_or_else(|_| "{}".into()),
        Err(e) => serde_json::json!({
            "active_profile": "openai",
            "profiles": {},
            "error": e.to_string(),
        })
        .to_string(),
    };
    CString::new(json).unwrap_or_default().into_raw()
}

/// Save the active LLM profile id and profile map from JSON.
///
/// # Safety
/// `profiles_json` must be a valid null-terminated C string.
#[no_mangle]
pub unsafe extern "C" fn sp_llm_save_profiles_json(profiles_json: *const c_char) -> i32 {
    let Some(json) = (unsafe { cstr_to_str(profiles_json) }) else {
        return -1;
    };
    let payload: config::LlmProfilesPayload = match serde_json::from_str(json) {
        Ok(payload) => payload,
        Err(e) => {
            log::error!("sp_llm_save_profiles_json: parse: {e}");
            return -1;
        }
    };
    match config::save_llm_profiles_payload(&payload) {
        Ok(()) => 0,
        Err(e) => {
            log::error!("sp_llm_save_profiles_json: save: {e}");
            -1
        }
    }
}

/// Test a single LLM profile using the runtime correction path and global prompt settings.
///
/// # Safety
/// `profile_json` must be a valid null-terminated C string.
#[no_mangle]
pub unsafe extern "C" fn sp_llm_test_profile_json(profile_json: *const c_char) -> *mut c_char {
    let Some(json) = (unsafe { cstr_to_str(profile_json) }) else {
        return CString::new(
            serde_json::json!({
                "success": false,
                "elapsed_ms": 0,
                "message": "Missing profile JSON",
            })
            .to_string(),
        )
        .unwrap_or_default()
        .into_raw();
    };
    let profile: config::LlmProfileRuntimeConfig = match serde_json::from_str(json) {
        Ok(profile) => profile,
        Err(e) => {
            return CString::new(
                serde_json::json!({
                    "success": false,
                    "elapsed_ms": 0,
                    "message": format!("Invalid profile JSON: {e}"),
                })
                .to_string(),
            )
            .unwrap_or_default()
            .into_raw();
        }
    };

    let cfg = config::load_config().unwrap_or_default();
    let system_prompt = prompt::load_system_prompt(&config::resolve_system_prompt_path(&cfg));
    let user_prompt_template =
        prompt::load_user_prompt_template(&config::resolve_user_prompt_path(&cfg));
    let dict_path = config::resolve_dictionary_path(&cfg);
    let dictionary = dictionary::load_dictionary(&dict_path).unwrap_or_default();
    let candidates =
        prompt::filter_dictionary_candidates(&dictionary, "", cfg.llm.dictionary_max_candidates);
    let test_asr = "so umm i installed this program called koe on my computer and like, \
                     i wanna know, you know, how much CPU and memory its using basically";
    let user_prompt = prompt::render_user_prompt(&user_prompt_template, test_asr, &candidates, &[]);

    let rt = match Runtime::new() {
        Ok(rt) => rt,
        Err(e) => {
            return CString::new(
                serde_json::json!({
                    "success": false,
                    "elapsed_ms": 0,
                    "message": format!("Failed to create async runtime: {e}"),
                })
                .to_string(),
            )
            .unwrap_or_default()
            .into_raw();
        }
    };

    let request = CorrectionRequest {
        asr_text: String::new(),
        dictionary_entries: candidates,
        system_prompt,
        user_prompt,
    };
    let start = Instant::now();
    let result = match profile.provider.as_str() {
        #[cfg(feature = "mlx")]
        "mlx" => {
            let model_path = config::resolve_model_dir(&profile.mlx.model)
                .to_string_lossy()
                .to_string();
            let llm = MlxLlmProvider::new(
                model_path,
                cfg.llm.temperature,
                cfg.llm.top_p,
                cfg.llm.max_output_tokens,
                cfg.llm.timeout_ms,
            );
            rt.block_on(llm.correct(&request))
        }
        #[cfg(not(feature = "mlx"))]
        "mlx" => Err(errors::KoeError::LlmFailed(
            "MLX LLM support is not enabled in this build".into(),
        )),
        _ => {
            let client = match build_http_client(cfg.llm.timeout_ms) {
                Ok(c) => c,
                Err(e) => {
                    return CString::new(
                        serde_json::json!({
                            "success": false,
                            "elapsed_ms": 0,
                            "message": format!("Failed to create HTTP client: {e}"),
                        })
                        .to_string(),
                    )
                    .unwrap_or_default()
                    .into_raw();
                }
            };
            let llm = OpenAiCompatibleProvider::new(
                client,
                profile.base_url,
                profile.api_key,
                profile.model,
                cfg.llm.temperature,
                cfg.llm.top_p,
                cfg.llm.max_output_tokens,
                profile.max_token_parameter,
                profile.no_reasoning_control,
            );
            rt.block_on(llm.correct(&request))
        }
    };
    let elapsed = start.elapsed();
    let elapsed_ms = elapsed.as_millis() as u64;
    let json = match result {
        Ok(_) => serde_json::json!({
            "success": true,
            "elapsed_ms": elapsed_ms,
            "message": "Connection successful!",
        }),
        Err(e) => serde_json::json!({
            "success": false,
            "elapsed_ms": elapsed_ms,
            "message": format!("{e}"),
        }),
    };

    CString::new(json.to_string())
        .unwrap_or_default()
        .into_raw()
}

/// Free a string returned by sp_core_scan_models_json().
///
/// # Safety
/// `s` must be a pointer previously returned by this library, or null.
#[no_mangle]
pub unsafe extern "C" fn sp_core_free_string(s: *mut c_char) {
    if !s.is_null() {
        unsafe {
            drop(CString::from_raw(s));
        }
    }
}

/// Model status check with configurable verification mode.
/// mode: 0=Normal (cached sha256), 1=CacheOnly (no compute), 2=ForceVerify (always compute)
/// Returns: 0=not installed, 1=incomplete, 2=installed
///
/// # Safety
/// `model_path` must be a valid null-terminated C string.
#[no_mangle]
pub unsafe extern "C" fn sp_model_status(model_path: *const c_char, mode: i32) -> i32 {
    let path = match unsafe { cstr_to_str(model_path) } {
        Some(s) => s,
        None => return 0,
    };
    let verify_mode = match mode {
        1 => model_manager::VerifyMode::CacheOnly,
        2 => model_manager::VerifyMode::ForceVerify,
        _ => model_manager::VerifyMode::Normal,
    };
    let model_dir = config::resolve_model_dir(path);
    model_manager::model_status(&model_dir, verify_mode) as i32
}

/// Start downloading a model. Returns 0=started, -1=already downloading, -2=error.
///
/// # Safety
/// `model_path` must be a valid null-terminated C string. `ctx` is passed through to callbacks.
#[no_mangle]
pub unsafe extern "C" fn sp_core_download_model(
    model_path: *const c_char,
    progress_cb: ModelProgressCallback,
    status_cb: ModelStatusCallback,
    ctx: *mut c_void,
) -> i32 {
    let path = match unsafe { cstr_to_str(model_path) } {
        Some(s) => s.to_string(),
        None => return -2,
    };
    let model_dir = config::resolve_model_dir(&path);

    // Register download with cancellation token
    let cancel_token = {
        let mut guard = MODEL_DOWNLOADS.lock().unwrap();
        let map = guard.get_or_insert_with(HashMap::new);
        if map.contains_key(&path) {
            return -1;
        }
        let token = CancellationToken::new();
        let clone = token.clone();
        map.insert(path.clone(), token);
        clone
    };

    let cb = Arc::new(ModelCallbackCtx {
        ctx,
        progress_cb,
        status_cb,
    });

    let global = CORE.lock().unwrap();
    let runtime = match global.as_ref() {
        Some(core) => &core.runtime,
        None => return -2,
    };

    let path_clone = path.clone();
    let cb_status = cb.clone();

    runtime.spawn(async move {
        invoke_model_status(&cb_status, 0, "started");

        let cb_progress = cb_status.clone();
        let result = model_manager::download_model(
            &model_dir,
            move |progress| {
                if let Ok(cstr) = CString::new(progress.filename.as_str()) {
                    (cb_progress.progress_cb)(
                        cb_progress.ctx,
                        progress.file_index as u32,
                        progress.file_count as u32,
                        progress.bytes_downloaded,
                        progress.bytes_total,
                        cstr.as_ptr(),
                    );
                }
            },
            cancel_token,
        )
        .await
        .map(|_| ())
        .map_err(|e| e.to_string());

        // Unregister download
        {
            let mut guard = MODEL_DOWNLOADS.lock().unwrap();
            if let Some(map) = guard.as_mut() {
                map.remove(&path_clone);
            }
        }

        match result {
            Ok(()) => invoke_model_status(&cb_status, 1, "completed"),
            Err(e) if e.contains("cancelled") => invoke_model_status(&cb_status, 3, "cancelled"),
            Err(e) => invoke_model_status(&cb_status, 2, &e),
        }
    });

    0
}

/// Cancel an active download. Returns 1 if cancelled, 0 if not found.
///
/// # Safety
/// `model_path` must be a valid null-terminated C string.
#[no_mangle]
pub unsafe extern "C" fn sp_core_cancel_download(model_path: *const c_char) -> i32 {
    let path = match unsafe { cstr_to_str(model_path) } {
        Some(s) => s,
        None => return 0,
    };
    let guard = MODEL_DOWNLOADS.lock().unwrap();
    if let Some(map) = guard.as_ref() {
        if let Some(token) = map.get(path) {
            token.cancel();
            return 1;
        }
    }
    0
}

/// Remove downloaded model files (keep manifest). Returns number of files removed, -1 on error.
///
/// # Safety
/// `model_path` must be a valid null-terminated C string.
#[no_mangle]
pub unsafe extern "C" fn sp_core_remove_model_files(model_path: *const c_char) -> i32 {
    let path = match unsafe { cstr_to_str(model_path) } {
        Some(s) => s,
        None => return -1,
    };
    let model_dir = config::resolve_model_dir(path);
    match model_manager::remove_model_files(&model_dir) {
        Ok(n) => n as i32,
        Err(_) => -1,
    }
}

fn invoke_model_status(cb: &ModelCallbackCtx, status: i32, message: &str) {
    if let Ok(cstr) = CString::new(message) {
        (cb.status_cb)(cb.ctx, status, cstr.as_ptr());
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use koe_asr::{AsrError, AsrEvent, AsrProvider, TranscriptAggregator};
    use std::collections::VecDeque;

    /// Mock ASR provider that yields a pre-configured sequence of events.
    struct MockAsrProvider {
        events: VecDeque<koe_asr::error::Result<AsrEvent>>,
    }

    impl MockAsrProvider {
        fn new(events: Vec<koe_asr::error::Result<AsrEvent>>) -> Self {
            Self {
                events: events.into(),
            }
        }
    }

    #[async_trait::async_trait]
    impl AsrProvider for MockAsrProvider {
        async fn connect(&mut self, _config: &koe_asr::AsrConfig) -> koe_asr::error::Result<()> {
            Ok(())
        }
        async fn send_audio(&mut self, _frame: &[u8]) -> koe_asr::error::Result<()> {
            Ok(())
        }
        async fn finish_input(&mut self) -> koe_asr::error::Result<()> {
            Ok(())
        }
        async fn next_event(&mut self) -> koe_asr::error::Result<AsrEvent> {
            self.events.pop_front().unwrap_or(Ok(AsrEvent::Closed))
        }
        async fn close(&mut self) -> koe_asr::error::Result<()> {
            Ok(())
        }
    }

    // ── wait_for_final tests ────────────────────────────────────────────

    #[tokio::test]
    async fn wait_for_final_returns_none_on_final_event() {
        let mut mock = MockAsrProvider::new(vec![
            Ok(AsrEvent::Interim("partial".into())),
            Ok(AsrEvent::Final("complete".into())),
        ]);
        let mut agg = TranscriptAggregator::new();
        let result = wait_for_final(0, &mut mock, &mut agg).await;
        assert!(result.is_none());
        assert_eq!(agg.best_text(), "complete");
    }

    #[tokio::test]
    async fn wait_for_final_returns_none_on_closed() {
        let mut mock = MockAsrProvider::new(vec![Ok(AsrEvent::Closed)]);
        let mut agg = TranscriptAggregator::new();
        let result = wait_for_final(0, &mut mock, &mut agg).await;
        assert!(result.is_none());
    }

    #[tokio::test]
    async fn wait_for_final_returns_error_on_error_event() {
        let mut mock = MockAsrProvider::new(vec![
            Ok(AsrEvent::Interim("partial".into())),
            Ok(AsrEvent::Error("provider error".into())),
        ]);
        let mut agg = TranscriptAggregator::new();
        let result = wait_for_final(0, &mut mock, &mut agg).await;
        assert_eq!(result, Some("provider error".into()));
    }

    #[tokio::test]
    async fn wait_for_final_returns_error_on_read_error() {
        let mut mock =
            MockAsrProvider::new(vec![Err(AsrError::Connection("connection lost".into()))]);
        let mut agg = TranscriptAggregator::new();
        let result = wait_for_final(0, &mut mock, &mut agg).await;
        assert!(result.is_some());
        assert!(result.unwrap().contains("connection"));
    }

    // ── Main loop error-with-partial-text tests ─────────────────────────

    /// Simulates the post-ASR decision: should the session fail?
    /// Mirrors the logic from run_session after asr.close().
    fn should_fail_session(asr_error: &Option<String>, _asr_text: &str) -> bool {
        // Only real ASR errors should fail the session.
        // An empty transcript is treated as a quiet no-op.
        asr_error.is_some()
    }

    #[test]
    fn error_with_no_text_fails_session() {
        let asr_error = Some("ASR error: connection lost".into());
        assert!(should_fail_session(&asr_error, ""));
    }

    #[test]
    fn error_with_partial_text_fails_session() {
        // ASR error should fail the session even with accumulated partial text
        let asr_error = Some("ASR error: connection lost".into());
        assert!(should_fail_session(&asr_error, "hello wor"));
    }

    #[test]
    fn no_error_with_text_proceeds() {
        assert!(!should_fail_session(&None, "hello world"));
    }

    #[test]
    fn no_error_no_text_does_not_fail() {
        assert!(!should_fail_session(&None, ""));
    }

    #[test]
    fn validate_prompt_templates_rejects_blank_prompt() {
        let templates = vec![config::PromptTemplate {
            name: "Empty".into(),
            enabled: true,
            shortcut: 1,
            system_prompt: Some("   ".into()),
            system_prompt_path: None,
        }];

        let error = validate_prompt_templates(&templates).unwrap_err();
        assert!(error.contains("non-empty prompt"));
    }
}
