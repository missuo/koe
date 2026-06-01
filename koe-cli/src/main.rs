use std::sync::Arc;

use clap::{Parser, Subcommand};
use indicatif::{MultiProgress, ProgressBar, ProgressStyle};
use koe_core::model_manager;

#[derive(Parser)]
#[command(name = "koe", about = "Koe voice input tool CLI")]
struct Cli {
    #[command(subcommand)]
    command: Commands,
}

#[derive(Subcommand)]
enum Commands {
    /// Transcribe an audio or video file to text
    Transcribe {
        /// Path to the audio or video file (any format supported by ffmpeg)
        file: String,
        /// Show interim (partial) results as they arrive
        #[arg(long, short = 'i')]
        interim: bool,
        /// Path to DoubaoIME credentials file
        #[arg(long)]
        credentials: Option<String>,
    },
    /// Manage local ASR models
    Model {
        #[command(subcommand)]
        action: ModelCommands,
    },
    /// Manifest management
    Manifest {
        #[command(subcommand)]
        action: ManifestCommands,
    },
}

#[derive(Subcommand)]
enum ManifestCommands {
    /// Generate manifest from a HuggingFace repo
    Generate {
        /// HuggingFace repo id (e.g. mlx-community/Qwen3-ASR-0.6B-4bit)
        repo: String,
        /// Provider name (e.g. mlx, sherpa-onnx)
        #[arg(long)]
        provider: String,
        /// Model description
        #[arg(long)]
        description: String,
        /// Output path (default: ~/.koe/models/<provider>/<repo-name>/.koe-manifest.json)
        #[arg(long, short)]
        output: Option<String>,
    },
}

#[derive(Subcommand)]
enum ModelCommands {
    /// List all discovered models and their status
    List,
    /// Show model status for a specific path
    Status {
        /// Model path (relative to ~/.koe/models/ or absolute)
        model: String,
        /// Verification mode: normal (default), cache-only, force
        #[arg(long, default_value = "normal")]
        verify_mode: String,
    },
    /// Download model files
    Pull {
        /// Model path (relative to ~/.koe/models/ or absolute)
        model: String,
    },
    /// Remove downloaded model files (keeps manifest)
    Remove {
        /// Model path (relative to ~/.koe/models/ or absolute)
        model: String,
    },
}

#[tokio::main]
async fn main() {
    let cli = Cli::parse();

    // Ensure ~/.koe/ and default manifests exist
    let _ = koe_core::config::ensure_defaults();

    let result = match cli.command {
        Commands::Transcribe {
            file,
            interim,
            credentials,
        } => transcribe(&file, interim, credentials.as_deref()).await,
        Commands::Model { action } => match action {
            ModelCommands::List => list(),
            ModelCommands::Status { model, verify_mode } => status(&model, &verify_mode),
            ModelCommands::Pull { model } => pull(&model).await,
            ModelCommands::Remove { model } => remove(&model),
        },
        Commands::Manifest { action } => match action {
            ManifestCommands::Generate {
                repo,
                provider,
                description,
                output,
            } => manifest_generate(&repo, &provider, &description, output.as_deref()).await,
        },
    };

    if let Err(e) = result {
        eprintln!("error: {e}");
        std::process::exit(1);
    }
}

fn list() -> Result<(), String> {
    let models = model_manager::scan_models();

    if models.is_empty() {
        println!(
            "No models found in {}",
            model_manager::models_dir().display()
        );
        return Ok(());
    }

    for model in &models {
        let status = model_manager::model_status(&model.path, model_manager::VerifyMode::CacheOnly);
        let tag = match status {
            model_manager::ModelStatus::Installed => "installed",
            model_manager::ModelStatus::Incomplete => "incomplete",
            model_manager::ModelStatus::NotInstalled => "not installed",
        };

        let display_path = model
            .path
            .strip_prefix(model_manager::models_dir())
            .unwrap_or(&model.path);

        println!(
            "{:<40} [{}] {}",
            display_path.display(),
            tag,
            model.manifest.description
        );
    }

    Ok(())
}

fn status(model: &str, verify_mode_str: &str) -> Result<(), String> {
    let model_dir = koe_core::config::resolve_model_dir(model);

    if !model_dir.exists() {
        return Err(format!(
            "model directory not found: {}",
            model_dir.display()
        ));
    }

    let mode = match verify_mode_str {
        "cache-only" => model_manager::VerifyMode::CacheOnly,
        "force" => model_manager::VerifyMode::ForceVerify,
        _ => model_manager::VerifyMode::Normal,
    };

    println!("Verifying {model}...");
    let status = model_manager::model_status(&model_dir, mode);
    match status {
        model_manager::ModelStatus::Installed => {
            println!("{model} — installed (verified)");
            println!("Path: {}", model_dir.display());
        }
        model_manager::ModelStatus::Incomplete => {
            println!("{model} — incomplete (files missing, wrong size, or sha256 mismatch)");
        }
        model_manager::ModelStatus::NotInstalled => {
            println!("{model} — not installed (manifest only, no data files)");
        }
    }

    Ok(())
}

