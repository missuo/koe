pub mod audio_buffer;
pub mod config;
pub mod dictionary;
pub mod errors;
pub mod ffi;
pub mod llm;
pub mod prompt;
pub mod session;
pub mod telemetry;

use crate::config::Config;
use crate::ffi::{
    cstr_to_str, invoke_final_text_ready, invoke_interim_text, invoke_session_error,
    invoke_session_ready, invoke_session_warning, invoke_state_changed, SPCallbacks,
    SPFeedbackConfig, SPHotkeyConfig, SPSessionContext, SPSessionMode,
};
use crate::llm::openai_compatible::OpenAiCompatibleProvider;
use crate::llm::{CorrectionRequest, LlmProvider};
use crate::session::{Session, SessionState};
use koe_asr::{
    AliyunAsrProvider, AsrConfig, AsrEvent, AsrProvider, DoubaoWsProvider, TranscriptAggregator,
};

use std::ffi::c_char;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};
use tokio::runtime::Runtime;
use tokio::sync::mpsc;
use tokio::time::{timeout, Duration};

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
}

static CORE: Mutex<Option<Core>> = Mutex::new(None);

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

    let core = Core {
        runtime,
        audio_tx: None,
        session: Arc::new(Mutex::new(None)),
        cancelled: Arc::new(AtomicBool::new(false)),
        config: cfg,
        dictionary,
        system_prompt,
        user_prompt_template,
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
        core.config = cfg;
        core.dictionary = dictionary;
        core.system_prompt = system_prompt;
        core.user_prompt_template = user_prompt_template;
        log::info!("config, dictionary, and prompts reloaded");
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
        core.config = new_cfg;
    }

    // Create session
    let session = Session::new(context.mode, bundle_id, context.frontmost_pid);
    let session_id = session.id.clone();
    let mode = context.mode;

    // Audio channel
    let (audio_tx, audio_rx) = mpsc::channel::<Vec<u8>>(1024);
    core.audio_tx = Some(audio_tx);

    // Reset cancelled flag for new session
    core.cancelled.store(false, Ordering::SeqCst);
    let cancelled = core.cancelled.clone();

    let session_arc = core.session.clone();
    {
        let mut s = session_arc.lock().unwrap();
        *s = Some(session);
    }

    // Capture config for the async task
    let cfg = &core.config;
    let asr_provider = cfg.asr.provider.clone();
    let (asr_config, asr_provider_name) = match asr_provider.as_str() {
        "aliyun" => {
            let aliyun = &cfg.asr.aliyun;
            let config = AsrConfig {
                url: String::new(), // not used for aliyun
                app_key: String::new(),
                access_key: aliyun.api_key.clone(),
                resource_id: String::new(),
                sample_rate_hz: 16000,
                connect_timeout_ms: aliyun.connect_timeout_ms,
                final_wait_timeout_ms: aliyun.final_wait_timeout_ms,
                enable_ddc: false,
                enable_itn: false,
                enable_punc: false,
                enable_nonstream: false,
                hotwords: Vec::new(),
                language: Some(aliyun.language.clone()),
            };
            (config, "aliyun".to_string())
        }
        _ => {
            // Default to doubao
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
            (config, "doubao".to_string())
        }
    };
    let llm_config = cfg.llm.clone();
    let dictionary = core.dictionary.clone();
    let dictionary_max_candidates = cfg.llm.dictionary_max_candidates;
    let system_prompt = core.system_prompt.clone();
    let user_prompt_template = core.user_prompt_template.clone();

    // Spawn the session task
    core.runtime.spawn(async move {
        run_session(
            session_arc,
            session_id,
            mode,
            audio_rx,
            asr_config,
            asr_provider_name,
            llm_config,
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
    mode: SPSessionMode,
    mut audio_rx: mpsc::Receiver<Vec<u8>>,
    asr_config: AsrConfig,
    asr_provider: String,
    llm_config: config::LlmSection,
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
    invoke_state_changed(&recording_state.to_string());

    // --- Connect ASR ---
    log::info!("[{session_id}] Using ASR provider: {asr_provider}");
    let mut asr: Box<dyn AsrProvider> = match asr_provider.as_str() {
        "aliyun" => Box::new(AliyunAsrProvider::new()),
        _ => Box::new(DoubaoWsProvider::new()),
    };

    // Buffer audio frames during ASR connection to prevent channel overflow
    let mut pre_connect_buffer: Vec<Vec<u8>> = Vec::new();
    let connect_result = tokio::time::timeout(
        Duration::from_millis(asr_config.connect_timeout_ms),
        async {
            // Start ASR connection
            let connect_future = asr.connect(&asr_config);
            tokio::pin!(connect_future);

            loop {
                tokio::select! {
                    result = &mut connect_future => {
                        return result;
                    }
                    frame = audio_rx.recv() => {
                        if let Some(data) = frame {
                            // Buffer audio during connection
                            if pre_connect_buffer.len() < 100 { // Limit buffer to ~20 seconds
                                pre_connect_buffer.push(data);
                            }
                        }
                    }
                }
            }
        },
    )
    .await;

    match connect_result {
        Ok(Ok(())) => {
            log::info!(
                "[{session_id}] ASR connected, buffered {} frames",
                pre_connect_buffer.len()
            );
            invoke_session_ready();
        }
        Ok(Err(e)) => {
            log::error!("[{session_id}] ASR connection failed: {e}");
            invoke_session_error(&e.to_string());
            invoke_state_changed("failed");
            cleanup_session(&session_arc);
            return;
        }
        Err(_) => {
            log::error!("[{session_id}] ASR connection timeout");
            invoke_session_error("connection timeout");
            invoke_state_changed("failed");
            cleanup_session(&session_arc);
            return;
        }
    }

    // Send buffered audio first
    for data in pre_connect_buffer {
        if let Err(e) = asr.send_audio(&data).await {
            log::error!("[{session_id}] ASR send error (buffered): {e}");
            break;
        }
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
                            invoke_interim_text(&text);
                        }
                    }
                    Ok(AsrEvent::Definite(text)) => {
                        aggregator.update_definite(&text);
                        invoke_interim_text(&aggregator.best_text());
                    }
                    Ok(AsrEvent::Final(text)) => {
                        aggregator.update_final(&text);
                        invoke_interim_text(&text);
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
        invoke_state_changed("cancelled");
        cleanup_session(&session_arc);
        invoke_state_changed("idle");
        return;
    }

    // --- Finalize ASR ---
    {
        let mut s = session_arc.lock().unwrap();
        if let Some(ref mut session) = *s {
            let _ = session.transition(SessionState::FinalizingAsr);
        }
    }
    invoke_state_changed("finalizing_asr");

    // Wait for final result if we haven't received one yet
    if !aggregator.has_final_result() && !asr_done {
        let wait_result = timeout(
            Duration::from_millis(final_wait_timeout_ms),
            wait_for_final(asr.as_mut(), &mut aggregator),
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
        invoke_session_error("no speech recognized");
        invoke_state_changed("failed");
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
    let llm_enabled =
        llm_config.enabled && !llm_config.base_url.is_empty() && !llm_config.api_key.is_empty();

    let final_text = if llm_enabled {
        {
            let mut s = session_arc.lock().unwrap();
            if let Some(ref mut session) = *s {
                let _ = session.transition(SessionState::Correcting);
            }
        }
        invoke_state_changed("correcting");

        let llm = OpenAiCompatibleProvider::new(
            llm_config.base_url,
            llm_config.api_key,
            llm_config.model,
            llm_config.temperature,
            llm_config.top_p,
            llm_config.max_output_tokens,
            llm_config.max_token_parameter,
            llm_config.timeout_ms,
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
                log::info!("[{session_id}] LLM corrected: {} chars", corrected.len());
                corrected
            }
            Err(e) => {
                log::warn!("[{session_id}] LLM failed, falling back to ASR text: {e}");
                invoke_session_warning(&format!("LLM correction failed: {e}"));
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

    // Store corrected text
    {
        let mut s = session_arc.lock().unwrap();
        if let Some(ref mut session) = *s {
            session.corrected_text = Some(final_text.clone());
            let _ = session.transition(SessionState::PreparingPaste);
        }
    }
    invoke_state_changed("preparing_paste");

    // --- Deliver result to Obj-C ---
    invoke_final_text_ready(&final_text);

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
    invoke_state_changed("completed");

    log::info!("[{session_id}] session completed");
    cleanup_session(&session_arc);
    invoke_state_changed("idle");
}

async fn wait_for_final(asr: &mut dyn AsrProvider, aggregator: &mut TranscriptAggregator) {
    loop {
        match asr.next_event().await {
            Ok(AsrEvent::Final(text)) => {
                aggregator.update_final(&text);
                invoke_interim_text(&text);
                return;
            }
            Ok(AsrEvent::Interim(text)) => {
                if !text.is_empty() {
                    aggregator.update_interim(&text);
                    invoke_interim_text(&text);
                }
            }
            Ok(AsrEvent::Definite(text)) => {
                aggregator.update_definite(&text);
                invoke_interim_text(&aggregator.best_text());
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
