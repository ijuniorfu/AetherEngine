import Foundation
import Testing
@testable import AetherEngine

/// AE#441: `seekableLiveRange`'s lower bound was window arithmetic (`max(0, edge - window)`) and never
/// consulted the cache, so it advertised a rewind depth the session had never written.
@Suite("AE#441 the advertised live floor is the resident one")
struct Issue441ResidentLiveFloorTests {

    // MARK: - The intersection

    /// The report's regime, measured on the harness: a session joined at edge 181.62 s advertised a
    /// floor of 0.00 for its whole run, while a seek to 0.20 landed at 181.66.
    @Test("a floor above the arithmetic one wins, because it is the one a seek can reach")
    func residentFloorRaisesTheBound() {
        var w = LiveWindow(windowSeconds: 1800)
        w.noteEdge(246.71)
        w.noteResidentFloor(181.66)
        #expect(w.seekableRange?.lowerBound == 181.66)
        #expect(w.seekableRange?.upperBound == 246.71)
    }

    /// The window is a cap, not a promise of depth: retention that kept LESS than the window is the
    /// case above, and one that happens to hold more must not widen the advertised range past policy.
    @Test("the window still caps a cache that holds more than it")
    func policyStillCaps() {
        var w = LiveWindow(windowSeconds: 30)
        w.noteEdge(600)
        w.noteResidentFloor(100)          // the cache kept 500 s; the session promised 30
        #expect(w.seekableRange?.lowerBound == 570)
    }

    /// Paths with no segment cache to ask (software live) report nothing, and must keep exactly the
    /// behaviour they had.
    @Test("an unknown floor leaves the arithmetic untouched")
    func unknownFloorIsUnchangedBehaviour() {
        var w = LiveWindow(windowSeconds: 1800)
        w.noteEdge(246.71)
        w.noteResidentFloor(nil)
        #expect(w.seekableRange?.lowerBound == 0)
        var deep = LiveWindow(windowSeconds: 30)
        deep.noteEdge(600)
        deep.noteResidentFloor(nil)
        #expect(deep.seekableRange?.lowerBound == 570)
    }

    /// A floor read while the edge is still catching up can exceed it for a tick, and a reversed
    /// ClosedRange traps. This is the guard that keeps a crash out of a diagnostics path.
    @Test("a floor past the edge collapses the range instead of trapping")
    func floorPastEdgeDoesNotTrap() {
        var w = LiveWindow(windowSeconds: 1800)
        w.noteEdge(10)
        w.noteResidentFloor(42)
        let range = w.seekableRange
        #expect(range?.lowerBound == 10)
        #expect(range?.upperBound == 10)
    }

    /// `clamp` reads the same range, which is what makes the engine's own resume clamp (AE#444) and
    /// `seek(to:)` aim at a position that was actually retained.
    @Test("clamp aims at the resident floor, not the arithmetic one")
    func clampFollowsTheHonestFloor() {
        var w = LiveWindow(windowSeconds: 1800)
        w.noteEdge(246.71)
        w.noteResidentFloor(181.66)
        #expect(w.clamp(0.2) == 181.66)
        #expect(w.clamp(200) == 200)
        #expect(w.clamp(9999) == 246.71)
    }

    @Test("live-only sessions still have no range at all")
    func liveOnlyUnaffected() {
        var w = LiveWindow(windowSeconds: nil)
        w.noteEdge(500)
        w.noteResidentFloor(120)
        #expect(w.seekableRange == nil)
        #expect(w.clamp(3) == 500)
    }

    // MARK: - The floor the cache reports

    @Test("the backward floor is the deepest contiguous index, not the lowest resident one")
    func backwardFloorStopsAtAHole() {
        let cache = SegmentCache(forwardWindow: 10, backwardWindow: 10)
        defer { cache.close() }
        for i in [0, 1, 2, 5, 6, 7] { cache.store(index: i, data: Data([UInt8(i)])) }
        #expect(cache.highestResidentIndex == 7)
        // A rewind to 2 could not play forward across the hole at 3, so 5 is the honest floor.
        #expect(cache.contiguousBackwardFloor(from: 7) == 5)
    }

    @Test("a fully contiguous cache reports its first segment")
    func backwardFloorOnContiguousCache() {
        let cache = SegmentCache(forwardWindow: 10, backwardWindow: 10)
        defer { cache.close() }
        for i in 0..<6 { cache.store(index: i, data: Data([UInt8(i)])) }
        #expect(cache.contiguousBackwardFloor(from: 5) == 0)
    }

    @Test("walking from an absent index reports nothing below it")
    func backwardFloorFromAHole() {
        let cache = SegmentCache(forwardWindow: 10, backwardWindow: 10)
        defer { cache.close() }
        cache.store(index: 0, data: Data([0]))
        #expect(cache.contiguousBackwardFloor(from: 4) == 5)
    }

    @Test("an empty cache has no top to walk back from")
    func emptyCacheHasNoFloor() {
        let cache = SegmentCache(forwardWindow: 10, backwardWindow: 10)
        defer { cache.close() }
        #expect(cache.highestResidentIndex == nil)
    }
}
