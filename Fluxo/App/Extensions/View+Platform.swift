//
//  View+Platform.swift
//  Fluxo
//
//  Small cross-platform helpers so that feature code does not need #if checks.
//

import SwiftUI

#if canImport(UIKit)
import UIKit

typealias PlatformImage = UIImage
#elseif canImport(AppKit)
import AppKit

typealias PlatformImage = NSImage
#endif

extension Image {
    init(platformImage: PlatformImage) {
        #if canImport(UIKit)
        self.init(uiImage: platformImage)
        #else
        self.init(nsImage: platformImage)
        #endif
    }

    /// Decodes an inline `data:image/...` URL. Returns nil for any other URL or undecodable data.
    init?(dataURL url: URL) {
        guard url.absoluteString.hasPrefix("data:image"),
              let data = try? Data(contentsOf: url),
              let image = PlatformImage(data: data) else {
            return nil
        }
        self.init(platformImage: image)
    }
}

extension Color {
    /// Neutral background used behind channel artwork (the former UIColor.lightGray).
    static let artworkPlaceholder = Color(white: 2.0 / 3.0)
}

extension View {

    /// Shows the mini player: as a tab bar bottom accessory on iOS, as a floating bar on other platforms.
    @ViewBuilder
    func playerAccessory<Accessory: View>(isVisible: Bool, @ViewBuilder accessory: () -> Accessory) -> some View {
        #if os(iOS)
        self
            .tabBarMinimizeBehavior(.onScrollDown)
            .tabViewBottomAccessory {
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

    /// Presents the player full screen on iOS and as a resizable sheet on macOS.
    @ViewBuilder
    func playerPresentation<Content: View>(isPresented: Binding<Bool>, @ViewBuilder content: @escaping () -> Content) -> some View {
        #if os(macOS)
        self.sheet(isPresented: isPresented) {
            content()
                .frame(minWidth: 720, idealWidth: 960, minHeight: 420, idealHeight: 600)
        }
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

    /// Uses the URL keyboard where the platform has one.
    @ViewBuilder
    func urlKeyboard() -> some View {
        #if os(iOS) || os(visionOS)
        self.keyboardType(.URL)
        #else
        self
        #endif
    }

    /// Inline navigation title with a visible bar where the platform supports it.
    @ViewBuilder
    func inlineNavigationBar() -> some View {
        #if os(iOS) || os(visionOS)
        self
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(.visible, for: .navigationBar)
        #else
        self
        #endif
    }
}
