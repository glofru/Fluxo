//
//  LogoTone.swift
//  Fluxo
//
//  Whether a channel logo is dark lettering on a transparent background (black or navy text, no badge of its own),
//  which disappears on the graphite tiles of the Apple TV app: such logos get a light tile, on the cards
//  (`TVLandscapeArtworkView`) and in the Top Shelf images (`TopShelfArtworkRenderer`) alike.
//

#if os(tvOS)
import CoreGraphics
import Foundation

@MainActor
enum LogoTone {
    struct Result: Equatable {
        /// `LogoRequest.key` of the image measured.
        let key: String
        let isDarkOnTransparent: Bool
    }

    /// The tone of the logos measured so far, by `LogoRequest.key` (one small value per logo and size).
    private static var cache: [String: Bool] = [:]

    /// The tone of an image measured before, if any.
    static func cached(_ request: LogoRequest) -> Bool? {
        cache[request.key]
    }

    /// Measures the image of `request` (and remembers it).
    static func measure(_ image: CGImage, for request: LogoRequest) -> Bool {
        if let known = cache[request.key] {
            return known
        }
        let value = isDarkOnTransparent(image)
        if cache.count > 2_000 {
            cache.removeAll(keepingCapacity: true)
        }
        cache[request.key] = value
        return value
    }

    /// Dark artwork on a transparent background: drawn at 24 × 24, it covers less than 85 % of the square and its
    /// opaque pixels are dark on average (luminance under 0.28). Opaque logos (a badge with its own background)
    /// never are.
    nonisolated static func isDarkOnTransparent(_ image: CGImage) -> Bool {
        let side = 24
        var pixels = [UInt8](repeating: 0, count: side * side * 4)
        let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(
                data: buffer.baseAddress, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side * 4,
                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else {
                return false
            }
            context.interpolationQuality = .medium
            context.draw(image, in: CGRect(x: 0, y: 0, width: side, height: side))
            return true
        }
        guard drawn else {
            return false
        }
        var coverage = 0.0
        var luminance = 0.0
        for index in stride(from: 0, to: pixels.count, by: 4) {
            let alpha = Double(pixels[index + 3]) / 255
            guard alpha > 0.05 else {
                continue
            }
            // Premultiplied: divide by alpha for the color's own luminance, weighted by how opaque it is.
            let red = Double(pixels[index]) / 255 / alpha
            let green = Double(pixels[index + 1]) / 255 / alpha
            let blue = Double(pixels[index + 2]) / 255 / alpha
            luminance += (0.2126 * red + 0.7152 * green + 0.0722 * blue) * alpha
            coverage += alpha
        }
        let pixelCount = Double(side * side)
        guard coverage > 0, coverage / pixelCount < 0.85 else {
            return false
        }
        return luminance / coverage < 0.28
    }
}
#endif
