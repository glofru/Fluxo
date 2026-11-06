//
//  DebugPosture.swift
//  Fluxo
//
//  Debug harness for the iPhone with a hinge (see `DisplayPosture`). The iPhone Duo simulator only shows the
//  cover display: neither `simctl` nor the Simulator can open its hinge, so the inner display stays dark and
//  the app never receives a hinge update or a fold there. These launch arguments simulate one:
//
//  -FluxoDebugPosture closed|book|flat|tabletop   Simulated hinge: closed (no fold); book (partially open, the
//                                                 fold from top to bottom); flat (fully open, the same fold);
//                                                 tabletop (partially open with the fold from side to side,
//                                                 the phone standing like a laptop).
//  -FluxoDebugPostureSize <w>x<h>|full            The window is shown at that size, centered (default: the
//                                                 inner display, 951 x 669 pt, or 669 x 951 pt for tabletop;
//                                                 466 x 678 pt, the cover display, for closed), so the layout
//                                                 can be checked on a larger simulator. `full` keeps the window.
//
//  The `posture:<mode>` route changes the simulated posture while the app runs (e.g. during playback). With any
//  harness argument the real posture the system reports is logged whenever it changes.
//

#if DEBUG && os(iOS)
import Observation
import os
import SwiftUI

@MainActor
@Observable
final class DebugPostureSimulation {

    enum Mode: String, CaseIterable {
        case closed
        case book
        case flat
        case tabletop
    }

    static let shared = DebugPostureSimulation()

    /// nil: the real posture.
    var mode: Mode?
    /// nil: the default size of `mode`; `.zero`: the whole window.
    private(set) var size: CGSize?

    private init() {
        let arguments = UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)
        if let value = arguments["FluxoDebugPosture"].map({ "\($0)".lowercased() }) {
            mode = Mode(rawValue: value)
            if mode == nil {
                DebugLaunchOptions.logger.error("Unknown -FluxoDebugPosture \(value, privacy: .public) (closed, book, flat, tabletop)")
            }
        }
        if let value = arguments["FluxoDebugPostureSize"].map({ "\($0)".lowercased() }) {
            if value == "full" {
                size = .zero
            } else {
                let parts = value.split(separator: "x").compactMap { Double($0) }
                if parts.count == 2, parts[0] > 0, parts[1] > 0 {
                    size = CGSize(width: parts[0], height: parts[1])
                } else {
                    DebugLaunchOptions.logger.error("Invalid -FluxoDebugPostureSize \(value, privacy: .public) (e.g. 951x669, full)")
                }
            }
        }
    }

    /// The window size the simulated display has, or nil to keep the real window.
    func frameSize(in available: CGSize) -> CGSize? {
        guard let mode else {
            return nil
        }
        let wanted: CGSize
        if let size {
            guard size != .zero else {
                return nil
            }
            wanted = size
        } else {
            switch mode {
            case .closed:
                wanted = CGSize(width: 466, height: 678)
            case .book, .flat:
                wanted = CGSize(width: 951, height: 669)
            case .tabletop:
                wanted = CGSize(width: 669, height: 951)
            }
        }
        // Only when the simulator is large enough to show it.
        guard wanted.width <= available.width, wanted.height <= available.height else {
            return nil
        }
        return wanted
    }

    /// `real` with the simulated hinge and fold.
    func apply(to real: DisplayPosture) -> DisplayPosture {
        guard let mode else {
            return real
        }
        var posture = real
        posture.isSimulated = true
        posture.occlusions = []
        let size = real.windowSize
        switch mode {
        case .closed:
            posture.hingeStatus = .closed
            posture.hingeAngle = 0
            posture.folds = []
        case .book:
            posture.hingeStatus = .partiallyOpen
            posture.hingeAngle = 100
            posture.folds = [CGRect(x: size.width / 2, y: 0, width: 0, height: size.height)]
        case .flat:
            posture.hingeStatus = .fullyOpen
            posture.hingeAngle = 180
            posture.folds = [CGRect(x: size.width / 2, y: 0, width: 0, height: size.height)]
        case .tabletop:
            posture.hingeStatus = .partiallyOpen
            posture.hingeAngle = 100
            posture.folds = [CGRect(x: 0, y: size.height / 2, width: size.width, height: 0)]
        }
        return posture
    }
}

