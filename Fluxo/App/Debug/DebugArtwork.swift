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
import Synchronization
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

    /// The kinds of key art `scenePoster` draws: original scenes for the invented titles of the `store` seed, so the
    /// App Store screenshots show posters that look like a film's, without any real film, studio or artwork.
    enum PosterScene: CaseIterable {
        /// Deep space: stars, nebulae, a ringed planet and a moon (science fiction).
        case space
        /// Layers of hills under a setting sun (action, adventure).
        case mountains
        /// A skyline at night with lit windows and a moon (drama).
        case city
        /// Waves under a low sun and its reflection (documentaries).
        case ocean
        /// A bright sky with rays, a big sun and rolling hills (comedy).
        case sunburst
        /// Overlapping soft circles in three colors (animation).
        case bubbles
        /// Two stage spotlights in sepia (classics).
        case spotlight
    }

    /// A 2:3 poster of `scene` with the title large at the bottom and `subtitle` above it, in a palette derived from the
    /// title (the same title always looks the same). 400 x 600 px at scale 1; `scale` multiplies it.
    static func scenePoster(title: String, subtitle: String?, scene: PosterScene, scale: CGFloat = 1) -> String? {
        let key = "\(title)|\(subtitle ?? "")|\(scene)|\(scale)"
        if let cached = scenePosterCache.withLock({ $0[key] }) {
            return cached
        }
        let seed = stableHash(title)
        let size = CGSize(width: 400 * scale, height: 600 * scale)
        let image = draw(size: size, opaque: true) { context in
            var random = SeededRandom(seed: UInt64(seed))
            let bounds = CGRect(origin: .zero, size: size)
            let hue = Double(seed % 360) / 360
            drawScene(scene, in: bounds, hue: hue, random: &random, context: context)

            // A scrim under the title, so it reads on any scene.
            fillVertical(context, in: CGRect(x: 0, y: 0, width: size.width, height: size.height * 0.42), colors: [
                CGColor(srgbRed: 0.03, green: 0.02, blue: 0.08, alpha: 0),
                CGColor(srgbRed: 0.03, green: 0.02, blue: 0.08, alpha: 0.78),
            ])
            let white = CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1)
            let titleRect = CGRect(x: size.width * 0.08, y: size.height * 0.06, width: size.width * 0.84, height: size.height * 0.26)
            drawWrapped(title.uppercased(), in: titleRect, fontSize: 40 * scale, color: white, context: context)
            if let subtitle {
                let subtitleRect = CGRect(x: size.width * 0.08, y: size.height * 0.025, width: size.width * 0.84, height: size.height * 0.04)
                drawWrapped(subtitle.uppercased(), in: subtitleRect, fontSize: 13 * scale, bold: false, color: CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.78), context: context)
            }
        }
        let uri = image.flatMap { encode($0, type: .jpeg, quality: 0.74) }
        scenePosterCache.withLock { $0[key] = uri }
        return uri
    }

    /// Posters already drawn: every episode of a season shares its season's poster.
    private static let scenePosterCache = Mutex<[String: String?]>([:])

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

    // MARK: - Scenes

    /// SplitMix64: the same sequence for the same seed on every launch and platform.
    private struct SeededRandom {
        var state: UInt64

        init(seed: UInt64) {
            state = seed &+ 0x9e37_79b9_7f4a_7c15
        }

        mutating func next() -> Double {
            state &+= 0x9e37_79b9_7f4a_7c15
            var z = state
            z = (z ^ (z >> 30)) &* 0xbf58_476d_1ce4_e5b9
            z = (z ^ (z >> 27)) &* 0x94d0_49bb_1331_11eb
            z ^= z >> 31
            return Double(z >> 11) / Double(1 << 53)
        }

        mutating func next(_ range: ClosedRange<Double>) -> Double {
            range.lowerBound + next() * (range.upperBound - range.lowerBound)
        }
    }

    // swiftlint:disable:next cyclomatic_complexity
    private static func drawScene(_ scene: PosterScene, in bounds: CGRect, hue: Double, random: inout SeededRandom, context: CGContext) {
        let width = bounds.width
        let height = bounds.height
        // CoreGraphics' origin is bottom left: y grows upwards.
        switch scene {
        case .space:
            let base = 0.62 + hue * 0.2
            fillVertical(context, in: bounds, colors: [
                color(hue: base, saturation: 0.75, brightness: 0.32),
                color(hue: base + 0.05, saturation: 0.9, brightness: 0.12),
                color(hue: base + 0.08, saturation: 0.9, brightness: 0.05),
            ])
            glow(context, at: CGPoint(x: width * random.next(0.15...0.5), y: height * random.next(0.55...0.8)), radius: width * 0.6, color: color(hue: base + 0.25, saturation: 0.8, brightness: 0.9, alpha: 0.35))
            glow(context, at: CGPoint(x: width * random.next(0.6...0.9), y: height * random.next(0.7...0.9)), radius: width * 0.45, color: color(hue: base - 0.1, saturation: 0.8, brightness: 0.9, alpha: 0.28))
            stars(context, in: bounds, count: 140, random: &random)
            let planet = CGRect(x: width * 0.28, y: height * 0.2, width: width * 0.9, height: width * 0.9)
            context.saveGState()
            context.addEllipse(in: planet)
            context.clip()
            fillDiagonal(context, in: planet, colors: [
                color(hue: base + 0.3, saturation: 0.55, brightness: 0.95),
                color(hue: base + 0.12, saturation: 0.8, brightness: 0.45),
                color(hue: base + 0.05, saturation: 0.9, brightness: 0.08),
            ])
            context.restoreGState()
            context.saveGState()
            context.translateBy(x: planet.midX, y: planet.midY)
            context.rotate(by: 0.32)
            context.setStrokeColor(color(hue: base + 0.32, saturation: 0.35, brightness: 1, alpha: 0.55))
            context.setLineWidth(width * 0.018)
            context.strokeEllipse(in: CGRect(x: -planet.width * 0.78, y: -planet.height * 0.16, width: planet.width * 1.56, height: planet.height * 0.32))
            context.restoreGState()
            let moon = width * 0.11
            context.setFillColor(color(hue: base + 0.4, saturation: 0.15, brightness: 0.95))
            context.fillEllipse(in: CGRect(x: width * 0.14, y: height * 0.62, width: moon, height: moon))

        case .mountains:
            let warm = 0.94 + hue * 0.1
            fillVertical(context, in: bounds, colors: [
                color(hue: 0.7, saturation: 0.8, brightness: 0.2),
                color(hue: warm - 0.12, saturation: 0.65, brightness: 0.65),
                color(hue: warm, saturation: 0.7, brightness: 0.98),
                color(hue: warm + 0.06, saturation: 0.55, brightness: 1),
            ], locations: [0, 0.45, 0.72, 1], top: height, bottom: height * 0.35)
            stars(context, in: CGRect(x: 0, y: height * 0.7, width: width, height: height * 0.3), count: 40, random: &random)
            let sun = CGPoint(x: width * random.next(0.3...0.7), y: height * 0.5)
            glow(context, at: sun, radius: width * 0.55, color: color(hue: warm + 0.04, saturation: 0.45, brightness: 1, alpha: 0.6))
            context.setFillColor(color(hue: warm + 0.06, saturation: 0.18, brightness: 1))
            context.fillEllipse(in: CGRect(x: sun.x - width * 0.12, y: sun.y - width * 0.12, width: width * 0.24, height: width * 0.24))
            for layer in 0..<4 {
                let t = Double(layer) / 3
                let base = height * (0.5 - 0.11 * Double(layer))
                ridge(context, in: bounds, base: base, amplitude: height * (0.13 - 0.02 * t), peaks: 1.2 + Double(layer) * 0.6, random: &random, colors: [
                    color(hue: 0.72 - 0.04 * t, saturation: 0.45 + 0.3 * t, brightness: 0.72 - 0.55 * t),
                    color(hue: 0.74 - 0.04 * t, saturation: 0.6 + 0.3 * t, brightness: 0.5 - 0.42 * t),
                ])
            }

        case .city:
            let night = 0.6 + hue * 0.12
            fillVertical(context, in: bounds, colors: [
                color(hue: night, saturation: 0.85, brightness: 0.1),
                color(hue: night + 0.05, saturation: 0.7, brightness: 0.35),
                color(hue: night + 0.3, saturation: 0.55, brightness: 0.7),
            ], locations: [0, 0.6, 1], top: height, bottom: height * 0.3)
            stars(context, in: CGRect(x: 0, y: height * 0.6, width: width, height: height * 0.4), count: 60, random: &random)
            let moon = CGPoint(x: width * random.next(0.62...0.82), y: height * 0.8)
            glow(context, at: moon, radius: width * 0.3, color: color(hue: 0.12, saturation: 0.2, brightness: 1, alpha: 0.45))
            context.setFillColor(color(hue: 0.12, saturation: 0.1, brightness: 1))
            context.fillEllipse(in: CGRect(x: moon.x - width * 0.07, y: moon.y - width * 0.07, width: width * 0.14, height: width * 0.14))
            for layer in 0..<2 {
                var x = -width * 0.05
                let near = layer == 1
                while x < width {
                    let buildingWidth = width * random.next(near ? 0.1...0.2 : 0.06...0.12)
                    let buildingHeight = height * random.next(near ? 0.18...0.42 : 0.3...0.55)
                    let rect = CGRect(x: x, y: 0, width: buildingWidth, height: buildingHeight)
                    context.setFillColor(near ? color(hue: night, saturation: 0.6, brightness: 0.07) : color(hue: night + 0.04, saturation: 0.5, brightness: 0.22))
                    context.fill(rect)
                    let window = width * (near ? 0.016 : 0.01)
                    var wy = window * 2
                    while wy < buildingHeight - window * 2 {
                        var wx = rect.minX + window
                        while wx < rect.maxX - window * 1.5 {
                            if random.next() < (near ? 0.28 : 0.2) {
                                context.setFillColor(color(hue: 0.11 + random.next(0...0.04), saturation: 0.6, brightness: 1, alpha: near ? 0.9 : 0.55))
                                context.fill(CGRect(x: wx, y: wy, width: window, height: window * 1.3))
                            }
                            wx += window * 2
                        }
                        wy += window * 2.6
                    }
                    x += buildingWidth + width * random.next(0...0.015)
                }
            }

        case .ocean:
            let sea = 0.5 + hue * 0.12
            fillVertical(context, in: bounds, colors: [
                color(hue: 0.68, saturation: 0.6, brightness: 0.3),
                color(hue: 0.92, saturation: 0.45, brightness: 0.85),
                color(hue: 0.08, saturation: 0.6, brightness: 1),
            ], locations: [0, 0.6, 1], top: height, bottom: height * 0.42)
            let sun = CGPoint(x: width * random.next(0.35...0.65), y: height * 0.45)
            glow(context, at: sun, radius: width * 0.5, color: color(hue: 0.07, saturation: 0.5, brightness: 1, alpha: 0.65))
            context.setFillColor(color(hue: 0.1, saturation: 0.25, brightness: 1))
            context.fillEllipse(in: CGRect(x: sun.x - width * 0.1, y: sun.y - width * 0.1, width: width * 0.2, height: width * 0.2))
            fillVertical(context, in: CGRect(x: 0, y: 0, width: width, height: height * 0.43), colors: [
                color(hue: sea, saturation: 0.6, brightness: 0.55),
                color(hue: sea + 0.06, saturation: 0.8, brightness: 0.12),
            ])
            for line in 0..<26 {
                let y = height * 0.43 * (1 - pow(Double(line) / 26, 1.6))
                let spread = width * (0.04 + 0.3 * Double(line) / 26)
                context.setFillColor(color(hue: 0.09, saturation: 0.35, brightness: 1, alpha: 0.5 - 0.016 * Double(line)))
                context.fill(CGRect(x: sun.x - spread / 2 + random.next(-6...6), y: y, width: spread * random.next(0.4...1), height: max(1, height * 0.004)))
            }
            for layer in 0..<3 {
                let t = Double(layer) / 2
                ridge(context, in: bounds, base: height * (0.2 - 0.07 * Double(layer)), amplitude: height * 0.03, peaks: 4 + Double(layer) * 2, random: &random, colors: [
                    color(hue: sea + 0.04 * t, saturation: 0.65, brightness: 0.45 - 0.2 * t, alpha: 0.85),
                    color(hue: sea + 0.06, saturation: 0.8, brightness: 0.12, alpha: 0.95),
                ])
            }

        case .sunburst:
            let sky = 0.08 + hue * 0.1
            fillVertical(context, in: bounds, colors: [
                color(hue: sky + 0.5, saturation: 0.55, brightness: 0.95),
                color(hue: sky, saturation: 0.55, brightness: 1),
            ])
            let center = CGPoint(x: width * 0.5, y: height * 0.55)
            context.saveGState()
            context.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.16))
            for ray in stride(from: 0, to: 24, by: 2) {
                let a1 = Double(ray) / 24 * 2 * .pi
                let a2 = Double(ray + 1) / 24 * 2 * .pi
                context.move(to: center)
                context.addLine(to: CGPoint(x: center.x + cos(a1) * height, y: center.y + sin(a1) * height))
                context.addLine(to: CGPoint(x: center.x + cos(a2) * height, y: center.y + sin(a2) * height))
                context.closePath()
            }
            context.fillPath()
            context.restoreGState()
            glow(context, at: center, radius: width * 0.4, color: CGColor(srgbRed: 1, green: 0.95, blue: 0.75, alpha: 0.8))
            context.setFillColor(color(hue: 0.12, saturation: 0.75, brightness: 1))
            context.fillEllipse(in: CGRect(x: center.x - width * 0.17, y: center.y - width * 0.17, width: width * 0.34, height: width * 0.34))
            for layer in 0..<2 {
                ridge(context, in: bounds, base: height * (0.4 - 0.12 * Double(layer)), amplitude: height * 0.07, peaks: 1.4 + Double(layer), random: &random, colors: [
                    color(hue: sky + 0.25 + 0.05 * Double(layer), saturation: 0.6, brightness: 0.75 - 0.2 * Double(layer)),
                    color(hue: sky + 0.3 + 0.05 * Double(layer), saturation: 0.7, brightness: 0.5 - 0.2 * Double(layer)),
                ])
            }

        case .bubbles:
            fillDiagonal(context, in: bounds, colors: [
                color(hue: hue, saturation: 0.6, brightness: 0.95),
                color(hue: hue + 0.18, saturation: 0.75, brightness: 0.55),
            ])
            for index in 0..<18 {
                let diameter = width * random.next(0.12...0.62)
                let point = CGPoint(x: width * random.next(-0.1...1.0), y: height * random.next(0.15...1.0))
                let bubbleHue = hue + [0, 0.33, 0.6][index % 3]
                context.setFillColor(color(hue: bubbleHue, saturation: 0.55, brightness: 1, alpha: random.next(0.18...0.5)))
                context.fillEllipse(in: CGRect(x: point.x - diameter / 2, y: point.y - diameter / 2, width: diameter, height: diameter))
            }

        case .spotlight:
            fillVertical(context, in: bounds, colors: [
                color(hue: 0.08, saturation: 0.35, brightness: 0.22),
                color(hue: 0.07, saturation: 0.45, brightness: 0.06),
            ])
            for source in [CGPoint(x: width * 0.1, y: height), CGPoint(x: width * 0.9, y: height)] {
                context.saveGState()
                context.move(to: source)
                context.addLine(to: CGPoint(x: width * (source.x < width / 2 ? 0.35 : 0.2), y: height * 0.12))
                context.addLine(to: CGPoint(x: width * (source.x < width / 2 ? 0.8 : 0.65), y: height * 0.12))
                context.closePath()
                context.clip()
                fillVertical(context, in: bounds, colors: [
                    color(hue: 0.11, saturation: 0.3, brightness: 1, alpha: 0.32),
                    color(hue: 0.1, saturation: 0.3, brightness: 1, alpha: 0.04),
                ])
                context.restoreGState()
            }
            glow(context, at: CGPoint(x: width * 0.5, y: height * 0.14), radius: width * 0.45, color: color(hue: 0.11, saturation: 0.35, brightness: 1, alpha: 0.4))
        }
    }

    /// A vertical gradient of `colors`, from `top` (default the top of `rect`) to `bottom`.
    private static func fillVertical(_ context: CGContext, in rect: CGRect, colors: [CGColor], locations: [CGFloat]? = nil, top: CGFloat? = nil, bottom: CGFloat? = nil) {
        guard let gradient = CGGradient(colorsSpace: colorSpace, colors: colors as CFArray, locations: locations) else {
            return
        }
        context.saveGState()
        context.clip(to: rect)
        context.drawLinearGradient(gradient, start: CGPoint(x: rect.midX, y: top ?? rect.maxY), end: CGPoint(x: rect.midX, y: bottom ?? rect.minY), options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
        context.restoreGState()
    }

    /// A gradient of `colors` from the top left to the bottom right of `rect`.
    private static func fillDiagonal(_ context: CGContext, in rect: CGRect, colors: [CGColor]) {
        guard let gradient = CGGradient(colorsSpace: colorSpace, colors: colors as CFArray, locations: nil) else {
            return
        }
        context.saveGState()
        context.clip(to: rect)
        context.drawLinearGradient(gradient, start: CGPoint(x: rect.minX, y: rect.maxY), end: CGPoint(x: rect.maxX, y: rect.minY), options: [])
        context.restoreGState()
    }

    /// A soft radial glow of `color`, fading out at `radius`.
    private static func glow(_ context: CGContext, at center: CGPoint, radius: CGFloat, color: CGColor) {
        guard let clear = color.copy(alpha: 0),
              let gradient = CGGradient(colorsSpace: colorSpace, colors: [color, clear] as CFArray, locations: [0, 1]) else {
            return
        }
        context.drawRadialGradient(gradient, startCenter: center, startRadius: 0, endCenter: center, endRadius: radius, options: [])
    }

    /// Small white dots of random sizes and brightness inside `rect`.
    private static func stars(_ context: CGContext, in rect: CGRect, count: Int, random: inout SeededRandom) {
        let unit = rect.width / 400
        for _ in 0..<count {
            let size = unit * random.next(0.8...2.6)
            context.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: random.next(0.25...0.9)))
            context.fillEllipse(in: CGRect(x: rect.minX + rect.width * random.next(), y: rect.minY + rect.height * random.next(), width: size, height: size))
        }
    }

    /// A line of hills (a sum of sines) around `base`, filled down to the bottom of `bounds` with a vertical gradient.
    private static func ridge(_ context: CGContext, in bounds: CGRect, base: CGFloat, amplitude: CGFloat, peaks: Double, random: inout SeededRandom, colors: [CGColor]) {
        let phases = (0..<3).map { _ in random.next(0...(2 * .pi)) }
        let frequencies = [peaks * 0.5, peaks * 1.1, peaks * 2.3]
        let weights = [1.0, 0.5, 0.2]
        let path = CGMutablePath()
        path.move(to: CGPoint(x: bounds.minX, y: bounds.minY))
        let steps = 80
        var highest = base
        for step in 0...steps {
            let t = Double(step) / Double(steps)
            var value = 0.0
            for index in 0..<3 {
                value += weights[index] * sin(t * frequencies[index] * 2 * .pi + phases[index])
            }
            let y = base + amplitude * (0.5 + 0.5 * value / 1.7)
            highest = max(highest, y)
            path.addLine(to: CGPoint(x: bounds.minX + bounds.width * t, y: y))
        }
        path.addLine(to: CGPoint(x: bounds.maxX, y: bounds.minY))
        path.closeSubpath()
        context.saveGState()
        context.addPath(path)
        context.clip()
        fillVertical(context, in: CGRect(x: bounds.minX, y: bounds.minY, width: bounds.width, height: highest - bounds.minY), colors: colors)
        context.restoreGState()
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
