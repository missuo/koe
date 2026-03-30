use std::collections::HashMap;
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
const CHECKSUM_CACHE_FILE: &str = ".koe-checksum.json";

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

/// Controls how `model_status()` verifies file integrity.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum VerifyMode {
    /// Use cached sha256 if valid (mtime matches), compute on cache miss, write back.
    Normal,
    /// Use cached sha256 if valid, return false on cache miss (never compute).
    CacheOnly,
    /// Ignore cache, always compute sha256, write back.
    ForceVerify,
}

/// Per-file checksum cache entry stored in `.koe-checksum.json`.
#[derive(Debug, Serialize, Deserialize, Clone)]
struct ChecksumEntry {
    /// File mtime (seconds since epoch) at the time sha256 was computed.
    mtime: i64,
    /// Hex-encoded sha256 hash.
    sha256: String,
}

fn load_checksum_cache(path: &Path) -> Option<HashMap<String, ChecksumEntry>> {
    let content = std::fs::read_to_string(path).ok()?;
    serde_json::from_str(&content).ok()
}

fn write_checksum_cache(path: &Path, cache: &HashMap<String, ChecksumEntry>) -> Result<()> {
    let json = serde_json::to_string_pretty(cache)
        .map_err(|e| KoeError::Config(format!("serialize checksum cache: {e}")))?;
    std::fs::write(path, json)
        .map_err(|e| KoeError::Config(format!("write checksum cache: {e}")))?;
    Ok(())
}

