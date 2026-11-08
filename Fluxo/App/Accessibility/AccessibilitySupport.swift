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
    /// and would squeeze their labels, a menu button shows the choice at full size. A menu also replaces the
    /// segments when their labels do not fit the width (long translations on a small iPhone, large text).
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
            // The segmented picker's ideal width gives every segment the width of the longest label.
            ViewThatFits(in: .horizontal) {
                content
                    .pickerStyle(.segmented)
                content
                    .pickerStyle(.menu)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
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

extension View {
    /// The screen's usual title (large at the top of a tab or a list), inline at the accessibility text sizes: a large
    /// title is one line that does not wrap, so a long word is cut there ("Einstellung…") while the inline title
    /// keeps the whole width of the bar. Nothing changes on platforms without large titles.
    func largeTitleAdaptingToTextSize() -> some View {
        modifier(AdaptiveTitleDisplayMode())
    }
}

private struct AdaptiveTitleDisplayMode: ViewModifier {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    func body(content: Content) -> some View {
        #if os(iOS)
        content
            .toolbarTitleDisplayMode(dynamicTypeSize.prefersStackedLayout ? .inline : .automatic)
        #else
        content
        #endif
    }
}

extension ToggleStyle where Self == AdaptiveSwitchToggleStyle {
    /// A switch next to its label, or under it at the accessibility text sizes (iOS), so the label keeps the whole
    /// width of the row: next to the switch a long word gets a narrow column and is split ("Per-sönli-che") even
    /// where it fits the row. Only for switches of forms and lists: a toggle in a menu keeps the menu's own style.
    static var switchAdaptingToTextSize: AdaptiveSwitchToggleStyle { AdaptiveSwitchToggleStyle() }
}

struct AdaptiveSwitchToggleStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        AdaptiveSwitchToggle(configuration: configuration)
    }
}

private struct AdaptiveSwitchToggle: View {
    let configuration: ToggleStyleConfiguration

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        #if os(iOS)
        if dynamicTypeSize.prefersStackedLayout {
            VStack(alignment: .leading, spacing: 10) {
                configuration.label
                    .frame(maxWidth: .infinity, alignment: .leading)
                    // VoiceOver reads it as the switch's label, once.
                    .accessibilityHidden(true)
                Toggle(isOn: configuration.$isOn) {
                    configuration.label
                }
                .toggleStyle(.switch)
                .labelsHidden()
            }
        } else {
            // The style the toggle would have without this one (a switch in a form).
            Toggle(configuration)
        }
        #else
        Toggle(configuration)
        #endif
    }
}

/// A row's label of a title and a smaller detail under it, with an icon in front; at the accessibility text sizes
/// (iOS) the icon goes above them, as `SettingsLabel`'s does: next to a label of two texts, the list indents the first
/// line of each, so the detail started halfway across the row.
struct DetailLabel<Title: View, Detail: View>: View {
    let systemImage: String
    @ViewBuilder var title: () -> Title
    @ViewBuilder var detail: () -> Detail

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        #if os(iOS)
        if dynamicTypeSize.prefersStackedLayout {
            VStack(alignment: .leading, spacing: 8) {
                Image(systemName: systemImage)
                    .foregroundStyle(.tint)
                    .accessibilityHidden(true)
                texts
            }
        } else {
            label
        }
        #else
        label
        #endif
    }

    private var label: some View {
        Label {
            texts
        } icon: {
            Image(systemName: systemImage)
        }
    }

    private var texts: some View {
        VStack(alignment: .leading, spacing: 2) {
            title()
            detail()
                .font(.caption)
                .foregroundStyle(Theme.secondaryText)
        }
    }
}

