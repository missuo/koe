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
    cstr_to_str, invoke_final_text_ready, invoke_interim_text, invoke_session_error,
    invoke_session_ready, invoke_session_warning, invoke_state_changed, SPCallbacks,
    SPFeedbackConfig, SPHotkeyConfig, SPSessionContext, SPSessionMode,
};
use crate::llm::openai_compatible::{
    build_http_client, OpenAiCompatibleProvider, LLM_HTTP_POOL_IDLE_TIMEOUT,
};
use crate::llm::{CorrectionRequest, LlmProvider};
use crate::session::{Session, SessionState};
use koe_asr::{
    AsrConfig, AsrEvent, AsrProvider, DoubaoWsProvider, QwenAsrProvider, TranscriptAggregator,
};
#[cfg(feature = "mlx")]
use koe_asr::{MlxConfig, MlxProvider};
#[cfg(feature = "sherpa-onnx")]
use koe_asr::{SherpaOnnxConfig, SherpaOnnxProvider};
use reqwest::Client;

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
}

static CORE: Mutex<Option<Core>> = Mutex::new(None);

fn llm_http_client_needs_reload(current: &Config, next: &Config) -> bool {
    current.llm.timeout_ms != next.llm.timeout_ms
}

// ─── FFI Entry Points ───────────────────────────────────────────────

