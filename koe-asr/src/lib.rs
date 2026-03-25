//! # koe-asr
//!
//! Streaming ASR (Automatic Speech Recognition) client abstraction.
//!
//! ## Quick Start
//!
//! ```rust,no_run
//! use koe_asr::{
//!     create_provider, AsrConfig, AsrEvent, AsrProvider, DoubaoConfig, ProviderConfig,
//!     TranscriptAggregator,
//! };
//!
//! # async fn example() -> Result<(), koe_asr::AsrError> {
//! let config = AsrConfig {
//!     provider: ProviderConfig::Doubao(DoubaoConfig {
//!         app_key: "your-app-key".into(),
//!         access_key: "your-access-key".into(),
//!         ..Default::default()
//!     }),
//!     ..Default::default()
//! };
//!
//! let mut asr = create_provider(&config);
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
pub mod error;
pub mod event;
pub mod provider;
pub mod providers;
pub mod transcript;

pub use config::{
    AsrConfig, AsrProviderKind, DoubaoConfig, OpenAIRealtimeConfig, ProviderConfig,
    QwenRealtimeConfig,
};
pub use error::AsrError;
pub use event::AsrEvent;
pub use provider::AsrProvider;
pub use providers::{
    create_provider, AnyAsrProvider, DoubaoWsProvider, OpenAIRealtimeProvider,
    QwenRealtimeProvider,
};
pub use transcript::TranscriptAggregator;
