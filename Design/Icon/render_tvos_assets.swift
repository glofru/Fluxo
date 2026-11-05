// Renders the Apple TV app icon and Top Shelf images from the icon layers in Design/Icon/Layers.
//
// Icon Composer documents (Fluxo/AppIcon.icon) have no tvOS rendition: Apple TV icons are layered image stacks,
// which tvOS tilts with parallax under focus. This draws the same three layers the iPhone icon is made of, at
// the 5:3 shape of a TV icon, into the "App Icon & Top Shelf Image" brand assets of Fluxo/Assets.xcassets:
//
//   Back     the brand gradient (Fluxo Violet to Fluxo Ink, as in AppIcon.icon), opaque
//   Middle   the three stream bands, flowing in from the left edge
//   Front    the play glyph
//
// and the Top Shelf images (one flat picture of the same layers, wider). The bands of the layer SVGs start at
// the left edge of their 1024 x 1024 canvas and end under the glyph; on a wider canvas they are stretched
// sideways, so they still come in from the edge and gather under the glyph, which keeps its proportions.
//
// Usage (from the repository root):
//   xcrun swift Design/Icon/render_tvos_assets.swift
import AppKit

let root = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : FileManager.default.currentDirectoryPath)
let layers = root.appendingPathComponent("Design/Icon/Layers")
let brandAssets = root.appendingPathComponent("Fluxo/Assets.xcassets/App Icon & Top Shelf Image.brandassets")

// Brand palette (README, "Brand"): the gradient of AppIcon.icon's default appearance.
let violet = CGColor(srgbRed: 0.41569, green: 0.29804, blue: 1.0, alpha: 1)
let ink = CGColor(srgbRed: 0.07843, green: 0.05882, blue: 0.23529, alpha: 1)

/// Where the bands end in the layer SVGs (under the glyph's flat side), in their 1024-point canvas.
let bandsEnd: CGFloat = 420

func image(_ name: String) -> NSImage {
    guard let image = NSImage(contentsOf: layers.appendingPathComponent("\(name).svg")) else {
        fatalError("cannot read \(name).svg")
    }
    return image
}

let bands = ["stream-pink", "stream-lilac", "stream-cyan"].map(image) // back to front
let play = image("play")

enum Layer {
    case back, middle, front
}

/// Draws `layers` on a canvas of `size` pixels; the glyph is `glyphHeight` of the canvas height.
func render(_ drawn: [Layer], size: CGSize, glyphHeight: CGFloat) -> NSBitmapImageRep {
    guard let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: Int(size.width), pixelsHigh: Int(size.height), bitsPerSample: 8,
        samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
    ) else {
        fatalError("no bitmap")
    }
    rep.size = size
    NSGraphicsContext.saveGraphicsState()
    defer { NSGraphicsContext.restoreGraphicsState() }
    let context = NSGraphicsContext(bitmapImageRep: rep)!
    NSGraphicsContext.current = context
    let cg = context.cgContext
    cg.clear(CGRect(origin: .zero, size: size))

    // The 1024-point icon canvas, scaled so the glyph (500 points tall) is `glyphHeight` of the height, centered.
    let scale = glyphHeight * size.height / 500
    let square = CGRect(x: size.width / 2 - 512 * scale, y: size.height / 2 - 512 * scale, width: 1024 * scale, height: 1024 * scale)

    if drawn.contains(.back) {
        // Top left to bottom right as in AppIcon.icon (start 0.3, 0; stop 0.7, 1; y down there, up here).
        let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: [violet, ink] as CFArray, locations: [0, 1])!
        cg.drawLinearGradient(gradient, start: CGPoint(x: size.width * 0.3, y: size.height), end: CGPoint(x: size.width * 0.7, y: 0), options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
    }
    if drawn.contains(.middle) {
        // Stretched sideways so that the left edge of the layer is the canvas's and its band ends stay under the glyph.
        let end = square.minX + bandsEnd * scale
        let rect = CGRect(x: 0, y: square.minY, width: end / bandsEnd * 1024, height: square.height)
        for band in bands {
            band.draw(in: rect)
        }
    }
    if drawn.contains(.front) {
        play.draw(in: square)
    }
    return rep
}

