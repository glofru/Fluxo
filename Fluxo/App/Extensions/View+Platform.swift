//
//  View+Platform.swift
//  Fluxo
//
//  Small cross-platform helpers so that feature code does not need #if checks.
//

import SwiftUI

// Images (logos, posters) go through LogoImage / LogoImageLoader, which decode off the main thread
// at the displayed size; never decode them synchronously in a view body.

/// The kind of device, for the few layouts that are iPad-only (an iPhone in landscape can be regular width too).
enum DeviceIdiom {
    /// iPad (and an iPad app running on a Mac); false on iPhone and on macOS.
    @MainActor
    static var isPad: Bool {
        #if os(iOS)
        UIDevice.current.userInterfaceIdiom == .pad
        #else
        false
        #endif
    }
}

extension Color {
    /// Neutral background used behind channel artwork (the former UIColor.lightGray).
    static let artworkPlaceholder = Color(white: 2.0 / 3.0)
}

extension View {

    /// Shows the mini player: as a tab bar bottom accessory on iOS (the tab bar minimizes while scrolling down
    /// and the accessory then moves inline), as a floating glass bar on other platforms. Nothing shows, not even
    /// an empty accessory, while `isVisible` is false.
    @ViewBuilder
    func playerAccessory<Accessory: View>(isVisible: Bool, @ViewBuilder accessory: () -> Accessory) -> some View {
        #if os(iOS)
        self
            .tabBarMinimizeBehavior(.onScrollDown)
            .tabViewBottomAccessory(isEnabled: isVisible) {
                accessory()
            }
        #else
        self.safeAreaInset(edge: .bottom) {
            if isVisible {
                accessory()
                    .frame(maxWidth: 480, minHeight: 44, maxHeight: 56)
                    .glassEffect(.regular.interactive(), in: .capsule)
                    .padding(.bottom, 12)
            }
        }
        #endif
    }

    /// Shape used for the context menu preview where the platform supports it.
    @ViewBuilder
    func contextMenuPreviewShape(_ shape: some Shape) -> some View {
        #if os(macOS)
        self
        #else
        self.contentShape(.contextMenuPreview, shape)
        #endif
    }

    /// Uses the URL keyboard where the platform has one, without autocorrection or capitalization.
    @ViewBuilder
    func urlKeyboard() -> some View {
        // tvOS too: the URL layout of the on-screen keyboard, and of the Continuity Keyboard on a nearby iPhone.
        #if os(iOS) || os(tvOS)
        self
            .keyboardType(.URL)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
        #else
        self.autocorrectionDisabled()
        #endif
    }

    /// Lift / highlight under the iPad pointer; macOS cards handle hover in their button style.
    @ViewBuilder
    func cardHoverEffect() -> some View {
        #if os(iOS)
        self.hoverEffect(.lift)
        #else
        self
        #endif
    }

    /// Highlight of a list row under the iPad pointer; macOS lists highlight rows themselves.
    @ViewBuilder
    func rowHoverEffect() -> some View {
        #if os(iOS)
        self.hoverEffect(.highlight)
        #else
        self
        #endif
    }

    /// Soft scroll edge effect under the floating glass toolbar (iOS 26 / macOS 26).
    @ViewBuilder
    func softScrollEdge() -> some View {
        self.scrollEdgeEffectStyle(.soft, for: .top)
    }

    /// Inline navigation title where the platform supports it. The bar keeps its default (Liquid Glass)
    /// appearance: forcing a visible bar background would put an opaque strip over glass sheets.
    @ViewBuilder
    func inlineNavigationBar() -> some View {
        #if os(iOS)
        self.navigationBarTitleDisplayMode(.inline)
        #else
        self
        #endif
    }

    /// Lets a form or list in a sheet show the sheet's Liquid Glass background (iOS) at partial heights,
    /// instead of covering it with the opaque grouped background.
    @ViewBuilder
    func glassSheetContentBackground() -> some View {
        #if os(iOS)
        self.scrollContentBackground(.hidden)
        #else
        self
        #endif
    }
}

// MARK: - Touch and pointer modifiers

// SwiftUI marks these unavailable on tvOS: rows there have no swipe, there is no text selection, inspector column or
// separator between rows. The helpers apply them where they exist and change nothing on Apple TV, whose screens
// offer the same actions through focus (buttons, context menus) instead.
extension View {

    /// The swipe actions of a list row.
    @ViewBuilder
    func rowSwipeActions<Actions: View>(edge: HorizontalEdge = .trailing, allowsFullSwipe: Bool = true, @ViewBuilder content: () -> Actions) -> some View {
        #if os(tvOS)
        self
        #else
        self.swipeActions(edge: edge, allowsFullSwipe: allowsFullSwipe, content: content)
        #endif
    }

    /// Hides the separator of a list row.
    @ViewBuilder
    func rowSeparatorHidden() -> some View {
        #if os(tvOS)
        self
        #else
        self.listRowSeparator(.hidden)
        #endif
    }

    /// Lets the user select and copy the text.
    @ViewBuilder
    func selectableText() -> some View {
        #if os(tvOS)
        self
        #else
        self.textSelection(.enabled)
        #endif
    }

    /// An inspector column next to the content (iPad, Mac), `width` wide within the user's resizing.
    @ViewBuilder
    func sideInspector<Inspector: View>(isPresented: Binding<Bool>, width: (min: CGFloat, ideal: CGFloat, max: CGFloat), @ViewBuilder content: () -> Inspector) -> some View {
        #if os(tvOS)
        self
        #else
        self.inspector(isPresented: isPresented) {
            content()
                .inspectorColumnWidth(min: width.min, ideal: width.ideal, max: width.max)
        }
        #endif
    }

    /// A grouped list: inset grouped on iPhone and iPad, inset on the Mac, the TV's own grouped style on Apple TV.
    @ViewBuilder
    func groupedListStyle() -> some View {
        #if os(iOS)
        self.listStyle(.insetGrouped)
        #elseif os(macOS)
        self.listStyle(.inset)
        #else
        self.listStyle(.grouped)
        #endif
    }
}

extension SearchScopeActivation {
    /// The scopes show as soon as search starts (iPhone, iPad, Mac); tvOS shows them its own way.
    static var onSearchStart: SearchScopeActivation {
        #if os(tvOS)
        .automatic
        #else
        .onSearchPresentation
        #endif
    }
}

extension Color {
    /// The system background of a screen (what Home's hero fades into).
    static var appBackground: Color {
        #if os(macOS)
        Color(nsColor: .windowBackgroundColor)
        #elseif os(tvOS)
        // tvOS draws the background behind the app itself (and has no `systemBackground`): fading into clear fades
        // into it.
        Color.clear
        #else
        Color(uiColor: .systemBackground)
        #endif
    }
}
