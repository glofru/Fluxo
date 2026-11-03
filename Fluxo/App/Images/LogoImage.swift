//
//  LogoImage.swift
//  Fluxo
//
//  SwiftUI view for channel logos and posters, backed by the shared LogoImageLoader.
//

import SwiftUI

enum LogoImagePhase {
    /// The image is being loaded.
    case loading
    /// There is no image, or it cannot be loaded.
    case unavailable
}

/// Shows `source` (an http(s) or `data:image` URL) decoded at exactly `size` points.
///
/// The view keeps a reference to its bitmap only while it is on screen; once it disappears the
/// bitmap is owned by the bounded memory cache alone, and a load that is still running is cancelled.
struct LogoImage<Placeholder: View>: View {

    let source: String?
    let size: CGSize
    var contentMode: ContentMode = .fit
    var accessibilityLabel: String?
    @ViewBuilder var placeholder: (LogoImagePhase) -> Placeholder

    @Environment(\.displayScale) private var displayScale

    @State private var loaded: LoadedImage?
    @State private var failedKey: String?

    private struct LoadedImage {
        let key: String
        let image: CGImage
    }

    var body: some View {
        let request = LogoRequest(source: source, pointSize: size, scale: displayScale, contentMode: contentMode == .fit ? .fit : .fill)
        let loader = LogoImageLoader.shared
        // The synchronous memory lookup shows cached images in the very first frame (no flicker on reuse).
        let image = request.flatMap { request in
            loaded?.key == request.key ? loaded?.image : loader.cachedImage(for: request)
        }

        Group {
            if let image {
                picture(image)
            } else if let request, failedKey != request.key, !loader.hasFailed(request) {
                placeholder(.loading)
            } else {
                placeholder(.unavailable)
            }
        }
        .frame(width: size.width, height: size.height)
        .clipped()
        .task(id: request?.key) {
            guard let request, image == nil, loaded?.key != request.key else {
                return
            }
            let result = await loader.image(for: request)
            guard !Task.isCancelled else {
                return
            }
            if let result {
                loaded = LoadedImage(key: request.key, image: result)
            } else {
                failedKey = request.key
            }
        }
        .onDisappear {
            // Off screen the bitmap stays only in the cache, which may evict it.
            loaded = nil
            // Transient failures (offline, timeout) are not remembered by the loader: retry when the
            // view comes back. Permanent failures are still answered by `loader.hasFailed`.
            failedKey = nil
        }
    }

    @ViewBuilder
    private func picture(_ image: CGImage) -> some View {
        if let accessibilityLabel {
            Image(image, scale: displayScale, label: Text(accessibilityLabel))
                .resizable()
                .aspectRatio(contentMode: contentMode)
        } else {
            Image(decorative: image, scale: displayScale)
                .resizable()
                .aspectRatio(contentMode: contentMode)
        }
    }
}