fn remove(model: &str) -> Result<(), String> {
    let model_dir = koe_core::config::resolve_model_dir(model);

    if !model_dir.exists() {
        return Err(format!(
            "model directory not found: {}",
            model_dir.display()
        ));
    }

    let removed = model_manager::remove_model_files(&model_dir).map_err(|e| format!("{e}"))?;
    println!("{model}: removed {removed} file(s), manifest kept");
    Ok(())
}

async fn pull(model: &str) -> Result<(), String> {
    let model_dir = koe_core::config::resolve_model_dir(model);

    if !model_dir.exists() {
        return Err(format!(
            "model directory not found: {}",
            model_dir.display()
        ));
    }

    let multi = Arc::new(MultiProgress::new());
    let bars: Arc<std::sync::Mutex<Vec<Option<ProgressBar>>>> =
        Arc::new(std::sync::Mutex::new(Vec::new()));

    let style = ProgressStyle::with_template(
        "{prefix:<25!} {msg:<9} [{bar:20}] {bytes:>10}/{total_bytes:>10}",
    )
    .unwrap()
    .progress_chars("█▓░");

    let style_done =
        ProgressStyle::with_template("{prefix:<25!} {msg:<9} {total_bytes:>44}").unwrap();

    let multi_clone = multi.clone();
    let bars_clone = bars.clone();
    let style_c = style.clone();
    let style_done_c = style_done.clone();

    let cancel = model_manager::CancellationToken::new();
    model_manager::download_model(
        &model_dir,
        move |progress| {
            let mut bars_guard = bars_clone.lock().unwrap();

            // Ensure vec is large enough
            while bars_guard.len() <= progress.file_index {
                bars_guard.push(None);
            }

            let pb = bars_guard[progress.file_index].get_or_insert_with(|| {
                let pb = multi_clone.add(ProgressBar::new(progress.bytes_total));
                pb.set_style(style_c.clone());
                pb.set_prefix(progress.filename.clone());
                pb
            });

            if progress.already_exists {
                pb.set_length(progress.bytes_total);
                pb.set_position(progress.bytes_total);
                pb.set_style(style_done_c.clone());
                pb.set_message("exists");
                pb.finish();
            } else if progress.bytes_downloaded >= progress.bytes_total && progress.bytes_total > 0
            {
                pb.set_position(progress.bytes_total);
                pb.set_style(style_done_c.clone());
                pb.set_message("done");
                pb.finish();
            } else {
                if pb.length().unwrap_or(0) == 0 && progress.bytes_total > 0 {
                    pb.set_length(progress.bytes_total);
                }
                pb.set_message("pulling");
                pb.set_position(progress.bytes_downloaded);
            }
        },
        cancel,
    )
    .await
    .map_err(|e| format!("{e}"))?;

    // Verify after download
    eprint!("\nVerifying...");
    let status = model_manager::model_status(&model_dir, model_manager::VerifyMode::ForceVerify);
    match status {
        model_manager::ModelStatus::Installed => {
            eprintln!(" ok");
            println!("{model}: pull complete");
            println!("Path: {}", model_dir.display());
        }
        _ => {
            eprintln!(" failed");
            return Err(format!("{model}: verification failed after download"));
        }
    }
    Ok(())
}

// ─── Transcribe ─────────────────────────────────────────────────────

async fn transcribe(
    file: &str,
    show_interim: bool,
    credentials: Option<&str>,
) -> Result<(), String> {
    use koe_asr::{AsrConfig, AsrEvent, AsrProvider, DoubaoImeProvider, TranscriptAggregator};
    use std::collections::HashMap;

    let path = std::path::Path::new(file);
    if !path.exists() {
        return Err(format!("file not found: {file}"));
    }

    // Decode audio/video to raw PCM using ffmpeg
    eprintln!("Decoding {file} ...");
    let pcm_data = decode_to_pcm(file)?;
    let duration_secs = pcm_data.len() as f64 / (16000.0 * 2.0); // 16kHz, 16-bit mono
    eprintln!("Audio: {:.1}s, {} bytes PCM", duration_secs, pcm_data.len());

    // Configure credentials path
    let mut custom_headers = HashMap::new();
    if let Some(cred_path) = credentials {
        custom_headers.insert("credential_path".to_string(), cred_path.to_string());
    }

    let config = AsrConfig {
        custom_headers,
        language: None,
        ..Default::default()
    };

    let mut asr = DoubaoImeProvider::new();
    eprintln!("Connecting to DoubaoIME ASR...");
    asr.connect(&config)
        .await
        .map_err(|e| format!("connect: {e}"))?;

    // Feed PCM in chunks (20ms frames = 640 bytes at 16kHz 16-bit mono)
    // Send without delay (realtime=false equivalent) for faster processing.
    const CHUNK_SIZE: usize = 640;
    for chunk in pcm_data.chunks(CHUNK_SIZE) {
        asr.send_audio(chunk)
            .await
            .map_err(|e| format!("send_audio: {e}"))?;
    }

    asr.finish_input()
        .await
        .map_err(|e| format!("finish_input: {e}"))?;

    // Collect results
    let mut aggregator = TranscriptAggregator::new();
    loop {
        match asr.next_event().await.map_err(|e| format!("event: {e}"))? {
            AsrEvent::Interim(text) => {
                aggregator.update_interim(&text);
                if show_interim {
                    eprint!("\r\x1b[2K[interim] {text}");
                }
            }
            AsrEvent::Definite(text) => {
                aggregator.update_definite(&text);
                if show_interim {
                    eprint!("\r\x1b[2K[definite] {text}");
                }
            }
            AsrEvent::Final(text) => {
                aggregator.update_final(&text);
                if show_interim {
                    eprintln!();
                }
                break;
            }
            AsrEvent::Error(msg) => {
                if show_interim {
                    eprintln!();
                }
                asr.close().await.ok();
                return Err(format!("ASR error: {msg}"));
            }
            AsrEvent::Closed(_) => {
                if show_interim {
                    eprintln!();
                }
                break;
            }
            _ => {}
        }
    }

    asr.close().await.ok();

    let result = aggregator.best_text();
    if result.is_empty() {
        eprintln!("No speech detected.");
    } else {
        println!("{result}");
    }

    Ok(())
}

