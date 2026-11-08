//
//  AVPlayerViewModel+Cast.swift
//  Fluxo
//
//  Playback on a Chromecast.
//

import AVKit
import OSLog
import SwiftUI

private let logger = Logger(subsystem: "dev.watermelon.Fluxo", category: "Player")

extension AVPlayerViewModel {
    // MARK: - Chromecast
    //
    // While a Cast session is connected, a channel that is played goes to the receiver (Google's Default Media
    // Receiver) as its original stream URL, see `CastMedia`. Local playback stops while the Chromecast plays (the
    // engine and the player item are torn down, so the IPTV provider sees one connection, the receiver's; a
    // running recording is finished and saved), and the transport (play / pause, skip, scrubbing, channel up /
    // down, stop) drives the receiver. When casting ends (Stop Casting, the session drops), the channel plays here
    // again, on-demand media from the receiver's position. A channel the receiver cannot play keeps playing here,
    // with `castError` explaining why.

    func clearCastError() {
        castError = nil
    }

    /// Stops casting and plays the channel on this device again.
    func stopCasting() {
        cast.disconnect()
    }

    func handleCast(_ event: CastController.Event) {
        switch event {
        case .sessionStarted(let resumed):
            if isCasting {
                // Back from the background: the receiver kept playing.
                startCastTimeline()
                refreshPlaybackState()
            } else if currentChannel != nil {
                guard !resumed || isLocalPlaybackSuspended else {
                    return
                }
                let startTime = pendingCastStartTime ?? localOnDemandPosition
                pendingCastStartTime = nil
                castCurrentChannel(startTime: startTime)
            } else if resumed {
                adoptsResumedCastMedia = true
                adoptCastMedia()
            }

        case .sessionEnded(let error, let switchingDevice):
            adoptsResumedCastMedia = false
            guard isCasting else {
                // Nothing was cast (e.g. the channel could not be): a message about it is over with the session.
                if error == nil {
                    castError = nil
                }
                return
            }
            if let message = error?.message {
                castError = String(localized: "Casting stopped. \(message)", comment: "Cast error; the placeholder is the reason given by the Cast device.")
            }
            if isCastAdopted {
                endCastingState()
                stop()
                return
            }
            let position = castOnDemandPosition
            if switchingDevice {
                // The next device gets the channel as soon as its session starts.
                endCastingState()
                pendingCastStartTime = position
                refreshPlaybackState()
            } else {
                resumeLocalPlayback(at: position)
            }

        case .sessionFailedToStart:
            adoptsResumedCastMedia = false
            if isCasting || isLocalPlaybackSuspended {
                let position = pendingCastStartTime
                pendingCastStartTime = nil
                resumeLocalPlayback(at: position)
            }

        case .mediaStatusChanged:
            if isCasting, castMediaWasReplaced {
                // Another sender loaded something else on the receiver: show (and control) that instead.
                logger.info("Another sender replaced the cast media")
                endCastingState()
                stop()
                adoptsResumedCastMedia = true
                adoptCastMedia()
            } else if isCasting {
                updateCastTimeline()
                updateCastTracks()
                refreshPlaybackState()
            } else if adoptsResumedCastMedia {
                adoptCastMedia()
            }
        }
    }

    /// The receiver's audio and text tracks in the Audio and Subtitles menu while casting, the local ones otherwise.
    func updateCastTracks() {
        guard isCasting else {
            mediaSelection.hideCastTracks()
            return
        }
        mediaSelection.showCastTracks(cast.mediaStatus) { [weak self] trackIDs in
            self?.cast.setActiveTracks(trackIDs)
        }
    }

    /// Makes `channel` the current one and sends it to the receiver.
    func castChannel(_ channel: PlayableChannel) {
        if channel != currentChannel {
            if !isLocalPlaybackSuspended {
                // The previous channel was playing here (it could not be cast): it stops either way.
                surface.stopPictureInPicture()
                tearDownPlayback()
                isLocalPlaybackSuspended = true
            }
            currentChannel = channel
            streamError = nil
            castResumePosition = nil
        }
        castCurrentChannel(startTime: nil)
    }

