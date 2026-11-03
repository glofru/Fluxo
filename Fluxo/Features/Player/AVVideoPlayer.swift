//
//  AVVideoPlayer.swift
//  Fluxo
//
//  Created by Gianluca Lofrumento on 2025-07-05.
//

import AVKit
import SwiftUI

#if os(macOS)

/// macOS player. Shows the long-lived AVPlayerView of the view model's PlayerSurface, so that
/// Picture in Picture survives the player sheet being closed.
struct AVVideoPlayer: NSViewRepresentable {
    let surface: PlayerSurface

    func makeNSView(context: Context) -> PlayerContainerView {
        let container = PlayerContainerView(surface: surface)
        container.attachPlayerView()
        return container
    }

    func updateNSView(_ nsView: PlayerContainerView, context: Context) {
        // Only reclaim the view when no other player screen shows it (e.g. it was parked for PiP).
        // Taking it from a newer screen here would leave that screen blank.
        if surface.playerView.superview == nil || surface.isPlayerViewParked {
            nsView.attachPlayerView()
        }
    }
}

/// One container per player screen. The shared AVPlayerView moves into the newest container.
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

    func attachPlayerView() {
        let playerView = surface.playerView
        guard playerView.superview !== self else {
            return
        }
        surface.unparkPlayerView()
        playerView.removeFromSuperview()
        playerView.translatesAutoresizingMaskIntoConstraints = false
        playerView.alphaValue = 1
        addSubview(playerView)
        NSLayoutConstraint.activate([
            playerView.leadingAnchor.constraint(equalTo: leadingAnchor),
            playerView.trailingAnchor.constraint(equalTo: trailingAnchor),
            playerView.topAnchor.constraint(equalTo: topAnchor),
            playerView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        super.viewWillMove(toWindow: newWindow)
        // The player sheet is closing while PiP plays: keep the AVPlayerView inside a window (the
        // one the sheet was attached to) so that AppKit keeps driving PiP and can restore it.
        guard newWindow == nil, let window, surface.playerView.superview === self, surface.isPictureInPictureActive else {
            return
        }
        surface.parkPlayerView(in: window.sheetParent ?? window)
    }
}

#else

/// iOS / visionOS player. Embeds the long-lived AVPlayerViewController of the view model's
/// PlayerSurface, so that Picture in Picture survives the player cover being dismissed.
///
/// Every player screen gets its own host controller and the shared AVPlayerViewController is a child
/// of the newest host. SwiftUI only ever tears down a host, so closing and quickly reopening the
/// player cannot remove the shared controller from the screen that shows it now.
struct AVVideoPlayer: UIViewControllerRepresentable {
    let surface: PlayerSurface

    func makeUIViewController(context: Context) -> PlayerHostViewController {
        PlayerHostViewController(surface: surface)
    }

    func updateUIViewController(_ uiViewController: PlayerHostViewController, context: Context) {
    }
}

final class PlayerHostViewController: UIViewController {
    private let surface: PlayerSurface

    init(surface: PlayerSurface) {
        self.surface = surface
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        embedPlayer()
    }

    private func embedPlayer() {
        let controller = surface.controller
        guard controller.parent !== self else {
            return
        }
        // The controller can only have one parent: take it from a previous player screen.
        if controller.parent != nil {
            controller.willMove(toParent: nil)
            controller.view.removeFromSuperview()
            controller.removeFromParent()
        }
        addChild(controller)
        controller.view.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(controller.view)
        NSLayoutConstraint.activate([
            controller.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            controller.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            controller.view.topAnchor.constraint(equalTo: view.topAnchor),
            controller.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        controller.didMove(toParent: self)
    }
}

#endif
