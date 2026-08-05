//! WeType (微信输入法 / WeChat Input Method) **offline** voice ASR provider.
//!
//! Pure-Rust reimplementation of Tencent's on-device `embed_140m` decoder
//! (`embed_140m_..._merge_4.kv.conv1d.dyQu.onnx.xnet`, a 40-layer pre-norm
//! Transformer CTC model over a 10502-token vocab). Reverse-engineered by
//! static analysis of the WeType 3.5.2 iOS app; runs 100% locally with **no
//! network, no Python, and no external inference engine** — just `ndarray`
//! (matmuls) and `rustfft` (the FBank front-end).
//!
//! ## Model files
//! The provider needs a directory containing:
//!   * `embed140m.koepack`      — packed weights (int8 + per-tensor scale, ~135 MB),
//!                                produced by `export_koepack.py` from the `.onnx.xnet`.
//!   * `dict.decoder.utf8.txt`  — the 10502-line vocabulary (`id token flags`).
//!
//! ## Pipeline (all verified to transcribe correct Chinese)
//!   1. **FBank**: pre-emphasis 0.97, 400/160 Hamming frames, 512-pt power
//!      spectrum, 39 area-normalized mel filters (`1127·ln(1+f/700)`, 0–8 kHz),
//!      natural-**log** compression, + 1 log-energy channel = 40 dims.
//!   2. **Online CMS**: per-utterance running-mean subtraction (window 50) —
//!      normalizes level so quiet recordings don't collapse to all-blank.
//!   3. **Conv2D subsampling front-end** (÷5 in time) → 512-dim linear.
//!   4. **40× pre-norm Transformer** (H=8, HD=64, FFN=2048, GELU-tanh, LN eps 1e-6).
//!   5. **CTC greedy** decode over the 10502 vocab (blank = id 0).
//!
//! Weight layout is "A" (XNET stores linear weights out-major `[out,in]`; the
//! packer transposes them to `[in,out]` so the forward pass is a plain `x·W`).
//!
//! ## Usage
//! ```no_run
//! # #[cfg(feature = "wetype-offline")]
//! # async fn ex() -> Result<(), koe_asr::AsrError> {
//! use koe_asr::{AsrProvider, AsrConfig, AsrEvent};
//! use koe_asr::wetype::WeTypeOfflineProvider;
//! let mut asr = WeTypeOfflineProvider::new("/path/to/model_dir");
//! asr.connect(&AsrConfig::default()).await?;
//! // asr.send_audio(&pcm16le_mono_16k).await?;
//! asr.finish_input().await?;
//! if let AsrEvent::Final(text) = asr.next_event().await? { println!("{text}"); }
//! # Ok(()) }
//! ```

use crate::config::AsrConfig;
use crate::error::{AsrError, Result};
use crate::event::AsrEvent;
use crate::provider::AsrProvider;

use std::collections::HashMap;
use std::collections::VecDeque;
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex};

use ndarray::{s, Array1, Array2, Array3, Axis};
use rustfft::{num_complex::Complex, FftPlanner};

const D: usize = 512;
const H: usize = 8;
const HD: usize = 64;
const VOCAB: usize = 10502;
const NLAYERS: usize = 40;

/// Process-global single-entry cache of the loaded model, keyed by directory.
/// Holds a strong `Arc` so the model survives between sessions (no reload lag);
/// with int8-resident weights this is ≈135 MB.
static MODEL_CACHE: Mutex<Option<(PathBuf, Arc<Model>)>> = Mutex::new(None);

// ---------------------------------------------------------------------------
// Model files & on-demand download
// ---------------------------------------------------------------------------

/// Default host serving the model assets (`<base>/embed140m.koepack`, `<base>/dict.decoder.utf8.txt`).
pub const DEFAULT_BASE_URL: &str = "https://model.koe.li";
/// File name of the packed weights inside the model directory.
pub const PACK_FILE: &str = "embed140m.koepack";
/// File name of the decoder vocabulary inside the model directory.
pub const DICT_FILE: &str = "dict.decoder.utf8.txt";
/// SHA-256 (hex) of the current `embed140m.koepack` (134,809,044 bytes).
pub const PACK_SHA256: &str = "8b01be7ca614b399e6a4d90a9774faf47ac9c62f982d0b734cd134ddac999dae";
/// SHA-256 (hex) of the current `dict.decoder.utf8.txt` (129,706 bytes).
pub const DICT_SHA256: &str = "08a16004cfcf5b9f1668e055f3100de9b8a44f88541819def2bbd56bfd42f484";

