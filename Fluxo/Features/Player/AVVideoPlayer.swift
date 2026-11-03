//
//  AVVideoPlayer.swift
//  Fluxo
//
//  Created by Gianluca Lofrumento on 2025-07-05.
//

import AVKit
import SwiftUI

#if os(macOS)

/// Shows the long-lived video view of the view model's PlayerSurface, so that Picture in Picture
/// survives the player screen being closed. The controls are SwiftUI views on top of it.
struct AVVideoPlayer: NSViewRepresentable {
    let surface: PlayerSurface

    func makeNSView(context: Context) -> PlayerContainerView {
        let container = PlayerContainerView(surface: surface)
        container.attachVideoView()
        return container
    }

    func updateNSView(_ nsView: PlayerContainerView, context: Context) {
        // Only reclaim the view when no other player screen shows it (e.g. it was parked for PiP).
        // Taking it from a newer screen here would leave that screen blank.
        if surface.videoView.superview == nil || surface.isVideoViewParked {
            nsView.attachVideoView()
        }
    }
}

/// One container per player screen. The shared video view moves into the newest container.
final class PlayerContainerView: NSView {
    private let surface: PlayerSurface

    init(surface: PlayerSurface) {
        self.surface = surface
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    func attachVideoView() {
        let videoView = surface.videoView
        guard videoView.superview !== self else {
            return
        }
        surface.unparkVideoView()
        videoView.removeFromSuperview()
        videoView.translatesAutoresizingMaskIntoConstraints = false
        videoView.alphaValue = 1
        addSubview(videoView)
        NSLayoutConstraint.activate([
            videoView.leadingAnchor.constraint(equalTo: leadingAnchor),
            videoView.trailingAnchor.constraint(equalTo: trailingAnchor),
            videoView.topAnchor.constraint(equalTo: topAnchor),
            videoView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        super.viewWillMove(toWindow: newWindow)
        // The player screen is closing while PiP plays: keep the video view inside a window (the main
        // window, or the one a sheet was attached to) so that AppKit keeps driving PiP and can restore it.
        guard newWindow == nil, let window, surface.videoView.superview === self, surface.isPictureInPictureActive else {
            return
        }
        surface.parkVideoView(in: window.sheetParent ?? window)
    }
}

#else

/// iOS player. Embeds the long-lived video view of the view model's PlayerSurface, so that
/// Picture in Picture survives the player cover being dismissed.
///
/// Every player screen gets its own container and the shared video view moves into the newest one.
/// SwiftUI only ever tears down a container, so closing and quickly reopening the player cannot remove
/// the video view from the screen that shows it now.
struct AVVideoPlayer: UIViewRepresentable {
    let surface: PlayerSurface

    func makeUIView(context: Context) -> PlayerContainerView {
        let container = PlayerContainerView(surface: surface)
        container.attachVideoView()
        return container
    }

    func updateUIView(_ uiView: PlayerContainerView, context: Context) {
        if surface.videoView.superview == nil {
            uiView.attachVideoView()
        }
    }
}

final class PlayerContainerView: UIView {
    private let surface: PlayerSurface

    init(surface: PlayerSurface) {
        self.surface = surface
        super.init(frame: .zero)
        backgroundColor = .black
        isUserInteractionEnabled = false
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    func attachVideoView() {
        let videoView = surface.videoView
        guard videoView.superview !== self else {
            return
        }
        videoView.removeFromSuperview()
        videoView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(videoView)
        NSLayoutConstraint.activate([
            videoView.leadingAnchor.constraint(equalTo: leadingAnchor),
            videoView.trailingAnchor.constraint(equalTo: trailingAnchor),
            videoView.topAnchor.constraint(equalTo: topAnchor),
            videoView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        // A newer screen may have released the view meanwhile (e.g. it was closed first).
        if window != nil, surface.videoView.superview == nil {
            attachVideoView()
        }
    }
}

#endif
