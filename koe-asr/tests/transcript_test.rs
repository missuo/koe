use koe_asr::TranscriptAggregator;

#[test]
fn final_text_refreshes_same_utterance_without_duplication() {
    let mut agg = TranscriptAggregator::new();

    agg.update_final("hello");
    agg.update_final("hello world");
    agg.update_final("hello world");

    assert_eq!(agg.best_text(), "hello world");
}

#[test]
fn final_text_appends_new_segment_after_pause() {
    let mut agg = TranscriptAggregator::new();

    agg.update_final("第一句话。");
    // New segment after a pause carries unrelated content.
    agg.update_final("第二句话。");

    assert_eq!(agg.best_text(), "第一句话。第二句话。");
}

#[test]
fn final_text_ignores_stale_replay_of_earlier_content() {
    let mut agg = TranscriptAggregator::new();

    agg.update_final("hello world");
    // Server replays a stale prefix of what we already have.
    agg.update_final("hello");

    assert_eq!(agg.best_text(), "hello world");
}

#[test]
fn final_text_strips_boundary_overlap_between_segments() {
    let mut agg = TranscriptAggregator::new();

    agg.update_final("今天天气不错");
    // New segment repeats the last two chars of the previous tail.
    agg.update_final("不错我们去公园");

    assert_eq!(agg.best_text(), "今天天气不错我们去公园");
}
