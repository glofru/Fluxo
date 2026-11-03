//
//  CastButton.swift
//  Fluxo
//
//  The Cast button and its icon. SF Symbols has no Cast glyph, and Google's Cast design checklist asks for the
//  standard one, so it is drawn here from the Material Design "cast" / "cast_connected" icons (Apache 2.0): a
//  screen with three waves in its lower leading corner, the screen filled while connected, the waves lighting up
//  in turn while connecting.
//

import SwiftUI

/// The Cast icon in a 24 × 24 grid, scaled to the rect.
struct CastGlyphShape: Shape {
    /// The filled screen of `cast_connected`.
    var isConnected: Bool
    /// The waves drawn, 0...3 (all three normally; fewer while the connecting animation runs).
    var waves: Int = 3

    func path(in rect: CGRect) -> Path {
        let scale = min(rect.width, rect.height) / 24
        let origin = CGPoint(x: rect.midX - 12 * scale, y: rect.midY - 12 * scale)
        func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(x: origin.x + x * scale, y: origin.y + y * scale)
        }

        var path = Path()

        // The screen frame, open at the lower leading corner where the waves are.
        var frame = Path()
        frame.move(to: point(2, 8))
        frame.addLine(to: point(2, 5))
        frame.addArc(tangent1End: point(2, 4), tangent2End: point(3, 4), radius: scale)
        frame.addLine(to: point(21, 4))
        frame.addArc(tangent1End: point(22, 4), tangent2End: point(22, 5), radius: scale)
        frame.addLine(to: point(22, 19))
        frame.addArc(tangent1End: point(22, 20), tangent2End: point(21, 20), radius: scale)
        frame.addLine(to: point(14, 20))
        path.addPath(frame.strokedPath(StrokeStyle(lineWidth: 2 * scale)))

        // The waves: a quarter disc and two quarter rings around the corner.
        let corner = point(1, 21)
        if waves >= 1 {
            var dot = Path()
            dot.move(to: corner)
            dot.addArc(center: corner, radius: 3 * scale, startAngle: .degrees(-90), endAngle: .degrees(0), clockwise: false)
            dot.closeSubpath()
            path.addPath(dot)
        }
        for (index, radius) in [6.0, 10.0].enumerated() where waves >= index + 2 {
            var wave = Path()
            wave.addArc(center: corner, radius: radius * scale, startAngle: .degrees(-90), endAngle: .degrees(0), clockwise: false)
            path.addPath(wave.strokedPath(StrokeStyle(lineWidth: 2 * scale)))
        }

        if isConnected {
            var screen = Path()
            screen.move(to: point(5, 7))
            screen.addLine(to: point(19, 7))
            screen.addLine(to: point(19, 17))
            screen.addLine(to: point(13.37, 17))
            screen.addCurve(to: point(5, 8.63), control1: point(12.09, 13.04), control2: point(8.96, 9.91))
            screen.closeSubpath()
            path.addPath(screen)
        }
        return path
    }
}

/// The Cast icon for a connection state: waves animating while connecting (unless Reduce Motion is on).
struct CastIcon: View {
    let connection: CastController.Connection
    var size: CGFloat = 22

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        switch connection {
        case .connecting where !reduceMotion:
            TimelineView(.periodic(from: .now, by: 0.35)) { context in
                let step = Int(context.date.timeIntervalSinceReferenceDate / 0.35) % 3
                CastGlyphShape(isConnected: false, waves: step + 1)
                    .frame(width: size, height: size)
            }
        case .connected:
            CastGlyphShape(isConnected: true)
                .frame(width: size, height: size)
        default:
            CastGlyphShape(isConnected: false)
                .frame(width: size, height: size)
        }
    }
}

/// Opens the Cast device picker. It shows only where casting exists (iOS) and, after the first use, only while
/// a Cast device is on the network or a session is active (`CastController.showsCastButton`).
struct CastButton: View {
    enum Style {
        /// On the player's glass capsule (white on video, accent while connected).
        case player
        /// In the mini player.
        case miniPlayer
    }

    let cast: CastController
    var style: Style = .player
    /// Called before the picker opens (the player keeps its controls on screen).
    var interacted: () -> Void = {}

    @ScaledMetric(relativeTo: .body) private var iconSize: CGFloat = 21

    var body: some View {
        if cast.showsCastButton {
            Button {
                interacted()
                cast.presentPicker()
            } label: {
                CastIcon(connection: cast.connection, size: style == .player ? iconSize : iconSize * 0.9)
                    .foregroundStyle(iconStyle)
                    .frame(width: style == .player ? PlayerControlMetrics.buttonSize : 30, height: 44)
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(accessibilityLabel)
            .accessibilityIdentifier("cast.button")
            .help(accessibilityLabel)
            .transition(.opacity.combined(with: .scale(scale: 0.8)))
        }
    }

    private var iconStyle: AnyShapeStyle {
        if cast.isConnected {
            return AnyShapeStyle(Theme.accent)
        }
        // The player is always dark; the other icons on its glass capsule are white.
        return style == .player ? AnyShapeStyle(.white) : AnyShapeStyle(.primary)
    }

    private var accessibilityLabel: String {
        switch cast.connection {
        case .disconnected:
            return String(localized: "Cast")
        case .connecting(let device):
            return String(localized: "Connecting to \(device.name)")
        case .connected(let device):
            return String(localized: "Casting to \(device.name)")
        }
    }
}

/// Sizes the player's controls share with the cast button.
enum PlayerControlMetrics {
    static let buttonSize: CGFloat = 44
}

#if DEBUG
#Preview("Cast icons") {
    HStack(spacing: 24) {
        CastIcon(connection: .disconnected, size: 44)
        CastIcon(connection: .connecting(SimulatedCastBackend.devices[0]), size: 44)
        CastIcon(connection: .connected(SimulatedCastBackend.devices[0]), size: 44)
    }
    .padding()
}
#endif
