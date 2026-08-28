import Foundation
import CoreGraphics

extension AetherEngine {

    /// Frame from the DVR segment cache at `atSessionSeconds` (seekableLiveRange axis). No network: converts session time to raw output via seam history, then decodes locally. nil when no native live session, time outside resident window, or decode fails.
    public func liveScrubThumbnail(atSessionSeconds seconds: Double, maxWidth: Int = 320) async -> CGImage? {
        guard isLive, let session = nativeVideoSession else { return nil }
        // seekableLiveRange is output-time + seam shift; segment table and tfdt live on raw output. Resolve newest seam (inverts $currentTime fold).
        let outputSeconds: Double
        outputSeconds = presentationAxis.itemSeconds(forSourceSeconds: seconds)
            ?? (seconds - playlistShiftSeconds)
        let gen = loadGeneration
        let source = await Task.detached(priority: .userInitiated) { [session] in
            session.scrubThumbnailSource(atSeconds: outputSeconds)
        }.value
        guard let source else { return nil }
        // Guard against zap/stop clearing the LRU: a stale extractor's segment indices collide with the next channel's.
        guard loadGeneration == gen else { return nil }
        let extractor: FrameExtractor
        if let idx = scrubThumbnailExtractors.firstIndex(where: { $0.segmentIndex == source.segmentIndex }) {
            let hit = scrubThumbnailExtractors.remove(at: idx)
            scrubThumbnailExtractors.append(hit)
            extractor = hit.extractor
        } else {
            extractor = FrameExtractor(reader: DataIOReader(data: source.data), formatHint: "mp4")
            scrubThumbnailExtractors.append((source.segmentIndex, extractor))
            while scrubThumbnailExtractors.count > 2 {
                let evicted = scrubThumbnailExtractors.removeFirst()
                Task { await evicted.extractor.shutdown() }
            }
        }
        return await extractor.thumbnail(at: outputSeconds, maxWidth: maxWidth)
    }