/// One downloadable model file plus its expected SHA-256 (hex).
#[derive(Clone)]
pub struct ModelAsset {
    pub file: String,
    pub url: String,
    pub sha256: String,
}

/// Where to fetch the model from. The host is left to the caller (GitHub
/// Releases, Cloudflare R2, …); build one with [`WeTypeModelSpec::from_base_url`].
#[derive(Clone)]
pub struct WeTypeModelSpec {
    pub assets: Vec<ModelAsset>,
}

impl WeTypeModelSpec {
    /// Assets served under `<base>/embed140m.koepack` and `<base>/dict.decoder.utf8.txt`.
    /// `base` may be any HTTPS prefix (trailing slash optional).
    pub fn from_base_url(base: &str) -> Self {
        let b = base.trim_end_matches('/');
        Self {
            assets: vec![
                ModelAsset {
                    file: PACK_FILE.into(),
                    url: format!("{b}/{PACK_FILE}"),
                    sha256: PACK_SHA256.into(),
                },
                ModelAsset {
                    file: DICT_FILE.into(),
                    url: format!("{b}/{DICT_FILE}"),
                    sha256: DICT_SHA256.into(),
                },
            ],
        }
    }
}

fn sha256_hex(path: &Path) -> Option<String> {
    use sha2::{Digest, Sha256};
    let mut f = std::fs::File::open(path).ok()?;
    let mut hasher = Sha256::new();
    let mut buf = [0u8; 1 << 16];
    loop {
        let n = std::io::Read::read(&mut f, &mut buf).ok()?;
        if n == 0 {
            break;
        }
        hasher.update(&buf[..n]);
    }
    Some(hex::encode(hasher.finalize()))
}

/// True if `dir` already holds every asset with a matching SHA-256.
pub fn model_present(dir: &Path, spec: &WeTypeModelSpec) -> bool {
    spec.assets.iter().all(|a| {
        sha256_hex(&dir.join(&a.file))
            .map(|h| h.eq_ignore_ascii_case(&a.sha256))
            .unwrap_or(false)
    })
}

/// Ensure every model asset is present in `dir`, downloading any that are
/// missing or whose SHA-256 does not match. `progress(file, done, total)` is
/// called periodically while downloading (`total` may be `None` if the server
/// omits Content-Length). Each download goes to a `*.part` file and is
/// atomically renamed only after its hash verifies, so a killed download never
/// leaves a corrupt model in place.
pub async fn ensure_model<F>(dir: &Path, spec: &WeTypeModelSpec, mut progress: F) -> Result<()>
where
    F: FnMut(&str, u64, Option<u64>),
{
    use futures_util::StreamExt;
    use std::io::Write;
    std::fs::create_dir_all(dir)
        .map_err(|e| AsrError::Protocol(format!("mkdir {}: {e}", dir.display())))?;
    let client = reqwest::Client::new();
    for a in &spec.assets {
        let dest = dir.join(&a.file);
        if sha256_hex(&dest)
            .map(|h| h.eq_ignore_ascii_case(&a.sha256))
            .unwrap_or(false)
        {
            continue; // already present & verified
        }
        let resp = client
            .get(&a.url)
            .send()
            .await
            .map_err(|e| AsrError::Connection(format!("GET {}: {e}", a.url)))?;
        if !resp.status().is_success() {
            return Err(AsrError::Connection(format!(
                "GET {} -> HTTP {}",
                a.url,
                resp.status()
            )));
        }
        let total = resp.content_length();
        let part = dir.join(format!("{}.part", a.file));
        let mut f = std::fs::File::create(&part)
            .map_err(|e| AsrError::Protocol(format!("create {}: {e}", part.display())))?;
        let mut done: u64 = 0;
        let mut stream = resp.bytes_stream();
        while let Some(chunk) = stream.next().await {
            let chunk =
                chunk.map_err(|e| AsrError::Connection(format!("stream {}: {e}", a.url)))?;
            f.write_all(&chunk)
                .map_err(|e| AsrError::Protocol(format!("write {}: {e}", part.display())))?;
            done += chunk.len() as u64;
            progress(&a.file, done, total);
        }
        f.flush().ok();
        drop(f);
        let got = sha256_hex(&part)
            .ok_or_else(|| AsrError::Protocol(format!("hash {} failed", part.display())))?;
        if !got.eq_ignore_ascii_case(&a.sha256) {
            let _ = std::fs::remove_file(&part);
            return Err(AsrError::Protocol(format!(
                "sha256 mismatch for {}: expected {}, got {got}",
                a.file, a.sha256
            )));
        }
        std::fs::rename(&part, &dest)
            .map_err(|e| AsrError::Protocol(format!("rename -> {}: {e}", dest.display())))?;
    }
    Ok(())
}

