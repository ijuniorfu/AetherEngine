import Foundation
import Testing
@testable import AetherEngine

/// AE#443: a session counter has to describe the session.
///
/// The reporter of #443 read a fall in the CLI's `rx=` as evidence that the engine had swapped its
/// origin socket under a deep live rewind, and built a server-side theory on top of it. The socket
/// swap never happened (one `pump conn start` for the whole campaign, on their logs and on the
/// harness), and neither did the producer restart the fall was then attributed to. What fell was an
/// `AVPlayerItemAccessLogEvent` boundary: those counters are totals PER ENTRY, and AVFoundation opens
/// a new entry whenever the playback session changes under it.
///
/// Measured before the fix on the live loopback harness, one origin connection and no restart in the
/// whole run: `rx` went 3.4 MB -> 2.2 MB -> 0.6 MB and `drop` 44 -> 0, mid-session, while playing.
struct Issue443SessionCounterTests {

    @Test("a per-entry counter reads as the session's total, not as the newest entry's")
    func sumsAcrossEntries() {
        // The shape of the defect: entry 2 opened mid-session and is still filling.
        #expect(LiveTelemetrySampler.sessionTotal(perEntry: [Int64(3_600_000), 2_300_000]) == 5_900_000)
        #expect(LiveTelemetrySampler.sessionTotal(perEntry: [44, 0]) == 44)
    }

    @Test("a single entry still reads as itself")
    func singleEntry() {
        #expect(LiveTelemetrySampler.sessionTotal(perEntry: [Int64(1_100_000)]) == 1_100_000)
    }

    @Test("entries that cannot report the field are skipped, not clamped into the total")
    func skipsUnavailableEntries() {
        // AVFoundation reports an unavailable counter as a negative, and clamping it to 0 would let a
        // known-unknown entry read as a measured zero.
        #expect(LiveTelemetrySampler.sessionTotal(perEntry: [Int64(10), -1, 5]) == 15)
    }

    @Test("nothing measurable stays nil, which is not the same as a measured zero")
    func nilWhenNothingMeasurable() {
        #expect(LiveTelemetrySampler.sessionTotal(perEntry: [Int64(-1), -1]) == nil)
        #expect(LiveTelemetrySampler.sessionTotal(perEntry: [Int]()) == nil)
    }

    @Test("a measured zero is reported as zero")
    func measuredZero() {
        #expect(LiveTelemetrySampler.sessionTotal(perEntry: [0, 0]) == 0)
    }
}
