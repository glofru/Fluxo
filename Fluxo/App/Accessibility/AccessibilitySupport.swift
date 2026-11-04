//
//  AccessibilitySupport.swift
//  Fluxo
//
//  Building blocks for accessibility shared by every screen: layouts that stack at the accessibility text
//  sizes, card sizes that grow with Dynamic Type, the Large Content Viewer for controls that cannot grow,
//  Smart Invert exclusions for artwork and video, visible shapes behind plain buttons when Button Shapes is on,
//  and VoiceOver announcements.
//

import Accessibility
import SwiftUI

// MARK: - Dynamic Type

extension DynamicTypeSize {
    /// The accessibility text sizes (AX1 to AX5): side-by-side layouts stack there, and single-line labels may
    /// wrap.
    var prefersStackedLayout: Bool {
        isAccessibilitySize
    }
}

/// A row that becomes a column at the accessibility text sizes, so labels keep the whole width instead of
/// being truncated next to an image or a button.
struct AdaptiveStack<Content: View>: View {
    var horizontalAlignment: HorizontalAlignment = .leading
    var verticalAlignment: VerticalAlignment = .center
    var spacing: CGFloat?
    /// The first size that stacks.
    var stacksFrom: DynamicTypeSize = .accessibility1
    @ViewBuilder var content: () -> Content

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        let layout = dynamicTypeSize >= stacksFrom
            ? AnyLayout(VStackLayout(alignment: horizontalAlignment, spacing: spacing))
            : AnyLayout(HStackLayout(alignment: verticalAlignment, spacing: spacing))
        layout {
            content()
        }
    }
}

/// How much the cards of the horizontal rows grow with the text size: 1 at the default size, then with the
/// subheadline style, up to `maximum`, so a card never gets wider than a phone screen (the extra text then
/// wraps onto more lines, see `CardTextMetrics`).
struct CardScale: DynamicProperty {
    @ScaledMetric(relativeTo: .subheadline) private var scaled: CGFloat = 1
    var maximum: CGFloat = 1.45

    var value: CGFloat {
        min(maximum, max(1, scaled))
    }

    /// `size` grown by the scale, rounded to whole points.
    func scaled(_ size: CGSize) -> CGSize {
        CGSize(width: (size.width * value).rounded(), height: (size.height * value).rounded())
    }

    func scaled(_ length: CGFloat) -> CGFloat {
        (length * value).rounded()
    }
}

/// Line limits of card titles: the design's limit up to the largest standard size, more at the accessibility
/// sizes, where a name of a few words needs several lines even on a wider card.
enum CardTextMetrics {
    static func titleLineLimit(_ standard: Int, at size: DynamicTypeSize) -> Int {
        switch size {
        case .accessibility1, .accessibility2:
            return standard + 2
        case .accessibility3, .accessibility4, .accessibility5:
            return standard + 4
        default:
            return standard
        }
    }
}

extension View {
    /// A segmented picker, or a menu at the accessibility text sizes: segments do not grow with Dynamic Type
    /// and would squeeze their labels, a menu button shows the choice at full size.
    func segmentedPickerStyleAdaptingToTextSize() -> some View {
        modifier(AdaptiveSegmentedPickerStyle())
    }
}

private struct AdaptiveSegmentedPickerStyle: ViewModifier {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    func body(content: Content) -> some View {
        if dynamicTypeSize.prefersStackedLayout {
            content
                .pickerStyle(.menu)
                .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            content
                .pickerStyle(.segmented)
        }
    }
}

extension View {
    /// Medium and large sheet heights, or large only at the accessibility text sizes, where half a screen shows
    /// a line or two.
    func mediumAndLargeDetentsAdaptingToTextSize() -> some View {
        modifier(AdaptiveDetents())
    }
}

private struct AdaptiveDetents: ViewModifier {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    func body(content: Content) -> some View {
        content
            .presentationDetents(dynamicTypeSize.prefersStackedLayout ? [.large] : [.medium, .large])
    }
}