fn mtime_secs(meta: &std::fs::Metadata) -> i64 {
    meta.modified()
        .ok()
        .and_then(|t| t.duration_since(std::time::UNIX_EPOCH).ok())
        .map(|d| d.as_secs() as i64)
        .unwrap_or(0)
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

/// Unified model status check with configurable verification depth.
pub fn model_status(model_dir: &Path, mode: VerifyMode) -> ModelStatus {
    let model = match load_manifest(model_dir) {
        Some(m) => m,
        None => return ModelStatus::NotInstalled,
    };

    if model.manifest.files.is_empty() {
        return ModelStatus::Installed;
    }

    let cache_path = model_dir.join(CHECKSUM_CACHE_FILE);
    let cache: HashMap<String, ChecksumEntry> = match mode {
        VerifyMode::ForceVerify => HashMap::new(),
        _ => load_checksum_cache(&cache_path).unwrap_or_default(),
    };

    let mut found = 0usize;
    let total = model.manifest.files.len();
    let mut new_cache = cache.clone();
    let mut cache_dirty = false;

    for file in &model.manifest.files {
        if check_file(model_dir, file, mode, &cache, &mut new_cache, &mut cache_dirty) {
            found += 1;
        }
    }

    if cache_dirty && mode != VerifyMode::CacheOnly {
        let _ = write_checksum_cache(&cache_path, &new_cache);
    }

    if found == total {
        ModelStatus::Installed
    } else if found > 0 {
        ModelStatus::Incomplete
    } else {
        ModelStatus::NotInstalled
    }
}

/// Check a single file against its manifest entry.
fn check_file(
    model_dir: &Path,
    file: &ModelFile,
    mode: VerifyMode,
    cache: &HashMap<String, ChecksumEntry>,
    new_cache: &mut HashMap<String, ChecksumEntry>,
    cache_dirty: &mut bool,
) -> bool {
    let file_path = model_dir.join(&file.name);
    let meta = match std::fs::metadata(&file_path) {
        Ok(m) => m,
        Err(_) => return false,
    };

    // manifest 有 size → 比较
    if file.size > 0 && meta.len() != file.size {
        return false;
    }

    // manifest 无 sha → size 通过即可
    if file.sha256.is_empty() {
        return true;
    }

    // manifest 有 sha → 需要验证
    let mtime = mtime_secs(&meta);

    // 检查缓存（ForceVerify 传入空 cache，不会命中）
    if let Some(entry) = cache.get(&file.name) {
        if entry.mtime == mtime {
            return entry.sha256 == file.sha256;
        }
    }

    // 缓存无效
    if mode == VerifyMode::CacheOnly {
        return false;
    }

    // 计算 sha256
    match sha256_file(&file_path) {
        Ok(hash) => {
            let ok = hash == file.sha256;
            new_cache.insert(
                file.name.clone(),
                ChecksumEntry {
                    mtime,
                    sha256: hash,
                },
            );
            *cache_dirty = true;
            ok
        }
        Err(_) => false,
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
            // Verify sha256 if available — catches same-size corruption
            if !file.sha256.is_empty() {
                if let Ok(hash) = sha256_file(&dest) {
                    if hash != file.sha256 {
                        log::warn!(
                            "file {} has correct size but wrong sha256, re-downloading",
                            file.name
                        );
                        let _ = std::fs::remove_file(&dest);
                        // fall through to download
                    } else {
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
                // sha256 read failed — fall through to re-download
            } else {
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
    let mut reader = BufReader::with_capacity(128 * 1024, f);
    let mut hasher = Sha256::new();
    let mut buf = vec![0u8; 128 * 1024]; // heap-allocated, safe for GCD worker threads
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

#[cfg(test)]
mod tests {
    use super::*;
    use std::fs;

    /// Create a temp model dir with a manifest and a file that has the
    /// correct size but wrong content (wrong sha256).
    fn setup_corrupted_model() -> (PathBuf, String) {
        let tmp = std::env::temp_dir().join(format!(
            "koe-model-test-{}",
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .unwrap()
                .as_nanos()
        ));
        fs::create_dir_all(&tmp).unwrap();

        let correct_content = b"correct model data here";
        let corrupt_content = b"corrupt model data xxxx"; // same length, different content
        assert_eq!(correct_content.len(), corrupt_content.len());

        let correct_sha = {
            let mut hasher = Sha256::new();
            hasher.update(correct_content);
            format!("{:x}", hasher.finalize())
        };

        let manifest = ModelManifest {
            provider: "test".into(),
            description: "test model".into(),
            repo: "test/model".into(),
            files: vec![ModelFile {
                name: "model.bin".into(),
                size: correct_content.len() as u64,
                sha256: correct_sha.clone(),
                url: String::new(),
            }],
        };

        fs::write(
            tmp.join(MANIFEST_FILE),
            serde_json::to_string(&manifest).unwrap(),
        )
        .unwrap();

        // Write the CORRUPTED file (same size, wrong hash)
        fs::write(tmp.join("model.bin"), corrupt_content).unwrap();

        (tmp, correct_sha)
    }

    #[test]
    fn cache_only_does_not_detect_corruption() {
        // CacheOnly without prior verification: sha is uncached, returns false
        let (tmp, _) = setup_corrupted_model();

        let status = model_status(&tmp, VerifyMode::CacheOnly);
        // CacheOnly can't verify — no cache yet, so files with sha fail
        assert_ne!(status, ModelStatus::Installed);

        let _ = fs::remove_dir_all(&tmp);
    }

    #[test]
    fn normal_mode_detects_corruption() {
        let (tmp, _) = setup_corrupted_model();

        let status = model_status(&tmp, VerifyMode::Normal);
        assert_ne!(status, ModelStatus::Installed);

        let _ = fs::remove_dir_all(&tmp);
    }

    #[test]
    fn force_verify_detects_corruption() {
        let (tmp, _) = setup_corrupted_model();

        let status = model_status(&tmp, VerifyMode::ForceVerify);
        assert_ne!(status, ModelStatus::Installed);

        let _ = fs::remove_dir_all(&tmp);
    }

    #[test]
    fn normal_mode_valid_file() {
        let tmp = std::env::temp_dir().join(format!(
            "koe-model-test-valid-{}",
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .unwrap()
                .as_nanos()
        ));
        fs::create_dir_all(&tmp).unwrap();

        let content = b"valid model content";
        let sha = {
            let mut hasher = Sha256::new();
            hasher.update(content);
            format!("{:x}", hasher.finalize())
        };

        let manifest = ModelManifest {
            provider: "test".into(),
            description: "test".into(),
            repo: "test/model".into(),
            files: vec![ModelFile {
                name: "model.bin".into(),
                size: content.len() as u64,
                sha256: sha,
                url: String::new(),
            }],
        };

        fs::write(
            tmp.join(MANIFEST_FILE),
            serde_json::to_string(&manifest).unwrap(),
        )
        .unwrap();
        fs::write(tmp.join("model.bin"), content).unwrap();

        assert_eq!(model_status(&tmp, VerifyMode::Normal), ModelStatus::Installed);
        assert_eq!(model_status(&tmp, VerifyMode::ForceVerify), ModelStatus::Installed);

        let _ = fs::remove_dir_all(&tmp);
    }

    #[test]
    fn no_sha256_all_modes_accept_by_size() {
        let tmp = std::env::temp_dir().join(format!(
            "koe-model-test-nosha-{}",
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .unwrap()
                .as_nanos()
        ));
        fs::create_dir_all(&tmp).unwrap();

        let content = b"some model data";
        let manifest = ModelManifest {
            provider: "test".into(),
            description: "test".into(),
            repo: "test/model".into(),
            files: vec![ModelFile {
                name: "model.bin".into(),
                size: content.len() as u64,
                sha256: String::new(), // no sha256
                url: String::new(),
            }],
        };

        fs::write(
            tmp.join(MANIFEST_FILE),
            serde_json::to_string(&manifest).unwrap(),
        )
        .unwrap();
        fs::write(tmp.join("model.bin"), content).unwrap();

        assert_eq!(model_status(&tmp, VerifyMode::CacheOnly), ModelStatus::Installed);
        assert_eq!(model_status(&tmp, VerifyMode::Normal), ModelStatus::Installed);

        let _ = fs::remove_dir_all(&tmp);
    }

    #[test]
    fn normal_writes_cache_then_cache_only_hits() {
        let (tmp, _) = setup_corrupted_model();

        // Normal computes sha and writes cache
        let status1 = model_status(&tmp, VerifyMode::Normal);
        assert_ne!(status1, ModelStatus::Installed); // corrupted

        // Cache file should exist now
        assert!(tmp.join(CHECKSUM_CACHE_FILE).exists());

        // CacheOnly should hit the cache and return same result
        let status2 = model_status(&tmp, VerifyMode::CacheOnly);
        assert_eq!(status1, status2);

        let _ = fs::remove_dir_all(&tmp);
    }

    #[test]
    fn cache_hit_for_valid_model() {
        let tmp = std::env::temp_dir().join(format!(
            "koe-model-test-cache-{}",
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .unwrap()
                .as_nanos()
        ));
        fs::create_dir_all(&tmp).unwrap();

        let content = b"valid cached model";
        let sha = {
            let mut hasher = Sha256::new();
            hasher.update(content);
            format!("{:x}", hasher.finalize())
        };

        let manifest = ModelManifest {
            provider: "test".into(),
            description: "test".into(),
            repo: "test/model".into(),
            files: vec![ModelFile {
                name: "model.bin".into(),
                size: content.len() as u64,
                sha256: sha,
                url: String::new(),
            }],
        };

        fs::write(tmp.join(MANIFEST_FILE), serde_json::to_string(&manifest).unwrap()).unwrap();
        fs::write(tmp.join("model.bin"), content).unwrap();

        // Normal: compute + cache
        assert_eq!(model_status(&tmp, VerifyMode::Normal), ModelStatus::Installed);
        assert!(tmp.join(CHECKSUM_CACHE_FILE).exists());

        // CacheOnly: cache hit
        assert_eq!(model_status(&tmp, VerifyMode::CacheOnly), ModelStatus::Installed);

        let _ = fs::remove_dir_all(&tmp);
    }

    #[test]
    fn cache_only_returns_not_installed_for_missing_files() {
        let tmp = std::env::temp_dir().join(format!(
            "koe-model-test-missing-{}",
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .unwrap()
                .as_nanos()
        ));
        fs::create_dir_all(&tmp).unwrap();

        let manifest = ModelManifest {
            provider: "test".into(),
            description: "test".into(),
            repo: "test/model".into(),
            files: vec![ModelFile {
                name: "model.bin".into(),
                size: 100,
                sha256: "abc".into(),
                url: String::new(),
            }],
        };
        fs::write(tmp.join(MANIFEST_FILE), serde_json::to_string(&manifest).unwrap()).unwrap();
        // No model.bin file

        assert_eq!(model_status(&tmp, VerifyMode::CacheOnly), ModelStatus::NotInstalled);

        let _ = fs::remove_dir_all(&tmp);
    }

    #[test]
    fn force_verify_ignores_existing_cache() {
        let (tmp, _) = setup_corrupted_model();

        // Build a fake cache that claims Installed
        let mut fake_cache = HashMap::new();
        let meta = fs::metadata(tmp.join("model.bin")).unwrap();
        fake_cache.insert(
            "model.bin".to_string(),
            ChecksumEntry {
                mtime: mtime_secs(&meta),
                sha256: "fake_matching_sha_that_would_fool_cache".into(),
            },
        );
        write_checksum_cache(&tmp.join(CHECKSUM_CACHE_FILE), &fake_cache).unwrap();

        // Normal would trust the cache (mtime matches) — but the cached sha
        // doesn't match the manifest sha, so it still fails
        // ForceVerify ignores cache entirely, recomputes sha
        let status = model_status(&tmp, VerifyMode::ForceVerify);
        assert_ne!(status, ModelStatus::Installed);

        let _ = fs::remove_dir_all(&tmp);
    }

    #[test]
    fn remove_model_files_deletes_cache() {
        let tmp = std::env::temp_dir().join(format!(
            "koe-model-test-remove-{}",
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .unwrap()
                .as_nanos()
        ));
        fs::create_dir_all(&tmp).unwrap();

        let content = b"model data for remove test";
        let sha = {
            let mut hasher = Sha256::new();
            hasher.update(content);
            format!("{:x}", hasher.finalize())
        };
        let manifest = ModelManifest {
            provider: "test".into(),
            description: "test".into(),
            repo: "test/model".into(),
            files: vec![ModelFile {
                name: "model.bin".into(),
                size: content.len() as u64,
                sha256: sha,
                url: String::new(),
            }],
        };
        fs::write(tmp.join(MANIFEST_FILE), serde_json::to_string(&manifest).unwrap()).unwrap();
        fs::write(tmp.join("model.bin"), content).unwrap();

        // Build cache
        assert_eq!(model_status(&tmp, VerifyMode::Normal), ModelStatus::Installed);
        assert!(tmp.join(CHECKSUM_CACHE_FILE).exists());

        // Remove model files (keeps manifest)
        let removed = remove_model_files(&tmp).unwrap();
        assert!(removed >= 1);
        assert!(!tmp.join(CHECKSUM_CACHE_FILE).exists());
        assert!(tmp.join(MANIFEST_FILE).exists());

        assert_eq!(model_status(&tmp, VerifyMode::CacheOnly), ModelStatus::NotInstalled);

        let _ = fs::remove_dir_all(&tmp);
    }

    #[test]
    fn mtime_change_invalidates_cache() {
        let tmp = std::env::temp_dir().join(format!(
            "koe-model-test-mtime-{}",
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .unwrap()
                .as_nanos()
        ));
        fs::create_dir_all(&tmp).unwrap();

        let content = b"original content";
        let sha = {
            let mut hasher = Sha256::new();
            hasher.update(content);
            format!("{:x}", hasher.finalize())
        };
        let manifest = ModelManifest {
            provider: "test".into(),
            description: "test".into(),
            repo: "test/model".into(),
            files: vec![ModelFile {
                name: "model.bin".into(),
                size: content.len() as u64,
                sha256: sha,
                url: String::new(),
            }],
        };
        fs::write(tmp.join(MANIFEST_FILE), serde_json::to_string(&manifest).unwrap()).unwrap();
        fs::write(tmp.join("model.bin"), content).unwrap();

        // Build cache
        assert_eq!(model_status(&tmp, VerifyMode::Normal), ModelStatus::Installed);

        // Overwrite file with different content (same size, different sha, new mtime)
        // Use sleep to ensure mtime changes (filesystem granularity)
        std::thread::sleep(std::time::Duration::from_secs(1));
        fs::write(tmp.join("model.bin"), b"modified content").unwrap();

        // CacheOnly: mtime changed → cache invalid → returns false
        assert_ne!(model_status(&tmp, VerifyMode::CacheOnly), ModelStatus::Installed);

        // Normal: recomputes sha, finds mismatch
        assert_ne!(model_status(&tmp, VerifyMode::Normal), ModelStatus::Installed);

        let _ = fs::remove_dir_all(&tmp);
    }

    #[test]
    fn cache_only_no_cache_file_does_not_panic() {
        // Simulates what scan_models_json does: CacheOnly on a model
        // directory that has never been verified (no .koe-checksum.json).
        let tmp = std::env::temp_dir().join(format!(
            "koe-model-test-nocache-{}",
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .unwrap()
                .as_nanos()
        ));
        fs::create_dir_all(&tmp).unwrap();

        let content = b"installed model data";
        let sha = {
            let mut hasher = Sha256::new();
            hasher.update(content);
            format!("{:x}", hasher.finalize())
        };
        let manifest = ModelManifest {
            provider: "test".into(),
            description: "test".into(),
            repo: "test/model".into(),
            files: vec![ModelFile {
                name: "model.bin".into(),
                size: content.len() as u64,
                sha256: sha,
                url: String::new(),
            }],
        };
        fs::write(tmp.join(MANIFEST_FILE), serde_json::to_string(&manifest).unwrap()).unwrap();
        fs::write(tmp.join("model.bin"), content).unwrap();

        // No .koe-checksum.json exists
        assert!(!tmp.join(CHECKSUM_CACHE_FILE).exists());

        // CacheOnly should NOT panic — returns NotInstalled because
        // cache miss for files with sha256 in manifest
        let status = model_status(&tmp, VerifyMode::CacheOnly);
        assert_eq!(status, ModelStatus::NotInstalled);

        // No cache file should have been written
        assert!(!tmp.join(CHECKSUM_CACHE_FILE).exists());

        let _ = fs::remove_dir_all(&tmp);
    }
}
