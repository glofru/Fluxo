//
//  TopShelfArtwork.swift
//  Fluxo
//
//  The images of the Top Shelf items, drawn by the app (`TopShelfPublisher`) and only shown by the extension: the
//  same artwork as the app's landscape cards (`TVLandscapeArtworkView`), in their dark look, which suits the Top
//  Shelf in both appearances: a channel's logo on the tile background, a poster in front of a blurred copy of
//  itself, or the name's initials on its color when there is no artwork. On Now items carry the LIVE badge of the
//  On Now cards. The system draws the focus, the title and the progress bar over them.
//

#if os(tvOS)
import ImageIO
import SwiftUI
import TVServices
import UniformTypeIdentifiers

/// What an image shows; equal arts make the same image (its file is reused).
struct TopShelfArt: Hashable, Sendable {
    let logo: String?
    let name: String
    let kind: ChannelContentKind
    let isLive: Bool

    /// File name stem: a digest of what the image shows, so a changed logo or name makes a new file, as does a
    /// change of language (the LIVE badge, the initials).
    var fileStem: String {
        var hasher = StableHasher()
        // v5: drawn in the direction of the language (the LIVE badge in the top right corner in Arabic).
        hasher.combine("v5")
        hasher.combine(logo ?? "")
        hasher.combine(name)
        hasher.combine(String(kind.rawValue))
        hasher.combine(isLive ? "live" : "")
        hasher.combine(Bundle.main.preferredLocalizations.first ?? "")
        hasher.combine(Locale.current.identifier)
        return hasher.hex
    }

    /// The same art without its logo or poster: the initials tile it is drawn as while the artwork cannot be
    /// loaded, cached under its own name so the artwork is tried again the next time.
    var placeholder: TopShelfArt {
        TopShelfArt(logo: nil, name: name, kind: kind, isLive: isLive)
    }
}

/// FNV-1a over UTF-8, 64 bits twice (two offsets): stable across launches, unlike `Hasher`.
private struct StableHasher {
    private var first: UInt64 = 0xcbf2_9ce4_8422_2325
    private var second: UInt64 = 0x8422_2325_cbf2_9ce4

    mutating func combine(_ text: String) {
        for byte in text.utf8 + [0] {
            first = (first ^ UInt64(byte)) &* 0x0000_0100_0000_01b3
            second = (second ^ UInt64(byte)) &* 0x0000_0100_0000_01b3
        }
    }

    var hex: String {
        String(format: "%016llx%016llx", first, second)
    }
}

@MainActor
enum TopShelfArtworkRenderer {

    /// The size of a 16:9 Top Shelf image, in points.
    static var imageSize: CGSize {
        let size = TVTopShelfSectionedContent.imageSize(for: .hdtv)
        return size.width > 0 && size.height > 0 ? size : CGSize(width: 404, height: 228)
    }

    /// Writes the art as `<stem>.jpg` (1x) and `<stem>@2x.jpg` into `directory`, unless they are there already.
    /// Returns the two file names, or nil when the image could not be made (or the task was cancelled).
    ///
    /// Only what was drawn from the art is kept under its name. When its logo or poster cannot be loaded (the
    /// host is down, it failed before, the publish was cancelled while it loaded), the initials tile is written
    /// under the name of `art.placeholder` instead, and the artwork is loaded again by the next publish.
    static func write(_ art: TopShelfArt, to directory: URL) async -> (String, String)? {
        if let names = existing(art, in: directory) {
            return names
        }
        let size = imageSize
        let image = await loadImage(for: art, size: size)
        guard !Task.isCancelled else {
            return nil
        }
        let drawn = image == nil ? art.placeholder : art
        if drawn != art, let names = existing(drawn, in: directory) {
            return names
        }
        let names = fileNames(drawn)
        let isDarkLogo = !art.kind.usesPosterArtwork && image.map(LogoTone.isDarkOnTransparent) == true
        for (name, scale) in [(names.0, CGFloat(1)), (names.1, CGFloat(2))] {
            let renderer = ImageRenderer(content: TopShelfArtworkView(art: drawn, image: image, size: size, isDarkLogo: isDarkLogo))
            renderer.scale = scale
            renderer.isOpaque = true
            guard let cgImage = renderer.cgImage, let data = jpeg(cgImage) else {
                return nil
            }
            do {
                try data.write(to: directory.appending(path: name), options: .atomic)
            } catch {
                return nil
            }
            // Drawing is main-actor work: let the focus engine and the pages run between images.
            await Task.yield()
        }
        return names
    }

    private static func fileNames(_ art: TopShelfArt) -> (String, String) {
        ("\(art.fileStem).jpg", "\(art.fileStem)@2x.jpg")
    }

    /// The file names of the art when both images are in `directory`.
    private static func existing(_ art: TopShelfArt, in directory: URL) -> (String, String)? {
        let names = fileNames(art)
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: directory.appending(path: names.0).path(percentEncoded: false)),
              fileManager.fileExists(atPath: directory.appending(path: names.1).path(percentEncoded: false)) else {
            return nil
        }
        return names
    }

    /// The logo or poster at the size it is drawn at (2x), from the app's image cache; nil without artwork.
    private static func loadImage(for art: TopShelfArt, size: CGSize) async -> CGImage? {
        let pointSize: CGSize
        let mode: LogoContentMode
        if art.kind.usesPosterArtwork {
            pointSize = TopShelfArtworkView.posterSize(in: size)
            mode = .fill
        } else {
            pointSize = TopShelfArtworkView.logoBox(in: size)
            mode = .fit
        }
        guard let request = LogoRequest(source: art.logo, pointSize: pointSize, scale: 2, contentMode: mode) else {
            return nil
        }
        return await LogoImageLoader.shared.image(for: request)
    }

    private static func jpeg(_ image: CGImage) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else {
            return nil
        }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.86] as CFDictionary)
        return CGImageDestinationFinalize(destination) ? data as Data : nil
    }
}

