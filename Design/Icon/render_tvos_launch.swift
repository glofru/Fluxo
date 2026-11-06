// Renders the mark of the Apple TV launch screen: the three stream bands of the icon flowing in from nothing, into
// the play glyph, on a transparent canvas, in two looks: the white glyph of the icon for the dark appearance and an
// ink glyph for the light one. They go into the `TVLaunchMark` image set of the asset catalog (tv idiom only, so the
// iPhone, iPad and Mac catalogs do not carry it), next to `TVLaunchBackground`, the page background of the TV app
// (`Color.tvPageBackground`: 0.055 white dark, 0.93 light).
//
// The launch storyboard (FluxoTV/LaunchScreen.storyboard, UILaunchStoryboardName in Info-tvOS.plist) centers the
// mark on that background, so the launch dissolves into Home in either appearance. (A UILaunchScreen dictionary is
// drawn plain black on tvOS 27.2.)
//
// Usage (from the repository root):
//   xcrun swift Design/Icon/render_tvos_launch.swift
import AppKit

let root = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : FileManager.default.currentDirectoryPath)
let layers = root.appendingPathComponent("Design/Icon/Layers")
let output = root.appendingPathComponent("Fluxo/Assets.xcassets/TVLaunchMark.imageset")

/// The mark's canvas in points: wide enough for the bands to fade in on the left of the glyph, which is centered.
let canvas = CGSize(width: 640, height: 320)
/// The glyph is this share of the canvas height.
let glyphHeight: CGFloat = 0.62
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

/// The glyph's color on the light background: the ink of the brand (`FluxoInk`).
let ink = NSColor(srgbRed: 0.078, green: 0.059, blue: 0.235, alpha: 1)

func render(scale: CGFloat, glyph: NSColor?) -> NSBitmapImageRep {
    let size = CGSize(width: canvas.width * scale, height: canvas.height * scale)
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
    let unit = glyphHeight * size.height / 500
    let square = CGRect(x: size.width / 2 - 512 * unit, y: size.height / 2 - 512 * unit, width: 1024 * unit, height: 1024 * unit)

    // The bands, stretched so they start at the left edge and end under the glyph, fading in from transparent.
    let end = square.minX + bandsEnd * unit
    let bandsRect = CGRect(x: 0, y: square.minY, width: end / bandsEnd * 1024, height: square.height)
    cg.saveGState()
    cg.beginTransparencyLayer(auxiliaryInfo: nil)
    for band in bands {
        band.draw(in: bandsRect)
    }
    // Keep the bands where the mask is opaque: transparent at the left edge, full from 70 % of the way to the glyph.
    let fade = CGGradient(
        colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
        colors: [CGColor(gray: 0, alpha: 0), CGColor(gray: 0, alpha: 1)] as CFArray,
        locations: [0, 1]
    )!
    cg.setBlendMode(.destinationIn)
    cg.drawLinearGradient(fade, start: CGPoint(x: 0, y: 0), end: CGPoint(x: end * 0.7, y: 0), options: [.drawsAfterEndLocation])
    cg.endTransparencyLayer()
    cg.restoreGState()

    // The glyph, white as in the icon, or recolored.
    if let glyph {
        cg.saveGState()
        cg.beginTransparencyLayer(auxiliaryInfo: nil)
        play.draw(in: square)
        cg.setBlendMode(.sourceIn)
        cg.setFillColor(glyph.cgColor)
        cg.fill(square)
        cg.endTransparencyLayer()
        cg.restoreGState()
    } else {
        play.draw(in: square)
    }
    return rep
}

try! FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
var images: [String] = []
for (look, glyph) in [("light", Optional(ink)), ("dark", nil)] {
    for scale in [1, 2] {
        let file = "TVLaunchMark-\(look)@\(scale)x.png"
        let data = render(scale: CGFloat(scale), glyph: glyph).representation(using: .png, properties: [:])!
        try! data.write(to: output.appendingPathComponent(file))
        let appearance = look == "dark" ? #", "appearances" : [ { "appearance" : "luminosity", "value" : "dark" } ]"# : ""
        images.append(#"    { "filename" : "\#(file)", "idiom" : "tv", "scale" : "\#(scale)x"\#(appearance) }"#)
        print("TVLaunchMark.imageset/\(file)")
    }
}
let contents = """
{
  "images" : [
\(images.joined(separator: ",\n"))
  ],
  "info" : { "author" : "xcode", "version" : 1 }
}

"""
try! contents.write(to: output.appendingPathComponent("Contents.json"), atomically: true, encoding: .utf8)