    /// Sends the current channel to the connected receiver, trying the fallbacks of `CastMedia` in turn.
    func castCurrentChannel(startTime: TimeInterval?) {
        guard let channel = currentChannel, let device = cast.connectedDevice else {
            return
        }
        let isLive = currentItem.map { $0.kind == .live } ?? (channel.url.map { PlaybackRoute(url: $0).isLiveRemux } ?? true)
        switch CastMedia.requests(for: channel.url, title: channel.name, subtitle: currentItem?.groupName, logo: channel.logo, isLive: isLive, startTime: startTime) {
        case .failure(let reason):
            logger.info("Not casting: \(reason.message, privacy: .public)")
            castError = reason.message
            resumeLocalPlayback(at: startTime)
        case .success(let requests):
            castError = nil
            if !isLocalPlaybackSuspended {
                surface.stopPictureInPicture()
                tearDownPlayback()
                isLocalPlaybackSuspended = true
            }
            isCasting = true
            isCastAdopted = false
            isCastLoading = true
            castMediaURL = nil
            castLoadGeneration &+= 1
            timeline.reset()
            canSeek = false
            loadOnCast(requests[...], deviceName: device.name, originalURL: channel.url, generation: castLoadGeneration, lastFailure: nil)
            startCastTimeline()
            refreshPlaybackState()
        }
    }

    private func loadOnCast(_ requests: ArraySlice<CastLoadRequest>, deviceName: String, originalURL: URL?, generation: Int, lastFailure: CastFailure?) {
        guard let request = requests.first else {
            // Every stream failed: play the channel here again, and say why.
            let failure = lastFailure ?? CastFailure(kind: .media, message: nil)
            castError = CastMedia.failureMessage(for: originalURL, deviceName: deviceName, failure: failure)
            resumeLocalPlayback(at: nil)
            return
        }
        cast.load(request) { [weak self] result in
            guard let self, generation == self.castLoadGeneration, self.isCasting else {
                return
            }
            switch result {
            case .success:
                logger.info("Casting \(request.contentType, privacy: .public) to the receiver")
                self.isCastLoading = false
                self.castMediaURL = request.url
                self.updateCastTimeline()
                self.refreshPlaybackState()
            case .failure(let failure) where failure.kind == .cancelled:
                // Declined (e.g. the Cast terms) or replaced: never retried automatically.
                self.resumeLocalPlayback(at: request.startTime)
            case .failure(let failure) where failure.kind == .media && requests.count > 1:
                logger.info("The receiver refused \(request.contentType, privacy: .public); trying the next stream")
                self.loadOnCast(requests.dropFirst(), deviceName: deviceName, originalURL: originalURL, generation: generation, lastFailure: failure)
            case .failure(let failure):
                self.loadOnCast([], deviceName: deviceName, originalURL: originalURL, generation: generation, lastFailure: failure)
            }
        }
    }

    /// Plays the current channel on this device again, from `position` for on-demand media.
    private func resumeLocalPlayback(at position: TimeInterval?) {
        endCastingState()
        defer {
            refreshPlaybackState()
        }
        guard isLocalPlaybackSuspended, let channel = currentChannel else {
            // Still playing here (the channel could not be cast at all).
            return
        }
        guard let url = channel.url else {
            isLocalPlaybackSuspended = false
            streamError = String(localized: "This channel has no valid stream URL.", comment: "Player error: the playlist entry has no usable address.")
            return
        }
        let resume = position.flatMap { $0 > 1 ? $0 : nil }
        start(channel, url: url, startTime: resume)
        pendingResumePosition = resume
    }

    /// Clears the casting state (the session itself is left as it is).
    func endCastingState() {
        castLoadGeneration &+= 1
        castTimelineTask?.cancel()
        castTimelineTask = nil
        isCastLoading = false
        castMediaURL = nil
        castResumePosition = nil
        isCastAdopted = false
        guard isCasting else {
            return
        }
        isCasting = false
        canSeek = false
        timeline.reset()
    }

