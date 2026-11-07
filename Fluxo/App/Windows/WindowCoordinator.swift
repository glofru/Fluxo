//
//  WindowCoordinator.swift
//  Fluxo
//
//  The windows (scenes) of the app. On iPad the app can have several main windows and player windows side by
//  side (Split View, Slide Over, Stage Manager), but a few things exist once per app: the player (one AVPlayer,
//  one video layer, one Picture in Picture controller), the Add / Edit Playlist sheet, the delete confirmation and
//  the import and guide errors. Each of them is presented in exactly one window: the one it was asked for in.
//
//  Every window registers here with an identifier. A window that shows an app-wide presentation "claims" it when
//  it becomes active, for the window the user touched (or focused with the keyboard) last, and keeps it until it
//  ends; moving focus to another window never moves a sheet that is already up. The player can also be moved on
//  purpose (the mini player of another window, a player window).
//
//  Each main window has its own `AppNavigation`. App Intents (Siri, Shortcuts) move the UI of the main window used
//  last through `intentNavigation`; the first window adopts a navigation created with the app, so an intent that
//  launches the app can move the UI before its window appears.
//

import Observation
import SwiftUI

@MainActor
@Observable
final class WindowCoordinator {

    /// What a window is for.
    enum WindowKind: Hashable {
        /// The app (tabs or sidebar): it can show every app-wide presentation.
        case main
        /// A window that plays one channel (iPad, "Open in New Window"): it only ever shows the player.
        case player
    }

    /// App-wide presentations; each is shown in at most one window.
    enum Presentation: Hashable, CaseIterable {
        case player
        case playlistSheet
        case playlistDelete
        case playlistFailure
        case guideMatching
        case guideFailure
        /// "Reminder Not Found", after a notification of a deleted reminder was opened.
        case missingReminder
        /// The Cast device picker, opened by the cast buttons of the player and the mini player.
        case castPicker
    }

    private(set) var windows: [UUID: WindowKind] = [:]
    /// Windows in the order they were connected (the first main window is the fallback for presentations).
    private var order: [UUID] = []
    /// The window the user touched, clicked or focused last.
    private(set) var lastActiveWindowID: UUID?
    private var owners: [Presentation: UUID] = [:]
    /// The navigation of every main window.
    @ObservationIgnored private var navigations: [UUID: AppNavigation] = [:]
    /// A navigation no window has adopted yet: the next main window takes it (see `makeMainWindowNavigation()`).
    @ObservationIgnored private var unclaimedNavigation: AppNavigation? = AppNavigation()

    /// Player windows opened from a card in this session: they start playing as soon as they appear. A window
    /// restored at launch (state restoration) is not in here, so it waits for a tap instead of playing on its own.
    var pendingPlayerWindows: Set<PlayerWindowValue> = []

    /// More than one window is connected.
    var hasSeveralWindows: Bool {
        windows.count > 1
    }

    // MARK: - Windows

    func register(_ id: UUID, kind: WindowKind, navigation: AppNavigation? = nil) {
        if windows[id] == nil {
            order.append(id)
        }
        windows[id] = kind
        navigations[id] = navigation
        lastActiveWindowID = id
    }

    /// The window was closed (or disconnected by the system): what it presented moves to another window.
    func unregister(_ id: UUID) {
        windows[id] = nil
        navigations[id] = nil
        order.removeAll { $0 == id }
        if lastActiveWindowID == id {
            lastActiveWindowID = order.last
        }
        for (presentation, owner) in owners where owner == id {
            owners[presentation] = preferredMainWindowID
        }
    }

    /// The user touched, clicked or focused `id`.
    func noteActivity(in id: UUID?) {
        guard let id, windows[id] != nil, lastActiveWindowID != id else {
            return
        }
        lastActiveWindowID = id
    }

    /// The main window app-wide presentations go to: the one used last, else the first one.
    var preferredMainWindowID: UUID? {
        if let lastActiveWindowID, windows[lastActiveWindowID] == .main {
            return lastActiveWindowID
        }
        return order.first { windows[$0] == .main }
    }

