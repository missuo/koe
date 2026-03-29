use std::path::PathBuf;
use std::sync::mpsc as std_mpsc;
use std::time::Duration;

use crate::config::AsrConfig;
use crate::error::{AsrError, Result};
use crate::event::AsrEvent;

/// Configuration for the sherpa-onnx local streaming ASR provider.
#[derive(Debug, Clone)]
pub struct SherpaOnnxConfig {
    /// Model directory path (e.g. ~/.koe/models/sherpa-onnx/<model-name>/)
    pub model_dir: PathBuf,
    /// Number of threads for inference
    pub num_threads: i32,
    /// Hotwords (dictionary terms) for improved recognition
    pub hotwords: Vec<String>,
    /// Score boost for hotwords
    pub hotwords_score: f32,
    /// Endpoint rule 2: trailing silence after speech (seconds)
    pub endpoint_silence: f32,
}

enum SherpaCmd {
    Audio(Vec<f32>),
    Finish,
    Close,
}

/// Local streaming ASR provider using sherpa-onnx OnlineRecognizer.
///
/// Runs the synchronous sherpa-onnx API on a dedicated worker thread,
/// bridging to async via channels.
pub struct SherpaOnnxProvider {
    config: SherpaOnnxConfig,
    cmd_tx: Option<std_mpsc::Sender<SherpaCmd>>,
    event_rx: Option<tokio::sync::mpsc::Receiver<AsrEvent>>,
    worker: Option<std::thread::JoinHandle<()>>,
}

impl SherpaOnnxProvider {
    pub fn new(config: SherpaOnnxConfig) -> Self {
        Self {
            config,
            cmd_tx: None,
            event_rx: None,
            worker: None,
        }
    }
}

#[async_trait::async_trait]
impl crate::provider::AsrProvider for SherpaOnnxProvider {
    // Local provider: configuration is passed via `new()`, not through AsrConfig.
    // The `_config` parameter is unused here.
    async fn connect(&mut self, _config: &AsrConfig) -> Result<()> {
        let model_dir = &self.config.model_dir;

        if !model_dir.exists() {
            return Err(AsrError::Connection(format!(
                "model not found: {}",
                model_dir.display()
            )));
        }

        let (encoder, decoder, joiner, tokens) = find_model_files(model_dir)?;

        let num_threads = self.config.num_threads;
        let endpoint_silence = self.config.endpoint_silence;
        let hotwords_score = self.config.hotwords_score;
        let hotwords_buf = if self.config.hotwords.is_empty() {
            None
        } else {
            Some(self.config.hotwords.join("\n").into_bytes())
        };
        let (cmd_tx, cmd_rx) = std_mpsc::channel::<SherpaCmd>();
        let (event_tx, event_rx) = tokio::sync::mpsc::channel::<AsrEvent>(256);

        let worker = std::thread::spawn(move || {
            worker_loop(
                encoder,
                decoder,
                joiner,
                tokens,
                num_threads,
                endpoint_silence,
                hotwords_buf,
                hotwords_score,
                cmd_rx,
                event_tx,
            );
        });

        self.cmd_tx = Some(cmd_tx);
        self.event_rx = Some(event_rx);
        self.worker = Some(worker);

        Ok(())
    }

    async fn send_audio(&mut self, frame: &[u8]) -> Result<()> {
        let samples: Vec<f32> = frame
            .chunks_exact(2)
            .map(|c| i16::from_le_bytes([c[0], c[1]]) as f32 / 32768.0)
            .collect();

        if let Some(ref tx) = self.cmd_tx {
            tx.send(SherpaCmd::Audio(samples))
                .map_err(|_| AsrError::Connection("worker thread closed".into()))?;
        }
        Ok(())
    }

    async fn finish_input(&mut self) -> Result<()> {
        if let Some(ref tx) = self.cmd_tx {
            let _ = tx.send(SherpaCmd::Finish);
        }
        Ok(())
    }

    async fn next_event(&mut self) -> Result<AsrEvent> {
        if let Some(ref mut rx) = self.event_rx {
            rx.recv()
                .await
                .ok_or(AsrError::Connection("event channel closed".into()))
        } else {
            Err(AsrError::Connection("not connected".into()))
        }
    }

    async fn close(&mut self) -> Result<()> {
        if let Some(tx) = self.cmd_tx.take() {
            let _ = tx.send(SherpaCmd::Close);
        }
        if let Some(worker) = self.worker.take() {
            let _ = worker.join();
        }
        self.event_rx = None;
        Ok(())
    }
}

