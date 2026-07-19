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

#[test]
fn live_preview_keeps_previous_final_visible_during_new_segment_interim() {
    let mut agg = TranscriptAggregator::new();

    agg.update_final("第一句话");
    // After a pause DoubaoIME's interim only carries the new segment.
    agg.update_interim("第二");
    assert_eq!(agg.live_preview(), "第一句话第二");

    agg.update_interim("第二句话");
    assert_eq!(agg.live_preview(), "第一句话第二句话");

    agg.update_final("第二句话");
    assert_eq!(agg.live_preview(), "第一句话第二句话");
}

#[test]
fn live_preview_advances_when_definite_arrives_after_prior_final() {
    let mut agg = TranscriptAggregator::new();

    agg.update_final("第一句话。");
    agg.update_definite("第一句话。第二句话。");

    assert_eq!(agg.live_preview(), "第一句话。第二句话。");
    assert_eq!(agg.best_text(), "第一句话。第二句话。");
}

#[test]
fn live_preview_uses_definite_before_any_final() {
    let mut agg = TranscriptAggregator::new();

    agg.update_interim("临时识别");
    agg.update_definite("确认识别");

    assert_eq!(agg.live_preview(), "确认识别");
}

#[test]
fn final_after_definite_replaces_cleanly_when_revised_mid_string() {
    // A second-pass definite extends the committed view, then the third-pass
    // final revises a character the definite had confirmed (八 → 吧). The
    // final must wholesale-replace the committed text; baking the definite
    // into final_text would defeat the prefix check in merge_committed_text
    // and duplicate the transcript via the overlap fallback.
    let mut agg = TranscriptAggregator::new();

    agg.update_final("今天天气不错。");
    agg.update_definite("今天天气不错。我们去公园八");
    assert_eq!(agg.live_preview(), "今天天气不错。我们去公园八");

    agg.update_final("今天天气不错。我们去公园吧。");
    assert_eq!(agg.best_text(), "今天天气不错。我们去公园吧。");
    assert_eq!(agg.live_preview(), "今天天气不错。我们去公园吧。");
}

#[test]
fn live_preview_keeps_updating_when_new_segment_shares_a_char_with_prior_final() {
    // Aggregator contract for the "live caption freezes after a pause" case:
    // two segments were finalized cumulatively, then a third segment begins
    // whose first character happens to match a position inside the cumulative
    // final. WHEN a provider emits interims that include the full running
    // transcript, live_preview must surface the latest interim rather than
    // the stale committed final. (Providers that emit only per-segment
    // interims can still freeze the preview here — that is a provider
    // limitation, not an aggregator one; see the reverted v1.0.22 DoubaoIME
    // bake for why fixing it provider-side is not straightforward.)
    let mut agg = TranscriptAggregator::new();

    agg.update_final("今天天气不错");
    agg.update_final("今天天气不错我们去公园");

    // New segment 3 begins with the character "我" — which also happens to be
    // the first character of segment 2 ("我们去公园").
    agg.update_interim("今天天气不错我们去公园我");
    assert_eq!(agg.live_preview(), "今天天气不错我们去公园我");

    agg.update_interim("今天天气不错我们去公园我喜欢");
    assert_eq!(agg.live_preview(), "今天天气不错我们去公园我喜欢");
}

#[test]
fn live_preview_does_not_duplicate_full_transcript_interim() {
    let mut agg = TranscriptAggregator::new();

    agg.update_interim("hello");
    agg.update_interim("hello world");
    assert_eq!(agg.live_preview(), "hello world");
}
