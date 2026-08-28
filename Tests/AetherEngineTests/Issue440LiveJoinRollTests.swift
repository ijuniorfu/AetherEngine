import AVFoundation
import Testing
@testable import AetherEngine

/// AE#440: a live join presents its first frame and can then hold it perfectly still for seconds while
/// AVPlayer decides whether to let the rate roll. Two halves are pinned here: which phase a host sees
/// across that hold, and when the engine is allowed to cut it short.
@Suite("AE#440 live join: intent, motion, and the stall-avoidance hold")
struct Issue440LiveJoinRollTests {

    // MARK: - The phase across the hold

    /// The report's exact shape: the autostart has written `state = .playing`, AVPlayer has the picture
    /// up and is holding it, and nothing has moved yet. `.playing` here is what dropped a host's spinner
    /// 2.7 s before motion.
    @Test("an autostart that has not rolled yet reads as loading, not playing")
    func startedButNotRolledIsLoading() {
        #expect(PlaybackPhase.derive(state: .playing, isBuffering: false, isSeeking: false,
                                     stall: .flowing, transportHasRolled: false) == .loading)
    }

    /// The wait publishes `isBuffering` too, and a start is not a RE-buffer: `.rebuffering` is reserved
    /// for an underrun after playback existed, so the axis that names the hold has to be the roll.
    @Test("a buffering start before the first roll is still loading")
    func bufferingBeforeFirstRollIsLoading() {
        #expect(PlaybackPhase.derive(state: .playing, isBuffering: true, isSeeking: false,
                                     stall: .flowing, transportHasRolled: false) == .loading)
    }

    @Test("the same buffering, once the transport has rolled, is a rebuffer")
    func bufferingAfterFirstRollIsRebuffering() {
        #expect(PlaybackPhase.derive(state: .playing, isBuffering: true, isSeeking: false,
                                     stall: .flowing, transportHasRolled: true) == .rebuffering)
    }

    @Test("the roll itself is the edge to .playing")
    func rollIsThePlayingEdge() {
        #expect(PlaybackPhase.derive(state: .playing, isBuffering: false, isSeeking: false,
                                     stall: .flowing, transportHasRolled: true) == .playing)
    }

    /// A paused mount (`autoplay: false`) never rolls and must not read as a session still arriving:
    /// it is honestly not playing.
    @Test("a paused mount that never rolled is paused, not loading")
    func pausedMountStaysPaused() {
        #expect(PlaybackPhase.derive(state: .paused, isBuffering: false, isSeeking: false,
                                     stall: .flowing, transportHasRolled: false) == .paused)
    }

    /// The reader axis is about the SOURCE and outranks everything below it (#410); a join over a dead
    /// origin must keep saying so rather than reporting a startup that is merely slow.
    @Test("a dead source outranks the not-yet-rolled start")
    func stallOutranksNotRolled() {
        #expect(PlaybackPhase.derive(state: .playing, isBuffering: true, isSeeking: false,
                                     stall: .reconnecting, transportHasRolled: false)
                == .stalled(reconnecting: true))
    }

    /// A host seek during the start is a host action and stays visible, as it is after the roll.
    @Test("a seek during the start still reads as seeking")
    func seekOutranksNotRolled() {
        #expect(PlaybackPhase.derive(state: .playing, isBuffering: false, isSeeking: true,
                                     stall: .flowing, transportHasRolled: false) == .seeking)
    }

    @Test("terminal states ignore the roll axis entirely")
    func terminalStatesUnaffected() {
        #expect(PlaybackPhase.derive(state: .ended, isBuffering: false, isSeeking: false,
                                     stall: .flowing, transportHasRolled: false) == .ended)
        #expect(PlaybackPhase.derive(state: .error("boom"), isBuffering: false, isSeeking: false,
                                     stall: .flowing, transportHasRolled: false) == .error("boom"))
        #expect(PlaybackPhase.derive(state: .idle, isBuffering: false, isSeeking: false,
                                     stall: .flowing, transportHasRolled: false) == .idle)
    }

    // MARK: - When the hold may be cut short

    @Test("the armed join holding on a non-empty buffer is the case this exists for")
    func firesOnTheHold() {
        #expect(NativeAVPlayerHost.shouldStartLiveJoinImmediately(
            armed: true, alreadySpent: false, hostWantsToPlay: true,
            isWaitingToMinimizeStalls: true, playbackBufferEmpty: false, bufferedAheadSeconds: 4.0))
    }

    @Test("never without the opt-in")
    func offByDefault() {
        #expect(!NativeAVPlayerHost.shouldStartLiveJoinImmediately(
            armed: false, alreadySpent: false, hostWantsToPlay: true,
            isWaitingToMinimizeStalls: true, playbackBufferEmpty: false, bufferedAheadSeconds: 4.0))
    }

    /// One shot, and it belongs to the join. Past it AVPlayer's stall policy is the right one: a live
    /// channel that runs dry mid-stream should wait rather than spin at rate 1 over nothing.
    @Test("a spent one-shot never fires again in the session")
    func onceOnly() {
        #expect(!NativeAVPlayerHost.shouldStartLiveJoinImmediately(
            armed: true, alreadySpent: true, hostWantsToPlay: true,
            isWaitingToMinimizeStalls: true, playbackBufferEmpty: false, bufferedAheadSeconds: 4.0))
    }

    /// An empty buffer is the documented failure shape: `AVPlayer.h` says the call then behaves as if
    /// the buffer had emptied during playback, which is what parks rate at 0 and never resumes.
    @Test("never over an empty buffer")
    func refusesEmptyBuffer() {
        #expect(!NativeAVPlayerHost.shouldStartLiveJoinImmediately(
            armed: true, alreadySpent: false, hostWantsToPlay: true,
            isWaitingToMinimizeStalls: true, playbackBufferEmpty: true, bufferedAheadSeconds: 0.0))
    }

    /// `EvaluatingBufferingRate` is the brief monitoring period Apple documents as not worth showing a
    /// spinner for. Firing there would preempt an evaluation about to start playback by itself.
    @Test("never while AVPlayer is only evaluating its buffering rate")
    func refusesEvaluatingReason() {
        #expect(!NativeAVPlayerHost.shouldStartLiveJoinImmediately(
            armed: true, alreadySpent: false, hostWantsToPlay: true,
            isWaitingToMinimizeStalls: false, playbackBufferEmpty: false, bufferedAheadSeconds: 4.0))
    }

    /// A host that paused during the join asked for a still picture; overriding into motion would
    /// resurrect a session the host put down.
    @Test("never against a host that does not want to play")
    func refusesWithoutPlayIntent() {
        #expect(!NativeAVPlayerHost.shouldStartLiveJoinImmediately(
            armed: true, alreadySpent: false, hostWantsToPlay: false,
            isWaitingToMinimizeStalls: true, playbackBufferEmpty: false, bufferedAheadSeconds: 4.0))
    }

    /// The reason string the host compares against is AVFoundation's own, not a literal of ours.
    @Test("the hold is identified by AVFoundation's own reason constant")
    func reasonConstantIsTheOneAVPlayerPublishes() {
        #expect(AVPlayer.WaitingReason.toMinimizeStalls.rawValue
                == "AVPlayerWaitingToMinimizeStallsReason")
    }

    /// The device A/B that settled this (AE#440, 6.53.0) sampled the buffer across every hold in the
    /// control run and found `empty=false` with 3.7 to 4.9 s ahead of the playhead, for the hold's whole
    /// duration. That is the shape the lever is for: AVPlayer holds a real cushion while it waits on its
    /// own rate estimate, so starting on it costs nothing (0 stalls, 0 drops, 10 of 10 zaps).
    @Test("the depth measured on hardware across the real hold is allowed through")
    func firesAtTheDepthMeasuredOnDevice() {
        for ahead in [3.7, 4.0, 4.9] {
            #expect(NativeAVPlayerHost.shouldStartLiveJoinImmediately(
                armed: true, alreadySpent: false, hostWantsToPlay: true,
                isWaitingToMinimizeStalls: true, playbackBufferEmpty: false,
                bufferedAheadSeconds: ahead))
        }
    }

    /// `isPlaybackBufferEmpty` is the documented MINIMUM from `AVPlayer.h`, not a measure of safety: a
    /// single served fragment reads `false` exactly as a four-second cushion does. Behind that boolean
    /// the device run found 3.7 s; behind the same boolean a starved join can hold 0.2 s, and cutting
    /// the wait short there trades a still picture for an immediate stall. The depth is what separates
    /// them, so the depth is what the guard reads.
    @Test("a non-empty buffer that is only a fragment is still refused")
    func refusesAFragment() {
        for ahead in [0.0, 0.2, 0.9, 1.4] {
            #expect(!NativeAVPlayerHost.shouldStartLiveJoinImmediately(
                armed: true, alreadySpent: false, hostWantsToPlay: true,
                isWaitingToMinimizeStalls: true, playbackBufferEmpty: false,
                bufferedAheadSeconds: ahead))
        }
    }

    @Test("the threshold itself is inclusive, so a cushion exactly at the floor may start")
    func thresholdIsInclusive() {
        #expect(NativeAVPlayerHost.shouldStartLiveJoinImmediately(
            armed: true, alreadySpent: false, hostWantsToPlay: true,
            isWaitingToMinimizeStalls: true, playbackBufferEmpty: false,
            bufferedAheadSeconds: NativeAVPlayerHost.minimumLiveJoinBufferAhead))
    }

    /// A non-finite reading is an absent one. `currentTime()` on an item that has not resolved yields
    /// NaN, and NaN fails every comparison silently, so it must be rejected explicitly rather than by
    /// falling through a `>=`.
    @Test("a non-finite depth is refused rather than compared")
    func refusesNonFiniteDepth() {
        #expect(!NativeAVPlayerHost.shouldStartLiveJoinImmediately(
            armed: true, alreadySpent: false, hostWantsToPlay: true,
            isWaitingToMinimizeStalls: true, playbackBufferEmpty: false,
            bufferedAheadSeconds: .nan))
        #expect(!NativeAVPlayerHost.shouldStartLiveJoinImmediately(
            armed: true, alreadySpent: false, hostWantsToPlay: true,
            isWaitingToMinimizeStalls: true, playbackBufferEmpty: false,
            bufferedAheadSeconds: .infinity))
    }

    /// Both readings have to agree. AVPlayer calling the buffer empty outranks a span that looks deep,
    /// because the empty flag is the one `AVPlayer.h` ties the failure mode to.
    @Test("AVPlayer's own empty flag outranks a deep-looking span")
    func emptyFlagOutranksDepth() {
        #expect(!NativeAVPlayerHost.shouldStartLiveJoinImmediately(
            armed: true, alreadySpent: false, hostWantsToPlay: true,
            isWaitingToMinimizeStalls: true, playbackBufferEmpty: true,
            bufferedAheadSeconds: 4.0))
    }

    /// The depth is the CONTIGUOUS span ahead of the playhead, not the sum of every loaded range: an
    /// island past a gap cannot sustain a rate that has to cross the gap to reach it.
    @Test("an island past a gap does not count toward the depth")
    func depthIgnoresIslandPastGap() {
        let now = 100.0
        let ranges = [(100.0, 100.6), (120.0, 128.0)]
        let ahead = NativeAVPlayerHost.contiguousBufferedEnd(ranges: ranges, now: now) - now
        #expect(abs(ahead - 0.6) < 0.001)
        #expect(!NativeAVPlayerHost.shouldStartLiveJoinImmediately(
            armed: true, alreadySpent: false, hostWantsToPlay: true,
            isWaitingToMinimizeStalls: true, playbackBufferEmpty: false,
            bufferedAheadSeconds: ahead))
    }

    /// The default is what a host gets without asking, and since 6.55.0 that is on: the device A/B
    /// measured the join tail removed (press-to-motion 6.4-7.2 s down to 4.3-5.6 s) with stalls and
    /// drops unchanged at zero in both arms.
    @Test("a live join starts immediately unless the host opts out")
    func defaultIsOn() {
        #expect(LoadOptions().liveJoinStartsImmediately)
        #expect(!LoadOptions(liveJoinStartsImmediately: false).liveJoinStartsImmediately)
    }

    /// An inherited property of the span helper, pinned here because the floor is 1.5 s and this can
    /// move the reading by up to 1 s: `contiguousBufferedEnd` treats a range starting within a second
    /// AFTER the playhead as contiguous with it (AE#422 kept that tolerance for the gap between the
    /// rendered frame and the range's reported start). It cannot reach the join case, since the lever
    /// only runs once a frame is presented over a buffer AVPlayer calls non-empty, but a reader of the
    /// floor should see it rather than infer a stricter measure than exists.
    @Test("a sub-tolerance gap ahead of the playhead is bridged, not subtracted")
    func toleranceBridgesASubSecondGap() {
        let ahead = NativeAVPlayerHost.contiguousBufferedEnd(ranges: [(100.8, 103.0)], now: 100.0) - 100.0
        #expect(abs(ahead - 3.0) < 0.001)
    }
}