/// Find encoder/decoder/joiner/tokens files in the model directory.
/// Prefers int8 quantized models when available (smaller, faster on CPU).
fn find_model_files(
    model_dir: &std::path::Path,
) -> Result<(String, String, String, String)> {
    let entries: Vec<_> = std::fs::read_dir(model_dir)
        .map_err(|e| AsrError::Connection(format!("read model dir: {e}")))?
        .filter_map(|e| e.ok())
        .map(|e| e.file_name().to_string_lossy().to_string())
        .collect();

    // Prefer int8 > fp16 > fp32
    let find = |pattern: &str| -> Result<String> {
        let candidates: Vec<_> = entries
            .iter()
            .filter(|name| name.contains(pattern) && name.ends_with(".onnx"))
            .collect();
        let chosen = candidates
            .iter()
            .find(|n| n.contains(".int8."))
            .or_else(|| candidates.iter().find(|n| n.contains(".fp16.")))
            .or_else(|| candidates.first());
        chosen
            .map(|name| model_dir.join(name).to_string_lossy().to_string())
            .ok_or_else(|| {
                AsrError::Connection(format!(
                    "missing {pattern}*.onnx in {}",
                    model_dir.display()
                ))
            })
    };

    let encoder = find("encoder")?;
    let decoder = find("decoder")?;
    let joiner = find("joiner")?;

    let tokens = entries
        .iter()
        .find(|name| *name == "tokens.txt")
        .map(|name| model_dir.join(name).to_string_lossy().to_string())
        .ok_or_else(|| {
            AsrError::Connection(format!("missing tokens.txt in {}", model_dir.display()))
        })?;

    log::info!("sherpa model files: encoder={encoder}, decoder={decoder}, joiner={joiner}");
    Ok((encoder, decoder, joiner, tokens))
}

/// Worker thread: runs sherpa-onnx OnlineRecognizer synchronously.
fn worker_loop(
    encoder: String,
    decoder: String,
    joiner: String,
    tokens: String,
    num_threads: i32,
    endpoint_silence: f32,
    hotwords_buf: Option<Vec<u8>>,
    hotwords_score: f32,
    cmd_rx: std_mpsc::Receiver<SherpaCmd>,
    event_tx: tokio::sync::mpsc::Sender<AsrEvent>,
) {
    use sherpa_onnx::{OnlineRecognizer, OnlineRecognizerConfig};

    let mut config = OnlineRecognizerConfig::default();
    config.model_config.transducer.encoder = Some(encoder);
    config.model_config.transducer.decoder = Some(decoder);
    config.model_config.transducer.joiner = Some(joiner);
    config.model_config.tokens = Some(tokens);
    config.model_config.num_threads = num_threads;
    config.decoding_method = Some("greedy_search".into());
    config.enable_endpoint = true;
    config.rule1_min_trailing_silence = 2.4;
    config.rule2_min_trailing_silence = endpoint_silence;
    config.rule3_min_utterance_length = 300.0; // effectively disabled
    config.hotwords_buf = hotwords_buf;
    config.hotwords_score = hotwords_score;

    let recognizer = match OnlineRecognizer::create(&config) {
        Some(r) => r,
        None => {
            let _ = event_tx.blocking_send(AsrEvent::Error(
                "failed to create sherpa-onnx recognizer".into(),
            ));
            return;
        }
    };

    let stream = recognizer.create_stream();
    let _ = event_tx.blocking_send(AsrEvent::Connected);

    let mut accumulated_text = String::new();
    let mut last_text = String::new();
    let decode_timeout = Duration::from_millis(200);

    loop {
        match cmd_rx.recv_timeout(decode_timeout) {
            Ok(SherpaCmd::Audio(samples)) => {
                stream.accept_waveform(16000, &samples);
            }
            Ok(SherpaCmd::Finish) => {
                stream.input_finished();
                // Final decode pass
                while recognizer.is_ready(&stream) {
                    recognizer.decode(&stream);
                }
                let result_text = recognizer
                    .get_result(&stream)
                    .map(|r| r.text)
                    .unwrap_or_default();
                let final_text = format!("{}{}", accumulated_text, result_text);
                let _ = event_tx.blocking_send(AsrEvent::Final(final_text));
                break;
            }
            Ok(SherpaCmd::Close) => {
                break;
            }
            Err(std_mpsc::RecvTimeoutError::Timeout) => {
                // Periodic decode — fall through to decode loop below
            }
            Err(std_mpsc::RecvTimeoutError::Disconnected) => {
                break;
            }
        }

        // Decode available frames
        while recognizer.is_ready(&stream) {
            recognizer.decode(&stream);
        }

        let result_text = recognizer
            .get_result(&stream)
            .map(|r| r.text)
            .unwrap_or_default();

        // Check endpoint (sentence boundary detected)
        if recognizer.is_endpoint(&stream) {
            if !result_text.is_empty() {
                accumulated_text.push_str(&result_text);
                let _ = event_tx.blocking_send(AsrEvent::Definite(accumulated_text.clone()));
            }
            recognizer.reset(&stream);
            last_text = String::new();
        } else {
            // Emit Interim if text changed
            let current = format!("{}{}", accumulated_text, result_text);
            if current != last_text && !current.is_empty() {
                let _ = event_tx.blocking_send(AsrEvent::Interim(current.clone()));
                last_text = current;
            }
        }
    }

    let _ = event_tx.blocking_send(AsrEvent::Closed);
}
