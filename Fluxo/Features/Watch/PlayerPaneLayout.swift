//
//  PlayerPaneLayout.swift
//  Fluxo
//
//  Where the player puts the video, its controls and the companion panel (`PlayerCompanionPanel`), from the
//  posture of the display (`DisplayPosture`):
//
//  - Regular iPhones, iPads, the Mac, and the cover display of a foldable: the video fills the screen, as
//    always. Wide iPad and Mac players can make room for the side panel (`PlayerSidePanel`) on the trailing edge.
//  - A foldable open like a book (partially open, the fold from top to bottom): the video on one half, the
//    companion panel on the other, nothing on the fold. Fully open (flat) the video fills the whole display by
//    default; the top bar button splits it the same way.
//  - A foldable standing like a laptop (partially open, the fold from side to side): the video on the upper half
//    with its top bar, the transport controls on the lower half (always visible) above the channel list.
//
//  The user's choice (panel shown or hidden) is remembered separately for "partly open" and "flat". The video
//  view keeps its identity in every layout, so changing the posture never interrupts playback.
//

// The touch and pointer player screen (iPhone, iPad, Mac). Apple TV plays in the system's player, whose transport bar the Siri Remote drives (Fluxo/TV).
#if !os(tvOS)
import SwiftUI

struct PlayerPaneLayout: Equatable {

    enum Mode: Equatable {
        /// The video fills the screen.
        case full
        /// The video and the panel side by side.
        case sideBySide
        /// The video above, the controls (and the panel) below.
        case stacked
    }

    var mode: Mode = .full
    /// Frames in the coordinate space of the player's safe area (its `GeometryReader`).
    var video: CGRect = .zero
    var panel: CGRect?
    /// Wide players (iPad, Mac): the channel list and guide next to the video (see `PlayerSidePanel`).
    var sidePanel: CGRect?
    /// Stacked: the channel list shows below the controls.
    var showsPanelList = false
    /// Side by side: the side the video is on.
    var videoEdge: HorizontalEdge = .leading
    /// The posture divides the display, so the top bar offers to show or hide the panel.
    var canSplit = false
    var isStacked: Bool {
        mode == .stacked
    }

    /// - Parameters:
    ///   - size: size of the player's safe area.
    ///   - insets: the safe area insets around it (the posture's frames include them).
    ///   - showsPanelWhenPartlyOpen / showsPanelWhenFlat: the user's choices.
    ///   - videoOnTrailingSide: side by side, the video is on the trailing half.
    static func make(
        posture: DisplayPosture,
        size: CGSize,
        insets: EdgeInsets,
        showsPanelWhenPartlyOpen: Bool,
        showsPanelWhenFlat: Bool,
        videoOnTrailingSide: Bool
    ) -> PlayerPaneLayout {
        let bounds = CGRect(origin: .zero, size: size)
        var layout = PlayerPaneLayout(video: bounds)
        guard let split = posture.split() else {
            return layout
        }
        layout.canSplit = true
        let showsPanel = posture.isPartiallyOpen ? showsPanelWhenPartlyOpen : showsPanelWhenFlat

        // From the window's space (safe areas included) to the safe area's, kept inside it: the video still
        // runs under the safe areas on the outer edges (it ignores them), never across the fold.
        func local(_ rect: CGRect) -> CGRect {
            let moved = rect.offsetBy(dx: -insets.leading, dy: -insets.top).intersection(bounds)
            return moved.isNull ? .zero : moved
        }

        switch split.axis {
        case .horizontal:
            guard showsPanel else {
                return layout
            }
            layout.mode = .sideBySide
            layout.videoEdge = videoOnTrailingSide ? .trailing : .leading
            layout.video = local(videoOnTrailingSide ? split.second : split.first)
            layout.panel = local(videoOnTrailingSide ? split.first : split.second)
        case .vertical:
            // Standing like a laptop, the lower half lies flat: the video always goes up. Flat, the panel is
            // optional like side by side.
            guard posture.isPartiallyOpen || showsPanel else {
                return layout
            }
            layout.mode = .stacked
            layout.showsPanelList = showsPanel
            layout.video = local(split.first)
            layout.panel = local(split.second)
        }
        return layout
    }

    /// The video makes room for the side panel on the trailing edge of a player of `size` (its safe area).
    func reservingTrailingSidePanel(width: CGFloat, in size: CGSize) -> PlayerPaneLayout {
        var layout = self
        let panelWidth = min(width, size.width)
        layout.video = CGRect(x: 0, y: 0, width: size.width - panelWidth, height: size.height)
        layout.sidePanel = CGRect(x: size.width - panelWidth, y: 0, width: panelWidth, height: size.height)
        return layout
    }
}

/// The user's choices for the player on a foldable iPhone.
enum FoldablePlayerPreferences {
    /// Partly open (book or laptop posture): the companion panel shows. On by default.
    static let panelWhenPartlyOpenKey = "player.foldable.panelWhenPartlyOpen"
    /// Fully open (flat): the companion panel shows. Off by default: the video gets the whole display.
    static let panelWhenFlatKey = "player.foldable.panelWhenFlat"
    /// Side by side: the video is on the trailing half.
    static let videoOnTrailingSideKey = "player.foldable.videoOnTrailingSide"
}
#endif
