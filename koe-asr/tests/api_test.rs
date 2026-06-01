use koe_asr::{AsrConfig, AsrEvent, AsrProvider, DoubaoWsProvider, TranscriptAggregator};

#[test]
fn test_default_config() {
    let config = AsrConfig::default();
    assert_eq!(config.sample_rate_hz, 16000);
    assert!(config.enable_ddc);
    assert!(config.enable_itn);
    assert!(config.enable_punc);
    assert!(config.enable_nonstream);
    assert!(config.hotwords.is_empty());
    assert!(!config.url.is_empty());
    assert!(!config.resource_id.is_empty());
}

#[test]
fn test_custom_config() {
    let config = AsrConfig {
        app_key: "test-key".into(),
        access_key: "test-access".into(),
        hotwords: vec!["Rust".into(), "Tokio".into()],
        ..Default::default()
    };
    assert_eq!(config.app_key, "test-key");
    assert_eq!(config.hotwords.len(), 2);
}

#[test]
fn test_provider_creation() {
    let provider = DoubaoWsProvider::new();
    assert!(!provider.connect_id().is_empty());
    assert!(provider.logid().is_none());
}

#[test]
fn test_transcript_aggregator_interim() {
    let mut agg = TranscriptAggregator::new();
    assert!(!agg.has_any_text());
    assert!(!agg.has_final_result());

    agg.update_interim("hello");
    assert!(agg.has_any_text());
    assert_eq!(agg.best_text(), "hello");

    agg.update_interim("hello world");
    assert_eq!(agg.best_text(), "hello world");
    assert_eq!(agg.interim_history(10).len(), 2);
}

#[test]
fn test_transcript_aggregator_definite_overrides_interim() {
    let mut agg = TranscriptAggregator::new();
    agg.update_interim("interim text");
    agg.update_definite("definite text");
    assert_eq!(agg.best_text(), "definite text");
}

#[test]
fn test_transcript_aggregator_final_overrides_all() {
    let mut agg = TranscriptAggregator::new();
    agg.update_interim("interim");
    agg.update_definite("definite");
    agg.update_final("final result");
    assert!(agg.has_final_result());
    assert_eq!(agg.best_text(), "final result");
}

#[test]
fn test_transcript_aggregator_history_limit() {
    let mut agg = TranscriptAggregator::new();
    for i in 0..20 {
        agg.update_interim(&format!("revision {i}"));
    }
    let history = agg.interim_history(5);
    assert_eq!(history.len(), 5);
    assert_eq!(history[0], "revision 15");
    assert_eq!(history[4], "revision 19");
}

#[test]
fn test_transcript_aggregator_dedup_consecutive() {
    let mut agg = TranscriptAggregator::new();
    agg.update_interim("same text");
    agg.update_interim("same text");
    agg.update_interim("same text");
    assert_eq!(agg.interim_history(10).len(), 1);
}

#[test]
fn test_asr_event_variants() {
    // Ensure all variants can be constructed and debug-printed
    let events = vec![
        AsrEvent::Connected,
        AsrEvent::Interim("partial".into()),
        AsrEvent::Definite("confirmed".into()),
        AsrEvent::Final("done".into()),
        AsrEvent::Error("oops".into()),
        AsrEvent::Closed(None),
    ];
    for event in &events {
        let _ = format!("{:?}", event);
    }
    assert_eq!(events.len(), 6);
}

#[tokio::test]
async fn test_connect_fails_with_invalid_credentials() {
    let config = AsrConfig {
        app_key: "invalid".into(),
        access_key: "invalid".into(),
        connect_timeout_ms: 2000,
        ..Default::default()
    };

    let mut provider = DoubaoWsProvider::new();
    let result = provider.connect(&config).await;
    // Should fail since credentials are invalid
    assert!(result.is_err());
}

#[tokio::test]
async fn test_doubaoime_connect_and_send_silence() {
    let mut headers = std::collections::HashMap::new();
    headers.insert(
        "credential_path".to_string(),
        "/tmp/test_doubaoime_creds.json".to_string(),
    );

    let config = AsrConfig {
        connect_timeout_ms: 10000,
        final_wait_timeout_ms: 10000,
        enable_punc: true,
        custom_headers: headers,
        ..Default::default()
    };

    let mut provider = koe_asr::DoubaoImeProvider::new();
    match provider.connect(&config).await {
        Ok(()) => println!("Connected!"),
        Err(e) => {
            println!("ERROR connecting: {e}");
            return;
        }
    }

    // Send 1 second of silence (16000 samples * 2 bytes = 32000 bytes)
    let silence = vec![0u8; 32000];
    provider.send_audio(&silence).await.unwrap();

    // Finish
    provider.finish_input().await.unwrap();

    // Read events until closed
    let mut aggregator = TranscriptAggregator::new();
    loop {
        match provider.next_event().await {
            Ok(AsrEvent::Interim(text)) => {
                println!("INTERIM: {text}");
                aggregator.update_interim(&text);
            }
            Ok(AsrEvent::Definite(text)) => {
                println!("DEFINITE: {text}");
                aggregator.update_definite(&text);
            }
            Ok(AsrEvent::Final(text)) => {
                println!("FINAL: {text}");
                aggregator.update_final(&text);
                break;
            }
            Ok(AsrEvent::Closed(_)) => {
                println!("CLOSED");
                break;
            }
            Ok(AsrEvent::Error(e)) => {
                println!("ERROR event: {e}");
                break;
            }
            Ok(other) => println!("OTHER: {other:?}"),
            Err(e) => {
                println!("ERROR: {e}");
                break;
            }
        }
    }

    println!("Best text: '{}'", aggregator.best_text());
    provider.close().await.ok();
}
