// Renders the app's mark for the Apple TV pages that show it (Settings' header and the welcome screen): the icon
// itself, flat (`Fluxo-flat.svg`: the brand gradient, the three stream bands, the play glyph), square, which the
// pages round. It goes into the `TVAppMark` image set of the asset catalog, tv idiom only, so the iPhone, iPad and
// Mac catalogs do not carry it. Icon Composer has no tvOS rendition, so the TV pages cannot show `AppIcon.icon`.
//
// Usage (from the repository root):
//   xcrun swift Design/Icon/render_tvos_mark.swift
import AppKit

let root = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : FileManager.default.currentDirectoryPath)
let source = root.appendingPathComponent("Design/Icon/Fluxo-flat.svg")
let output = root.appendingPathComponent("Fluxo/Assets.xcassets/TVAppMark.imageset")
/// The largest size a page draws it at, in points.
let side: CGFloat = 320

guard let icon = NSImage(contentsOf: source) else {
    fatalError("cannot read Fluxo-flat.svg")
}

func render(scale: CGFloat) -> NSBitmapImageRep {
    let pixels = Int(side * scale)
    guard let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8, samplesPerPixel: 4,
        hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
    ) else {
        fatalError("no bitmap")
    }
    rep.size = CGSize(width: pixels, height: pixels)
    NSGraphicsContext.saveGraphicsState()
    defer { NSGraphicsContext.restoreGraphicsState() }
    let context = NSGraphicsContext(bitmapImageRep: rep)!
    NSGraphicsContext.current = context
    context.imageInterpolation = .high
    // The SVG's bands start outside its 1024-point canvas: drawn into the canvas, they are clipped at its edges.
    icon.draw(in: CGRect(x: 0, y: 0, width: pixels, height: pixels))
    return rep
}

try! FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
var images: [String] = []
for scale in [1, 2] {
    let file = "TVAppMark@\(scale)x.png"
    let data = render(scale: CGFloat(scale)).representation(using: .png, properties: [:])!
    try! data.write(to: output.appendingPathComponent(file))
    images.append(#"    { "filename" : "\#(file)", "idiom" : "tv", "scale" : "\#(scale)x" }"#)
    print("TVAppMark.imageset/\(file)")
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