/// Shares the real or the simulated posture, frames the window to the simulated display, and logs the posture.
struct DebugPostureModifier: ViewModifier {

    let posture: DisplayPosture

    @State private var simulation = DebugPostureSimulation.shared

    func body(content: Content) -> some View {
        let effective = simulation.apply(to: posture)
        Group {
            if simulation.mode == nil {
                content
            } else {
                simulated(content, posture: effective)
            }
        }
        .environment(\.displayPosture, effective)
        .onChange(of: posture, initial: true) { _, posture in
            if DebugLaunchOptions.current.isActive {
                DebugLaunchOptions.logger.notice("Display posture: \(Self.describe(posture), privacy: .public)")
            }
        }
        .onChange(of: simulation.mode, initial: true) { _, mode in
            if let mode {
                DebugLaunchOptions.logger.notice("Simulated display posture: \(mode.rawValue, privacy: .public)")
            }
        }
    }

    private func simulated(_ content: Content, posture effective: DisplayPosture) -> some View {
        GeometryReader { proxy in
            let available = CGSize(
                width: proxy.size.width + proxy.safeAreaInsets.leading + proxy.safeAreaInsets.trailing,
                height: proxy.size.height + proxy.safeAreaInsets.top + proxy.safeAreaInsets.bottom
            )
            if let size = simulation.frameSize(in: available) {
                ZStack {
                    Color.black
                        .ignoresSafeArea()
                    content
                        .frame(width: size.width, height: size.height)
                        .overlay {
                            DebugFoldLine(posture: effective)
                        }
                        .clipShape(.rect(cornerRadius: 40, style: .continuous))
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                content
                    .overlay {
                        DebugFoldLine(posture: effective)
                    }
            }
        }
    }

    static func describe(_ posture: DisplayPosture) -> String {
        func rect(_ rect: CGRect) -> String {
            String(format: "(%.0f, %.0f, %.0f x %.0f)", rect.minX, rect.minY, rect.width, rect.height)
        }
        let hinge = posture.hingeStatus.map { "\($0.rawValue) \(posture.hingeAngle.map { String(format: "%.0f°", $0) } ?? "")" } ?? "none"
        let split = posture.split().map { "\($0.axis == .horizontal ? "side by side" : "stacked") at \(rect($0.seam))" } ?? "none"
        return [
            "window \(String(format: "%.0f x %.0f", posture.windowSize.width, posture.windowSize.height))",
            "hinge \(hinge)",
            "folds [\(posture.folds.map(rect).joined(separator: ", "))]",
            "occlusions [\(posture.occlusions.map(rect).joined(separator: ", "))]",
            "vertical bar \(posture.verticalBarEdge.map { $0 == .leading ? "leading" : "trailing" } ?? "none")",
            "split \(split)",
        ].joined(separator: "; ")
    }
}

/// A hairline where the simulated display folds, so screenshots show where the crease would be.
private struct DebugFoldLine: View {
    let posture: DisplayPosture

    var body: some View {
        if posture.isSimulated, let split = posture.split() {
            Canvas { context, _ in
                var path = Path()
                if split.axis == .horizontal {
                    path.move(to: CGPoint(x: split.seam.midX, y: 0))
                    path.addLine(to: CGPoint(x: split.seam.midX, y: split.seam.maxY))
                } else {
                    path.move(to: CGPoint(x: 0, y: split.seam.midY))
                    path.addLine(to: CGPoint(x: split.seam.maxX, y: split.seam.midY))
                }
                context.stroke(path, with: .color(.gray.opacity(0.45)), style: StrokeStyle(lineWidth: 1, dash: [6, 4]))
            }
            .ignoresSafeArea()
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
    }
}
#endif