    // MARK: - Navigation

    /// The navigation for a new main window: the one App Intents may already have moved (at launch), else a new
    /// one. Safe to call from a view's initializer: nothing observes it.
    func makeMainWindowNavigation() -> AppNavigation {
        if let navigation = unclaimedNavigation {
            unclaimedNavigation = nil
            return navigation
        }
        return AppNavigation()
    }

    /// The navigation App Intents move: the main window used last, else the one the next main window adopts.
    var intentNavigation: AppNavigation {
        if let id = preferredMainWindowID, let navigation = navigations[id] {
            return navigation
        }
        if let navigation = unclaimedNavigation {
            return navigation
        }
        let navigation = AppNavigation()
        unclaimedNavigation = navigation
        return navigation
    }

    // MARK: - Presentations

    func owner(of presentation: Presentation) -> UUID? {
        owners[presentation]
    }

    /// `presentation` is active and shown in window `id`. With no window registered (previews) every view shows it.
    func shows(_ presentation: Presentation, in id: UUID?, isActive: Bool) -> Bool {
        guard isActive else {
            return false
        }
        guard let id, !windows.isEmpty else {
            return true
        }
        return owners[presentation] == id
    }

    /// Called by every window when `presentation` starts or ends; the first call wins, so the presentation stays
    /// in the window it was claimed for until it ends.
    func update(_ presentation: Presentation, isActive: Bool) {
        if isActive {
            if owners[presentation] == nil || windows[owners[presentation]!] == nil {
                owners[presentation] = preferredWindow(for: presentation)
            }
        } else {
            owners[presentation] = nil
        }
    }

    /// Moves `presentation` to window `id` (e.g. the mini player of another window was tapped).
    func move(_ presentation: Presentation, to id: UUID) {
        guard windows[id] != nil else {
            return
        }
        owners[presentation] = id
        lastActiveWindowID = id
    }

    private func preferredWindow(for presentation: Presentation) -> UUID? {
        // The player and the Cast picker (opened from a player) show where they were asked for, player windows
        // included; the app-wide sheets need a main window.
        if presentation == .player || presentation == .castPicker, let lastActiveWindowID, windows[lastActiveWindowID] != nil {
            return lastActiveWindowID
        }
        return preferredMainWindowID
    }
}

extension EnvironmentValues {
    /// The identifier of the window a view is in (see `WindowCoordinator`); nil outside a registered window.
    @Entry var windowID: UUID?

    /// Whether the app-wide sheets and alerts (`playlistManagement()`, `guideManagement(_:)`, and on Apple TV the
    /// reminder and link alerts) show from this presenter now (see `AppModalsGate`). Always open on iPhone, iPad and
    /// Mac, which have one presenter per window.
    @Entry var appModalsGate = AppModalsGate.open
}

/// Whether a presenter of the app-wide sheets and alerts shows them now. On Apple TV the full-screen player covers
/// the tab bar: a sheet or an alert presented from the tab bar while it is up would make SwiftUI dismiss the player
/// (and closing the player stops playback) to show it. So the app has two presenters there, the tab bar and the
/// player (`TVContentView`), and the gate of exactly one of them is open at a time.
///
/// A check, not a stored value: `isOpen()` reads the state it depends on (observable, so the presenter's view
/// updates when it changes) at the moment it is called. A presentation handed over to the other presenter is
/// dismissed, and SwiftUI then calls the setter of the binding it held, possibly one created before the hand-over:
/// the setter asks the gate again and, closed now, leaves the request alone, so the other presenter shows it. A
/// `Bool` captured in the binding would still say open there, and the request would be lost.
struct AppModalsGate: Sendable {
    let isOpen: @MainActor @Sendable () -> Bool

    static let open = AppModalsGate { true }
}

extension FocusedValues {
    /// The identifier of the focused window, for the menu bar commands.
    @Entry var windowID: UUID?
}
