//
//  PlayerStatusBar.swift
//  Fluxo
//
//  The status bar (time, battery, connectivity) over the full player.
//
//  It shows with the player's controls, in light content over the video whatever the app's appearance, and hides
//  right after they faded out, so the video gets the whole screen. While the player is dragged down it shows: in
//  light content as long as the player's black is under it, then in the app's own style once the app is (the
//  player's top edge passed below it). Closing the player, or handing the video to Picture in Picture, gives it
//  back to the app. On iPhone in landscape the system never shows it.
//
//  The player only publishes what it needs (`PlayerStatusBarStyle`, from its controls); the view that hosts it
//  applies it (`playerStatusBar(_:)`): that view also knows where a dragged player is, and a single place sets
//  the status bar, so two modifiers never compete for it.
//
//  Showing and hiding it never moves the player's controls: on iPad it changes the top safe area, which the
//  player does not follow (`PlayerTopSafeArea`), and it hides only after the controls faded out.
//

import SwiftUI

/// What the full player needs from the status bar.
enum PlayerStatusBarStyle: Equatable {
    /// Nothing of the player is under the status bar: the app's own status bar, in the app's style.
    case app
    /// Over the video (the controls are on screen): light content, readable on the dark scrim.
    case overVideo
    /// The controls hid: the video takes the whole screen.
    case hidden
}

/// The status bar the player asks for, published by `WatchChannelView` for the view that hosts it.
struct PlayerStatusBarPreferenceKey: PreferenceKey {
    static let defaultValue: PlayerStatusBarStyle? = nil

    static func reduce(value: inout PlayerStatusBarStyle?, nextValue: () -> PlayerStatusBarStyle?) {
        value = nextValue() ?? value
    }
}

extension View {

    /// Sets the status bar of the scene for the player shown in this view (iOS; nothing on macOS).
    func playerStatusBar(_ style: PlayerStatusBarStyle) -> some View {
        modifier(PlayerStatusBarModifier(style: style))
    }

    /// Reads the status bar the player in this view asks for (nil while no player is in it).
    func onPlayerStatusBarChange(_ action: @escaping (PlayerStatusBarStyle?) -> Void) -> some View {
        onPreferenceChange(PlayerStatusBarPreferenceKey.self) { style in
            action(style)
        }
    }
}

private struct PlayerStatusBarModifier: ViewModifier {
    let style: PlayerStatusBarStyle

    #if os(iOS)
    /// The app's appearance (the player's subtree is dark, the view that hosts it is not).
    @Environment(\.colorScheme) private var colorScheme
    #endif

    func body(content: Content) -> some View {
        #if os(iOS)
        if #available(iOS 27.0, *) {
            content
                .toolbarVisibility(style == .hidden ? .hidden : .automatic, for: .statusBar)
                .toolbarColorScheme(style == .overVideo ? .dark : nil, for: .statusBar)
        } else {
            // iOS 26 has no SwiftUI way to choose the status bar's style (`ToolbarPlacement.statusBar` is iOS 27),
            // so over the video it shows only in dark mode, where the default style is light content, and stays
            // hidden otherwise rather than risking dark text on the video.
            content
                .statusBarHidden(style == .hidden || (style == .overVideo && colorScheme != .dark))
        }
        #else
        content
        #endif
    }
}

#if os(iOS)
/// The top safe area the player lays itself out in, kept steady while the status bar shows and hides.
///
/// On iPad the top safe area is the status bar's height: it would change (and move the controls, the side panel
/// and the status overlay) every time the status bar shows or hides with the controls. The player ignores the
/// real top inset and uses the largest it has seen at its current size instead, so its controls stay under the
/// status bar's place when it is hidden. On iPhone the sensor housing sets the inset (portrait) or there is no
/// status bar at all (landscape), so this changes nothing there.
struct PlayerTopSafeArea: Equatable {
    /// What the player sees: its frame's size and its real top inset.
    struct Sample: Equatable {
        var size: CGSize
        var top: CGFloat

        /// The size with the top inset added back: the same whether the status bar shows or not (hiding it
        /// grows the frame by the inset it frees), different after a rotation or a resize.
        var extent: CGSize {
            CGSize(width: size.width, height: size.height + top)
        }
    }

    private(set) var top: CGFloat = 0
    private var extent: CGSize = .zero

    mutating func update(_ sample: Sample) {
        // The inset animates with the status bar; a point or two either way is that, not a new size.
        let isSameSize = abs(sample.extent.width - extent.width) < 2 && abs(sample.extent.height - extent.height) < 2
        if !isSameSize {
            // Rotated, resized (iPad windows) or another screen: start over from the real inset.
            extent = sample.extent
            top = sample.top
        } else {
            top = max(top, sample.top)
        }
    }
}

extension View {

    /// Lays the player out with a top safe area that does not follow the status bar (see `PlayerTopSafeArea`).
    func playerSteadyTopSafeArea(_ safeArea: Binding<PlayerTopSafeArea>) -> some View {
        self
            .safeAreaPadding(.top, safeArea.wrappedValue.top)
            .ignoresSafeArea(.container, edges: .top)
            .background {
                // Measures the real top inset (and the frame, for rotations) behind the player.
                Color.clear
                    .onGeometryChange(for: PlayerTopSafeArea.Sample.self) { proxy in
                        PlayerTopSafeArea.Sample(size: proxy.size, top: proxy.safeAreaInsets.top)
                    } action: { sample in
                        safeArea.wrappedValue.update(sample)
                    }
            }
    }
}

#endif
