import Foundation

/// AE#464: the audio presentation offset as a live setting.
///
/// Lip-sync error belongs to the viewer's chain (a soundbar or AVR adding video-processing latency,
/// or the reverse), not to the file, so it is a per-setup nudge people set once and expect a player
/// to honour on every session. AVFoundation offers a host nothing to set it with: `AVPlayerItem`
/// carries no audio-delay control, and an HLS-streamed asset vends no `AVAssetTrack` for an
/// `AVAudioMix` to bind to. Where the timestamps still exist is inside the engine, which is why this
/// lives here rather than on top.
extension AetherEngine {

    /// The audio presentation offset in force for this session, in seconds. Positive presents audio
    /// LATER relative to video. 0 (the default) means untouched.
    public var audioDelaySeconds: Double { loadedOptions.audioDelaySeconds }

    /// Change the audio presentation offset while playback runs.
    ///
    /// Positive delays audio, negative advances it; the value is clamped to
    /// `AudioDelayPolicy.maxAbsSeconds` and survives every rebuild the session makes on its own
    /// (reload at position, audio-track switch, AirPlay LAN swap, background return), because it is
    /// stored in the options those rebuilds replay. Passing the value already in force does nothing.
    ///
    /// **What it costs, per route.** The offset moves audio at the last place the engine still holds
    /// its timestamps, and on both routes the media between there and the speaker is already
    /// committed to the previous value: up to `AudioLookaheadPolicy.targetLeadSeconds` of decoded
    /// audio on `.software`, and the segments AVPlayer has already fetched on `.loopback`, whose cut
    /// audio cannot be re-timed in place (the seam would gain a gap or an overlap of exactly the
    /// change, and a change that moves audio earlier is eaten by the muxer's strictly-increasing DTS
    /// rule). So a change is applied by re-anchoring at the playhead, which costs what a seek to the
    /// current position costs and is the reason this is not free the way `setRate` is. A session that
    /// cannot seek (live without a DVR window) keeps the value and lets it arrive at the next seam
    /// the session makes on its own, rather than being denied it.
    ///
    /// On `.remoteBypass` AVPlayer owns the whole media selection and the engine never sees the
    /// timestamps, and an audio-only session has no video for audio to be early or late against. Both
    /// keep the value for a later load and log the no-op, in `selectAudioTrack`'s style: a host that
    /// set it and heard nothing change cannot otherwise tell "this route cannot" from "it did not
    /// arrive".
    public func setAudioDelay(_ seconds: Double) {
        let requested = seconds
        let clamped = AudioDelayPolicy.clamp(requested)
        if AudioDelayPolicy.isOutOfRange(requested) {
            EngineLog.emit(
                "[AetherEngine] AE#464: audio delay \(Self.ms(requested)) is outside "
                + "+/-\(Self.ms(AudioDelayPolicy.maxAbsSeconds)); using \(Self.ms(clamped))",
                category: .engine
            )
        }
        guard AudioDelayPolicy.isChange(from: loadedOptions.audioDelaySeconds, to: clamped) else { return }
        setLoadedAudioDelay(clamped)

        let route = videoRoute
        switch AudioDelayPolicy.application(for: route) {
        case .unavailable:
            EngineLog.emit(
                "[AetherEngine] AE#464: audio delay = \(Self.ms(clamped)), kept for the next load: "
                + "this session's audio timestamps are not the engine's to move (route=\(route.rawValue))",
                category: .engine
            )

        case .sampleTimestamps:
            softwareHost?.setAudioDelay(clamped)
            EngineLog.emit(
                "[AetherEngine] AE#464: audio delay = \(Self.ms(clamped)) on the software path",
                category: .engine
            )
            recutForAudioDelay(clamped)

        case .segmentTimestamps:
            guard let session = nativeVideoSession else { return }
            let idx = session.applyAudioDelay(clamped, recuttingFromPlaylistTime: currentTime)
            EngineLog.emit(
                "[AetherEngine] AE#464: audio delay = \(Self.ms(clamped)) on the loopback path, "
                + "segments from \(idx) dropped to be re-cut",
                category: .engine
            )
            reanchorProducerForAudioDelay(at: idx, session: session)
            recutForAudioDelay(clamped)
        }
    }

    /// Bring the change to the playhead instead of waiting for the media already committed to the old
    /// value to drain. Deliberately the ordinary seek: it is the one path that makes AVPlayer let go
    /// of what it has buffered and the software host flush what it has decoded, and both routes need
    /// exactly that. Live without a DVR window has no position to return to, so the value simply
    /// stands from the next seam the session makes on its own.
    private func recutForAudioDelay(_ delay: Double) {
        guard Self.audioDelayRecutIsPossible(state: state, isLive: isLive, hasLiveWindow: liveWindow != nil) else {
            EngineLog.emit(
                "[AetherEngine] AE#464: audio delay = \(Self.ms(delay)) stands, but this session cannot "
                + "re-anchor at the playhead (state=\(state), live=\(isLive)); it arrives at the next seam",
                category: .engine
            )
            return
        }
        let position = currentTime
        Task { @MainActor in
            await self.seek(to: position, origin: .host)
        }
    }

    /// Rebuild the producer at the playhead so the segments the seek is about to ask for are cut by a
    /// muxer carrying the new offset. Authoritative for the same reason the seek-deadline re-anchor
    /// is: a stale in-flight scrub target must not win the coalescer and leave the producer cutting
    /// somewhere else. `requestRestart` does blocking teardown, so it runs off-main.
    private func reanchorProducerForAudioDelay(at index: Int, session: HLSVideoEngine) {
        Task.detached {
            session.requestRestart(at: index, authoritative: true)
        }
    }

    /// Whether the session has a playhead to come back to. Pure so the rule is testable without a
    /// session: the states that carry no position are the same ones `seek` refuses, and a live source
    /// without a DVR window has no seekable range at all.
    static func audioDelayRecutIsPossible(state: PlaybackState, isLive: Bool, hasLiveWindow: Bool) -> Bool {
        switch state {
        case .idle, .loading, .ended, .error: return false
        default: break
        }
        return !isLive || hasLiveWindow
    }

    /// Milliseconds, for log lines. The unit the correction is actually reasoned about in.
    static func ms(_ seconds: Double) -> String {
        String(format: "%+.0f ms", seconds * 1000)
    }
}