// ---------------------------------------------------------------------------
// Weight container
// ---------------------------------------------------------------------------

struct Conv {
    /// weight reshaped to [Co, Cin*kh*kw]
    w: Array2<f32>,
    kh: usize,
    kw: usize,
}

/// INT8-resident linear weight, stored (out,in) as in the pack. Kept quantized
/// in RAM (≈¼ the size of f32) and dequantized into a transient scratch matrix
/// per matmul — the conversion is ~0.5% of the gemm cost, so this trades a
/// negligible amount of CPU for a 4× smaller resident model.
struct Lin {
    w: Vec<i8>,
    scale: f32,
    out: usize,
    inp: usize,
}

impl Lin {
    /// `x[T,in] · W`, where the effective weight `W[in,out] = stored[out,in].Tᵀ · scale`
    /// (layout A). Returns `[T,out]`.
    fn matmul(&self, x: &Array2<f32>) -> Array2<f32> {
        let wf: Vec<f32> = self.w.iter().map(|&b| b as f32).collect();
        let w = Array2::from_shape_vec((self.out, self.inp), wf).expect("lin shape");
        let mut y = x.dot(&w.t()); // [T,out]
        let s = self.scale;
        y.mapv_inplace(|v| v * s);
        y
    }
    /// `x · W + bias`.
    fn matmul_bias(&self, x: &Array2<f32>, bias: &Array1<f32>) -> Array2<f32> {
        self.matmul(x) + bias
    }
}

struct Layer {
    pnw: Array1<f32>,
    pnb: Array1<f32>,
    mnw: Array1<f32>,
    mnb: Array1<f32>,
    q: Lin,
    k: Lin,
    v: Lin,
    o: Lin,
    f1: Lin,
    f1b: Array1<f32>,
    f2: Lin,
    f2b: Array1<f32>,
}

struct Model {
    fc0: Conv,
    fc1: Conv,
    fc2: Conv,
    flin: Lin, // (512,3840) -> in=3840,out=512
    flb: Array1<f32>,
    layers: Vec<Layer>,
    ow: Lin, // (10502,512) -> in=512,out=10502
    ob: Array1<f32>,
    vocab: Vec<String>,
}

// ---------------------------------------------------------------------------
// .koepack loader
// ---------------------------------------------------------------------------

struct PackReader<'a> {
    d: &'a [u8],
    p: usize,
}
impl<'a> PackReader<'a> {
    fn u32(&mut self) -> Result<u32> {
        let e = self.p + 4;
        let b = self
            .d
            .get(self.p..e)
            .ok_or_else(|| AsrError::Protocol("koepack truncated".into()))?;
        self.p = e;
        Ok(u32::from_le_bytes([b[0], b[1], b[2], b[3]]))
    }
    fn u8(&mut self) -> Result<u8> {
        let b = *self
            .d
            .get(self.p)
            .ok_or_else(|| AsrError::Protocol("koepack truncated".into()))?;
        self.p += 1;
        Ok(b)
    }
    fn f32(&mut self) -> Result<f32> {
        Ok(f32::from_bits(self.u32()?))
    }
    fn bytes(&mut self, n: usize) -> Result<&'a [u8]> {
        let e = self.p + n;
        let b = self
            .d
            .get(self.p..e)
            .ok_or_else(|| AsrError::Protocol("koepack truncated".into()))?;
        self.p = e;
        Ok(b)
    }
}

/// One parsed tensor: either raw fp32 (dtype 0) or int8+scale (dtype 2).
enum Raw {
    F32 { dims: Vec<usize>, data: Vec<f32> },
    /// Raw int8 (NOT dequantized) + scale, shape (out, in) as stored.
    I8 {
        out: usize,
        inp: usize,
        scale: f32,
        data: Vec<i8>,
    },
}

