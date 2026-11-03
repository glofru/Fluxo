//
//  ZoomTransitions.swift
//  Fluxo
//
//  Zoom transitions (iOS): the player grows out of the card or the mini player that opened it (see
//  `PlayerPresentation`), and a group's "See All" grid grows out of its Home row. On macOS these helpers do
//  nothing.
//

import SwiftUI

/// Identifiers of the views the player can zoom from.
enum PlayerTransition {
    /// The mini player in the tab bar accessory. Also the fallback when no card opened the player.
    static let miniPlayerID = "player.miniPlayer"
}

extension EnvironmentValues {
    /// Namespace of the zoom transitions of one NavigationStack (set by `channelDestinations()`).
    @Entry var routeTransitionNamespace: Namespace.ID?
}

extension View {

    /// Marks this view as a source the full-screen player can grow from (see `PlayChannelAction`): its frame
    /// and corner radius are kept in `PlayerSourceFrames` while it is on screen.
    func playerTransitionSource(id: String, cornerRadius: CGFloat = 16) -> some View {
        modifier(PlayerSourceModifier(id: id, cornerRadius: cornerRadius))
    }

    /// Marks this view as the source of the zoom into `route`'s screen.
    func routeTransitionSource(_ route: ChannelRoute, cornerRadius: CGFloat = 20) -> some View {
        modifier(RouteTransitionSourceModifier(id: route, cornerRadius: cornerRadius))
    }

    /// Zooms this (presented or pushed) screen out of the source marked with `sourceID` in `namespace`.
    @ViewBuilder
    func zoomTransition(sourceID: some Hashable, in namespace: Namespace.ID) -> some View {
        #if os(iOS)
        self.navigationTransition(.zoom(sourceID: sourceID, in: namespace))
        #else
        self
        #endif
    }
}

private struct PlayerSourceModifier: ViewModifier {

    let id: String
    let cornerRadius: CGFloat

    @Environment(\.playerSourceFrames) private var frames

    func body(content: Content) -> some View {
        #if os(iOS)
        if let frames {
            content
                .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { frame in
                    frames.update(id, frame: frame, cornerRadius: cornerRadius)
                }
                .onDisappear {
                    frames.update(id, frame: nil, cornerRadius: cornerRadius)
                }
        } else {
            content
        }
        #else
        content
        #endif
    }
}

private struct RouteTransitionSourceModifier<ID: Hashable>: ViewModifier {

    let id: ID
    let cornerRadius: CGFloat

    @Environment(\.routeTransitionNamespace) private var routeNamespace

    func body(content: Content) -> some View {
        #if os(iOS)
        if let namespace = routeNamespace {
            content.matchedTransitionSource(id: id, in: namespace) { source in
                source.clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            }
        } else {
            content
        }
        #else
        content
        #endif
    }
}
