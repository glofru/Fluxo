//
//  DisplayPosture.swift
//  Fluxo
//
//  The shape of the display the app runs on, for the iPhone with a hinge (the iPhone Duo, iPhone19,4): a
//  book-style foldable with a cover display (466 x 678 pt, used folded) and an inner display (669 x 951 pt,
//  used open) that folds across its middle.
//
//  What the iOS 27.1 SDK tells an app, and what this file reads:
//  - The hinge: `onHingeChange` (SwiftUI; `UIHingeInteraction` in UIKit) reports `DeviceHinge` with a status
//    (closed, partially open, fully open) and an angle, or no hinge at all on every other device.
//  - Reserved regions: `GeometryProxy.reservedRegions(kind:)`. A `.division` region is "a region where an
//    element should divide into two separate regions" (the fold); `.occlusion` regions are covered by
//    hardware or system elements.
//  - The vertical bar: on the cover display the system moves the status bar, the navigation bar items and the
//    tab bar into one vertical bar on the trailing edge (`UITraitCollection.verticalBarEdge`). Its width is part
//    of the safe area, so layouts that respect the safe area need nothing else.
//
//  The root of the window (`readsDisplayPosture()`) reads them once and shares one `DisplayPosture` value
//  through the environment. On regular iPhones, iPads and the Mac it stays `DisplayPosture()`: no hinge, no
//  fold, and no screen changes its layout.
//

import SwiftUI
#if os(iOS)
import UIKit
#endif

/// The hinge, the fold and the vertical bar of the display, in the window's coordinate space.
struct DisplayPosture: Equatable {

    enum HingeStatus: String, Equatable {
        case closed
        case partiallyOpen
        case fullyOpen
    }

    /// Where two panes divide the window: side by side (`horizontal`) or one above the other (`vertical`).
    struct Split: Equatable {
        enum Axis: Equatable {
            /// Panes side by side: the fold runs from top to bottom.
            case horizontal
            /// Panes one above the other: the fold runs from side to side (the phone stands like a laptop).
            case vertical
        }

        let axis: Axis
        /// Leading (side by side) or top (stacked) pane, in the coordinate space passed to `split(in:)`.
        let first: CGRect
        /// The fold between the panes; nothing is drawn there. Zero-wide when the system reports no region.
        let seam: CGRect
        /// Trailing (side by side) or bottom (stacked) pane.
        let second: CGRect
        /// True when the seam is the system's division region, false when it is the middle of the inner display.
        let isFold: Bool
    }

    /// nil on devices without a hinge (and until the first hinge update arrives).
    var hingeStatus: HingeStatus?
    /// Hinge angle in degrees, when there is a hinge.
    var hingeAngle: Double?
    /// Active division regions (folds), in the window's coordinate space (its top leading corner is 0, 0,
    /// safe areas included).
    var folds: [CGRect] = []
    /// Active occlusion regions, in the window's coordinate space.
    var occlusions: [CGRect] = []
    /// The edge of the system's vertical bar (cover display), nil where the bars are horizontal.
    var verticalBarEdge: HorizontalEdge?
    /// Size of the window, safe areas included.
    var windowSize: CGSize = .zero
    #if DEBUG
    /// Set by `-FluxoDebugPosture`: the values are simulated (Tools/Simulator/README.md).
    var isSimulated = false
    #endif

    var hasHinge: Bool {
        hingeStatus != nil
    }

    /// The device is open part way (book or laptop / tabletop posture): the two halves face different ways.
    var isPartiallyOpen: Bool {
        hingeStatus == .partiallyOpen
    }

    /// Smallest pane worth splitting the window for (a phone-sized column).
    static let minimumPaneLength: CGFloat = 280

    /// Where the window divides into two panes, in a coordinate space whose origin is the window's top leading
    /// corner, or nil when it does not divide (no hinge, the cover display, or panes that would be too small).
    ///
    /// The system's division region is used when it reports one. Without one, a device with a hinge that shows
    /// the app on its inner display (the larger one: at least 800 x 560 pt) divides at the middle of the long
    /// side, where a book-style display folds.
    func split() -> Split? {
        let window = CGRect(origin: .zero, size: windowSize)
        guard window.width > 0, window.height > 0 else {
            return nil
        }
        for fold in folds {
            let fold = fold.intersection(window)
            guard !fold.isNull else {
                continue
            }
            if fold.height >= window.height * 0.9, fold.width < window.width / 3 {
                return Self.sideBySide(in: window, seam: fold, isFold: true)
            }
            if fold.width >= window.width * 0.9, fold.height < window.height / 3 {
                return Self.stacked(in: window, seam: fold, isFold: true)
            }
        }
        guard hasHinge, hingeStatus != .closed, max(window.width, window.height) >= 800, min(window.width, window.height) >= 560 else {
            return nil
        }
        if window.width >= window.height {
            return Self.sideBySide(in: window, seam: CGRect(x: window.midX, y: 0, width: 0, height: window.height), isFold: false)
        }
        return Self.stacked(in: window, seam: CGRect(x: 0, y: window.midY, width: window.width, height: 0), isFold: false)
    }

    private static func sideBySide(in window: CGRect, seam: CGRect, isFold: Bool) -> Split? {
        let first = CGRect(x: 0, y: 0, width: seam.minX, height: window.height)
        let second = CGRect(x: seam.maxX, y: 0, width: window.width - seam.maxX, height: window.height)
        guard first.width >= minimumPaneLength, second.width >= minimumPaneLength else {
            return nil
        }
        return Split(axis: .horizontal, first: first, seam: CGRect(x: seam.minX, y: 0, width: seam.width, height: window.height), second: second, isFold: isFold)
    }