fn load_pack(path: &Path) -> Result<HashMap<String, Raw>> {
    let d = std::fs::read(path)
        .map_err(|e| AsrError::Protocol(format!("read koepack {}: {e}", path.display())))?;
    if d.get(0..4) != Some(b"KOE1") {
        return Err(AsrError::Protocol("bad koepack magic".into()));
    }
    let mut r = PackReader { d: &d, p: 4 };
    let n = r.u32()? as usize;
    let mut out = HashMap::with_capacity(n);
    for _ in 0..n {
        let nl = r.u32()? as usize;
        let name = String::from_utf8_lossy(r.bytes(nl)?).into_owned();
        let dt = r.u8()?;
        if dt == 0 {
            let nd = r.u8()? as usize;
            let mut dims = Vec::with_capacity(nd);
            let mut prod = 1usize;
            for _ in 0..nd {
                let x = r.u32()? as usize;
                dims.push(x);
                prod *= x;
            }
            let raw = r.bytes(prod * 4)?;
            let mut data = Vec::with_capacity(prod);
            for c in raw.chunks_exact(4) {
                data.push(f32::from_le_bytes([c[0], c[1], c[2], c[3]]));
            }
            out.insert(name, Raw::F32 { dims, data });
        } else if dt == 2 {
            let outd = r.u32()? as usize;
            let inp = r.u32()? as usize;
            let scale = r.f32()?;
            let raw = r.bytes(outd * inp)?;
            let data: Vec<i8> = raw.iter().map(|&b| b as i8).collect();
            out.insert(
                name,
                Raw::I8 {
                    out: outd,
                    inp,
                    scale,
                    data,
                },
            );
        } else {
            return Err(AsrError::Protocol(format!("bad koepack dtype {dt}")));
        }
    }
    Ok(out)
}

/// Take an int8 tensor (stored (out,in) + scale) as a resident [`Lin`].
/// Consumes the entry so no second copy is held during load.
fn lin(raw: &mut HashMap<String, Raw>, name: &str) -> Result<Lin> {
    match raw.remove(name) {
        Some(Raw::I8 {
            out,
            inp,
            scale,
            data,
        }) => Ok(Lin {
            w: data,
            scale,
            out,
            inp,
        }),
        _ => Err(AsrError::Protocol(format!("missing int8 tensor {name}"))),
    }
}
fn vec1(raw: &mut HashMap<String, Raw>, name: &str) -> Result<Array1<f32>> {
    match raw.remove(name) {
        Some(Raw::F32 { data, .. }) => Ok(Array1::from(data)),
        _ => Err(AsrError::Protocol(format!("missing fp32 tensor {name}"))),
    }
}
fn conv(raw: &mut HashMap<String, Raw>, name: &str) -> Result<Conv> {
    match raw.remove(name) {
        Some(Raw::F32 { dims, data }) if dims.len() == 4 => {
            let (co, cin, kh, kw) = (dims[0], dims[1], dims[2], dims[3]);
            let w = Array2::from_shape_vec((co, cin * kh * kw), data)
                .map_err(|e| AsrError::Protocol(format!("{name} conv shape: {e}")))?;
            Ok(Conv { w, kh, kw })
        }
        _ => Err(AsrError::Protocol(format!("missing conv tensor {name}"))),
    }
}

impl Model {
    /// Load `dir`'s model, or return the cached `Arc` if it was already loaded
    /// (single-entry process-global cache). Sharing across sessions removes the
    /// ~250 ms reload lag on every dictation while keeping one resident copy.
    fn load_or_cached(dir: &Path) -> Result<Arc<Model>> {
        {
            let cache = MODEL_CACHE.lock().unwrap();
            if let Some((cached_dir, model)) = cache.as_ref() {
                if cached_dir == dir {
                    return Ok(model.clone());
                }
            }
        }
        let model = Arc::new(Model::load(dir)?);
        *MODEL_CACHE.lock().unwrap() = Some((dir.to_path_buf(), model.clone()));
        Ok(model)
    }

    fn load(dir: &Path) -> Result<Model> {
        let mut raw = load_pack(&dir.join("embed140m.koepack"))?;
        let mut layers = Vec::with_capacity(NLAYERS);
        for i in 0..NLAYERS {
            let k = |s: &str| format!("{i}{s}");
            layers.push(Layer {
                pnw: vec1(&mut raw, &k("pnw"))?,
                pnb: vec1(&mut raw, &k("pnb"))?,
                mnw: vec1(&mut raw, &k("mnw"))?,
                mnb: vec1(&mut raw, &k("mnb"))?,
                q: lin(&mut raw, &k("q"))?,
                k: lin(&mut raw, &k("k"))?,
                v: lin(&mut raw, &k("v"))?,
                o: lin(&mut raw, &k("o"))?,
                f1: lin(&mut raw, &k("f1"))?,
                f1b: vec1(&mut raw, &k("f1b"))?,
                f2: lin(&mut raw, &k("f2"))?,
                f2b: vec1(&mut raw, &k("f2b"))?,
            });
        }
        let vocab = load_vocab(&dir.join("dict.decoder.utf8.txt"))?;
        Ok(Model {
            fc0: conv(&mut raw, "fc0")?,
            fc1: conv(&mut raw, "fc1")?,
            fc2: conv(&mut raw, "fc2")?,
            flin: lin(&mut raw, "flin")?,
            flb: vec1(&mut raw, "flb")?,
            layers,
            ow: lin(&mut raw, "ow")?,
            ob: vec1(&mut raw, "ob")?,
            vocab,
        })
    }
}

