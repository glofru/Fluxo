//
//  SubtitleOverlay.swift
//  Fluxo
//
//  Draws the cues of an external subtitle file over the video, in the caption style the user chose in
//  Settings > Accessibility > Subtitles & Captioning > Style (iOS) or System Settings > Accessibility >
//  Captions (macOS): font, text size, colors and opacity of the text, its background and window, the window's
//  corner radius and the text edge (outline, drop shadow, raised, depressed). It changes as soon as the style
//  changes. Subtitles inside the stream are drawn by the player layer itself, in the same style.
//
//  The cues sit at the bottom of the picture (not of the screen, when the video is letterboxed), rise above the
//  player controls while they show, and follow the reading direction of the text.
//

import CoreText
import MediaAccessibility
import SwiftUI

/// The system caption style (MediaAccessibility), read once and again when it changes.
@MainActor
@Observable
final class CaptionStyle {

    enum Edge: Equatable {
        case none
        case outline
        case dropShadow
        case raised
        case depressed
    }

    private(set) var fontName: String?
    /// Relative character size (1 is the default size).
    private(set) var relativeSize: CGFloat = 1
    private(set) var foreground = Color.white
    private(set) var background = Color.black.opacity(0.75)
    private(set) var window = Color.clear
    private(set) var windowCornerRadius: CGFloat = 0
    private(set) var edge: Edge = .none

    @ObservationIgnored private var observer: NSObjectProtocol?

    static let shared = CaptionStyle()

    private init() {
        read()
        observer = NotificationCenter.default.addObserver(
            forName: Notification.Name(kMACaptionAppearanceSettingsChangedNotification as String),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.read()
            }
        }
    }

    private func read() {
        let domain = MACaptionAppearanceDomain.user
        let descriptor = MACaptionAppearanceCopyFontDescriptorForStyle(domain, nil, .default).takeRetainedValue()
        // The system font (a name starting with a dot, the default) is used as such, so bold and italic runs
        // get its real weights; a font the user picked is used by name.
        let name = CTFontDescriptorCopyAttribute(descriptor, kCTFontNameAttribute) as? String
        fontName = name.flatMap { $0.hasPrefix(".") || $0.isEmpty ? nil : $0 }
        relativeSize = max(0.5, min(MACaptionAppearanceGetRelativeCharacterSize(domain, nil), 3))
        foreground = Self.color(MACaptionAppearanceCopyForegroundColor(domain, nil).takeRetainedValue(), opacity: MACaptionAppearanceGetForegroundOpacity(domain, nil))
        background = Self.color(MACaptionAppearanceCopyBackgroundColor(domain, nil).takeRetainedValue(), opacity: MACaptionAppearanceGetBackgroundOpacity(domain, nil))
        window = Self.color(MACaptionAppearanceCopyWindowColor(domain, nil).takeRetainedValue(), opacity: MACaptionAppearanceGetWindowOpacity(domain, nil))
        windowCornerRadius = MACaptionAppearanceGetWindowRoundedCornerRadius(domain, nil)
        switch MACaptionAppearanceGetTextEdgeStyle(domain, nil) {
        case .uniform:
            edge = .outline
        case .dropShadow:
            edge = .dropShadow
        case .raised:
            edge = .raised
        case .depressed:
            edge = .depressed
        default:
            edge = .none
        }
    }

    private static func color(_ color: CGColor, opacity: CGFloat) -> Color {
        Color(cgColor: color).opacity(Double(opacity) * Double(color.alpha))
    }
}

/// The external subtitles over the video. Draws nothing between cues.
struct SubtitleOverlay: View {
    let playback: ExternalSubtitlePlayback
    /// The size of the picture (`AVPlayerItem.presentationSize`), to sit on the video rather than the screen.
    let videoSize: CGSize
    let fillsScreen: Bool
    /// Room to leave at the bottom (the player controls are showing).
    let bottomInset: CGFloat

    private var style: CaptionStyle { CaptionStyle.shared }

    var body: some View {
        GeometryReader { proxy in
            let picture = Self.pictureRect(videoSize: videoSize, in: proxy.size, fills: fillsScreen)
            // About 5 % of the picture height at the default size, as TV captions are; never tiny on a phone.
            let fontSize = max(14, min(picture.height * 0.05, 44)) * style.relativeSize
            VStack(spacing: 4) {
                ForEach(Array(playback.visibleCues.enumerated()), id: \.offset) { _, cue in
                    cueText(cue, fontSize: fontSize)
                }
            }
            .frame(maxWidth: picture.width * 0.9)
            .padding(.bottom, max(picture.height * 0.06, 12) + max(0, bottomInset - (proxy.size.height - picture.maxY)))
            .frame(width: picture.width, height: picture.height, alignment: .bottom)
            .position(x: picture.midX, y: picture.midY)
            .animation(nil, value: playback.visibleCues)
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private func cueText(_ cue: SubtitleCue, fontSize: CGFloat) -> some View {
        Text(cue.text)
            .font(style.fontName.map { Font.custom($0, fixedSize: fontSize) } ?? .system(size: fontSize))
            .foregroundStyle(style.foreground)
            .multilineTextAlignment(.center)
            .lineSpacing(2)
            .padding(.horizontal, fontSize * 0.25)
            .padding(.vertical, fontSize * 0.05)
            .background(style.background, in: .rect)
            .modifier(CaptionEdge(edge: style.edge, size: fontSize))
            .padding(.horizontal, fontSize * 0.3)
            .padding(.vertical, fontSize * 0.15)
            .background(style.window, in: .rect(cornerRadius: style.windowCornerRadius))
            .fixedSize(horizontal: false, vertical: true)
    }

    /// Where an aspect-fit (or aspect-fill) picture of `videoSize` is drawn in `size`.
    static func pictureRect(videoSize: CGSize, in size: CGSize, fills: Bool) -> CGRect {
        guard videoSize.width > 0, videoSize.height > 0, size.width > 0, size.height > 0 else {
            return CGRect(origin: .zero, size: size)
        }
        let scale = fills
            ? max(size.width / videoSize.width, size.height / videoSize.height)
            : min(size.width / videoSize.width, size.height / videoSize.height)
        let width = min(size.width, videoSize.width * scale)
        let height = min(size.height, videoSize.height * scale)
        return CGRect(x: (size.width - width) / 2, y: (size.height - height) / 2, width: width, height: height)
    }
}

/// The text edge of the caption style.
private struct CaptionEdge: ViewModifier {
    let edge: CaptionStyle.Edge
    let size: CGFloat

    func body(content: Content) -> some View {
        switch edge {
        case .none:
            content
        case .outline:
            let radius = max(1, size * 0.05)
            content
                .shadow(color: .black, radius: 0, x: radius, y: 0)
                .shadow(color: .black, radius: 0, x: -radius, y: 0)
                .shadow(color: .black, radius: 0, x: 0, y: radius)
                .shadow(color: .black, radius: 0, x: 0, y: -radius)
        case .dropShadow:
            content.shadow(color: .black.opacity(0.9), radius: size * 0.06, x: size * 0.05, y: size * 0.05)
        case .raised:
            content.shadow(color: .black.opacity(0.8), radius: 0, x: 0, y: max(1, size * 0.05))
        case .depressed:
            content.shadow(color: .black.opacity(0.8), radius: 0, x: 0, y: -max(1, size * 0.05))
        }
    }
}