/// PNG for the layers with transparency; JPEG for the opaque ones (the gradient makes a PNG of several MB, and the
/// asset catalog compresses every image again anyway).
func write(_ rep: NSBitmapImageRep, to url: URL) {
    try! FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    let data = url.pathExtension == "jpg"
        ? rep.representation(using: .jpeg, properties: [.compressionFactor: 0.92])!
        : rep.representation(using: .png, properties: [:])!
    try! data.write(to: url)
    print(url.path.replacingOccurrences(of: root.path + "/", with: ""))
}

func writeJSON(_ object: Any, to directory: URL) {
    try! FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let data = try! JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
    try! data.write(to: directory.appendingPathComponent("Contents.json"))
}

let info = ["author": "xcode", "version": 1] as [String: Any]

/// An image stack (the app icon): Front, Middle, Back, each at `scales` of `size` points.
func imageStack(_ name: String, size: CGSize, scales: [Int]) {
    let stack = brandAssets.appendingPathComponent("\(name).imagestack")
    let names: [(Layer, String)] = [(.front, "Front"), (.middle, "Middle"), (.back, "Back")]
    for (layer, layerName) in names {
        let imageset = stack.appendingPathComponent("\(layerName).imagestacklayer/Content.imageset")
        var images: [[String: Any]] = []
        for scale in scales {
            let file = "\(layerName.lowercased())@\(scale)x.\(layer == .back ? "jpg" : "png")"
            write(render([layer], size: CGSize(width: size.width * CGFloat(scale), height: size.height * CGFloat(scale)), glyphHeight: 0.55), to: imageset.appendingPathComponent(file))
            images.append(["filename": file, "idiom": "tv", "scale": "\(scale)x"])
        }
        writeJSON(["images": images, "info": info], to: imageset)
        writeJSON(["info": info], to: imageset.deletingLastPathComponent())
    }
    writeJSON(["info": info, "layers": names.map { ["filename": "\($0.1).imagestacklayer"] }], to: stack)
}

/// A flat Top Shelf image at `scales` of `size` points.
func topShelf(_ name: String, size: CGSize, scales: [Int]) {
    let imageset = brandAssets.appendingPathComponent("\(name).imageset")
    var images: [[String: Any]] = []
    for scale in scales {
        let file = "\(name.lowercased().replacingOccurrences(of: " ", with: "-"))@\(scale)x.jpg"
        write(render([.back, .middle, .front], size: CGSize(width: size.width * CGFloat(scale), height: size.height * CGFloat(scale)), glyphHeight: 0.45), to: imageset.appendingPathComponent(file))
        images.append(["filename": file, "idiom": "tv", "scale": "\(scale)x"])
    }
    writeJSON(["images": images, "info": info], to: imageset)
}

try? FileManager.default.removeItem(at: brandAssets)
imageStack("App Icon - App Store", size: CGSize(width: 1280, height: 768), scales: [1])
imageStack("App Icon", size: CGSize(width: 400, height: 240), scales: [1, 2])
topShelf("Top Shelf Image", size: CGSize(width: 1920, height: 720), scales: [1, 2])
topShelf("Top Shelf Image Wide", size: CGSize(width: 2320, height: 720), scales: [1, 2])
writeJSON([
    "assets": [
        ["filename": "App Icon - App Store.imagestack", "idiom": "tv", "role": "primary-app-icon", "size": "1280x768"],
        ["filename": "App Icon.imagestack", "idiom": "tv", "role": "primary-app-icon", "size": "400x240"],
        ["filename": "Top Shelf Image Wide.imageset", "idiom": "tv", "role": "top-shelf-image-wide", "size": "2320x720"],
        ["filename": "Top Shelf Image.imageset", "idiom": "tv", "role": "top-shelf-image", "size": "1920x720"],
    ],
    "info": info,
], to: brandAssets)
