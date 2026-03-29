//! # koe-asr
//!
//! Streaming ASR (Automatic Speech Recognition) client for Volcengine/Doubao and Qwen.
//!
//! ## Quick Start (Doubao)
//!
//! ```rust,no_run
//! use koe_asr::{AsrConfig, AsrEvent, AsrProvider, DoubaoWsProvider, TranscriptAggregator};
//!
//! # async fn example() -> Result<(), koe_asr::AsrError> {
//! let config = AsrConfig {
//!     app_key: "your-app-key".into(),
//!     access_key: "your-access-key".into(),
//!     ..Default::default()
//! };
//!
//! let mut asr = DoubaoWsProvider::new();
//! asr.connect(&config).await?;
//!
//! // Push audio frames...
//! // asr.send_audio(&pcm_data).await?;
//! asr.finish_input().await?;
//!
//! let mut aggregator = TranscriptAggregator::new();
//! loop {
//!     match asr.next_event().await? {
//!         AsrEvent::Interim(text) => aggregator.update_interim(&text),
//!         AsrEvent::Definite(text) => aggregator.update_definite(&text),
//!         AsrEvent::Final(text) => { aggregator.update_final(&text); break; }
//!         AsrEvent::Closed => break,
//!         _ => {}
//!     }
//! }
//!
//! println!("{}", aggregator.best_text());
//! asr.close().await?;
//! # Ok(())
//! # }
//! ```

pub mod config;
pub mod doubao;
pub mod error;
pub mod event;
#[cfg(feature = "mlx")]
pub mod mlx;
pub mod provider;
pub mod qwen;
#[cfg(feature = "sherpa-onnx")]
pub mod sherpa_onnx;
pub mod transcript;

pub use qwen::QwenAsrProvider;
#[cfg(feature = "mlx")]
pub use mlx::{MlxConfig, MlxProvider};
#[cfg(feature = "sherpa-onnx")]
pub use sherpa_onnx::{SherpaOnnxConfig, SherpaOnnxProvider};
pub use config::AsrConfig;
pub use doubao::DoubaoWsProvider;
pub use error::AsrError;
pub use event::AsrEvent;
pub use provider::AsrProvider;
pub use transcript::TranscriptAggregator;
