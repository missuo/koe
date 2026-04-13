use koe_asr::TranscriptAggregator;

#[test]
fn final_text_replaces_previous_final_instead_of_appending() {
    let mut agg = TranscriptAggregator::new();

    agg.update_final("hello world");
    agg.update_final("hello world");

    assert_eq!(agg.best_text(), "hello world");
}

#[test]
fn final_text_can_overwrite_earlier_partial_final() {
    let mut agg = TranscriptAggregator::new();

    agg.update_final("hello");
    agg.update_final("hello world");

    assert_eq!(agg.best_text(), "hello world");
}
