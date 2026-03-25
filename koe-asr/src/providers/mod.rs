pub mod doubao;
pub mod openai;
pub mod qwen;

use crate::config::{AsrConfig, ProviderConfig};
use crate::error::Result;
use crate::event::AsrEvent;
use crate::provider::AsrProvider;

pub use doubao::DoubaoWsProvider;
pub use openai::OpenAIRealtimeProvider;
pub use qwen::QwenRealtimeProvider;

pub enum AnyAsrProvider {
    Doubao(DoubaoWsProvider),
    OpenAI(OpenAIRealtimeProvider),
    Qwen(QwenRealtimeProvider),
}

pub fn create_provider(config: &AsrConfig) -> AnyAsrProvider {
    match &config.provider {
        ProviderConfig::Doubao(_) => AnyAsrProvider::Doubao(DoubaoWsProvider::new()),
        ProviderConfig::OpenAI(_) => AnyAsrProvider::OpenAI(OpenAIRealtimeProvider::new()),
        ProviderConfig::Qwen(_) => AnyAsrProvider::Qwen(QwenRealtimeProvider::new()),
    }
}

impl AsrProvider for AnyAsrProvider {
    async fn connect(&mut self, config: &AsrConfig) -> Result<()> {
        match self {
            AnyAsrProvider::Doubao(provider) => provider.connect(config).await,
            AnyAsrProvider::OpenAI(provider) => provider.connect(config).await,
            AnyAsrProvider::Qwen(provider) => provider.connect(config).await,
        }
    }

    async fn send_audio(&mut self, frame: &[u8]) -> Result<()> {
        match self {
            AnyAsrProvider::Doubao(provider) => provider.send_audio(frame).await,
            AnyAsrProvider::OpenAI(provider) => provider.send_audio(frame).await,
            AnyAsrProvider::Qwen(provider) => provider.send_audio(frame).await,
        }
    }

    async fn finish_input(&mut self) -> Result<()> {
        match self {
            AnyAsrProvider::Doubao(provider) => provider.finish_input().await,
            AnyAsrProvider::OpenAI(provider) => provider.finish_input().await,
            AnyAsrProvider::Qwen(provider) => provider.finish_input().await,
        }
    }

    async fn next_event(&mut self) -> Result<AsrEvent> {
        match self {
            AnyAsrProvider::Doubao(provider) => provider.next_event().await,
            AnyAsrProvider::OpenAI(provider) => provider.next_event().await,
            AnyAsrProvider::Qwen(provider) => provider.next_event().await,
        }
    }

    async fn close(&mut self) -> Result<()> {
        match self {
            AnyAsrProvider::Doubao(provider) => provider.close().await,
            AnyAsrProvider::OpenAI(provider) => provider.close().await,
            AnyAsrProvider::Qwen(provider) => provider.close().await,
        }
    }
}
