//! Resource benchmark for the offline WeType provider: model-load RSS, steady
//! inference latency, and RSS drift across many runs (leak check).
//!   KOE_WETYPE_MODEL_DIR=/dir cargo test --release --features wetype-offline \
//!     --test wetype_bench_test -- --ignored --nocapture
#![cfg(feature = "wetype-offline")]

use koe_asr::wetype::WeTypeOfflineProvider;
use koe_asr::{AsrConfig, AsrProvider};
use std::time::Instant;

/// Peak resident set size in MB via getrusage(RUSAGE_SELF).ru_maxrss.
/// macOS reports bytes; Linux reports kilobytes.
fn max_rss_mb() -> f64 {
    #[repr(C)]
    #[derive(Default)]
    struct Rusage {
        ru_utime: [i64; 2],
        ru_stime: [i64; 2],
        ru_maxrss: i64,
        rest: [i64; 14],
    }
    extern "C" {
        fn getrusage(who: i32, usage: *mut Rusage) -> i32;
    }
    let mut u = Rusage::default();
    unsafe {
        getrusage(0, &mut u);
    }
    let raw = u.ru_maxrss as f64;
    if cfg!(target_os = "macos") {
        raw / (1024.0 * 1024.0)
    } else {
        raw / 1024.0
    }
}

/// Current resident set size (MB) via `ps -o rss=`. macOS/Linux report KB.
fn cur_rss_mb() -> f64 {
    let pid = std::process::id().to_string();
    let out = std::process::Command::new("ps")
        .args(["-o", "rss=", "-p", &pid])
        .output()
        .expect("ps");
    let kb: f64 = String::from_utf8_lossy(&out.stdout)
        .trim()
        .parse()
        .unwrap_or(0.0);
    kb / 1024.0
}

fn read_wav_pcm_i16(path: &str) -> Vec<i16> {
    let d = std::fs::read(path).expect("read wav");
    let mut i = 12;
    while i + 8 <= d.len() {
        let id = &d[i..i + 4];
        let sz = u32::from_le_bytes([d[i + 4], d[i + 5], d[i + 6], d[i + 7]]) as usize;
        if id == b"data" {
            let body = &d[i + 8..(i + 8 + sz).min(d.len())];
            return body
                .chunks_exact(2)
                .map(|c| i16::from_le_bytes([c[0], c[1]]))
                .collect();
        }
        i += 8 + sz + (sz & 1);
    }
    panic!("no data chunk");
}

#[tokio::test(flavor = "multi_thread")]
#[ignore = "needs KOE_WETYPE_MODEL_DIR"]
async fn bench_resources() {
    let dir = std::env::var("KOE_WETYPE_MODEL_DIR").expect("set KOE_WETYPE_MODEL_DIR");
    let pcm = read_wav_pcm_i16(&format!("{dir}/test_zh.wav"));
    let audio_secs = pcm.len() as f64 / 16000.0;

    let rss_before = cur_rss_mb();
    let mut asr = WeTypeOfflineProvider::new(&dir);
    let t_load = Instant::now();
    asr.connect(&AsrConfig::default()).await.unwrap();
    let load_ms = t_load.elapsed().as_secs_f64() * 1000.0;
    let rss_after_load = cur_rss_mb();

    // steady-state: reuse the one resident model, run many inferences
    let runs = 40;
    let mut times = Vec::with_capacity(runs);
    let mut rss_mid = 0.0;
    for i in 0..runs {
        let t = Instant::now();
        let text = asr.transcribe(&pcm).unwrap();
        times.push(t.elapsed().as_secs_f64() * 1000.0);
        if i == 0 {
            assert!(text.contains("天气很好"), "wrong transcript: {text:?}");
        }
        if i == runs / 2 {
            rss_mid = cur_rss_mb();
        }
    }
    let rss_after = cur_rss_mb();
    let peak = max_rss_mb();
    times.sort_by(|a, b| a.partial_cmp(b).unwrap());
    let median = times[times.len() / 2];
    let min = times[0];
    let max = times[times.len() - 1];
    let rtf = (median / 1000.0) / audio_secs;

    println!("\n──────── WeType offline resource bench ────────");
    println!("audio length        : {audio_secs:.2} s");
    println!("model load (connect) : {load_ms:.0} ms  (one-time)");
    println!(
        "inference latency    : median {median:.0} ms  (min {min:.0} / max {max:.0}), {runs} runs",
    );
    println!("real-time factor     : {rtf:.3}x  (lower is faster; <1 = faster than realtime)");
    println!("RSS before load      : {rss_before:.0} MB");
    println!("RSS after load       : {rss_after_load:.0} MB   (resident model ≈ {:.0} MB)", rss_after_load - rss_before);
    println!("RSS mid-run          : {rss_mid:.0} MB");
    println!(
        "RSS after {runs} runs    : {rss_after:.0} MB   (drift vs after-load: {:+.1} MB — leak check)",
        rss_after - rss_after_load
    );
    println!("peak RSS (load spike): {peak:.0} MB");
    println!("───────────────────────────────────────────────");

    asr.close().await.unwrap();
}
