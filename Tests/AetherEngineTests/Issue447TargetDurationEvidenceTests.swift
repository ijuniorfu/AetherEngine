// Tests/AetherEngineTests/Issue447TargetDurationEvidenceTests.swift
// AE#447: the served TARGETDURATION is sealed for the session (RFC 8216 forbids changing it, AE#209) and
// its 3x holdback gates the first live manifest, so what it is derived FROM decides every zap's startup
// depth. It must be derived from measurement. A packager's habitual `segment + 1` padding used to seed the
// cadence floor and cost 3x itself in first-serve holdback: measured in the field at 1.07-1.09 s per tune
// on a 2.000 s source advertising 3.
import XCTest
@testable import AetherEngine

private final class ScriptedUpstream: @unchecked Sendable {
    var now: Double = 0
    var cadence: Double?
    var closedCadence: Double?
    var segmentDuration: Double?
}

final class Issue447TargetDurationEvidenceTests: XCTestCase {

    private func makePolicy(_ s: ScriptedUpstream, cutTarget: Double = 0.5, advertised: Double?) -> LiveCadencePolicy {
        LiveCadencePolicy(
            observe: { s.cadence },
            cutTargetSeconds: cutTarget,
            observeSealEvidence: {
                LiveCadenceEvidence(closedCadenceSeconds: s.closedCadence,
                                    servedSegmentDurationSeconds: s.segmentDuration)
            },
            selfReportedTargetDurationSeconds: advertised,
            clock: { s.now }
        )
    }

    // MARK: - What the floor is made of

    func testAdvertisedTargetDurationDoesNotRaiseTheFloor() {
        let s = ScriptedUpstream()
        let policy = makePolicy(s, advertised: 3)     // padded advert over a 2.000 s cadence
        s.now = 1; s.cadence = 0.5; s.segmentDuration = 2.0
        XCTAssertEqual(try XCTUnwrap(policy.targetDurationFloorSeconds), 2.0, accuracy: 1e-9,
                       "the floor is the measured segment duration, not the advertised 3")
        XCTAssertEqual(policy.selfReportedTargetDurationSeconds, 3,
                       "the advert is still carried, for the seal log to report")
    }

    func testServedSegmentDurationFloorsTheBurstFlatteredCadence() {
        let s = ScriptedUpstream()
        let policy = makePolicy(s, advertised: nil)
        // A join burst hands over a backlog at 4-5x realtime, so the intervals say 0.5 s while the source
        // will never sustain better than its 2.000 s cut. Sealing on the interval alone would advertise a
        // 3 s patience for a 2 s cadence and leave no margin at all.
        s.now = 3; s.cadence = 0.5; s.segmentDuration = 2.0
        XCTAssertEqual(try XCTUnwrap(policy.targetDurationFloorSeconds), 2.0, accuracy: 1e-9)
    }

    func testFloorIsNilWhileNothingHasBeenMeasured() {
        let s = ScriptedUpstream()
        let policy = makePolicy(s, advertised: 6)
        s.now = 0
        XCTAssertNil(policy.targetDurationFloorSeconds,
                     "an advert alone is not a measurement; ceil(max EXTINF) carries the TD until one exists")
    }

    func testBatchyUpstreamStillWidensTheFloorPastItsSegmentDuration() {
        let s = ScriptedUpstream()
        let policy = makePolicy(s, cutTarget: 4, advertised: 4)
        s.now = 0; s.cadence = 0; s.segmentDuration = 4.0
        _ = policy.targetDurationFloorSeconds
        s.now = 20; s.cadence = 20; s.closedCadence = 20   // one real 20 s inter-batch gap, closed
        XCTAssertEqual(try XCTUnwrap(policy.targetDurationFloorSeconds), 20, accuracy: 1e-9,
                       "#167's relay shape is covered by observation, which is the only thing that ever covered it")
    }

    // MARK: - What it costs at the first serve

    /// The reported field shape: 2.000 s segments, fastZap cut target, upstream advertising 3.
    func testPaddedAdvertNoLongerDeepensTheStartupGate() {
        let s = ScriptedUpstream()
        let policy = makePolicy(s, advertised: 3)
        s.now = 3; s.cadence = 0.5; s.segmentDuration = 2.0

        let td = LiveEdgePolicy.targetDurationSeconds(
            maxSegmentDuration: 2.0,
            cutTargetSeconds: 0.5,
            cadenceFloorSeconds: policy.targetDurationFloorSeconds
        )
        XCTAssertEqual(td, 2, "ceil(max EXTINF) carries it; the advert used to push this to 3")
        XCTAssertEqual(LiveEdgePolicy.holdBackSeconds(targetDuration: td), 6.0, accuracy: 1e-9)

        // The gate opens on 3 segments / 6.0 s instead of 5 / 10.0 s: one segment-and-a-half of startup,
        // which the reporter measured as 1.07-1.09 s of wall clock on every tune.
        XCTAssertTrue(LiveEdgePolicy.startupCushionSatisfied(
            segmentCount: 3, summedDurationSeconds: 6.0, targetDuration: td, windowSegmentCount: 30))
        XCTAssertFalse(LiveEdgePolicy.startupCushionSatisfied(
            segmentCount: 3, summedDurationSeconds: 6.0, targetDuration: 3, windowSegmentCount: 30),
            "the value this replaces: 9 s of holdback, so 3 segments were never enough")
    }

    func testPatienceStillCoversTheMeasuredCadence() {
        // AVPlayer's unchanged-playlist tolerance is 1.5 x TD. At TD 2 that is 3 s over a 2 s cadence,
        // the same ratio the cut-target floor was built to guarantee.
        let td = LiveEdgePolicy.targetDurationSeconds(
            maxSegmentDuration: 2.0, cutTargetSeconds: 0.5, cadenceFloorSeconds: 2.0)
        XCTAssertGreaterThanOrEqual(Double(td) * 1.5, 2.0 * 1.5)
    }

    // MARK: - The seal says why

    func testSealAccountReportsMeasuredTermsAndTheUnusedAdvert() {
        let derivation = LiveTargetDurationDerivation(
            value: 2, maxSegmentDuration: 2.0, cutTargetFloor: 0.5, cadenceFloor: 2.0, selfReported: 3.0)
        let account = derivation.account
        XCTAssertTrue(account.contains("sealed at 2s"), account)
        XCTAssertTrue(account.contains("holdback 6.000s"), account)
        XCTAssertTrue(account.contains("max EXTINF 2.000s"), account)
        XCTAssertTrue(account.contains("measured floor 2.000s"), account)
        XCTAssertTrue(account.contains("upstream advertises 3.000s (reported, not used)"), account)
    }

    func testSealAccountNamesAnAbsentMeasurement() {
        let derivation = LiveTargetDurationDerivation(
            value: 4, maxSegmentDuration: 3.2, cutTargetFloor: 4.0, cadenceFloor: nil, selfReported: nil)
        XCTAssertTrue(derivation.account.contains("measured floor none yet"), derivation.account)
    }
}
