use crate::errors::{KoeError, Result};
use std::path::Path;

/// Load dictionary entries from a text file.
/// Skips empty lines and lines starting with '#'.
/// Returns deduplicated entries preserving order.
pub fn load_dictionary(path: &Path) -> Result<Vec<String>> {
    if !path.exists() {
        log::info!("dictionary file not found: {}, using empty", path.display());
        return Ok(vec![]);
    }

    let content = std::fs::read_to_string(path)
        .map_err(|e| KoeError::Config(format!("read {}: {e}", path.display())))?;

    let mut seen = std::collections::HashSet::new();
    let entries: Vec<String> = content
        .lines()
        .map(|l| l.trim())
        .filter(|l| !l.is_empty() && !l.starts_with('#'))
        .filter(|l| seen.insert(l.to_string()))
        .map(|l| l.to_string())
        .collect();

    log::info!("loaded {} dictionary entries from {}", entries.len(), path.display());
    Ok(entries)
}
