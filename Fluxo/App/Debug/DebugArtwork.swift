//
//  DebugArtwork.swift
//  Fluxo
//
//  Debug harness: draws channel logos and posters locally (CoreGraphics + CoreText) and returns them as
//  `data:image` URIs, so seeded libraries have artwork without any network access. Colors are derived from a
//  stable hash of the name, so the same channel looks the same on every launch.
//

#if DEBUG
import CoreGraphics
import CoreText
import Foundation
import ImageIO
import UniformTypeIdentifiers

enum DebugArtwork {

    /// The kinds of logos real playlists carry.
    enum LogoStyle: CaseIterable {
        /// White text on a colored rounded rectangle.
        case filled
        /// Colored text on a transparent background.
        case transparent
        /// Near-black text on a transparent background (hard to read on dark surfaces).
        case darkOnTransparent
        /// A wide 3:1 banner.
        case wide
        /// A square badge.
        case square
    }

    /// A PNG logo for a live channel.
    static func logo(for name: String, style: LogoStyle, scale: CGFloat = 1) -> String? {
        let seed = stableHash(name)
        let size: CGSize
        switch style {
        case .filled, .transparent, .darkOnTransparent:
            size = CGSize(width: 200 * scale, height: 120 * scale)
        case .wide:
            size = CGSize(width: 240 * scale, height: 80 * scale)
        case .square:
            size = CGSize(width: 120 * scale, height: 120 * scale)
        }
        let text = logoText(for: name)
        let hue = Double(seed % 360) / 360
        let image = draw(size: size, opaque: false) { context in
            let bounds = CGRect(origin: .zero, size: size)
            let textColor: CGColor
            switch style {
            case .filled, .wide, .square:
                let inset = bounds.insetBy(dx: size.width * 0.04, dy: size.height * 0.06)
                let radius = style == .square ? inset.width / 2 : inset.height * 0.22
                context.addPath(CGPath(roundedRect: inset, cornerWidth: radius, cornerHeight: radius, transform: nil))
                context.clip()
                fillGradient(context, in: inset, from: color(hue: hue, saturation: 0.72, brightness: 0.86), to: color(hue: hue + 0.06, saturation: 0.85, brightness: 0.52))
                textColor = CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1)
            case .transparent:
                textColor = color(hue: hue, saturation: 0.8, brightness: 0.85)
            case .darkOnTransparent:
                textColor = CGColor(srgbRed: 0.07, green: 0.07, blue: 0.09, alpha: 1)
            }
            drawCenteredLine(text, in: bounds.insetBy(dx: size.width * 0.12, dy: size.height * 0.2), color: textColor, context: context)
        }
        return image.flatMap { encode($0, type: .png, quality: nil) }
    }

    /// A JPEG 2:3 poster for a movie or series: a gradient, a simple shape and the title.
    static func poster(title: String, subtitle: String?, scale: CGFloat = 1) -> String? {
        let seed = stableHash(title)
        let size = CGSize(width: 240 * scale, height: 360 * scale)
        let hue = Double(seed % 360) / 360
        let image = draw(size: size, opaque: true) { context in
            let bounds = CGRect(origin: .zero, size: size)
            fillGradient(context, in: bounds, from: color(hue: hue, saturation: 0.65, brightness: 0.75), to: color(hue: hue + 0.12, saturation: 0.9, brightness: 0.16))

            // A "sun" or a "planet", placed from the hash.
            let diameter = size.width * (0.45 + Double(seed % 30) / 100)
            let center = CGPoint(x: size.width * (0.3 + Double((seed >> 5) % 40) / 100), y: size.height * 0.68)
            context.setFillColor(color(hue: hue + 0.5, saturation: 0.5, brightness: 1, alpha: 0.55))
            context.fillEllipse(in: CGRect(x: center.x - diameter / 2, y: center.y - diameter / 2, width: diameter, height: diameter))

            let white = CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1)
            let titleRect = CGRect(x: size.width * 0.08, y: size.height * 0.1, width: size.width * 0.84, height: size.height * 0.34)
            drawWrapped(title.uppercased(), in: titleRect, fontSize: 26 * scale, color: white, context: context)
            if let subtitle {
                let subtitleRect = CGRect(x: size.width * 0.08, y: size.height * 0.04, width: size.width * 0.84, height: size.height * 0.07)
                drawWrapped(subtitle, in: subtitleRect, fontSize: 13 * scale, bold: false, color: CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.8), context: context)
            }
        }
        return image.flatMap { encode($0, type: .jpeg, quality: 0.72) }
    }

    /// Programme images of the sizes and shapes XMLTV guides carry, to check that any of them fits the
    /// programme detail (route `programme:<channel>,<artwork>`).
    enum ProgrammeArtwork: String, CaseIterable {
        /// 32 x 32 px: a tiny channel badge.
        case tiny
        /// 1280 x 720 px: a usual 16:9 still.
        case still
        /// 6000 x 3375 px: a full-resolution 16:9 photo.
        case huge
        /// 4:3, 800 x 600 px.
        case classic
        /// 3000 x 300 px: a 10:1 banner.
        case wide
        /// 300 x 2400 px: a 1:8 strip.
        case tall
        /// 2:3, 600 x 900 px: a poster.
        case poster
        /// 1000 x 1000 px.
        case square

        var pixelSize: CGSize {
            switch self {
            case .tiny: CGSize(width: 32, height: 32)
            case .still: CGSize(width: 1_280, height: 720)
            case .huge: CGSize(width: 6_000, height: 3_375)
            case .classic: CGSize(width: 800, height: 600)
            case .wide: CGSize(width: 3_000, height: 300)
            case .tall: CGSize(width: 300, height: 2_400)
            case .poster: CGSize(width: 600, height: 900)
            case .square: CGSize(width: 1_000, height: 1_000)
            }
        }
    }

    /// A JPEG of `artwork`'s size: a gradient, a frame on its edges (so cropping shows), circles in the corners
    /// and its size in the middle.
    static func programmeArtwork(_ artwork: ProgrammeArtwork) -> String? {
        let size = artwork.pixelSize
        let shortSide = min(size.width, size.height)
        let image = draw(size: size, opaque: true) { context in
            let bounds = CGRect(origin: .zero, size: size)
            fillGradient(context, in: bounds, from: color(hue: 0.58, saturation: 0.7, brightness: 0.9), to: color(hue: 0.9, saturation: 0.8, brightness: 0.35))
            // The edges: cropping removes part of the yellow frame.
            let line = max(2, shortSide * 0.04)
            context.setStrokeColor(color(hue: 0.14, saturation: 0.9, brightness: 1))
            context.setLineWidth(line)
            context.stroke(bounds.insetBy(dx: line / 2, dy: line / 2))
            let diameter = shortSide * 0.22
            context.setFillColor(color(hue: 0.33, saturation: 0.6, brightness: 1, alpha: 0.85))
            for corner in [CGPoint(x: bounds.minX, y: bounds.minY), CGPoint(x: bounds.maxX, y: bounds.minY), CGPoint(x: bounds.minX, y: bounds.maxY), CGPoint(x: bounds.maxX, y: bounds.maxY)] {
                let x = corner.x == bounds.minX ? line * 2 : bounds.maxX - line * 2 - diameter
                let y = corner.y == bounds.minY ? line * 2 : bounds.maxY - line * 2 - diameter
                context.fillEllipse(in: CGRect(x: x, y: y, width: diameter, height: diameter))
            }
            let label = "\(Int(size.width))×\(Int(size.height))"
            drawCenteredLine(label, in: bounds.insetBy(dx: size.width * 0.15, dy: size.height * 0.38), color: CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1), context: context)
        }
        return image.flatMap { encode($0, type: .jpeg, quality: 0.8) }
    }

    /// FNV-1a, so colors do not change between launches (unlike `Hasher`).
    static func stableHash(_ string: String) -> Int {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in string.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01b3
        }
        return Int(hash % UInt64(Int32.max))
    }

    // MARK: - Drawing

    private static let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()

    private static func draw(size: CGSize, opaque: Bool, _ body: (CGContext) -> Void) -> CGImage? {
        let width = Int(size.width.rounded())
        let height = Int(size.height.rounded())
        let alpha: CGImageAlphaInfo = opaque ? .noneSkipLast : .premultipliedLast
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: colorSpace, bitmapInfo: alpha.rawValue) else {
            return nil
        }
        context.setShouldAntialias(true)
        body(context)
        return context.makeImage()
    }

    private static func encode(_ image: CGImage, type: UTType, quality: Double?) -> String? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, type.identifier as CFString, 1, nil) else {
            return nil
        }
        var properties: [CFString: Any] = [:]
        if let quality {
            properties[kCGImageDestinationLossyCompressionQuality] = quality
        }
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else {
            return nil
        }
        let mime = type == .png ? "image/png" : "image/jpeg"
        return "data:\(mime);base64,\((data as Data).base64EncodedString())"
    }

    private static func color(hue: Double, saturation: Double, brightness: Double, alpha: Double = 1) -> CGColor {
        // HSB to RGB.
        let h = (hue.truncatingRemainder(dividingBy: 1) + 1).truncatingRemainder(dividingBy: 1) * 6
        let c = brightness * saturation
        let x = c * (1 - abs(h.truncatingRemainder(dividingBy: 2) - 1))
        let m = brightness - c
        let (r, g, b): (Double, Double, Double)
        switch Int(h) {
        case 0: (r, g, b) = (c, x, 0)
        case 1: (r, g, b) = (x, c, 0)
        case 2: (r, g, b) = (0, c, x)
        case 3: (r, g, b) = (0, x, c)
        case 4: (r, g, b) = (x, 0, c)
        default: (r, g, b) = (c, 0, x)
        }
        return CGColor(srgbRed: r + m, green: g + m, blue: b + m, alpha: alpha)
    }

    private static func fillGradient(_ context: CGContext, in rect: CGRect, from start: CGColor, to end: CGColor) {
        guard let gradient = CGGradient(colorsSpace: colorSpace, colors: [start, end] as CFArray, locations: [0, 1]) else {
            return
        }
        // CoreGraphics' origin is bottom left: top left to bottom right.
        context.drawLinearGradient(gradient, start: CGPoint(x: rect.minX, y: rect.maxY), end: CGPoint(x: rect.maxX, y: rect.minY), options: [])
    }

    private static func font(size: CGFloat, bold: Bool) -> CTFont {
        let base = CTFontCreateUIFontForLanguage(.system, size, nil) ?? CTFontCreateWithName("Helvetica" as CFString, size, nil)
        guard bold else {
            return base
        }
        return CTFontCreateCopyWithSymbolicTraits(base, size, nil, .traitBold, .traitBold) ?? base
    }

    private static func attributed(_ text: String, font: CTFont, color: CGColor, centered: Bool) -> NSAttributedString {
        var alignment = centered ? CTTextAlignment.center : CTTextAlignment.left
        let paragraph = withUnsafeMutablePointer(to: &alignment) { pointer in
            var setting = CTParagraphStyleSetting(spec: .alignment, valueSize: MemoryLayout<CTTextAlignment>.size, value: pointer)
            return CTParagraphStyleCreate(&setting, 1)
        }
        return NSAttributedString(string: text, attributes: [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): color,
            NSAttributedString.Key(kCTParagraphStyleAttributeName as String): paragraph,
        ])
    }

    /// One line, scaled down to fit `rect`, centered.
    private static func drawCenteredLine(_ text: String, in rect: CGRect, color: CGColor, context: CGContext) {
        var fontSize = rect.height
        var line = CTLineCreateWithAttributedString(attributed(text, font: font(size: fontSize, bold: true), color: color, centered: true))
        var width = CTLineGetTypographicBounds(line, nil, nil, nil)
        if width > rect.width {
            fontSize *= rect.width / width
            line = CTLineCreateWithAttributedString(attributed(text, font: font(size: fontSize, bold: true), color: color, centered: true))
            width = CTLineGetTypographicBounds(line, nil, nil, nil)
        }
        var ascent: CGFloat = 0
        var descent: CGFloat = 0
        _ = CTLineGetTypographicBounds(line, &ascent, &descent, nil)
        context.textMatrix = .identity
        context.textPosition = CGPoint(x: rect.midX - width / 2, y: rect.midY - (ascent - descent) / 2)
        CTLineDraw(line, context)
    }

    /// Wrapped text inside `rect`, bottom aligned.
    private static func drawWrapped(_ text: String, in rect: CGRect, fontSize: CGFloat, bold: Bool = true, color: CGColor, context: CGContext) {
        let string = attributed(text, font: font(size: fontSize, bold: bold), color: color, centered: false)
        let framesetter = CTFramesetterCreateWithAttributedString(string)
        let fitting = CTFramesetterSuggestFrameSizeWithConstraints(framesetter, CFRange(), nil, CGSize(width: rect.width, height: rect.height), nil)
        let frameRect = CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: min(rect.height, ceil(fitting.height)))
        let frame = CTFramesetterCreateFrame(framesetter, CFRange(), CGPath(rect: frameRect, transform: nil), nil)
        context.textMatrix = .identity
        CTFrameDraw(frame, context)
    }

    /// The brand text of a logo: the name without quality tags and country prefixes, or its initials when long.
    private static func logoText(for name: String) -> String {
        var words = name
            .replacingOccurrences(of: "|", with: " ")
            .split(separator: " ")
            .map(String.init)
        let tags: Set<String> = ["HD", "FHD", "UHD", "4K", "SD", "HDR", "IT", "UK", "FR", "DE", "ES", "—", "-"]
        words.removeAll { tags.contains($0.uppercased()) }
        let text = words.joined(separator: " ")
        if text.count <= 12 {
            return text.isEmpty ? name : text
        }
        let initials = words.compactMap { $0.first(where: { $0.isLetter || $0.isNumber }) }
        return String(initials.prefix(4)).uppercased()
    }
}
#endif
