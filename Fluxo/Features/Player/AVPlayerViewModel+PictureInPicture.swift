//
//  AVPlayerViewModel+PictureInPicture.swift
//  Fluxo
//
//  Picture in Picture through the player surface.
//

import AVKit
import OSLog
import SwiftUI

private let logger = Logger(subsystem: "dev.watermelon.Fluxo", category: "Player")

extension AVPlayerViewModel {
    // MARK: - Picture in Picture

    func configureSurface() {
        surface.onPictureInPictureActiveChange = { [weak self] isActive in
            guard let self else {
                return
            }
            logger.info("Picture in Picture active: \(isActive, privacy: .public)")
            self.isPictureInPictureActive = isActive
            self.applyEnergyProfile()
            if isActive {
                // Let the user browse while the video plays in PiP. The surface (and with it the
                // controller that drives PiP) stays alive in this model.
                self.isClosingIntoPictureInPicture = false
                self.isPresented = false
            }
        }
        surface.onRestoreUserInterface = { [weak self] completion in
            guard let self else {
                completion(false)
                return
            }
            // `stop()` ends PiP from code and AVKit then asks to restore asynchronously, after
            // playback is already gone. Never reopen an empty player screen for that.
            guard self.currentChannel != nil else {
                completion(false)
                return
            }
            if self.isPresented && self.isPlayerUIVisible {
                completion(true)
                return
            }
            self.completePendingRestore(false)
            self.pendingRestoreCompletion = completion
            // Coming back from PiP: the mini player is the only source sure to be on screen.
            self.presentationSourceID = nil
            self.isPresented = true
            // Never leave PiP waiting if the player screen cannot appear.
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                self?.completePendingRestore(true)
            }
        }
        surface.onPictureInPictureError = { [weak self] error in
            guard let self else {
                return
            }
            if self.isClosingIntoPictureInPicture {
                // Closing the screen was asking for PiP: just close it, playback goes on in the mini player.
                logger.error("Picture in Picture did not start on close: \(error.localizedDescription, privacy: .public)")
                self.finishClosingIntoPictureInPicture()
            } else {
                self.streamError = error.localizedDescription
            }
        }
        surface.onPictureInPicturePossibleChange = { [weak self] isPossible in
            self?.updatePictureInPicturePossible(isPossible)
        }
    }

    func updatePictureInPicturePossible(_ isPossible: Bool) {
        guard isPictureInPicturePossible != isPossible else {
            return
        }
        logger.info("Picture in Picture possible: \(isPossible, privacy: .public)")
        isPictureInPicturePossible = isPossible
    }

    func completePendingRestore(_ restored: Bool) {
        let completion = pendingRestoreCompletion
        pendingRestoreCompletion = nil
        completion?(restored)
    }
}
