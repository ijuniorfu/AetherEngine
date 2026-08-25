import Testing
import Foundation
@testable import AetherEngine

/// AE#418 (rrgomes): after a restart whose gate re-aimed below its boundary, the clock ran ahead of
/// the picture by the re-aim. Captions about four seconds early on a resume that re-aimed 3.045 s,
/// about eight after restarts that re-aimed 3.1 and 5.0, and a synced host reports the wrong position
/// with them. Lip sync survives, because audio and video sit in the same segment.
///
/// AE#408 shipped the early-opening gate on the assumption that a segment keeping its own timestamps
/// leaves the item axis where the plan puts it, so it published no shift for that case. The reporter
/// measured the opposite from AVPlayer's loaded ranges, and `aetherctl play --picture-probe` measures
/// it directly: on a fixture whose picture states its own source time in binary, a resume at 53 s
/// whose gate re-aimed to 38.417 (boundary 52.000) showed source frame 41.250 while AVPlayer reported
/// item time 54.791, an axis error of exactly the re-aim, constant for the whole run.
///
/// **AVPlayer presents a segment at the position the PLAYLIST gives it, not at the tfdt it carries,
/// and then plays continuously from there.** Two consequences, and the fix needs both:
///
/// 1. The offset a consumer must fold is measured against the segment's ADVERTISED start, never
///    against where the gate actually opened. A pinned (late) gate makes the two identical, which is
///    why publishing the muxer's shift held until AE#408 added a gate that opens early.
/// 2. That offset belongs to the decode RUN, not to the timeline. A seek that leaves the loaded
///    region without provoking a restart lands on a sequentially cut, axis-true segment, and the
///    previous run's offset must stop applying there. Measured before this half landed: the same
///    run read `capErr=+0.892` after such a seek, the mirror image of the defect it had just fixed.
///
/// Measured on `tc-cues-lie.mkv` (Cues injected at non-sync positions, 12 s keyframe drought at
/// 43 s), source time decoded from the picture itself:
///
/// | arm | gate | published shift | picture vs item axis | picture vs `sourceTime` |
/// | --- | --- | --- | --- | --- |
/// | before AE#408 | late, pinned | +3.000 | +3.000 | +0.075 |
/// | AE#408 as shipped | early, 38.417 | 0.000 | -13.583 | -13.550 |
/// | with this change | early, 38.417 | -13.583 | -13.583 | -0.009 |
struct Issue418ReaimedGateAxisTests {

    // The reporter's `#65 ledger`, in the millisecond time base its lines are printed in.
    // Each row is (advertised boundary, where the gate actually opened, the drift he tabulated).
    private static let ledger: [(boundary: Int64, gateOpenedAt: Int64, drift: Int64)] = [
        (352_936, 349_891, -3_045),   // session 1 + 2, the resume at 354.0
        (676_134, 662_078, -14_056),  // session 1, seek to 682.0, re-aimed 4s, 8s, 16s
        (972_847, 969_802, -3_045),   // session 1, seek to 992.0
        (1_084_375, 1_083_332, -1_043), // session 1, seek to 1102.0
        (512_053, 508_925, -3_128),   // session 2, seek to 519.3
        (684_809, 679_762, -5_047),   // session 2, seek to 689.3
        (604_521, 604_896, 375)       // session 2, seek to 609.3: a LATE opening, the pinned case
    ]

    // MARK: - The offset is measured against the advertised start

