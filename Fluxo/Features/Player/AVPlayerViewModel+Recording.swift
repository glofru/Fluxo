//
//  AVPlayerViewModel+Recording.swift
//  Fluxo
//
//  Recording the playing live channel, and its limits (duration, free space).
//

import AVKit
import OSLog
import SwiftUI

private let logger = Logger(subsystem: "dev.watermelon.Fluxo", category: "Player")

extension AVPlayerViewModel {
    // MARK: - Recording

    func toggleRecording() {
        if isRecording {
            stopRecording()
        } else {
            startRecording()
        }
    }

    func startRecording() {
        guard canRecord, !isRecording else {
            return
        }
        if let available = PlatformStorage.availableCapacity(at: recordings.directory), available < RecordingLimits.minimumFreeSpaceToStart {
            logger.error("Not enough free space to start a recording: \(available) bytes")
            recordingError = RecordingLimits.notEnoughSpaceToStartMessage
            return
        }
        let url = recordings.makeRecordingURL(channelName: currentChannel?.name)
        do {
            try remuxer.startRecording(to: url)
            recordings.recordingDidStart(url, title: currentChannel?.name, logo: currentChannel?.logo)
            recordingError = nil
            recordingLimitReached = false
            lastRecordingSpaceCheck = 0
            isRecording = true
            timeline.updateRecordingDuration(0)
        } catch {
            recordingError = error.localizedDescription
        }
    }

    /// Stops the recording (keeping what it recorded) at the length set in Settings, or when the device is nearly
    /// full: the engine itself only stops on a write error, once the disk is already full.
    func enforceRecordingLimits(duration: TimeInterval) {
        guard isRecording, !recordingLimitReached else {
            return
        }
        if let maximum = RecordingLimits.maximumDuration, duration >= maximum {
            logger.info("Recording reached its limit of \(maximum)s: stopping")
            recordingLimitReached = true
            stopRecording()
            recordingError = RecordingLimits.stoppedAtLimitMessage(duration: maximum)
            return
        }
        guard duration - lastRecordingSpaceCheck >= RecordingLimits.freeSpaceCheckInterval else {
            return
        }
        lastRecordingSpaceCheck = duration
        if let available = PlatformStorage.availableCapacity(at: recordings.directory), available < RecordingLimits.minimumFreeSpaceWhileRecording {
            logger.error("The device is nearly full (\(available) bytes free): stopping the recording")
            recordingLimitReached = true
            stopRecording()
            recordingError = RecordingLimits.stoppedForSpaceMessage
        }
    }

    func stopRecording() {
        remuxer.stopRecording()
    }

    func clearRecordingError() {
        recordingError = nil
    }
}