/// One Top Shelf image. Everything is drawn synchronously (the artwork is loaded beforehand), as `ImageRenderer`
/// needs.
struct TopShelfArtworkView: View {
    let art: TopShelfArt
    let image: CGImage?
    let size: CGSize
    /// A dark logo on a transparent background: drawn on a light tile.
    var isDarkLogo = false

    /// The language the app runs in, which the images are drawn in. `ImageRenderer` lays out left to right unless
    /// told otherwise: the badge goes to the leading corner of the language, as on the app's On Now cards.
    private static let language = Locale.Language(identifier: Bundle.main.preferredLocalizations.first ?? "en")

    private static var layoutDirection: LayoutDirection {
        language.characterDirection == .rightToLeft ? .rightToLeft : .leftToRight
    }

    /// Letter spacing only for scripts of separate letters: it pulls apart the joined letters of Arabic and the
    /// headline of Devanagari, and adds nothing to Chinese, Japanese or Korean.
    private static var badgeTracking: CGFloat {
        language.script.map { [.latin, .cyrillic].contains($0) } == true ? 0.6 : 0
    }

    /// Where a logo fits: the share of the card the app's landscape cards give it.
    static func logoBox(in size: CGSize) -> CGSize {
        CGSize(width: size.width * 0.62, height: size.height * 0.56)
    }

    var body: some View {
        ZStack {
            if let image {
                if art.kind.usesPosterArtwork {
                    poster(image)
                } else {
                    logo(image)
                }
            } else {
                TopShelfPlaceholder(name: art.name, kind: art.kind, size: size)
            }
        }
        .frame(width: size.width, height: size.height)
        .overlay(alignment: .topLeading) {
            if art.isLive {
                Text("LIVE")
                    .font(.system(size: size.height * 0.075, weight: .heavy))
                    .tracking(Self.badgeTracking)
                    .lineLimit(1)
                    .fixedSize()
                    .foregroundStyle(.white)
                    .padding(.horizontal, size.height * 0.045)
                    .padding(.vertical, size.height * 0.018)
                    .background(Theme.liveFill, in: .capsule)
                    .padding(size.height * 0.07)
            }
        }
        .clipped()
        .environment(\.colorScheme, .dark)
        .environment(\.layoutDirection, Self.layoutDirection)
    }

    private func logo(_ image: CGImage) -> some View {
        ZStack {
            // Graphite (or a light tile for dark lettering), lit from the top left like the app's cards.
            LinearGradient(
                colors: isDarkLogo ? [Color(white: 0.95), Color(white: 0.8)] : [Color(white: 0.27), Color(white: 0.13)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            Image(decorative: image, scale: 2)
                .resizable()
                .scaledToFit()
                .frame(width: Self.logoBox(in: size).width, height: Self.logoBox(in: size).height)
                .shadow(color: .black.opacity(0.25), radius: 6, y: 2)
        }
    }

    /// The poster stands in front of a blurred copy of itself, clear of the bottom edge, where the system draws
    /// the progress bar of what was started.
    private func poster(_ image: CGImage) -> some View {
        let posterSize = Self.posterSize(in: size)
        return ZStack {
            Image(decorative: image, scale: 2)
                .resizable()
                .scaledToFill()
                .frame(width: size.width, height: size.height)
                .blur(radius: 30, opaque: true)
                .overlay(.black.opacity(0.32))
            Image(decorative: image, scale: 2)
                .resizable()
                .scaledToFill()
                .frame(width: posterSize.width, height: posterSize.height)
                .clipShape(.rect(cornerRadius: size.height * 0.025, style: .continuous))
                .shadow(color: .black.opacity(0.55), radius: size.height * 0.035, y: size.height * 0.01)
                .frame(maxHeight: .infinity, alignment: .top)
                .padding(.top, size.height * 0.06)
        }
    }

    /// 2:3, 80 % of the height.
    static func posterSize(in size: CGSize) -> CGSize {
        CGSize(width: size.height * 0.8 * 2 / 3, height: size.height * 0.8)
    }
}

/// The initials of a name on its color (the same hue as the app's `ArtworkPlaceholder`), at Top Shelf size.
private struct TopShelfPlaceholder: View {
    let name: String
    let kind: ChannelContentKind
    let size: CGSize

    var body: some View {
        let hue = ArtworkPlaceholder.hue(for: name)
        ZStack {
            LinearGradient(
                colors: [
                    Color(hue: hue, saturation: 0.55, brightness: 0.62),
                    Color(hue: (hue + 0.08).truncatingRemainder(dividingBy: 1), saturation: 0.65, brightness: 0.38),
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            VStack(spacing: size.height * 0.04) {
                Text(initials)
                    .font(.system(size: size.height * 0.3, weight: .heavy, design: .rounded))
                    .lineLimit(1)
                    .minimumScaleFactor(0.5)
                Image(systemName: kind.systemImage)
                    .font(.system(size: size.height * 0.1, weight: .semibold))
                    .opacity(0.75)
            }
            .foregroundStyle(.white)
            .padding(size.height * 0.08)
        }
    }

    private var initials: String {
        let words = name.split(whereSeparator: { $0 == " " || $0 == "-" || $0 == "|" || $0 == "_" }).prefix(2)
        let letters = words.compactMap { $0.first(where: { $0.isLetter || $0.isNumber }) }
        let result = letters.map(String.init).joined().uppercased(with: .current)
        return result.isEmpty ? "TV" : result
    }
}
#endif