    /// 1 Hz timer to update live surfaces while paused (the `$currentTime` sink already covers the playing case).
    func startLiveWindowTimer(host: NativeAVPlayerHost) {
        liveWindowTimerTask?.cancel()
        guard isLive else { return }
        liveWindowTimerTask = Task { [weak self, weak host] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                guard let self, let host else { return }
                guard self.isLive else { continue }
                self.publishLiveWindow(edgeSessionTime: host.seekableEnd + self.playlistShiftSeconds)
            }
        }
    }

    /// How far behind a live-only session (no DVR window) must be on resume before the playhead counts as
    /// evicted rather than merely behind. A live-only source retains seconds, not minutes.
    nonisolated static let liveOnlyResumeSnapSeconds: Double = 45
    /// Landing margin above the retained floor, so the resume does not start on the very segment the next
    /// eviction takes.
    nonisolated static let liveResumeClampMarginSeconds: Double = 5

    /// What resuming a behind-live session should do to the playhead, as one pure decision (AE#444).
    ///
    /// Both non-`none` outcomes are recoveries from a position that no longer exists, not policy about
    /// where a viewer should be: a live-only source retains seconds, and a DVR window that has slid past
    /// the playhead has evicted it. `clampsToWindow == false` hands that judgement to the host, which is
    /// the only place semantics like "a pause longer than 90 s re-tunes" can live.
    enum LiveResumeAction: Equatable {
        case none
        /// Live-only: `seek(to:)` refuses targets without a DVR window, so this drives the host directly.
        case edgeSnap
        case seek(to: Double)
    }

    nonisolated static func liveResumeAction(
        clampsToWindow: Bool,
        windowSeconds: Double?,
        behindLiveSeconds: Double,
        seekableLowerBound: Double?,
        edgeTime: Double
    ) -> LiveResumeAction {
        guard clampsToWindow else { return .none }
        let margin = liveResumeClampMarginSeconds
        guard let window = windowSeconds else {
            return behindLiveSeconds > liveOnlyResumeSnapSeconds ? .edgeSnap : .none
        }
        guard behindLiveSeconds > (window - margin) else { return .none }
        // AE#441: the lower bound is the cache's real floor now, so this lands on content that exists.
        return .seek(to: (seekableLowerBound ?? edgeTime) + margin)
    }

    /// After a long pause the sliding DVR window may have evicted the playhead. Clamp to the retained
    /// floor plus a margin, or for live-only (no DVR) snap to the edge when far enough behind.
    func clampLiveResumeIfBehindWindow() {
        guard isLive, let w = liveWindow else { return }
        let action = Self.liveResumeAction(
            clampsToWindow: loadedOptions.clampsLiveResumeToWindow,
            windowSeconds: w.windowSeconds,
            behindLiveSeconds: w.behindLiveSeconds,
            seekableLowerBound: w.seekableRange?.lowerBound,
            edgeTime: w.edgeTime
        )
        let behind = String(format: "%.1f", w.behindLiveSeconds)
        let window = w.windowSeconds.map { String(format: "%.0f", $0) } ?? "live-only"
        switch action {
        case .none:
            // AE#444: a resume the host owns says so. Silence here is indistinguishable from a resume
            // that was never behind, and this option exists precisely so somebody else decides.
            if !loadedOptions.clampsLiveResumeToWindow,
               w.behindLiveSeconds > Self.liveOnlyResumeSnapSeconds {
                EngineLog.emit(
                    "[AetherEngine] live resume clamp deferred to host: behind=\(behind)s window=\(window)",
                    category: .session
                )
            }
        case .edgeSnap:
            EngineLog.emit(
                "[AetherEngine] live resume clamp: behind=\(behind)s window=live-only -> edge snap",
                category: .session
            )
            Task { await self.seekToLiveEdge() }
        case .seek(let t):
            EngineLog.emit(
                "[AetherEngine] live resume clamp: behind=\(behind)s window=\(window) "
                + "-> seek \(String(format: "%.1f", t))",
                category: .session
            )
            Task { await self.seek(to: t) }
        }
    }

    /// AE#441: the segment cache's oldest contiguously-playable position, lifted onto the session axis
    /// the live surfaces speak. nil on every path with no such cache to ask (software live), which
    /// leaves `seekableLiveRange` on window arithmetic exactly as before.
    ///
    /// Same axis conversion as `liveScrubThumbnail`, inverted: the segment table and its `startSeconds`
    /// live on raw output, `seekableLiveRange` is output plus the seam shift.
    func residentLiveFloorSessionSeconds() -> Double? {
        guard let session = nativeVideoSession,
              let outputFloor = session.residentFloorOutputSeconds() else { return nil }
        return presentationAxis.sourceSeconds(forItemSeconds: outputFloor)
            ?? (outputFloor + playlistShiftSeconds)
    }

    /// AE#442: the TARGETDURATION the live playlist is serving, nil on every path that serves none
    /// (remote HLS live, the software live path, and before the first playlist build).
    var liveTargetDurationSeconds: Double? {
        nativeVideoSession?.sealedLiveTargetDurationSeconds().map(Double.init)
    }

    /// Publish `liveEdgeTime`, `seekableLiveRange`, `isAtLiveEdge`, `behindLiveSeconds`. Path-agnostic; no-op when no live window is active.
    @MainActor
    func publishLiveWindow(edgeSessionTime: Double) {
        guard var w = liveWindow else { return }
        w.noteEdge(edgeSessionTime)
        w.notePlayhead(currentTime)
        w.noteResidentFloor(residentLiveFloorSessionSeconds())
        liveWindow = w
        // AE#442: tick-to-tick advancement, not a running maximum: a backward DVR seek drops the
        // playhead, and the next advancing publish has to be able to record the new, larger distance.
        if let previous = lastPublishedLivePlayhead, currentTime > previous + 0.05 {
            liveBehindWhenLastAdvancing = w.behindLiveSeconds
        }
        lastPublishedLivePlayhead = currentTime
        clock.liveEdgeTime = w.edgeTime
        clock.seekableLiveRange = w.seekableRange
        clock.isAtLiveEdge = w.isAtEdge
        clock.behindLiveSeconds = w.behindLiveSeconds
    }

    /// Seek to the current live edge. No-op when not live.
    public func seekToLiveEdge() async {
        guard isLive, let w = liveWindow else { return }
        // Live-only (no DVR window): seek(to:) refuses; drive native host directly to seekableEnd as the recovery move after eviction.
        guard w.windowSeconds != nil else {
            if let host = nativeHost {
                let clockTarget = max(0, host.seekableEnd)
                EngineLog.emit(
                    "[AetherEngine] live-only edge snap: clockTarget=\(String(format: "%.1f", clockTarget))",
                    category: .engine
                )
                await host.seek(to: clockTarget)
                nativeClockSeconds = clockTarget
                clock.currentTime = clockTarget + playlistShiftSeconds
                clock.sourceTime = currentTime
            }
            return
        }
        await seek(to: w.edgeTime)
    }
}
