mod benchmark;
mod dict;
mod text;

use std::sync::Arc;

use clap::{Parser, Subcommand};
use indicatif::{MultiProgress, ProgressBar, ProgressStyle};
use koe_core::{asr_factory, model_manager};

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
        /// ASR provider to use (default: the provider from ~/.koe/config.yaml)
        #[arg(long, short = 'p')]
        provider: Option<String>,
    },
    /// Benchmark ASR providers over a corpus of audio files with references.
    ///
    /// The corpus directory holds audio files (any ffmpeg-supported format),
    /// each with a sibling .txt file of the same stem containing the
    /// reference transcript.
    Benchmark {
        /// Directory containing audio files + .txt reference transcripts
        corpus_dir: String,
        /// Comma-separated provider names, or "all" for every provider
        /// available in this build (default: the configured provider)
        #[arg(long)]
        providers: Option<String>,
        /// Emit JSON instead of Markdown
        #[arg(long)]
        json: bool,
    },
    /// Manage local ASR models
    Model {
        #[command(subcommand)]
        action: ModelCommands,
    },
    /// Dictionary management and suggestions
    Dict {
        #[command(subcommand)]
        action: DictCommands,
    },
    /// Manifest management
    Manifest {
        #[command(subcommand)]
        action: ManifestCommands,
    },
}