fn load_vocab(path: &Path) -> Result<Vec<String>> {
    let txt = std::fs::read_to_string(path)
        .map_err(|e| AsrError::Protocol(format!("read vocab {}: {e}", path.display())))?;
    let mut v = Vec::with_capacity(VOCAB);
    for line in txt.lines() {
        // format: "id token flags" — token is the 2nd whitespace field
        let tok = line.split(' ').nth(1).unwrap_or("").to_string();
        v.push(tok);
    }
    Ok(v)
}

// ---------------------------------------------------------------------------
// FBank + online CMS
// ---------------------------------------------------------------------------

struct FBank {
    fb: Array2<f32>, // [39, 257]
    ham: Vec<f32>,   // [400]
    fft: Arc<dyn rustfft::Fft<f32>>,
}

impl FBank {
    fn new() -> FBank {
        let n_fft = 512usize;
        let win = 400usize;
        let ham: Vec<f32> = (0..win)
            .map(|n| {
                0.54 - 0.46 * (2.0 * std::f32::consts::PI * n as f32 / (win as f32 - 1.0)).cos()
            })
            .collect();
        // mel filterbank: 39 filters, 0..8000 Hz, area-normalized
        let h2m = |f: f64| 1127.0 * (1.0 + f / 700.0).ln();
        let m2h = |m: f64| 700.0 * ((m / 1127.0).exp() - 1.0);
        let nmel = 39usize;
        let (mlo, mhi) = (h2m(0.0), h2m(8000.0));
        let bpt: Vec<f64> = (0..nmel + 2)
            .map(|i| {
                let mel = mlo + (mhi - mlo) * i as f64 / (nmel as f64 + 1.0);
                n_fft as f64 * m2h(mel) / 16000.0
            })
            .collect();
        let mut fb = Array2::<f32>::zeros((nmel, n_fft / 2 + 1));
        for m in 1..=nmel {
            let (l, c, r) = (bpt[m - 1], bpt[m], bpt[m + 1]);
            let k0 = l.floor() as isize;
            let k1 = r.ceil() as isize;
            for k in k0..=k1 {
                if k < 0 || k as usize > n_fft / 2 {
                    continue;
                }
                let kf = k as f64;
                let val = if kf >= l && kf < c {
                    (kf - l) / (c - l)
                } else if kf >= c && kf <= r {
                    (r - kf) / (r - c)
                } else {
                    0.0
                };
                fb[[m - 1, k as usize]] = val as f32;
            }
            let area = (2.0 / (r - l)) as f32;
            for k in 0..=n_fft / 2 {
                fb[[m - 1, k]] *= area;
            }
        }
        let mut planner = FftPlanner::new();
        let fft = planner.plan_fft_forward(n_fft);
        FBank { fb, ham, fft }
    }

    /// samples (f32, from i16) -> features [T,40] with online CMS applied.
    fn compute(&self, sig_in: &[f32]) -> Array2<f32> {
        let win = 400usize;
        let hop = 160usize;
        let n_fft = 512usize;
        // pre-emphasis 0.97
        let mut sig = vec![0f32; sig_in.len()];
        if !sig_in.is_empty() {
            sig[0] = sig_in[0];
            for i in 1..sig_in.len() {
                sig[i] = sig_in[i] - 0.97 * sig_in[i - 1];
            }
        }
        if sig.len() < win {
            return Array2::zeros((0, 40));
        }
        let nfr = 1 + (sig.len() - win) / hop;
        let mut feat = Array2::<f32>::zeros((nfr, 40));
        let mut buf: Vec<Complex<f32>> = vec![Complex { re: 0.0, im: 0.0 }; n_fft];
        for t in 0..nfr {
            let off = t * hop;
            for c in buf.iter_mut() {
                *c = Complex { re: 0.0, im: 0.0 };
            }
            for n in 0..win {
                buf[n].re = sig[off + n] * self.ham[n];
            }
            self.fft.process(&mut buf);
            // power spectrum, 257 bins
            let mut pw = [0f32; 257];
            let mut esum = 0f64;
            for k in 0..257 {
                let p = buf[k].re * buf[k].re + buf[k].im * buf[k].im;
                pw[k] = p;
                esum += p as f64;
            }
            // mel + log
            for m in 0..39 {
                let mut acc = 0f32;
                let row = self.fb.row(m);
                for k in 0..257 {
                    acc += row[k] * pw[k];
                }
                feat[[t, m]] = acc.max(1e-10).ln();
            }
            feat[[t, 39]] = (esum.max(1e-10) as f32).ln();
        }
        online_cms(&mut feat, 50);
        feat
    }
}