    @Test("every re-aimed restart in the report publishes its own drift, not zero")
    func ledgerRowsPublishTheirDrift() {
        for row in Self.ledger {
            let published = HLSSegmentProducer.presentedShiftPts(
                actualFirstDts: row.gateOpenedAt, desiredTfdtPts: row.boundary)
            #expect(published == row.drift,
                    "boundary \(row.boundary) opened at \(row.gateOpenedAt)")
        }
    }

    @Test("a gate that opened early publishes a negative shift, which is what was missing")
    func earlyGatePublishesNegative() {
        // The harness case: boundary 52.000 s, gate re-aimed three times and opened at 38.417 s.
        let published = HLSSegmentProducer.presentedShiftPts(
            actualFirstDts: 38_417, desiredTfdtPts: 52_000)
        #expect(published == -13_583)
    }

    @Test("a gate that opened exactly on its boundary publishes nothing")
    func exactGatePublishesZero() {
        #expect(HLSSegmentProducer.presentedShiftPts(actualFirstDts: 44_000, desiredTfdtPts: 44_000) == 0)
    }

    @Test("a late gate is unchanged, because the pin already made the two axes agree")
    func lateGateUnchanged() {
        // Pre-AE#408 behaviour on the same fixture: the gate opened at 55.0 for a boundary at 52.0
        // and the pin moved the first frame down to 52.0, so the content sits 3 s above the axis.
        #expect(HLSSegmentProducer.presentedShiftPts(actualFirstDts: 55_000, desiredTfdtPts: 52_000) == 3_000)
    }

    @Test("an unresolved timestamp publishes nothing rather than a garbage offset")
    func unresolvedPublishesZero() {
        #expect(HLSSegmentProducer.presentedShiftPts(actualFirstDts: .min, desiredTfdtPts: 52_000) == 0)
        #expect(HLSSegmentProducer.presentedShiftPts(actualFirstDts: 38_417, desiredTfdtPts: .min) == 0)
    }

    // MARK: - The offset belongs to the run, not to the timeline

    @Test("a run beginning on the segment the gate opened into carries that offset")
    func runOnTheAnchorCarriesTheOffset() {
        let shift = HLSVideoEngine.axisShiftForRun(
            beginningAt: 13, anchorIndex: 13, anchorShiftSeconds: -13.583)
        #expect(shift == -13.583)
    }

    @Test("a run beginning anywhere else is worth its advertised position")
    func runElsewhereIsAxisTrue() {
        // The measured case: the seek left the loaded region, no restart followed, and AVPlayer
        // anchored on seg11, which a previous pump had cut on its own boundary.
        #expect(HLSVideoEngine.axisShiftForRun(
            beginningAt: 11, anchorIndex: 2, anchorShiftSeconds: -0.875) == 0)
        #expect(HLSVideoEngine.axisShiftForRun(
            beginningAt: 14, anchorIndex: 13, anchorShiftSeconds: -13.583) == 0)
    }

    @Test("with no epoch on record a run inherits nothing")
    func noAnchorOnRecord() {
        #expect(HLSVideoEngine.axisShiftForRun(
            beginningAt: 0, anchorIndex: .min, anchorShiftSeconds: 0) == 0)
    }

    // MARK: - What counts as the beginning of a run

    @Test("the next index in sequence continues the run")
    func sequentialFetchContinuesTheRun() {
        #expect(!VideoSegmentProvider.beginsFreshDecodeRun(index: 12, previousTarget: 11))
    }

    @Test("the same index again is a retry, not a new run")
    func repeatedFetchIsARetry() {
        // A republished axis mid-run would move the clock under a picture that never changed.
        #expect(!VideoSegmentProvider.beginsFreshDecodeRun(index: 11, previousTarget: 11))
    }

    @Test("a jump in either direction begins a run")
    func jumpBeginsARun() {
        #expect(VideoSegmentProvider.beginsFreshDecodeRun(index: 40, previousTarget: 11))
        #expect(VideoSegmentProvider.beginsFreshDecodeRun(index: 3, previousTarget: 11))
        // One short of contiguous is still a jump: the segment between them was never fetched.
        #expect(VideoSegmentProvider.beginsFreshDecodeRun(index: 13, previousTarget: 11))
    }

    @Test("the session's first fetch begins a run")
    func firstFetchBeginsARun() {
        // `cache.targetIndex` before any declaration, so the resume segment is an anchor and gets
        // the epoch's offset published against it.
        #expect(VideoSegmentProvider.beginsFreshDecodeRun(index: 13, previousTarget: -1))
    }
}