    /// A session the SDK resumed while nothing plays here (the app was relaunched while casting): show what the
    /// receiver plays, so the mini player and the player can control it.
    private func adoptCastMedia() {
        guard currentChannel == nil, cast.isConnected, let status = cast.mediaStatus, let url = status.contentURL,
              status.playerState != .idle else {
            return
        }
        adoptsResumedCastMedia = false
        currentItem = nil
        currentChannel = PlayableChannel(id: UUID(), name: status.title, logo: nil, url: url)
        isLocalPlaybackSuspended = true
        isCasting = true
        isCastAdopted = true
        castMediaURL = url
        startCastTimeline()
        updateCastTimeline()
        refreshPlaybackState()
    }

    /// The position of on-demand media playing here, to start the receiver at.
    private var localOnDemandPosition: TimeInterval? {
        guard !isCasting, !isLocalPlaybackSuspended, canSeek, !isTimeShiftAvailable, timeline.duration > 0 else {
            return nil
        }
        return timeline.currentTime
    }

    /// The receiver's position in on-demand media, to continue at on this device.
    private var castOnDemandPosition: TimeInterval? {
        guard let status = cast.mediaStatus, !status.isLive, status.duration > 0 else {
            return nil
        }
        return cast.streamPosition()
    }

    /// The receiver plays other media than the one sent to it: another sender (a phone, Google Home) loaded
    /// something in the same Default Media Receiver session. Only a status that is playing or paused counts, as
    /// the receiver may still report the previous media for a moment while it loads the new one.
    private var castMediaWasReplaced: Bool {
        guard !isCastLoading, let sent = castMediaURL, let status = cast.mediaStatus, let url = status.contentURL else {
            return false
        }
        return !CastMedia.isSameMedia(url, sent) && (status.playerState == .playing || status.playerState == .paused)
    }

    func seekOnCast(to seconds: TimeInterval) {
        guard canSeek else {
            return
        }
        cast.seek(to: min(max(0, seconds), max(0, timeline.duration - 1)))
    }

    var castPlaybackState: PlaybackState {
        if isCastLoading {
            return .connecting
        }
        // A status of the previous media (the receiver reports it until the new one starts).
        guard let status = cast.mediaStatus, status.contentURL == nil || castMediaURL == nil || CastMedia.isSameMedia(status.contentURL, castMediaURL) else {
            return .buffering
        }
        switch status.playerState {
        case .playing:
            return .playing
        case .paused:
            return .paused
        case .buffering, .loading:
            return .buffering
        case .idle:
            if status.idleReason == .error {
                let device = cast.connectedDevice?.name ?? String(localized: "The Cast device", comment: "Stands in for the Chromecast name in an error when the name is unknown.")
                return .failed(String(localized: "\(device) stopped playing this stream.", comment: "Cast error; the placeholder is the Chromecast name."))
            }
            return .ended
        }
    }

    private func startCastTimeline() {
        castTimelineTask?.cancel()
        castTimelineTask = Task { [weak self] in
            while !Task.isCancelled {
                self?.updateCastTimeline()
                try? await Task.sleep(for: .milliseconds(500))
            }
        }
    }

    private func updateCastTimeline() {
        guard isCasting, !isCastLoading, let status = cast.mediaStatus else {
            return
        }
        let duration = status.isLive ? 0 : status.duration
        timeline.update(
            currentTime: cast.streamPosition(),
            duration: duration,
            seekableStart: 0,
            seekableEnd: duration,
            timeBehindLive: 0,
            liveLatency: 0,
            isAtLiveEdge: true
        )
        if !status.isLive, duration > 0, status.contentURL == nil || CastMedia.isSameMedia(status.contentURL, castMediaURL),
           status.playerState == .playing || status.playerState == .paused {
            castResumePosition = cast.streamPosition()
        }
        let seekable = !status.isLive && duration > 2 && status.canSeek
        if seekable != canSeek {
            canSeek = seekable
            updateNowPlaying()
        }
    }
}
