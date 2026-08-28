import Testing
@testable import AetherEngine

/// AE#444: `play()` moved a behind-live playhead by itself, which made a host's own live-pause semantics
/// unreachable. The decision is now one pure function, and the host can own it.
@Suite("AE#444 who moves a behind-live playhead on resume")
struct Issue444LiveResumePolicyTests {

    private func action(clamps: Bool = true,
                        window: Double?,
                        behind: Double,
                        lowerBound: Double? = nil,
                        edge: Double = 1000) -> AetherEngine.LiveResumeAction {
        AetherEngine.liveResumeAction(clampsToWindow: clamps,
                                      windowSeconds: window,
                                      behindLiveSeconds: behind,
                                      seekableLowerBound: lowerBound,
                                      edgeTime: edge)
    }

    // MARK: - Default behaviour, unchanged

    @Test("a DVR playhead the window has slid past lands above the retained floor")
    func evictedDVRPlayheadIsRecovered() {
        #expect(action(window: 1800, behind: 1799, lowerBound: 200) == .seek(to: 205))
    }

    @Test("a playhead still inside the window is left alone")
    func insideWindowIsUntouched() {
        #expect(action(window: 1800, behind: 540, lowerBound: 200) == .none)
    }

    /// The report's own healthy state: 540 s of deliberate rewind inside a 1800 s window must survive a
    /// resume, and did even before the option existed.
    @Test("deliberate deep rewind inside the window survives a resume")
    func deliberateRewindSurvives() {
        #expect(action(window: 1800, behind: 540) == .none)
    }

    @Test("live-only snaps to the edge only past its own threshold")
    func liveOnlyThreshold() {
        #expect(action(window: nil, behind: 44) == .none)
        #expect(action(window: nil, behind: 46) == .edgeSnap)
    }

    /// AE#441: the landing is measured from the range's lower bound, which is now the cache's real floor
    /// rather than window arithmetic, so the clamp cannot aim at a position that was never retained.
    @Test("the landing follows the advertised floor")
    func landingFollowsTheFloor() {
        #expect(action(window: 30, behind: 100, lowerBound: 981) == .seek(to: 986))
    }

    /// With no range at all there is nothing to measure from; the edge is the only position known to
    /// exist.
    @Test("an absent lower bound falls back to the edge")
    func absentBoundFallsBackToEdge() {
        #expect(action(window: 30, behind: 100, lowerBound: nil, edge: 400) == .seek(to: 405))
    }

    // MARK: - Host-owned

    @Test("a host that owns resume gets no implicit seek, in either shape")
    func hostOwnedMovesNothing() {
        #expect(action(clamps: false, window: 1800, behind: 1799, lowerBound: 200) == .none)
        #expect(action(clamps: false, window: nil, behind: 600) == .none)
    }

    @Test("host-owned still does nothing when nothing was warranted anyway")
    func hostOwnedIsNotAnInversion() {
        #expect(action(clamps: false, window: 1800, behind: 10) == .none)
    }

    @Test("the option defaults to today's behaviour")
    func defaultIsUnchanged() {
        #expect(LoadOptions().clampsLiveResumeToWindow)
    }
}