#[derive(Subcommand)]
enum DictCommands {
    /// Suggest dictionary entries mined from voice-input history.
    ///
    /// Compares each session's raw ASR transcript against its LLM-corrected
    /// text and surfaces recurring corrections — likely proper nouns and
    /// technical terms a dictionary entry would fix. Suggestions are never
    /// added automatically; confirm with 'koe dict add <term>'.
    Suggest {
        /// Minimum number of sessions a correction must appear in
        #[arg(long, default_value_t = 2)]
        min_count: usize,
        /// Maximum suggestions to show
        #[arg(long, default_value_t = 20)]
        limit: usize,
        /// Path to history.db (default: ~/.koe/history.db)
        #[arg(long)]
        db: Option<String>,
        /// Emit JSON instead of a table
        #[arg(long)]
        json: bool,
    },
    /// Add terms to the dictionary (after your confirmation)
    Add {
        /// Terms to append to ~/.koe/dictionary.txt
        #[arg(required = true)]
        terms: Vec<String>,
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
            provider,
        } => transcribe(&file, interim, credentials.as_deref(), provider.as_deref()).await,
        Commands::Benchmark {
            corpus_dir,
            providers,
            json,
        } => run_benchmark(&corpus_dir, providers.as_deref(), json).await,
        Commands::Model { action } => match action {
            ModelCommands::List => list(),
            ModelCommands::Status { model, verify_mode } => status(&model, &verify_mode),
            ModelCommands::Pull { model } => pull(&model).await,
            ModelCommands::Remove { model } => remove(&model),
        },
        Commands::Dict { action } => match action {
            DictCommands::Suggest {
                min_count,
                limit,
                db,
                json,
            } => dict_suggest(min_count, limit, db.as_deref(), json),
            DictCommands::Add { terms } => dict_add(&terms),
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

/// Resolve a provider-name argument against what this build supports.
/// `None` falls back to the provider configured in ~/.koe/config.yaml.
fn resolve_provider(cfg: &koe_core::config::Config, requested: Option<&str>) -> Result<String, String> {
    let name = requested.unwrap_or(&cfg.asr.provider).to_string();
    let supported = asr_factory::supported_providers();
    if supported.contains(&name.as_str()) {
        Ok(name)
    } else {
        Err(format!(
            "unsupported provider '{name}' (available in this build: {})",
            supported.join(", ")
        ))
    }
}

async fn transcribe(
    file: &str,
    show_interim: bool,
    credentials: Option<&str>,
    provider: Option<&str>,
) -> Result<(), String> {
    use koe_asr::{AsrEvent, TranscriptAggregator};

    let path = std::path::Path::new(file);
    if !path.exists() {
        return Err(format!("file not found: {file}"));
    }

    // Decode audio/video to raw PCM using ffmpeg
    eprintln!("Decoding {file} ...");
    let pcm_data = decode_to_pcm(file)?;
    let duration_secs = pcm_data.len() as f64 / (16000.0 * 2.0); // 16kHz, 16-bit mono
    eprintln!("Audio: {:.1}s, {} bytes PCM", duration_secs, pcm_data.len());

    let cfg = koe_core::config::load_config().map_err(|e| format!("load config: {e}"))?;
    let provider_name = resolve_provider(&cfg, provider)?;
    let (mut config, mut asr) = asr_factory::create_asr_provider(&cfg, &provider_name, &[]);

    // --credentials overrides the DoubaoIME credential path from config
    if let Some(cred_path) = credentials {
        config
            .custom_headers
            .insert("credential_path".to_string(), cred_path.to_string());
    }

    eprintln!("Connecting to {provider_name} ASR...");
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

// ─── Dictionary ─────────────────────────────────────────────────────

fn dict_suggest(min_count: usize, limit: usize, db: Option<&str>, json: bool) -> Result<(), String> {
    let db_path = match db {
        Some(p) => std::path::PathBuf::from(p),
        None => koe_core::config::config_dir().join("history.db"),
    };

    let pairs = dict::load_history_pairs(&db_path)?;
    if pairs.is_empty() {
        let analyzable = dict::count_analyzable(&db_path);
        if analyzable == 0 {
            eprintln!(
                "No analyzable sessions yet. Raw ASR text is recorded from this \
                 version onward — dictate for a while, then run this again."
            );
        } else {
            eprintln!(
                "No LLM-corrected sessions found ({analyzable} sessions have raw text). \
                 Enable LLM correction to collect correction pairs."
            );
        }
        return Ok(());
    }

    let cfg = koe_core::config::load_config().map_err(|e| format!("load config: {e}"))?;
    let dict_path = koe_core::config::resolve_dictionary_path(&cfg);
    let existing = koe_core::dictionary::load_dictionary(&dict_path)
        .map_err(|e| format!("load dictionary: {e}"))?;

    let all: Vec<dict::Replacement> = pairs
        .iter()
        .flat_map(|(asr, corrected)| dict::replacements(asr, corrected))
        .collect();
    let mut suggestions = dict::aggregate(all, &existing, min_count);
    let total = suggestions.len();
    suggestions.truncate(limit);

    if json {
        println!(
            "{}",
            serde_json::to_string_pretty(&suggestions).map_err(|e| format!("json: {e}"))?
        );
        return Ok(());
    }

    if suggestions.is_empty() {
        eprintln!(
            "No recurring corrections found across {} session(s). \
             Lower the threshold with --min-count 1 to see one-off corrections.",
            pairs.len()
        );
        return Ok(());
    }

    println!(
        "Dictionary suggestions from {} corrected session(s):\n",
        pairs.len()
    );
    for s in &suggestions {
        println!("  {}  ({}x)", s.term, s.count);
        println!("    heard as: {}", s.asr_forms.join(", "));
        println!("    example:  {}\n", s.example);
    }
    if total > suggestions.len() {
        println!("  … and {} more (raise --limit)\n", total - suggestions.len());
    }
    println!("Add with: koe dict add <term> …  (nothing is added automatically)");
    Ok(())
}

fn dict_add(terms: &[String]) -> Result<(), String> {
    let cfg = koe_core::config::load_config().map_err(|e| format!("load config: {e}"))?;
    let dict_path = koe_core::config::resolve_dictionary_path(&cfg);
    let existing = koe_core::dictionary::load_dictionary(&dict_path)
        .map_err(|e| format!("load dictionary: {e}"))?;
    let existing_lower: Vec<String> = existing.iter().map(|e| e.to_lowercase()).collect();

    let mut content = if dict_path.exists() {
        std::fs::read_to_string(&dict_path).map_err(|e| format!("read dictionary: {e}"))?
    } else {
        String::new()
    };

    let mut added = 0;
    for term in terms {
        let term = term.trim();
        if term.is_empty() {
            continue;
        }
        if existing_lower.contains(&term.to_lowercase()) {
            println!("already present: {term}");
            continue;
        }
        if !content.is_empty() && !content.ends_with('\n') {
            content.push('\n');
        }
        content.push_str(term);
        content.push('\n');
        println!("added: {term}");
        added += 1;
    }

    if added > 0 {
        std::fs::write(&dict_path, content).map_err(|e| format!("write dictionary: {e}"))?;
        println!(
            "{added} term(s) written to {} (takes effect next session)",
            dict_path.display()
        );
    }
    Ok(())
}

// ─── Benchmark ──────────────────────────────────────────────────────

async fn run_benchmark(
    corpus_dir: &str,
    providers: Option<&str>,
    json: bool,
) -> Result<(), String> {
    let cfg = koe_core::config::load_config().map_err(|e| format!("load config: {e}"))?;

    let provider_names: Vec<String> = match providers {
        None => vec![resolve_provider(&cfg, None)?],
        Some("all") => asr_factory::supported_providers()
            .iter()
            .map(|s| s.to_string())
            .collect(),
        Some(list) => list
            .split(',')
            .map(|name| resolve_provider(&cfg, Some(name.trim())).map(|_| name.trim().to_string()))
            .collect::<Result<Vec<_>, _>>()?,
    };

    let corpus = benchmark::load_corpus(std::path::Path::new(corpus_dir))?;
    eprintln!(
        "Benchmarking {} provider(s) over {} file(s)",
        provider_names.len(),
        corpus.len()
    );

    // Decode every file once; all providers consume the same PCM.
    let mut pcm_cache = Vec::with_capacity(corpus.len());
    for entry in &corpus {
        let file = entry.audio.to_string_lossy().to_string();
        eprintln!("Decoding {file} ...");
        let pcm = decode_to_pcm(&file)?;
        let audio_secs = pcm.len() as f64 / (16000.0 * 2.0);
        pcm_cache.push((audio_secs, pcm));
    }

    let mut reports = Vec::new();
    for name in &provider_names {
        eprintln!("Provider: {name}");
        reports.push(benchmark::run_provider(&cfg, name, &corpus, &pcm_cache).await);
    }

    if json {
        let value: Vec<serde_json::Value> = reports
            .iter()
            .map(|r| {
                serde_json::json!({
                    "provider": r.provider,
                    "overall_error_rate": r.overall_error_rate(),
                    "mean_finalize_ms": r.mean_finalize_ms(),
                    "mean_rtf": r.mean_rtf(),
                    "files": r.files,
                    "errors": r.errors,
                })
            })
            .collect();
        println!(
            "{}",
            serde_json::to_string_pretty(&value).map_err(|e| format!("json: {e}"))?
        );
    } else {
        println!("{}", benchmark::render_markdown(&reports));
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
