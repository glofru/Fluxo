//
//  View+Platform.swift
//  Fluxo
//
//  Small cross-platform helpers so that feature code does not need #if checks.
//

import SwiftUI

// Images (logos, posters) go through LogoImage / LogoImageLoader, which decode off the main thread
// at the displayed size; never decode them synchronously in a view body.

extension Color {
    /// Neutral background used behind channel artwork (the former UIColor.lightGray).
    static let artworkPlaceholder = Color(white: 2.0 / 3.0)
}

extension View {

    /// Shows the mini player: as a tab bar bottom accessory on iOS (the tab bar minimizes while scrolling down
    /// and the accessory then moves inline), as a floating glass bar on other platforms.
    @ViewBuilder
    func playerAccessory<Accessory: View>(isVisible: Bool, @ViewBuilder accessory: () -> Accessory) -> some View {
        #if os(iOS)
        let minimizing = self.tabBarMinimizeBehavior(.onScrollDown)
        if #available(iOS 26.1, *) {
            minimizing.tabViewBottomAccessory(isEnabled: isVisible) {
                accessory()
            }
        } else {
            // iOS 26.0 always shows the accessory: the accessory itself shows a "Not Playing" state.
            minimizing.tabViewBottomAccessory {
                accessory()
            }
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

    /// Presents the player full screen on iOS, and over the whole main window on macOS (the window's
    /// toolbar is hidden meanwhile, and the browser underneath keeps its state).
    @ViewBuilder
    func playerPresentation<Content: View>(isPresented: Binding<Bool>, @ViewBuilder content: @escaping () -> Content) -> some View {
        #if os(macOS)
        let isShowing = isPresented.wrappedValue
        ZStack {
            self
                .toolbar(isShowing ? .hidden : .automatic, for: .windowToolbar)
                .allowsHitTesting(!isShowing)
                .accessibilityHidden(isShowing)

            if isShowing {
                content()
                    .transition(.opacity)
                    .zIndex(1)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: isShowing)
        #else
        self.fullScreenCover(isPresented: isPresented, content: content)
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
        #if os(iOS)
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

extension Color {
    /// The system background of a screen (what Home's hero fades into).
    static var appBackground: Color {
        #if os(macOS)
        Color(nsColor: .windowBackgroundColor)
        #else
        Color(uiColor: .systemBackground)
        #endif
    }
}
