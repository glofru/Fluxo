//
//  ArtworkBanner.swift
//  Fluxo
//
//  A remote image of any size and shape in a banner of a fixed shape, as wide as the space it is given and never
//  wider. Backed by the shared LogoImageLoader, like LogoImage.
//

import SwiftUI

/// Shows `source` (an http(s) or `data:image` URL) in a banner of `aspectRatio`, as wide as the proposed width
/// and at most `maxHeight` tall.
///
/// The image never decides the size of the banner, so a huge, very wide or very tall image cannot widen the
/// layout around it. How it is drawn depends on its shape and size:
/// - close to the shape of the banner, it covers it (cropped a little at most);
/// - otherwise (a poster, a square badge, a 10:1 strip), it is shown whole over a blurred copy of itself that
///   covers the banner;
/// - a tiny image is never blown up beyond two points per pixel, so it stays a sharp-enough badge in the middle.
///
/// The image is decoded at the size of the banner (rounded up, so small changes do not decode it again), never
/// at the full resolution of the source.
struct ArtworkBanner<Placeholder: View>: View {

    let source: String?
    var aspectRatio: CGFloat = 16 / 9
    var maxHeight: CGFloat = .infinity
    @ViewBuilder var placeholder: (LogoImagePhase) -> Placeholder

    @Environment(\.displayScale) private var displayScale

    /// The banner's size, rounded up to `Self.sizeStep`; zero until it is laid out.
    @State private var decodeSize: CGSize = .zero
    @State private var loaded: LoadedImage?
    @State private var failedKey: String?

    /// Covering crops at most this much of the image's shape (a 16:10 or 2:1 image covers a 16:9 banner; a 4:3
    /// one is shown whole).
    static var coverTolerance: ClosedRange<CGFloat> {
        0.8...1.25
    }

    /// The largest enlargement of a small image, in points per decoded pixel.
    static var maximumUpscale: CGFloat {
        2
    }

    private static var sizeStep: CGFloat {
        32
    }

    private struct LoadedImage {
        let key: String
        let sourceKey: String
        let image: CGImage
    }

    var body: some View {
        let request = LogoRequest(source: source, pointSize: decodeSize, scale: displayScale, contentMode: .fit)
        let loader = LogoImageLoader.shared
        let image = request.flatMap { request in
            // The synchronous memory lookup shows cached images in the very first frame. While another size of
            // the same image loads (the window was resized), the previous one stays.
            if loaded?.key == request.key {
                return loaded?.image
            }
            return loader.cachedImage(for: request) ?? (loaded?.sourceKey == request.sourceKey ? loaded?.image : nil)
        }

        BannerLayout(aspectRatio: aspectRatio, maxHeight: maxHeight) {
            GeometryReader { proxy in
                Group {
                    if let image {
                        picture(image, in: proxy.size)
                    } else if source == nil || (request.map { failedKey == $0.key || loader.hasFailed($0) } ?? false) {
                        placeholder(.unavailable)
                    } else {
                        placeholder(.loading)
                    }
                }
                .frame(width: proxy.size.width, height: proxy.size.height)
            }
        }
        .clipped()
        .onGeometryChange(for: CGSize.self) { proxy in
            Self.roundedUp(proxy.size)
        } action: { size in
            decodeSize = size
        }
        .task(id: request?.key) {
            guard let request, loaded?.key != request.key, loader.cachedImage(for: request) == nil else {
                return
            }
            let result = await loader.image(for: request)
            guard !Task.isCancelled else {
                return
            }
            if let result {
                loaded = LoadedImage(key: request.key, sourceKey: request.sourceKey, image: result)
            } else {
                failedKey = request.key
            }
        }
        .onDisappear {
            // Off screen the bitmap stays only in the cache, which may evict it; transient failures are retried
            // when the banner comes back (permanent ones are still answered by `loader.hasFailed`).
            loaded = nil
            failedKey = nil
        }
    }

    @ViewBuilder
    private func picture(_ image: CGImage, in size: CGSize) -> some View {
        let layout = Self.placement(of: CGSize(width: image.width, height: image.height), in: size)
        let picture = Image(decorative: image, scale: displayScale).resizable().interpolation(.high)
        switch layout {
        case .cover:
            picture
                .scaledToFill()
                .frame(width: size.width, height: size.height)
                .clipped()
        case .whole(let scale):
            ZStack {
                // The blurred copy fills the bars beside or above the image.
                Color.artworkPlaceholder.opacity(0.2)
                picture
                    .scaledToFill()
                    .frame(width: size.width, height: size.height)
                    .blur(radius: 24, opaque: true)
                    .clipped()
                    .overlay(.black.opacity(0.18))
                picture
                    .frame(width: CGFloat(image.width) * scale, height: CGFloat(image.height) * scale)
                    .shadow(color: .black.opacity(0.25), radius: 10, y: 3)
            }
            .frame(width: size.width, height: size.height)
            .clipped()
        }
    }

    enum Placement: Equatable {
        /// Scaled to cover the banner, cropped.
        case cover
        /// Shown whole at `scale` points per pixel.
        case whole(scale: CGFloat)
    }

    /// How an image of `pixels` is drawn in a banner of `size` points.
    static func placement(of pixels: CGSize, in size: CGSize) -> Placement {
        guard pixels.width > 0, pixels.height > 0, size.width > 0, size.height > 0 else {
            return .whole(scale: 1)
        }
        let shapeRatio = (pixels.width / pixels.height) / (size.width / size.height)
        let coverScale = max(size.width / pixels.width, size.height / pixels.height)
        if coverTolerance.contains(shapeRatio), coverScale <= maximumUpscale {
            return .cover
        }
        let fitScale = min(size.width / pixels.width, size.height / pixels.height)
        return .whole(scale: min(fitScale, maximumUpscale))
    }

    private static func roundedUp(_ size: CGSize) -> CGSize {
        guard size.width.isFinite, size.height.isFinite, size.width > 0, size.height > 0 else {
            return .zero
        }
        return CGSize(width: (size.width / sizeStep).rounded(.up) * sizeStep, height: (size.height / sizeStep).rounded(.up) * sizeStep)
    }
}

/// Exactly the proposed width (never the width of its content), and the height of `aspectRatio` up to
/// `maxHeight`; the content is proposed that size.
private struct BannerLayout: Layout {
    let aspectRatio: CGFloat
    let maxHeight: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let ratio = max(0.01, aspectRatio)
        let width: CGFloat
        if let proposed = proposal.width, proposed.isFinite {
            width = max(0, proposed)
        } else {
            // No width to fill (the ideal size, or an unlimited one): the banner's own size.
            width = maxHeight.isFinite ? maxHeight * ratio : 320
        }
        return CGSize(width: width, height: min(width / ratio, maxHeight))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for subview in subviews {
            subview.place(at: CGPoint(x: bounds.midX, y: bounds.midY), anchor: .center, proposal: ProposedViewSize(bounds.size))
        }
    }
}
