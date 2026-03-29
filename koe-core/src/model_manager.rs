use std::path::{Path, PathBuf};
use std::sync::Arc;

use futures_util::StreamExt;
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use tokio::sync::Semaphore;
pub use tokio_util::sync::CancellationToken;

use crate::config;
use crate::errors::{KoeError, Result};

const MANIFEST_FILE: &str = ".koe-manifest.json";

// ─── Data Structures ────────────────────────────────────────────────

#[derive(Debug, Deserialize, Serialize, Clone)]
pub struct ModelManifest {
    pub provider: String,
    pub description: String,
    pub repo: String,
    pub files: Vec<ModelFile>,
}

#[derive(Debug, Deserialize, Serialize, Clone)]
pub struct ModelFile {
    pub name: String,
    pub size: u64,
    pub sha256: String,
    pub url: String,
}

/// A model discovered by scanning ~/.koe/models/.
#[derive(Debug, Clone)]
pub struct DiscoveredModel {
    /// Model directory path (unique identifier).
    pub path: PathBuf,
    pub manifest: ModelManifest,
}

/// Model installation status.
/// Values match the C FFI convention: 0=not installed, 1=incomplete, 2=installed.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
#[repr(i32)]
pub enum ModelStatus {
    /// Only manifest, no data files downloaded.
    NotInstalled = 0,
    /// Manifest exists, but some files missing or wrong size.
    Incomplete = 1,
    /// Manifest exists, all files present with correct sizes.
    Installed = 2,
}

// ─── Models Directory ───────────────────────────────────────────────

/// Returns ~/.koe/models/
pub fn models_dir() -> PathBuf {
    config::config_dir().join("models")
}

// ─── Scan ───────────────────────────────────────────────────────────

/// Local ASR providers supported by this build.
pub fn supported_providers() -> &'static [&'static str] {
    &[
        #[cfg(feature = "mlx")]
        "mlx",
        #[cfg(feature = "sherpa-onnx")]
        "sherpa-onnx",
    ]
}

/// Scan ~/.koe/models/**/.koe-manifest.json and return all discovered models.
pub fn scan_models() -> Vec<DiscoveredModel> {
    let dir = models_dir();
    if !dir.exists() {
        return Vec::new();
    }

    let mut models = Vec::new();
    scan_dir_recursive(&dir, &mut models);
    models
}

/// Scan models filtered to providers supported by this build.
pub fn scan_supported_models() -> Vec<DiscoveredModel> {
    let supported = supported_providers();
    let mut models = scan_models();
    models.retain(|m| supported.contains(&m.manifest.provider.as_str()));
    models
}

fn scan_dir_recursive(dir: &Path, models: &mut Vec<DiscoveredModel>) {
    let entries = match std::fs::read_dir(dir) {
        Ok(e) => e,
        Err(_) => return,
    };

    for entry in entries.flatten() {
        let path = entry.path();
        if path.is_dir() {
            let manifest_path = path.join(MANIFEST_FILE);
            if manifest_path.exists() {
                if let Some(model) = load_manifest(&path) {
                    models.push(model);
                }
            }
            // Continue scanning subdirectories
            scan_dir_recursive(&path, models);
        }
    }
}

fn load_manifest(model_dir: &Path) -> Option<DiscoveredModel> {
    let manifest_path = model_dir.join(MANIFEST_FILE);
    let content = std::fs::read_to_string(&manifest_path).ok()?;
    let manifest: ModelManifest = serde_json::from_str(&content).ok()?;
    Some(DiscoveredModel {
        path: model_dir.to_path_buf(),
        manifest,
    })
}

// ─── Status ─────────────────────────────────────────────────────────

/// Quick status check (size only, no sha256). Suitable for `list`.
pub fn check_model_status(model_dir: &Path) -> ModelStatus {
    check_status_inner(model_dir, false)
}

/// Full verification (size + sha256 when available). Suitable for `status` and `pull`.
pub fn verify_model_status(model_dir: &Path) -> ModelStatus {
    check_status_inner(model_dir, true)
}