/// per-utterance running-mean subtraction (causal window `win`).
fn online_cms(f: &mut Array2<f32>, win: usize) {
    let t = f.nrows();
    let d = f.ncols();
    let orig = f.clone();
    for i in 0..t {
        let a = i.saturating_sub(win - 1);
        let cnt = (i - a + 1) as f32;
        for j in 0..d {
            let mut sum = 0f32;
            for u in a..=i {
                sum += orig[[u, j]];
            }
            f[[i, j]] = orig[[i, j]] - sum / cnt;
        }
    }
}

// ---------------------------------------------------------------------------
// forward pass
// ---------------------------------------------------------------------------

/// conv2d over input [Cin,H,W] -> [Co,Ho,Wo] via im2col + matmul.
fn conv2d(x: &Array3<f32>, c: &Conv, stride: (usize, usize), pad: (usize, usize)) -> Array3<f32> {
    let (cin, ht, wf) = (x.shape()[0], x.shape()[1], x.shape()[2]);
    let (kh, kw) = (c.kh, c.kw);
    let (sh, sw) = stride;
    let (ph, pw) = pad;
    let hp = ht + 2 * ph;
    let wp = wf + 2 * pw;
    let mut xp = Array3::<f32>::zeros((cin, hp, wp));
    for ci in 0..cin {
        for i in 0..ht {
            for j in 0..wf {
                xp[[ci, i + ph, j + pw]] = x[[ci, i, j]];
            }
        }
    }
    let ho = (hp - kh) / sh + 1;
    let wo = (wp - kw) / sw + 1;
    // im2col: [Cin*kh*kw, Ho*Wo]
    let mut cols = Array2::<f32>::zeros((cin * kh * kw, ho * wo));
    for ci in 0..cin {
        for a in 0..kh {
            for b in 0..kw {
                let row = (ci * kh + a) * kw + b;
                for oi in 0..ho {
                    for oj in 0..wo {
                        cols[[row, oi * wo + oj]] = xp[[ci, oi * sh + a, oj * sw + b]];
                    }
                }
            }
        }
    }
    let co = c.w.shape()[0];
    let out = c.w.dot(&cols); // [Co, Ho*Wo]
    out.into_shape_with_order((co, ho, wo)).unwrap()
}

fn layer_norm(x: &Array2<f32>, g: &Array1<f32>, b: &Array1<f32>) -> Array2<f32> {
    let t = x.nrows();
    let d = x.ncols();
    let mut out = Array2::<f32>::zeros((t, d));
    for i in 0..t {
        let row = x.row(i);
        let mean = row.sum() / d as f32;
        let var = row.iter().map(|&v| (v - mean) * (v - mean)).sum::<f32>() / d as f32;
        let inv = 1.0 / (var + 1e-6).sqrt();
        for j in 0..d {
            out[[i, j]] = (row[j] - mean) * inv * g[j] + b[j];
        }
    }
    out
}

fn gelu(mut a: Array2<f32>) -> Array2<f32> {
    a.mapv_inplace(|x| 0.5 * x * (1.0 + (0.7978845608 * (x + 0.044715 * x * x * x)).tanh()));
    a
}

fn softmax_rows(a: &mut Array2<f32>) {
    for mut row in a.rows_mut() {
        let m = row.iter().cloned().fold(f32::NEG_INFINITY, f32::max);
        let mut s = 0f32;
        for v in row.iter_mut() {
            *v = (*v - m).exp();
            s += *v;
        }
        let inv = 1.0 / s;
        for v in row.iter_mut() {
            *v *= inv;
        }
    }
}

fn relu3(mut a: Array3<f32>) -> Array3<f32> {
    a.mapv_inplace(|x| if x > 0.0 { x } else { 0.0 });
    a
}

