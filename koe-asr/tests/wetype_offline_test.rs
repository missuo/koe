//! End-to-end test for the offline WeType embed_140m provider.
//!
//! Needs the model files locally; set the directory (containing
//! `embed140m.koepack`, `dict.decoder.utf8.txt`, and `test_zh.wav`) via
//!   KOE_WETYPE_MODEL_DIR=/path/to/dir cargo test --features wetype-offline -- --ignored
#![cfg(feature = "wetype-offline")]

use koe_asr::wetype::WeTypeOfflineProvider;
use koe_asr::{AsrConfig, AsrEvent, AsrProvider};

/// Minimal WAV reader: returns 16-bit PCM samples as little-endian bytes.
fn read_wav_pcm(path: &str) -> Vec<u8> {
    let d = std::fs::read(path).expect("read wav");
    // find "data" chunk
    let mut i = 12;
    while i + 8 <= d.len() {
        let id = &d[i..i + 4];
        let sz = u32::from_le_bytes([d[i + 4], d[i + 5], d[i + 6], d[i + 7]]) as usize;
        if id == b"data" {
            return d[i + 8..(i + 8 + sz).min(d.len())].to_vec();
        }
        i += 8 + sz + (sz & 1);
    }
    panic!("no data chunk in {path}");
}

#[tokio::test]
#[ignore = "needs KOE_WETYPE_MODEL_DIR with the ~135MB embed140m.koepack"]
async fn transcribes_test_zh() {
    let dir = std::env::var("KOE_WETYPE_MODEL_DIR")
        .expect("set KOE_WETYPE_MODEL_DIR to the model directory");
    let pcm = read_wav_pcm(&format!("{dir}/test_zh.wav"));

    let mut asr = WeTypeOfflineProvider::new(&dir);
    asr.connect(&AsrConfig::default()).await.unwrap();
    // feed in ~100ms chunks to exercise buffering
    for chunk in pcm.chunks(3200) {
        asr.send_audio(chunk).await.unwrap();
    }
    asr.finish_input().await.unwrap();

    let mut text = String::new();
    loop {
        match asr.next_event().await.unwrap() {
            AsrEvent::Final(t) => {
                text = t;
                break;
            }
            AsrEvent::Closed(_) => break,
            _ => {}
        }
    }
    asr.close().await.unwrap();

    println!("transcript = {text:?}");
    assert!(
        text.contains("天气很好"),
        "expected '今天天气很好', got {text:?}"
    );
}