fn check_status_inner(model_dir: &Path, verify_sha: bool) -> ModelStatus {
    let model = match load_manifest(model_dir) {
        Some(m) => m,
        None => return ModelStatus::NotInstalled,
    };

    if model.manifest.files.is_empty() {
        return ModelStatus::Installed;
    }

    let mut found = 0usize;
    let total = model.manifest.files.len();

    for file in &model.manifest.files {
        let file_path = model_dir.join(&file.name);
        if let Ok(meta) = std::fs::metadata(&file_path) {
            if meta.len() != file.size {
                continue;
            }
            if verify_sha && !file.sha256.is_empty() {
                match sha256_file(&file_path) {
                    Ok(hash) if hash == file.sha256 => {}
                    _ => continue,
                }
            }
            found += 1;
        }
    }

    if found == total {
        ModelStatus::Installed
    } else if found > 0 {
        ModelStatus::Incomplete
    } else {
        ModelStatus::NotInstalled
    }
}

// ─── Remove ─────────────────────────────────────────────────────────

/// Remove downloaded model files, keeping the manifest.
pub fn remove_model_files(model_dir: &Path) -> Result<usize> {
    let mut removed = 0;
    let entries =
        std::fs::read_dir(model_dir).map_err(|e| KoeError::Config(format!("read dir: {e}")))?;
    for entry in entries.flatten() {
        let name = entry.file_name();
        if name != MANIFEST_FILE && entry.path().is_file() {
            std::fs::remove_file(entry.path())
                .map_err(|e| KoeError::Config(format!("remove {}: {e}", entry.path().display())))?;
            removed += 1;
        }
    }
    Ok(removed)
}

// ─── Download ───────────────────────────────────────────────────────

/// Progress information for file downloads.
#[derive(Debug, Clone)]
pub struct DownloadProgress {
    pub file_index: usize,
    pub file_count: usize,
    pub filename: String,
    pub bytes_downloaded: u64,
    pub bytes_total: u64,
    /// true if file was already present and skipped
    pub already_exists: bool,
}

/// Download model files according to the manifest.
///
/// - Skips files already present with correct size
/// - Supports resume via `.part` files and Range headers
/// - Downloads in parallel (up to 4 concurrent)
/// - Verifies sha256 after download
/// - Respects cancellation token
pub async fn download_model<F>(
    model_dir: &Path,
    on_progress: F,
    cancel: CancellationToken,
) -> Result<()>
where
    F: Fn(DownloadProgress) + Send + Sync + 'static,
{
    let model = load_manifest(model_dir).ok_or_else(|| {
        KoeError::Config(format!("manifest not found in {}", model_dir.display()))
    })?;

    let files = &model.manifest.files;
    if files.is_empty() {
        return Ok(());
    }

    let file_count = files.len();
    let on_progress = Arc::new(on_progress);
    let semaphore = Arc::new(Semaphore::new(4));
    let client = reqwest::Client::builder()
        .user_agent("koe/1.0")
        .build()
        .map_err(|e| KoeError::Config(format!("http client: {e}")))?;

    let mut handles = Vec::new();

    for (file_index, file) in files.iter().enumerate() {
        let model_dir = model_dir.to_path_buf();
        let file = file.clone();
        let on_progress = on_progress.clone();
        let semaphore = semaphore.clone();
        let client = client.clone();
        let cancel = cancel.clone();

        let handle = tokio::spawn(async move {
            let _permit = semaphore.acquire().await.unwrap();
            if cancel.is_cancelled() {
                return Err(KoeError::Config("cancelled".into()));
            }
            download_file(
                &client,
                &model_dir,
                &file,
                file_index,
                file_count,
                &on_progress,
                &cancel,
            )
            .await
        });

        handles.push(handle);
    }

    let mut first_error: Option<KoeError> = None;
    for handle in handles {
        match handle.await {
            Ok(Ok(())) => {}
            Ok(Err(e)) => {
                if first_error.is_none() {
                    first_error = Some(e);
                }
            }
            Err(e) => {
                if first_error.is_none() {
                    first_error = Some(KoeError::Config(format!("join: {e}")));
                }
            }
        }
    }

    if let Some(e) = first_error {
        return Err(e);
    }

    Ok(())
}

