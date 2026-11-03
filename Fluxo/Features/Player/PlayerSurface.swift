//
//  PlayerSurface.swift
//  Fluxo
//
//  Owns the platform player view (AVPlayerViewController on iOS, AVPlayerView on macOS) for the
//  whole life of the player, independently of the SwiftUI views that display it.
//
//  Picture in Picture needs this: when the player screen is dismissed while PiP runs, SwiftUI tears
//  down its views, but the controller that drives PiP must stay alive so that PiP keeps playing and
//  the user interface can be restored when PiP stops.
//

import AVKit
import SwiftUI

@MainActor
final class PlayerSurface: NSObject {

    /// Called on the main thread when Picture in Picture starts (true) or stops (false).
    var onPictureInPictureActiveChange: ((Bool) -> Void)?

    /// Called on the main thread when PiP asks to restore the player UI. The handler must present the
    /// player and then call the completion with true (or false when it cannot be restored).
    var onRestoreUserInterface: ((@escaping (Bool) -> Void) -> Void)?

    /// Called on the main thread when Picture in Picture fails to start.
    var onPictureInPictureError: ((Error) -> Void)?

    /// True while Picture in Picture runs.
    private(set) var isPictureInPictureActive = false

    #if os(macOS)

    let playerView: AVPlayerView

    /// Invisible host in the main window that keeps the player view in a window while PiP runs
    /// with the player sheet closed.
    private var parkingView: NSView?

    var isPlayerViewParked: Bool {
        parkingView != nil && playerView.superview === parkingView
    }

    /// Moves the player view into an invisible host of `window` (it stays in a window, so AppKit
    /// keeps driving Picture in Picture and can restore it).
    func parkPlayerView(in window: NSWindow) {
        guard let contentView = window.contentView else {
            return
        }
        let parking = parkingView ?? NSView(frame: NSRect(x: 0, y: 0, width: 16, height: 9))
        parking.alphaValue = 0
        if parking.superview !== contentView {
            parking.removeFromSuperview()
            contentView.addSubview(parking)
        }
        parkingView = parking
        playerView.removeFromSuperview()
        playerView.translatesAutoresizingMaskIntoConstraints = true
        playerView.frame = parking.bounds
        parking.addSubview(playerView)
    }

    /// Removes the invisible host (the player view leaves it too when it is still parked).
    func unparkPlayerView() {
        guard let parking = parkingView else {
            return
        }
        if playerView.superview === parking {
            playerView.removeFromSuperview()
        }
        parking.removeFromSuperview()
        parkingView = nil
    }

    init(player: AVPlayer) {
        let view = AVPlayerView()
        view.player = player
        view.controlsStyle = .floating
        view.allowsPictureInPicturePlayback = true
        view.showsFullScreenToggleButton = true
        view.showsFrameSteppingButtons = false
        view.updatesNowPlayingInfoCenter = true
        view.videoGravity = .resizeAspect
        playerView = view
        super.init()
        view.pictureInPictureDelegate = self
    }

    #else

    let controller: AVPlayerViewController

    init(player: AVPlayer) {
        let controller = AVPlayerViewController()
        controller.player = player
        controller.allowsPictureInPicturePlayback = true
        controller.canStartPictureInPictureAutomaticallyFromInline = true
        controller.updatesNowPlayingInfoCenter = true
        controller.videoGravity = .resizeAspect
        self.controller = controller
        super.init()
        controller.delegate = self
    }

    #endif
}

#if os(macOS)

extension PlayerSurface: @preconcurrency AVPlayerViewPictureInPictureDelegate {

    func playerViewDidStartPicture(inPicture playerView: AVPlayerView) {
        isPictureInPictureActive = true
        onPictureInPictureActiveChange?(true)
    }

    func playerViewDidStopPicture(inPicture playerView: AVPlayerView) {
        isPictureInPictureActive = false
        // PiP ended without the player screen coming back: nothing shows the view any more.
        if isPlayerViewParked {
            unparkPlayerView()
        }
        onPictureInPictureActiveChange?(false)
    }

    func playerView(_ playerView: AVPlayerView, failedToStartPictureInPictureWithError error: Error) {
        onPictureInPictureError?(error)
    }

    func playerViewShouldAutomaticallyDismissAtPicture(inPictureStart playerView: AVPlayerView) -> Bool {
        // The view model dismisses the player sheet itself.
        false
    }

    func playerView(_ playerView: AVPlayerView, restoreUserInterfaceForPictureInPictureStopWithCompletionHandler completionHandler: @escaping (Bool) -> Void) {
        guard let onRestoreUserInterface else {
            completionHandler(false)
            return
        }
        onRestoreUserInterface(completionHandler)
    }
}

#else

extension PlayerSurface: @preconcurrency AVPlayerViewControllerDelegate {

    func playerViewControllerDidStartPictureInPicture(_ playerViewController: AVPlayerViewController) {
        isPictureInPictureActive = true
        onPictureInPictureActiveChange?(true)
    }

    func playerViewControllerDidStopPictureInPicture(_ playerViewController: AVPlayerViewController) {
        isPictureInPictureActive = false
        onPictureInPictureActiveChange?(false)
    }

    func playerViewController(_ playerViewController: AVPlayerViewController, failedToStartPictureInPictureWithError error: Error) {
        onPictureInPictureError?(error)
    }

    func playerViewControllerShouldAutomaticallyDismissAtPictureInPictureStart(_ playerViewController: AVPlayerViewController) -> Bool {
        // The controller is embedded in SwiftUI: the view model dismisses the player cover itself.
        false
    }

    func playerViewController(_ playerViewController: AVPlayerViewController, restoreUserInterfaceForPictureInPictureStopWithCompletionHandler completionHandler: @escaping (Bool) -> Void) {
        guard let onRestoreUserInterface else {
            completionHandler(false)
            return
        }
        onRestoreUserInterface(completionHandler)
    }
}

#endif