// MARK: - Large Content Viewer, Smart Invert, Button Shapes

extension View {
    /// Shows `title` and `systemImage` in the Large Content Viewer (a long press at the accessibility text sizes,
    /// iOS) for controls that keep their size, like the player's buttons and the mini player.
    func largeContentControl(_ title: String, systemImage: String) -> some View {
        accessibilityShowsLargeContentViewer {
            Label(title, systemImage: systemImage)
        }
    }

    /// Keeps photos, logos, posters and video in their real colors under Smart Invert.
    func artworkIgnoresInvertColors() -> some View {
        accessibilityIgnoresInvertColors(true)
    }

    /// Draws a visible shape behind a plain (text or icon only) button while Button Shapes is on, as the system
    /// does for its own borderless buttons.
    func accessibilityButtonShape<S: InsettableShape>(_ shape: S = Capsule(), padding: EdgeInsets = EdgeInsets(top: 3, leading: 8, bottom: 3, trailing: 8)) -> some View {
        modifier(ButtonShapeModifier(shape: shape, padding: padding))
    }
}

private struct ButtonShapeModifier<S: InsettableShape>: ViewModifier {
    let shape: S
    let padding: EdgeInsets

    @Environment(\.accessibilityShowBorders) private var showsBorders

    func body(content: Content) -> some View {
        if showsBorders {
            content
                .padding(padding)
                .background(.tint.opacity(0.14), in: shape)
                .overlay {
                    shape.strokeBorder(.tint.opacity(0.55), lineWidth: 1)
                }
        } else {
            content
        }
    }
}

/// A checkmark in front of the selected chip of a row of chips while Differentiate Without Color is on: the
/// selection is otherwise shown by the chip's tint (and a heavier weight).
struct SelectionCheckmark: View {
    let isSelected: Bool

    @Environment(\.accessibilityDifferentiateWithoutColor) private var differentiateWithoutColor

    var body: some View {
        if isSelected && differentiateWithoutColor {
            Image(systemName: "checkmark")
                .font(.caption.weight(.bold))
                .accessibilityHidden(true)
        }
    }
}

// MARK: - Announcements

/// VoiceOver announcements (also spoken by other assistive technologies that read them, and shown on braille
/// displays). Posting is cheap and does nothing while no assistive technology runs.
enum AccessibilityAnnouncer {
    enum Priority {
        /// Queued after what is being spoken, dropped if something else is announced first.
        case low
        case standard
        /// Interrupts the current speech: errors and state changes the user is waiting for.
        case high
    }

    @MainActor
    static func announce(_ text: String, priority: Priority = .standard) {
        guard !text.isEmpty else {
            return
        }
        var announcement = AttributedString(text)
        switch priority {
        case .low:
            announcement.accessibilitySpeechAnnouncementPriority = .low
        case .standard:
            announcement.accessibilitySpeechAnnouncementPriority = .default
        case .high:
            announcement.accessibilitySpeechAnnouncementPriority = .high
        }
        AccessibilityNotification.Announcement(announcement).post()
    }

    /// A large part of the screen changed (a custom presentation such as the player): VoiceOver moves to the
    /// first element of the new content.
    @MainActor
    static func screenChanged() {
        AccessibilityNotification.ScreenChanged().post()
    }

    /// Part of the screen changed (rows inserted, a panel appeared).
    @MainActor
    static func layoutChanged() {
        AccessibilityNotification.LayoutChanged().post()
    }
}

#Preview("Adaptive stack") {
    VStack(alignment: .leading, spacing: 24) {
        ForEach([DynamicTypeSize.large, .accessibility3], id: \.self) { size in
            AdaptiveStack(spacing: 12) {
                RoundedRectangle(cornerRadius: 10)
                    .fill(Theme.brandGradient)
                    .frame(width: 76, height: 50)
                Text("Sky Sport F1 HD, a long channel name")
                    .font(.body.weight(.semibold))
                Button("See All") {}
                    .accessibilityButtonShape()
            }
            .dynamicTypeSize(size)
        }
    }
    .padding()
}