    private static func stacked(in window: CGRect, seam: CGRect, isFold: Bool) -> Split? {
        let first = CGRect(x: 0, y: 0, width: window.width, height: seam.minY)
        let second = CGRect(x: 0, y: seam.maxY, width: window.width, height: window.height - seam.maxY)
        // Stacked panes only need room for a short video and the controls.
        guard first.height >= minimumPaneLength * 0.75, second.height >= minimumPaneLength * 0.75 else {
            return nil
        }
        return Split(axis: .vertical, first: first, seam: CGRect(x: 0, y: seam.minY, width: window.width, height: seam.height), second: second, isFold: isFold)
    }
}

extension EnvironmentValues {
    /// The posture of the window's display; set once at the root by `readsDisplayPosture()`.
    @Entry var displayPosture = DisplayPosture()
}

extension View {
    /// Reads the hinge, the reserved regions and the vertical bar of the window and shares them as
    /// `\.displayPosture`. Apply once, at the root of the window. On devices without a hinge it only measures
    /// the window.
    func readsDisplayPosture() -> some View {
        modifier(DisplayPostureReader())
    }
}

private struct DisplayPostureReader: ViewModifier {

    @State private var posture = DisplayPosture()

    func body(content: Content) -> some View {
        #if os(iOS)
        if #available(iOS 27.1, *) {
            measured(content)
                .onHingeChange { _, context in
                    if let hinge = context.hinge {
                        posture.hingeStatus = Self.status(of: hinge.status)
                        posture.hingeAngle = hinge.angle.degrees
                    } else {
                        posture.hingeStatus = nil
                        posture.hingeAngle = nil
                    }
                }
                .background {
                    VerticalBarEdgeReader { edge in
                        posture.verticalBarEdge = edge
                    }
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
                }
        } else {
            content
        }
        #else
        content
        #endif
    }

    #if os(iOS)
    @available(iOS 27.1, *)
    private func measured(_ content: Content) -> some View {
        content
            .onGeometryChange(for: Regions.self) { proxy in
                Regions(proxy)
            } action: { regions in
                posture.windowSize = regions.windowSize
                posture.folds = regions.folds
                posture.occlusions = regions.occlusions
            }
            #if DEBUG
            .modifier(DebugPostureModifier(posture: posture))
            #else
            .environment(\.displayPosture, posture)
            #endif
    }

    @available(iOS 27.1, *)
    private static func status(of status: DeviceHinge.Status) -> DisplayPosture.HingeStatus? {
        switch status {
        case .closed:
            return .closed
        case .partiallyOpen:
            return .partiallyOpen
        case .fullyOpen:
            return .fullyOpen
        default:
            return nil
        }
    }

    /// The window's size and reserved regions, measured on the root view and moved to the window's coordinate
    /// space (the root view sits inside the safe area; the window includes it).
    @available(iOS 27.1, *)
    private struct Regions: Equatable {
        var windowSize: CGSize
        var folds: [CGRect]
        var occlusions: [CGRect]

        init(_ proxy: GeometryProxy) {
            let insets = proxy.safeAreaInsets
            windowSize = CGSize(width: proxy.size.width + insets.leading + insets.trailing, height: proxy.size.height + insets.top + insets.bottom)
            // Frames in the root view's own space, not mirrored for right-to-left layouts (like every frame here).
            func regions(_ kind: ReservedRegion.Kind) -> [CGRect] {
                proxy.reservedRegions(kind: kind, layoutDirectionBehavior: .fixed)
                    .filter(\.isActive)
                    .map { $0.frame.offsetBy(dx: insets.leading, dy: insets.top) }
            }
            folds = regions(.division)
            occlusions = regions(.occlusion)
        }
    }
    #endif
}

#if os(iOS)
/// Reports the edge of the system's vertical bar (`UITraitCollection.verticalBarEdge`), which SwiftUI does not
/// expose, and follows its changes.
@available(iOS 27.1, *)
private struct VerticalBarEdgeReader: UIViewRepresentable {
    let onChange: (HorizontalEdge?) -> Void

    func makeUIView(context: Context) -> ReaderView {
        let view = ReaderView()
        view.onChange = onChange
        return view
    }

    func updateUIView(_ uiView: ReaderView, context: Context) {
        uiView.onChange = onChange
    }

    final class ReaderView: UIView {
        var onChange: ((HorizontalEdge?) -> Void)?
        private var reported: HorizontalEdge??

        override init(frame: CGRect) {
            super.init(frame: frame)
            isUserInteractionEnabled = false
            registerForTraitChanges(UITraitCollection.systemTraitsAffectingVerticalBarEdge) { (view: ReaderView, _: UITraitCollection) in
                view.report()
            }
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) {
            fatalError("init(coder:) is not used")
        }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            report()
        }

        private func report() {
            guard window != nil else {
                return
            }
            let edge: HorizontalEdge?
            switch traitCollection.verticalBarEdge {
            case .leading:
                edge = .leading
            case .trailing:
                edge = .trailing
            default:
                edge = nil
            }
            guard reported != .some(edge) else {
                return
            }
            reported = .some(edge)
            // Not during the view update that moved the view into the window.
            DispatchQueue.main.async { [onChange] in
                onChange?(edge)
            }
        }
    }
}
#endif