/// multi-head attention: q,k,v [T,512] -> [T,512], scale 1/sqrt(64).
fn mha(q: &Array2<f32>, k: &Array2<f32>, v: &Array2<f32>, t: usize) -> Array2<f32> {
    let scale = 0.125f32;
    let mut out = Array2::<f32>::zeros((t, D));
    for head in 0..H {
        let c0 = head * HD;
        let qh = q.slice(s![.., c0..c0 + HD]);
        let kh = k.slice(s![.., c0..c0 + HD]);
        let vh = v.slice(s![.., c0..c0 + HD]);
        let mut sc = qh.dot(&kh.t()); // [T,T]
        sc.mapv_inplace(|x| x * scale);
        softmax_rows(&mut sc);
        let oh = sc.dot(&vh); // [T,HD]
        out.slice_mut(s![.., c0..c0 + HD]).assign(&oh);
    }
    out
}

impl Model {
    fn forward(&self, feat: &Array2<f32>) -> Array2<f32> {
        let t_in = feat.nrows();
        // frontend: feat [T,40] as [1,T,40]
        let mut x3 = Array3::<f32>::zeros((1, t_in, 40));
        for i in 0..t_in {
            for j in 0..40 {
                x3[[0, i, j]] = feat[[i, j]];
            }
        }
        let a = relu3(conv2d(&x3, &self.fc0, (1, 1), (2, 2)));
        let b = relu3(conv2d(&a, &self.fc1, (5, 1), (1, 3)));
        // pad W by (0,1)
        let (cb, hb, wb) = (b.shape()[0], b.shape()[1], b.shape()[2]);
        let mut bp = Array3::<f32>::zeros((cb, hb, wb + 1));
        bp.slice_mut(s![.., .., 0..wb]).assign(&b);
        let cc = relu3(conv2d(&bp, &self.fc2, (1, 2), (1, 0)));
        let (co, tt, wo) = (cc.shape()[0], cc.shape()[1], cc.shape()[2]);
        // transpose (1,0,2) -> [T, Co, W] -> reshape [T, Co*W]
        let mut flat = Array2::<f32>::zeros((tt, co * wo));
        for ti in 0..tt {
            for ci in 0..co {
                for wi in 0..wo {
                    flat[[ti, ci * wo + wi]] = cc[[ci, ti, wi]];
                }
            }
        }
        let mut x = self.flin.matmul_bias(&flat, &self.flb); // [T,512]
        // 40 pre-norm layers
        for l in &self.layers {
            let h = layer_norm(&x, &l.pnw, &l.pnb);
            let q = l.q.matmul(&h);
            let k = l.k.matmul(&h);
            let v = l.v.matmul(&h);
            let attn = mha(&q, &k, &v, tt);
            x = &x + &l.o.matmul(&attn);
            let h2 = layer_norm(&x, &l.mnw, &l.mnb);
            let ff = gelu(l.f1.matmul_bias(&h2, &l.f1b));
            x = &x + &l.f2.matmul_bias(&ff, &l.f2b);
        }
        self.ow.matmul_bias(&x, &self.ob) // [T,VOCAB]
    }

    fn decode(&self, logits: &Array2<f32>) -> String {
        let mut out = String::new();
        let mut prev: i64 = -1;
        for row in logits.rows() {
            let mut best = 0usize;
            let mut bv = f32::NEG_INFINITY;
            for (i, &v) in row.iter().enumerate() {
                if v > bv {
                    bv = v;
                    best = i;
                }
            }
            if best as i64 != prev && best != 0 {
                let tok = &self.vocab[best];
                if tok != "<BLANK>" && tok != "<UNK>" && tok != "<SPACE>" {
                    out.push_str(tok);
                }
            }
            prev = best as i64;
        }
        out
    }
}

// keep Axis import used (silences unused warning across ndarray versions)
#[allow(unused_imports)]
use Axis as _AxisKeep;

// ---------------------------------------------------------------------------
// AsrProvider
// ---------------------------------------------------------------------------

/// Offline WeType embed_140m provider. One instance per recognition session.
pub struct WeTypeOfflineProvider {
    model_dir: PathBuf,
    model: Option<Arc<Model>>,
    fbank: Option<Arc<FBank>>,
    pcm: Vec<i16>,
    events: VecDeque<AsrEvent>,
    finished: bool,
}

impl WeTypeOfflineProvider {
    pub fn new(model_dir: impl Into<PathBuf>) -> Self {
        Self {
            model_dir: model_dir.into(),
            model: None,
            fbank: None,
            pcm: Vec::new(),
            events: VecDeque::new(),
            finished: false,
        }
    }

