import XCTest
@testable import AetherEngine

/// #405 (Syravo device trace, tvOS 26.6): a live MPEG-TS channel behind a one-slot Xtream host
/// froze twice in a minute. The origin caused both freezes; what the trace showed is where the
/// engine's READING of the situation differed from what the origin did, and cost ~12 s and eleven
/// replayed seconds of recovery. This file covers the pure decisions behind those readings.
final class Issue405LiveRecoveryReadingTests: XCTestCase {

    // MARK: - Stage 2 asks the producer (#405 finding 4)

    /// The incident: with the source re-resolving and no bytes arriving, stage 2 reloaded the
    /// unchanged local playlist. AVPlayer rejoined a FROZEN playlist at edge-minus-holdback, 5 s
    /// behind the frozen position, replayed seg-18..21 and parked again, and only two grace windows
    /// later did the final rung ask the host to retune.
    func testNoSegmentSinceTheStallIsAStarvedProducer() {
        XCTAssertTrue(
            AetherEngine.liveProducerIsStarved(
                isLive: true, segmentsAtStall: 21, segmentsNow: 21),
            "the field case: the producer finalized nothing while the consumer sat silent, so a fresh consumer item has the same frozen tail to work with")
    }

    /// The shape stage 2 exists for: the producer kept finalizing segments, so the playlist grew
    /// and it is the consumer that died on it. A fresh AVPlayerItem is exactly right there.
    func testASegmentFinalizedSinceTheStallKeepsStageTwo() {
        XCTAssertFalse(
            AetherEngine.liveProducerIsStarved(
                isLive: true, segmentsAtStall: 21, segmentsNow: 22))
    }

    /// Regression guard: a remote HLS session has no local producer at all, AVPlayer fetches the
    /// origin itself. Reading that absence as "no progress" would turn every live stall on that
    /// route into an immediate retune and skip the stage that recovers it.
    func testNoLocalProducerIsNotStarvation() {
        XCTAssertFalse(
            AetherEngine.liveProducerIsStarved(
                isLive: true, segmentsAtStall: nil, segmentsNow: nil),
            "absence of a producer to ask is not an answer from one")
        XCTAssertFalse(
            AetherEngine.liveProducerIsStarved(
                isLive: true, segmentsAtStall: nil, segmentsNow: 4),
            "no baseline to compare against; stage 2 keeps its old behaviour")
    }

    /// VOD has no retune to fall back on: liveSourceReset is a live-only escalation.
    func testVODNeverReadsAsStarved() {
        XCTAssertFalse(
            AetherEngine.liveProducerIsStarved(
                isLive: false, segmentsAtStall: 10, segmentsNow: 10))
    }
}