/// Initialize the core. Must be called once before any other function.
/// `config_path` is reserved for future use (currently loads from ~/.koe/config.yaml).
#[no_mangle]
pub extern "C" fn sp_core_create(config_path: *const c_char) -> i32 {
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
#[no_mangle]
pub extern "C" fn sp_core_push_audio(frame: *const u8, len: u32, _timestamp: u64) -> i32 {
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
/// Returns key codes and modifier flags for the configured trigger/cancel keys.
#[no_mangle]
pub extern "C" fn sp_core_get_hotkey_config() -> SPHotkeyConfig {
    let global = CORE.lock().unwrap();
    if let Some(ref core) = *global {
        let params = core.config.hotkey.resolve();
        SPHotkeyConfig {
            trigger_key_code: params.trigger.key_code,
            trigger_alt_key_code: params.trigger.alt_key_code,
            trigger_modifier_flag: params.trigger.modifier_flag,
            cancel_key_code: params.cancel.key_code,
            cancel_alt_key_code: params.cancel.alt_key_code,
            cancel_modifier_flag: params.cancel.modifier_flag,
        }
    } else {
        SPHotkeyConfig {
            trigger_key_code: 63,
            trigger_alt_key_code: 179,
            trigger_modifier_flag: 0x00800000,
            cancel_key_code: 58,
            cancel_alt_key_code: 0,
            cancel_modifier_flag: 0x00000020,
        }
    }
}

// ─── Session Task ───────────────────────────────────────────────────

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
    invoke_state_changed(session_token,&recording_state.to_string());
    invoke_session_ready(session_token);

    // --- Connect ASR ---
    log::info!("[{session_id}] Using ASR provider: {asr_provider}");
    if let Err(e) = asr.connect(&asr_config).await {
        log::error!("[{session_id}] ASR connection failed: {e}");
        invoke_session_error(session_token,&e.to_string());
        invoke_state_changed(session_token,"failed");
        cleanup_session(&session_arc);
        return;
    }

    // --- Stream audio to ASR + collect results ---
    let mut aggregator = TranscriptAggregator::new();
    let mut asr_done = false;

    // Stream audio frames until the channel is closed (session_end drops the sender)
    loop {
        tokio::select! {
            frame = audio_rx.recv() => {
                match frame {
                    Some(data) => {
                        if let Err(e) = asr.send_audio(&data).await {
                            log::error!("[{session_id}] ASR send error: {e}");
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
                        invoke_interim_text(session_token,&aggregator.best_text());
                    }
                    Ok(AsrEvent::Final(text)) => {
                        aggregator.update_final(&text);
                        invoke_interim_text(session_token,&text);
                    }
                    Ok(AsrEvent::Closed) => {
                        asr_done = true;
                        break;
                    }
                    Ok(AsrEvent::Error(msg)) => {
                        log::error!("[{session_id}] ASR error event: {msg}");
                    }
                    Ok(AsrEvent::Connected) => {}
                    Err(e) => {
                        log::error!("[{session_id}] ASR read error: {e}");
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
        invoke_state_changed(session_token,"cancelled");
        cleanup_session(&session_arc);
        invoke_state_changed(session_token,"idle");
        return;
    }

    // --- Finalize ASR ---
    {
        let mut s = session_arc.lock().unwrap();
        if let Some(ref mut session) = *s {
            let _ = session.transition(SessionState::FinalizingAsr);
        }
    }
    invoke_state_changed(session_token,"finalizing_asr");

    // Wait for final result if we haven't received one yet
    if !aggregator.has_final_result() && !asr_done {
        let wait_result = timeout(
            Duration::from_millis(final_wait_timeout_ms),
            wait_for_final(session_token, asr.as_mut(), &mut aggregator),
        )
        .await;

        if wait_result.is_err() {
            log::warn!("[{session_id}] ASR final result timed out");
        }
    }

    let _ = asr.close().await;

    let asr_text = aggregator.best_text().to_string();
    if asr_text.is_empty() {
        log::warn!("[{session_id}] no ASR text available");
        invoke_session_error(session_token,"no speech recognized");
        invoke_state_changed(session_token,"failed");
        cleanup_session(&session_arc);
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

    // --- LLM Correction ---
    // Check cancellation before the (potentially slow) LLM call so that an
    // aborted old session exits quickly when a new session has started.
    if cancelled.load(Ordering::SeqCst) {
        log::info!("[{session_id}] session cancelled before LLM correction");
        invoke_state_changed(session_token,"cancelled");
        cleanup_session(&session_arc);
        invoke_state_changed(session_token,"idle");
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
        invoke_state_changed(session_token,"correcting");

        let llm = OpenAiCompatibleProvider::new(
            llm_http_client,
            llm_config.base_url,
            llm_config.api_key,
            llm_config.model,
            llm_config.temperature,
            llm_config.top_p,
            llm_config.max_output_tokens,
            llm_config.max_token_parameter,
        );

        // Filter dictionary candidates for prompt
        let candidates =
            prompt::filter_dictionary_candidates(&dictionary, &asr_text, dictionary_max_candidates);

        log::info!("[{session_id}] LLM request — asr_text: \"{}\"", asr_text);
        log::info!(
            "[{session_id}] LLM request — {} dictionary entries, {} interim revisions",
            candidates.len(),
            interim_history.len()
        );

        let user_prompt = prompt::render_user_prompt(
            &user_prompt_template,
            &asr_text,
            &candidates,
            &interim_history,
        );
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
                invoke_session_warning(session_token,&format!("LLM correction failed: {e}"));
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
        invoke_state_changed(session_token,"cancelled");
        cleanup_session(&session_arc);
        invoke_state_changed(session_token,"idle");
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
    invoke_state_changed(session_token,"preparing_paste");

    // --- Deliver result to Obj-C ---
    invoke_final_text_ready(session_token,&final_text);

    // Session complete
    {
        let mut s = session_arc.lock().unwrap();
        if let Some(ref mut session) = *s {
            let _ = session.transition(SessionState::Pasting);
            // Pasting and clipboard restore happen on the Obj-C side
            // We transition directly to Completed here
            let _ = session.transition(SessionState::Completed);
        }
    }
    invoke_state_changed(session_token,"completed");

    log::info!("[{session_id}] session completed");
    cleanup_session(&session_arc);
    invoke_state_changed(session_token,"idle");
}

async fn wait_for_final(
    session_token: u64,
    asr: &mut dyn AsrProvider,
    aggregator: &mut TranscriptAggregator,
) {
    loop {
        match asr.next_event().await {
            Ok(AsrEvent::Final(text)) => {
                aggregator.update_final(&text);
                invoke_interim_text(session_token,&text);
                return;
            }
            Ok(AsrEvent::Interim(text)) => {
                if !text.is_empty() {
                    aggregator.update_interim(&text);
                    invoke_interim_text(session_token,&text);
                }
            }
            Ok(AsrEvent::Definite(text)) => {
                aggregator.update_definite(&text);
                invoke_interim_text(session_token,&aggregator.best_text());
            }
            Ok(AsrEvent::Closed) => return,
            Ok(_) => {}
            Err(_) => return,
        }
    }
}

fn cleanup_session(session_arc: &Arc<Mutex<Option<Session>>>) {
    let mut s = session_arc.lock().unwrap();
    *s = None;
}

fn llm_is_ready(cfg: &config::LlmSection) -> bool {
    cfg.enabled && !cfg.base_url.is_empty() && !cfg.api_key.is_empty() && !cfg.model.is_empty()
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
        let llm = OpenAiCompatibleProvider::new(
            llm_http_client,
            warmup_cfg.base_url,
            warmup_cfg.api_key,
            warmup_cfg.model,
            warmup_cfg.temperature,
            warmup_cfg.top_p,
            warmup_cfg.max_output_tokens,
            warmup_cfg.max_token_parameter,
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
                "description": m.manifest.description,
                "repo": m.manifest.repo,
                "total_size": m.manifest.files.iter().map(|f| f.size).sum::<u64>(),
                "status": model_manager::check_model_status(&m.path) as i32,
            })
        })
        .collect();
    let json_str = serde_json::to_string(&json).unwrap_or_else(|_| "[]".to_string());
    CString::new(json_str).unwrap_or_default().into_raw()
}

/// Get a config value by dot-separated key path (e.g. "asr.doubao.app_key").
/// Returns a heap-allocated C string that must be freed with sp_core_free_string().
/// Returns an empty string if the key is not found.
#[no_mangle]
pub extern "C" fn sp_config_get(key_path: *const c_char) -> *mut c_char {
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
#[no_mangle]
pub extern "C" fn sp_config_set(key_path: *const c_char, value: *const c_char) -> i32 {
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

/// Free a string returned by sp_core_scan_models_json().
#[no_mangle]
pub extern "C" fn sp_core_free_string(s: *mut c_char) {
    if !s.is_null() {
        unsafe {
            drop(CString::from_raw(s));
        }
    }
}

/// Check model status (quick, size only): 0=not installed, 1=incomplete, 2=installed
#[no_mangle]
pub extern "C" fn sp_core_check_model_status(model_path: *const c_char) -> i32 {
    let path = match unsafe { cstr_to_str(model_path) } {
        Some(s) => s,
        None => return -1,
    };
    let model_dir = config::resolve_model_dir(path);
    model_manager::check_model_status(&model_dir) as i32
}

/// Verify model status (thorough, size + sha256): 0=not installed, 1=incomplete, 2=installed
#[no_mangle]
pub extern "C" fn sp_core_verify_model_status(model_path: *const c_char) -> i32 {
    let path = match unsafe { cstr_to_str(model_path) } {
        Some(s) => s,
        None => return -1,
    };
    let model_dir = config::resolve_model_dir(path);
    model_manager::verify_model_status(&model_dir) as i32
}

/// Start downloading a model. Returns 0=started, -1=already downloading, -2=error.
#[no_mangle]
pub extern "C" fn sp_core_download_model(
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
#[no_mangle]
pub extern "C" fn sp_core_cancel_download(model_path: *const c_char) -> i32 {
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
#[no_mangle]
pub extern "C" fn sp_core_remove_model_files(model_path: *const c_char) -> i32 {
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