/// The menu picker of a form row (Settings › Video Quality, Skip back…). At the accessibility text sizes (iOS) it is
/// a menu with a label of its own, the row's label over the chosen value, which wraps: the system's menu picker puts
/// the value on one line and cuts it in the middle ("Hoc…80p)" for "Hoch (1080p)", "15 Minu…orher"). The menu lists
/// the same choices, with the chosen one checked. `value` is the title of the chosen choice, as the menu lists it.
struct FormMenuPicker<SelectionValue: Hashable, Content: View, Label: View>: View {
    @Binding var selection: SelectionValue
    let value: String
    @ViewBuilder var content: () -> Content
    @ViewBuilder var label: () -> Label

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        #if os(iOS)
        if dynamicTypeSize.prefersStackedLayout {
            Menu {
                picker
            } label: {
                VStack(alignment: .leading, spacing: 8) {
                    // The row's label as in the other rows; a menu's label is drawn in the tint otherwise.
                    label()
                        .foregroundStyle(Color.primary)
                    // The chevron next to the value where both fit on a line; else under it, so the value has the
                    // whole width and wraps between its words ("Automa-tisch" next to the chevron).
                    ViewThatFits(in: .horizontal) {
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text(value)
                                .fixedSize()
                            chevron
                        }
                        VStack(alignment: .leading, spacing: 4) {
                            Text(value)
                                .fixedSize(horizontal: false, vertical: true)
                            chevron
                        }
                    }
                    .foregroundStyle(.tint)
                    // Read as the menu's value.
                    .accessibilityHidden(true)
                }
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(.rect)
            }
            .accessibilityValue(Text(value))
        } else {
            picker
        }
        #else
        picker
        #endif
    }

    private var picker: some View {
        Picker(selection: $selection, content: content, label: label)
    }

    private var chevron: some View {
        Image(systemName: "chevron.up.chevron.down")
            .font(.subheadline.weight(.semibold))
    }
}

/// The confirm button of a sheet's bar ("Add", "Save"): its title, or the system's checkmark at the accessibility
/// text sizes (iOS), where a title next to the close button leaves the sheet's title a few letters ("Playlist
/// hinzu…"). The checkmark is read with the title by VoiceOver and shows it in the Large Content Viewer.
///
/// `textSize` is the text size of the sheet, read outside the toolbar: the bar caps the size of its own content,
/// so inside it the environment never reaches the accessibility sizes.
struct ConfirmToolbarButton: View {
    let title: String
    let textSize: DynamicTypeSize
    let action: () -> Void

    var body: some View {
        #if os(iOS)
        if textSize.prefersStackedLayout {
            Button(role: .confirm, action: action)
                .accessibilityLabel(Text(title))
                .largeContentControl(title, systemImage: "checkmark")
        } else {
            Button(title, role: .confirm, action: action)
        }
        #else
        Button(title, role: .confirm, action: action)
        #endif
    }
}

/// The title of an empty state (`ContentUnavailableView`'s label) that wraps onto as many lines as it needs. The
/// view's own title can end in "…" at the accessibility text sizes in long languages ("Playlists dur…" in German)
/// while there is room for another line.
struct EmptyStateLabel: View {
    let title: Text
    let systemImage: String

    init(_ title: LocalizedStringKey, systemImage: String) {
        self.title = Text(title)
        self.systemImage = systemImage
    }

    init(verbatim title: String, systemImage: String) {
        self.title = Text(verbatim: title)
        self.systemImage = systemImage
    }

    var body: some View {
        Label {
            title
                .lineLimit(nil)
                .fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: systemImage)
        }
    }
}

extension ContentUnavailableView where Label == EmptyStateLabel, Description == Text, Actions == EmptyView {
    /// An empty state whose title wraps onto as many lines as it needs (`EmptyStateLabel`), in place of
    /// `ContentUnavailableView(_:systemImage:description:)`.
    @MainActor
    init(wrapping title: LocalizedStringKey, systemImage: String, description: Text) {
        self.init {
            EmptyStateLabel(title, systemImage: systemImage)
        } description: {
            description
        }
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
                Text(verbatim: "Sky Sport F1 HD, a long channel name")
                    .font(.body.weight(.semibold))
                Button("See All") {}
                    .accessibilityButtonShape()
            }
            .dynamicTypeSize(size)
        }
    }
    .padding()
}