/// Decode an audio/video file to raw PCM (16kHz, mono, s16le) using ffmpeg.
fn decode_to_pcm(file: &str) -> Result<Vec<u8>, String> {
    let output = std::process::Command::new("ffmpeg")
        .args([
            "-i",
            file,
            "-f",
            "s16le",
            "-acodec",
            "pcm_s16le",
            "-ar",
            "16000",
            "-ac",
            "1",
            "-v",
            "error",
            "pipe:1",
        ])
        .stdout(std::process::Stdio::piped())
        .stderr(std::process::Stdio::piped())
        .output()
        .map_err(|e| {
            if e.kind() == std::io::ErrorKind::NotFound {
                "ffmpeg not found. Please install ffmpeg to decode audio/video files.".to_string()
            } else {
                format!("failed to run ffmpeg: {e}")
            }
        })?;

    if !output.status.success() {
        let stderr = String::from_utf8_lossy(&output.stderr);
        return Err(format!("ffmpeg failed: {stderr}"));
    }

    if output.stdout.is_empty() {
        return Err("ffmpeg produced no audio output".to_string());
    }

    Ok(output.stdout)
}

// ─── Manifest Generate ──────────────────────────────────────────────

#[derive(serde::Deserialize)]
struct HfTreeEntry {
    #[serde(rename = "type")]
    entry_type: String,
    path: String,
    size: Option<u64>,
    lfs: Option<HfLfsInfo>,
}

#[derive(serde::Deserialize)]
struct HfLfsInfo {
    oid: String,
    size: u64,
}

async fn manifest_generate(
    repo: &str,
    provider: &str,
    description: &str,
    output: Option<&str>,
) -> Result<(), String> {
    eprintln!("Querying https://huggingface.co/api/models/{repo}/tree/main ...");

    let client = reqwest::Client::builder()
        .user_agent("koe/1.0")
        .build()
        .map_err(|e| format!("http client: {e}"))?;

    let url = format!("https://huggingface.co/api/models/{repo}/tree/main");
    let entries: Vec<HfTreeEntry> = client
        .get(&url)
        .send()
        .await
        .map_err(|e| format!("fetch: {e}"))?
        .error_for_status()
        .map_err(|e| format!("fetch: {e}"))?
        .json()
        .await
        .map_err(|e| format!("parse: {e}"))?;

    let files: Vec<serde_json::Value> = entries
        .iter()
        .filter(|e| e.entry_type == "file")
        .map(|e| {
            let size = e.lfs.as_ref().map(|l| l.size).or(e.size).unwrap_or(0);
            let sha256 = e.lfs.as_ref().map(|l| l.oid.as_str()).unwrap_or("");
            let url = format!("https://huggingface.co/{}/resolve/main/{}", repo, e.path);
            serde_json::json!({
                "name": e.path,
                "size": size,
                "sha256": sha256,
                "url": url,
            })
        })
        .collect();

    let manifest = serde_json::json!({
        "provider": provider,
        "description": description,
        "repo": repo,
        "files": files,
    });

    let json = serde_json::to_string_pretty(&manifest).map_err(|e| format!("json: {e}"))?;

    let output_path = match output {
        Some(path) => std::path::PathBuf::from(path),
        None => {
            // ~/.koe/models/<provider>/<repo-last-segment>/.koe-manifest.json
            let dir_name = repo.rsplit('/').next().unwrap_or(repo);
            let dir = model_manager::models_dir().join(provider).join(dir_name);
            std::fs::create_dir_all(&dir).map_err(|e| format!("create dir: {e}"))?;
            dir.join(".koe-manifest.json")
        }
    };

    std::fs::write(&output_path, &json).map_err(|e| format!("write: {e}"))?;

    eprintln!("Generated manifest with {} files", files.len());
    eprintln!("Written to: {}", output_path.display());

    Ok(())
}
