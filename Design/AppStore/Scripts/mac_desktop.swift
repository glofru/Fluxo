// Composes a Mac screen for the App Store screenshots: the Dusk wallpaper, a menu bar with Fluxo's menus and the
// app's windows (captured one by one with `screencapture -o -l`), at their positions relative to one another and
// centered on a 1440 x 900 pt display (2880 x 1800 px). capture-mac.sh runs it.
//
//   xcrun swift mac_desktop.swift list                     the Fluxo windows on screen: "<id> <x> <y> <w> <h>" (points)
//   xcrun swift mac_desktop.swift compose <out.png> <wallpaper.png> <language> <capture.png>:<x>,<y>,<w>,<h> …
//
// Captures are listed back to front (the main window first, then its sheets and other windows). A sheet's capture is
// its parent window with the sheet, at the parent's size: it is drawn over the parent.

import AppKit
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

let arguments = CommandLine.arguments
guard arguments.count >= 2 else {
    FileHandle.standardError.write(Data("usage: mac_desktop.swift list | compose …\n".utf8))
    exit(2)
}

if arguments[1] == "list" {
    let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
    // Front to back in the list: print back to front.
    for window in list.reversed() where (window[kCGWindowOwnerName as String] as? String) == "Fluxo" {
        guard (window[kCGWindowLayer as String] as? Int) == 0,
              let bounds = window[kCGWindowBounds as String] as? [String: Double],
              let id = window[kCGWindowNumber as String] as? Int,
              (bounds["Width"] ?? 0) > 80, (bounds["Height"] ?? 0) > 80 else {
            continue
        }
        print(id, Int(bounds["X"] ?? 0), Int(bounds["Y"] ?? 0), Int(bounds["Width"] ?? 0), Int(bounds["Height"] ?? 0))
    }
    exit(0)
}

guard arguments[1] == "compose", arguments.count >= 6 else {
    FileHandle.standardError.write(Data("usage: mac_desktop.swift compose <out.png> <wallpaper.png> <language> <capture>:<x>,<y>,<w>,<h> …\n".utf8))
    exit(2)
}
let output = URL(fileURLWithPath: arguments[2])
let wallpaperURL = URL(fileURLWithPath: arguments[3])
let language = arguments[4]
let scale: CGFloat = 2
let size = CGSize(width: 1440, height: 900)
let menuBarHeight: CGFloat = 33

struct Capture {
    let image: CGImage
    let frame: CGRect
}

func load(_ url: URL) -> CGImage? {
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else {
        return nil
    }
    return CGImageSourceCreateImageAtIndex(source, 0, nil)
}

var captures: [Capture] = []
for argument in arguments[5...] {
    let parts = argument.split(separator: ":", maxSplits: 1).map(String.init)
    let numbers = parts.count == 2 ? parts[1].split(separator: ",").compactMap { Double($0) } : []
    guard numbers.count == 4, let image = load(URL(fileURLWithPath: parts[0])) else {
        FileHandle.standardError.write(Data("bad capture \(argument)\n".utf8))
        exit(1)
    }
    var frame = CGRect(x: numbers[0], y: numbers[1], width: numbers[2], height: numbers[3])
    // A sheet's capture is its parent window with the sheet on it, at the parent's size: it goes over the parent.
    let pointSize = CGSize(width: CGFloat(image.width) / 2, height: CGFloat(image.height) / 2)
    if let parent = captures.first, abs(pointSize.width - frame.width) > 4 || abs(pointSize.height - frame.height) > 4 {
        frame = CGRect(origin: parent.frame.origin, size: pointSize)
    }
    captures.append(Capture(image: image, frame: frame))
}
guard let wallpaper = load(wallpaperURL), !captures.isEmpty else {
    exit(1)
}

// The windows keep their places relative to the first one; the group is centered under the menu bar.
let union = captures.dropFirst().reduce(captures[0].frame) { $0.union($1.frame) }
let area = CGRect(x: 0, y: menuBarHeight, width: size.width, height: size.height - menuBarHeight)
let offset = CGPoint(x: area.midX - union.midX, y: area.midY - union.midY)

let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
guard let context = CGContext(data: nil, width: Int(size.width * scale), height: Int(size.height * scale), bitsPerComponent: 8,
                              bytesPerRow: 0, space: colorSpace, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else {
    exit(1)
}
// Top-left origin, in points.
context.translateBy(x: 0, y: size.height * scale)
context.scaleBy(x: scale, y: -scale)

func draw(_ image: CGImage, in rect: CGRect) {
    context.saveGState()
    context.translateBy(x: rect.minX, y: rect.maxY)
    context.scaleBy(x: 1, y: -1)
    context.draw(image, in: CGRect(origin: .zero, size: rect.size))
    context.restoreGState()
}

// The wallpaper fills the screen (aspect fill).
let wallpaperSize = CGSize(width: wallpaper.width, height: wallpaper.height)
let fill = max(size.width / wallpaperSize.width, size.height / wallpaperSize.height)
let wallpaperRect = CGRect(x: (size.width - wallpaperSize.width * fill) / 2, y: (size.height - wallpaperSize.height * fill) / 2,
                           width: wallpaperSize.width * fill, height: wallpaperSize.height * fill)
draw(wallpaper, in: wallpaperRect)

// The windows, with the system's window shadow.
for capture in captures {
    let rect = capture.frame.offsetBy(dx: offset.x, dy: offset.y)
    context.saveGState()
    context.setShadow(offset: CGSize(width: 0, height: -18), blur: 60, color: CGColor(srgbRed: 0.02, green: 0.01, blue: 0.08, alpha: 0.55))
    draw(capture.image, in: rect)
    context.restoreGState()
}

// The menu bar: translucent over the wallpaper, the app's menus on the left and the clock on the right.
context.setFillColor(CGColor(srgbRed: 0.05, green: 0.03, blue: 0.14, alpha: 0.42))
context.fill(CGRect(x: 0, y: 0, width: size.width, height: menuBarHeight))
let menus = language == "it"
    ? ["Fluxo", "File", "Modifica", "Vista", "Vai", "Riproduzione", "Finestra", "Aiuto"]
    : ["Fluxo", "File", "Edit", "View", "Go", "Playback", "Window", "Help"]
func text(_ string: String, at point: CGPoint, bold: Bool) {
    let font = NSFont.systemFont(ofSize: 14, weight: bold ? .bold : .medium)
    let attributed = NSAttributedString(string: string, attributes: [.font: font, .foregroundColor: NSColor.white])
    let line = CTLineCreateWithAttributedString(attributed)
    context.saveGState()
    context.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
    context.textPosition = CGPoint(x: point.x, y: point.y)
    CTLineDraw(line, context)
    context.restoreGState()
}
func width(_ string: String, bold: Bool) -> CGFloat {
    let font = NSFont.systemFont(ofSize: 14, weight: bold ? .bold : .medium)
    let line = CTLineCreateWithAttributedString(NSAttributedString(string: string, attributes: [.font: font]))
    return CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
}
var x: CGFloat = 22
for (index, menu) in menus.enumerated() {
    text(menu, at: CGPoint(x: x, y: 21.5), bold: index == 0)
    x += width(menu, bold: index == 0) + 22
}
let clock = "9:41"
text(clock, at: CGPoint(x: size.width - 22 - width(clock, bold: false), y: 21.5), bold: false)

guard let image = context.makeImage(),
      let destination = CGImageDestinationCreateWithURL(output as CFURL, UTType.png.identifier as CFString, 1, nil) else {
    exit(1)
}
CGImageDestinationAddImage(destination, image, nil)
exit(CGImageDestinationFinalize(destination) ? 0 : 1)
