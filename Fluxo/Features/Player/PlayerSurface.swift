//
//  PlayerSurface.swift
//  Fluxo
//
//  Owns the video view (an AVPlayerLayer) and the Picture in Picture controller for the whole life of
//  the player, independently of the SwiftUI views that display them.
//
//  The player screen draws its own controls (title, status, time-shift, recording, channel zapping), so
//  the video is a bare AVPlayerLayer and PiP is driven by an AVPictureInPictureController, which can be
//  started from a button. Picture in Picture needs this object to outlive the player screen: when the
//  screen is dismissed while PiP runs, SwiftUI tears down its views, but the PiP controller and its layer
//  must stay alive so that PiP keeps playing and the screen can be restored when PiP stops.
//

import AVKit
import SwiftUI

#if os(macOS)
typealias PlatformView = NSView
#else
typealias PlatformView = UIView
#endif

/// A view backed by an AVPlayerLayer.
final class PlayerLayerView: PlatformView {

    #if os(macOS)

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        playerLayer.backgroundColor = NSColor.black.cgColor
    }

    override func makeBackingLayer() -> CALayer {
        AVPlayerLayer()
    }

    // Mouse events go to the SwiftUI controls on top of the video.
    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }

    #else

    override class var layerClass: AnyClass {
        AVPlayerLayer.self
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .black
        isUserInteractionEnabled = false
    }

    #endif

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    var playerLayer: AVPlayerLayer {
        // swiftlint:disable:next force_cast
        layer as! AVPlayerLayer
    }
}

@MainActor
final class PlayerSurface: NSObject {

    /// Called on the main thread when Picture in Picture starts (true) or stops (false).
    var onPictureInPictureActiveChange: ((Bool) -> Void)?

    /// Called on the main thread when PiP can or can no longer be started (e.g. once the item is ready).
    var onPictureInPicturePossibleChange: ((Bool) -> Void)?

    /// Called on the main thread when PiP asks to restore the player UI. The handler must present the
    /// player and then call the completion with true (or false when it cannot be restored).
    var onRestoreUserInterface: ((@escaping (Bool) -> Void) -> Void)?

    /// Called on the main thread when Picture in Picture fails to start.
    var onPictureInPictureError: ((Error) -> Void)?

    /// True while Picture in Picture runs.
    private(set) var isPictureInPictureActive = false

    /// The long-lived video view. Player screens embed it (see AVVideoPlayer); it moves into the newest one.
    let videoView: PlayerLayerView

    private let pictureInPicture: AVPictureInPictureController?
    private var possibleObservation: NSKeyValueObservation?

    init(player: AVPlayer) {
        let view = PlayerLayerView(frame: .zero)
        view.playerLayer.player = player
        view.playerLayer.videoGravity = .resizeAspect
        videoView = view

        if AVPictureInPictureController.isPictureInPictureSupported() {
            pictureInPicture = AVPictureInPictureController(playerLayer: view.playerLayer)
        } else {
            pictureInPicture = nil
        }
        super.init()

        pictureInPicture?.delegate = self
        #if !os(macOS)
        pictureInPicture?.canStartPictureInPictureAutomaticallyFromInline = PlayerPreferences.autoPictureInPicture
        #endif
        possibleObservation = pictureInPicture?.observe(\.isPictureInPicturePossible, options: [.initial, .new]) { [weak self] controller, _ in
            let isPossible = controller.isPictureInPicturePossible
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self?.onPictureInPicturePossibleChange?(isPossible)
                }
            }
        }
    }

    /// False on devices without Picture in Picture.
    var isPictureInPictureSupported: Bool {
        pictureInPicture != nil
    }

    var isPictureInPicturePossible: Bool {
        pictureInPicture?.isPictureInPicturePossible ?? false
    }

    /// iOS starts PiP by itself when the app goes to the background while a video plays inline.
    var startsPictureInPictureAutomatically: Bool {
        get {
            #if os(macOS)
            return false
            #else
            return pictureInPicture?.canStartPictureInPictureAutomaticallyFromInline ?? false
            #endif
        }
        set {
            #if !os(macOS)
            pictureInPicture?.canStartPictureInPictureAutomaticallyFromInline = newValue
            #endif
        }
    }

    func togglePictureInPicture() {
        guard let pictureInPicture else {
            return
        }
        if pictureInPicture.isPictureInPictureActive {
            pictureInPicture.stopPictureInPicture()
        } else if pictureInPicture.isPictureInPicturePossible {
            pictureInPicture.startPictureInPicture()
        }
    }

    func stopPictureInPicture() {
        if pictureInPicture?.isPictureInPictureActive == true {
            pictureInPicture?.stopPictureInPicture()
        }
    }

    /// Aspect fit (letterboxed) or aspect fill (cropped to the screen).
    var fillsScreen: Bool {
        get {
            videoView.playerLayer.videoGravity == .resizeAspectFill
        }
        set {
            videoView.playerLayer.videoGravity = newValue ? .resizeAspectFill : .resizeAspect
        }
    }

    #if os(macOS)

    /// Invisible host in the main window that keeps the video view in a window while PiP runs
    /// with the player screen closed.
    private var parkingView: NSView?

    var isVideoViewParked: Bool {
        parkingView != nil && videoView.superview === parkingView
    }

    /// Moves the video view into an invisible host of `window` (it stays in a window, so AppKit keeps
    /// driving Picture in Picture and can restore it).
    func parkVideoView(in window: NSWindow) {
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
        videoView.removeFromSuperview()
        videoView.translatesAutoresizingMaskIntoConstraints = true
        videoView.frame = parking.bounds
        parking.addSubview(videoView)
    }

    /// Removes the invisible host (the video view leaves it too when it is still parked).
    func unparkVideoView() {
        guard let parking = parkingView else {
            return
        }
        if videoView.superview === parking {
            videoView.removeFromSuperview()
        }
        parking.removeFromSuperview()
        parkingView = nil
    }

    #endif
}

extension PlayerSurface: @preconcurrency AVPictureInPictureControllerDelegate {

    func pictureInPictureControllerDidStartPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
        isPictureInPictureActive = true
        onPictureInPictureActiveChange?(true)
    }

    func pictureInPictureControllerDidStopPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
        isPictureInPictureActive = false
        #if os(macOS)
        // PiP ended without the player screen coming back: nothing shows the view any more.
        if isVideoViewParked {
            unparkVideoView()
        }
        #endif
        onPictureInPictureActiveChange?(false)
    }

    func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController, failedToStartPictureInPictureWithError error: Error) {
        onPictureInPictureError?(error)
    }

    func pictureInPictureController(
        _ pictureInPictureController: AVPictureInPictureController,
        restoreUserInterfaceForPictureInPictureStopWithCompletionHandler completionHandler: @escaping (Bool) -> Void
    ) {
        guard let onRestoreUserInterface else {
            completionHandler(false)
            return
        }
        onRestoreUserInterface(completionHandler)
    }
}