async fn download_file<F>(
    client: &reqwest::Client,
    model_dir: &Path,
    file: &ModelFile,
    file_index: usize,
    file_count: usize,
    on_progress: &Arc<F>,
    cancel: &CancellationToken,
) -> Result<()>
where
    F: Fn(DownloadProgress),
{
    let dest = model_dir.join(&file.name);

    // Already complete?
    if let Ok(meta) = std::fs::metadata(&dest) {
        let size_ok = file.size == 0 || meta.len() == file.size;
        if size_ok {
            on_progress(DownloadProgress {
                file_index,
                file_count,
                filename: file.name.clone(),
                bytes_downloaded: meta.len(),
                bytes_total: file.size,
                already_exists: true,
            });
            return Ok(());
        }
    }

    // Resume from .part file
    let part_path = dest.with_extension(format!(
        "{}.part",
        dest.extension().unwrap_or_default().to_string_lossy()
    ));

    let existing_size = if part_path.exists() {
        std::fs::metadata(&part_path).map(|m| m.len()).unwrap_or(0)
    } else {
        0
    };

    let mut request = client.get(&file.url);
    if existing_size > 0 {
        request = request.header("Range", format!("bytes={}-", existing_size));
    }

    let response = request
        .send()
        .await
        .map_err(|e| KoeError::Config(format!("download {}: {e}", file.name)))?
        .error_for_status()
        .map_err(|e| KoeError::Config(format!("download {}: {e}", file.name)))?;

    let resuming = response.status() == reqwest::StatusCode::PARTIAL_CONTENT;

    let mut out = if resuming && existing_size > 0 {
        on_progress(DownloadProgress {
            file_index,
            file_count,
            filename: file.name.clone(),
            bytes_downloaded: existing_size,
            bytes_total: file.size,
            already_exists: false,
        });
        tokio::fs::OpenOptions::new()
            .append(true)
            .open(&part_path)
            .await
            .map_err(|e| KoeError::Config(format!("open part file: {e}")))?
    } else {
        if let Some(parent) = part_path.parent() {
            tokio::fs::create_dir_all(parent)
                .await
                .map_err(|e| KoeError::Config(format!("create dir: {e}")))?;
        }
        tokio::fs::File::create(&part_path)
            .await
            .map_err(|e| KoeError::Config(format!("create part file: {e}")))?
    };

    let mut downloaded = if resuming { existing_size } else { 0 };
    let mut stream = response.bytes_stream();

    use tokio::io::AsyncWriteExt;
    while let Some(chunk) = stream.next().await {
        if cancel.is_cancelled() {
            return Err(KoeError::Config("cancelled".into()));
        }
        let chunk = chunk.map_err(|e| KoeError::Config(format!("download {}: {e}", file.name)))?;
        out.write_all(&chunk)
            .await
            .map_err(|e| KoeError::Config(format!("write {}: {e}", file.name)))?;
        downloaded += chunk.len() as u64;
        on_progress(DownloadProgress {
            file_index,
            file_count,
            filename: file.name.clone(),
            bytes_downloaded: downloaded,
            bytes_total: file.size,
            already_exists: false,
        });
    }

    out.flush()
        .await
        .map_err(|e| KoeError::Config(format!("flush {}: {e}", file.name)))?;
    drop(out);

    // Verify integrity: use sha256 when available, otherwise check file size
    if !file.sha256.is_empty() {
        let actual_sha = sha256_file(&part_path)?;
        if actual_sha != file.sha256 {
            let _ = std::fs::remove_file(&part_path);
            return Err(KoeError::Config(format!(
                "sha256 mismatch for {}: expected {}, got {}",
                file.name, file.sha256, actual_sha
            )));
        }
    } else if file.size > 0 {
        let actual_size = std::fs::metadata(&part_path)
            .map(|m| m.len())
            .unwrap_or(0);
        if actual_size != file.size {
            let _ = std::fs::remove_file(&part_path);
            return Err(KoeError::Config(format!(
                "size mismatch for {}: expected {}, got {}",
                file.name, file.size, actual_size
            )));
        }
    }

    // Rename .part → final
    std::fs::rename(&part_path, &dest)
        .map_err(|e| KoeError::Config(format!("rename {}: {e}", file.name)))?;

    Ok(())
}

fn sha256_file(path: &Path) -> Result<String> {
    use std::io::{BufReader, Read};
    let f =
        std::fs::File::open(path).map_err(|e| KoeError::Config(format!("open for sha256: {e}")))?;
    let mut reader = BufReader::with_capacity(1024 * 1024, f);
    let mut hasher = Sha256::new();
    let mut buf = [0u8; 1024 * 1024];
    loop {
        let n = reader
            .read(&mut buf)
            .map_err(|e| KoeError::Config(format!("read for sha256: {e}")))?;
        if n == 0 {
            break;
        }
        hasher.update(&buf[..n]);
    }
    Ok(format!("{:x}", hasher.finalize()))
}
