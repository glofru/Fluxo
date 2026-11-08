//
//  AVPlayerViewModel+AudioSession.swift
//  Fluxo
//
//  The audio session of playback and its interruptions.
//

import AVKit
import Combine
import OSLog
import SwiftUI

private let logger = Logger(subsystem: "dev.watermelon.Fluxo", category: "Player")

extension AVPlayerViewModel {
    // MARK: - Audio session

    func activateAudioSession() {
        #if !os(macOS)
        let session = AVAudioSession.sharedInstance()
        do {
            // Required for background audio and Picture in Picture.
            try session.setCategory(.playback, mode: .moviePlayback)
            try session.setActive(true)
        } catch {
            logger.error("Unable to activate the playback audio session: \(error.localizedDescription, privacy: .public)")
        }
        #endif
    }

    func deactivateAudioSession() {
        #if !os(macOS)
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        #endif
    }

    /// Resumes playback when the system recommends it after an interruption (a call, Siri, another app's audio).
    func observeAudioSession() {
        #if os(iOS)
        NotificationCenter.default.publisher(for: AVAudioSession.resumptionRecommendationNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] notification in
                guard let context = notification.userInfo?[AVAudioSession.resumptionContextKey] as? AVAudioSession.ResumptionContext,
                      context.recommendation == .shouldResume else {
                    return
                }
                self?.play()
            }
            .store(in: &cancellables)
        #elseif os(tvOS)
        // tvOS 26 has only the interruption notification (the resumption recommendation is tvOS 27).
        NotificationCenter.default.publisher(for: AVAudioSession.interruptionNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] notification in
                guard let info = notification.userInfo,
                      let rawType = info[AVAudioSessionInterruptionTypeKey] as? UInt,
                      AVAudioSession.InterruptionType(rawValue: rawType) == .ended,
                      let rawOptions = info[AVAudioSessionInterruptionOptionKey] as? UInt,
                      AVAudioSession.InterruptionOptions(rawValue: rawOptions).contains(.shouldResume) else {
                    return
                }
                self?.play()
            }
            .store(in: &cancellables)
        #endif
    }
}
