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
            isWaitingToMinimizeStalls: true, playbackBufferEmpty: false))
    }

    @Test("never without the opt-in")
    func offByDefault() {
        #expect(!NativeAVPlayerHost.shouldStartLiveJoinImmediately(
            armed: false, alreadySpent: false, hostWantsToPlay: true,
            isWaitingToMinimizeStalls: true, playbackBufferEmpty: false))
    }

    /// One shot, and it belongs to the join. Past it AVPlayer's stall policy is the right one: a live
    /// channel that runs dry mid-stream should wait rather than spin at rate 1 over nothing.
    @Test("a spent one-shot never fires again in the session")
    func onceOnly() {
        #expect(!NativeAVPlayerHost.shouldStartLiveJoinImmediately(
            armed: true, alreadySpent: true, hostWantsToPlay: true,
            isWaitingToMinimizeStalls: true, playbackBufferEmpty: false))
    }

    /// An empty buffer is the documented failure shape: `AVPlayer.h` says the call then behaves as if
    /// the buffer had emptied during playback, which is what parks rate at 0 and never resumes.
    @Test("never over an empty buffer")
    func refusesEmptyBuffer() {
        #expect(!NativeAVPlayerHost.shouldStartLiveJoinImmediately(
            armed: true, alreadySpent: false, hostWantsToPlay: true,
            isWaitingToMinimizeStalls: true, playbackBufferEmpty: true))
    }

    /// `EvaluatingBufferingRate` is the brief monitoring period Apple documents as not worth showing a
    /// spinner for. Firing there would preempt an evaluation about to start playback by itself.
    @Test("never while AVPlayer is only evaluating its buffering rate")
    func refusesEvaluatingReason() {
        #expect(!NativeAVPlayerHost.shouldStartLiveJoinImmediately(
            armed: true, alreadySpent: false, hostWantsToPlay: true,
            isWaitingToMinimizeStalls: false, playbackBufferEmpty: false))
    }

    /// A host that paused during the join asked for a still picture; overriding into motion would
    /// resurrect a session the host put down.
    @Test("never against a host that does not want to play")
    func refusesWithoutPlayIntent() {
        #expect(!NativeAVPlayerHost.shouldStartLiveJoinImmediately(
            armed: true, alreadySpent: false, hostWantsToPlay: false,
            isWaitingToMinimizeStalls: true, playbackBufferEmpty: false))
    }

    /// The reason string the host compares against is AVFoundation's own, not a literal of ours.
    @Test("the hold is identified by AVFoundation's own reason constant")
    func reasonConstantIsTheOneAVPlayerPublishes() {
        #expect(AVPlayer.WaitingReason.toMinimizeStalls.rawValue
                == "AVPlayerWaitingToMinimizeStallsReason")
    }
}