    /// Make sure the model exists in `dir` (downloading from `base_url` and
    /// SHA-256-verifying if missing/corrupt), then return a provider ready to
    /// [`connect`](AsrProvider::connect). `progress(file, done, total)` reports
    /// download bytes. If the model is already present this returns immediately
    /// without touching the network.
    ///
    /// ```no_run
    /// # #[cfg(feature = "wetype-offline")]
    /// # async fn ex() -> Result<(), koe_asr::AsrError> {
    /// use koe_asr::wetype::WeTypeOfflineProvider;
    /// let asr = WeTypeOfflineProvider::ensure_and_new(
    ///     "/Library/Application Support/koe/wetype",     // where to store the model
    ///     "https://github.com/missuo/koe/releases/download/wetype-model-v1", // host (TBD)
    ///     |file, done, total| {
    ///         if let Some(t) = total { eprintln!("{file}: {}/{} bytes", done, t); }
    ///     },
    /// ).await?;
    /// # let _ = asr; Ok(()) }
    /// ```
    pub async fn ensure_and_new<F>(
        dir: impl Into<PathBuf>,
        base_url: &str,
        progress: F,
    ) -> Result<Self>
    where
        F: FnMut(&str, u64, Option<u64>),
    {
        let dir = dir.into();
        ensure_model(&dir, &WeTypeModelSpec::from_base_url(base_url), progress).await?;
        Ok(Self::new(dir))
    }

    /// Transcribe a whole PCM clip (16-bit mono 16 kHz) synchronously.
    /// Requires [`connect`](AsrProvider::connect) to have loaded the model.
    /// Runs the full FBank → transformer → CTC pipeline on the calling thread
    /// (CPU-bound, ~0.3 s for a few seconds of audio); allocates only transient
    /// working buffers that are freed on return — the resident model is reused.
    pub fn transcribe(&self, pcm: &[i16]) -> Result<String> {
        let model = self
            .model
            .clone()
            .ok_or_else(|| AsrError::Protocol("not connected".into()))?;
        let fbank = self.fbank.clone().unwrap();
        Ok(Self::transcribe_blocking(model, fbank, pcm.to_vec()))
    }

    /// Run recognition synchronously on the buffered audio (blocking, CPU-heavy).
    fn transcribe_blocking(model: Arc<Model>, fbank: Arc<FBank>, pcm: Vec<i16>) -> String {
        let sig: Vec<f32> = pcm.iter().map(|&s| s as f32).collect();
        let feat = fbank.compute(&sig);
        if feat.nrows() == 0 {
            return String::new();
        }
        let logits = model.forward(&feat);
        model.decode(&logits)
    }
}

#[async_trait::async_trait]
impl AsrProvider for WeTypeOfflineProvider {
    async fn connect(&mut self, _config: &AsrConfig) -> Result<()> {
        let dir = self.model_dir.clone();
        // load off the async runtime (or reuse the cached Arc — instant)
        let model = tokio::task::spawn_blocking(move || Model::load_or_cached(&dir))
            .await
            .map_err(|e| AsrError::Protocol(format!("model load join: {e}")))??;
        self.model = Some(model);
        self.fbank = Some(Arc::new(FBank::new()));
        self.events.push_back(AsrEvent::Connected);
        Ok(())
    }

    async fn send_audio(&mut self, frame: &[u8]) -> Result<()> {
        // interpret as little-endian i16 PCM, mono
        for c in frame.chunks_exact(2) {
            self.pcm.push(i16::from_le_bytes([c[0], c[1]]));
        }
        Ok(())
    }

    async fn finish_input(&mut self) -> Result<()> {
        if self.finished {
            return Ok(());
        }
        self.finished = true;
        let model = self
            .model
            .clone()
            .ok_or_else(|| AsrError::Protocol("not connected".into()))?;
        let fbank = self.fbank.clone().unwrap();
        let pcm = std::mem::take(&mut self.pcm);
        let text =
            tokio::task::spawn_blocking(move || Self::transcribe_blocking(model, fbank, pcm))
                .await
                .map_err(|e| AsrError::Protocol(format!("transcribe join: {e}")))?;
        self.events.push_back(AsrEvent::Final(text));
        self.events.push_back(AsrEvent::Closed(None));
        Ok(())
    }

    async fn next_event(&mut self) -> Result<AsrEvent> {
        if let Some(ev) = self.events.pop_front() {
            Ok(ev)
        } else {
            Ok(AsrEvent::Closed(None))
        }
    }

    async fn close(&mut self) -> Result<()> {
        self.pcm.clear();
        self.events.clear();
        self.model = None;
        self.fbank = None;
        Ok(())
    }
}
