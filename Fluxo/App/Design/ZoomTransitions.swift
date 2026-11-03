//
//  ZoomTransitions.swift
//  Fluxo
//
//  Zoom transitions (iOS): the player grows out of the card or the mini player that opened it, and a group's
//  "See All" grid grows out of its Home row. On macOS these helpers do nothing.
//

import SwiftUI

/// Identifiers of the views the player can zoom from.
enum PlayerTransition {
    /// The mini player in the tab bar accessory. Also the fallback when no card opened the player.
    static let miniPlayerID = "player.miniPlayer"
}

extension EnvironmentValues {
    /// Namespace of the player zoom transition; set once at the root of the window.
    @Entry var playerTransitionNamespace: Namespace.ID?
    /// Namespace of the zoom transitions of one NavigationStack (set by `channelDestinations()`).
    @Entry var routeTransitionNamespace: Namespace.ID?
}

extension View {

    /// Marks this view as a source the full-screen player can zoom from (see `PlayChannelAction`).
    func playerTransitionSource(id: String, cornerRadius: CGFloat = 16) -> some View {
        modifier(TransitionSourceModifier(id: id, cornerRadius: cornerRadius, kind: .player))
    }

    /// Marks this view as the source of the zoom into `route`'s screen.
    func routeTransitionSource(_ route: ChannelRoute, cornerRadius: CGFloat = 20) -> some View {
        modifier(TransitionSourceModifier(id: route, cornerRadius: cornerRadius, kind: .route))
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

private struct TransitionSourceModifier<ID: Hashable>: ViewModifier {

    enum Kind {
        case player
        case route
    }

    let id: ID
    let cornerRadius: CGFloat
    let kind: Kind

    @Environment(\.playerTransitionNamespace) private var playerNamespace
    @Environment(\.routeTransitionNamespace) private var routeNamespace

    func body(content: Content) -> some View {
        #if os(iOS)
        if let namespace = kind == .player ? playerNamespace : routeNamespace {
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
