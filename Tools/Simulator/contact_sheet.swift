// Combines screenshots into one labelled PNG grid, so a whole run can be reviewed in one image.
//
//   xcrun swift Tools/Simulator/contact_sheet.swift <output.png> [--height 700] [--columns 4] <image.png>...
//
// Each image is scaled to the tile height (aspect ratio kept) and labelled with its file name.

import CoreGraphics
import CoreText
import Foundation
import ImageIO
import UniformTypeIdentifiers

var arguments = Array(CommandLine.arguments.dropFirst())
guard !arguments.isEmpty else {
    FileHandle.standardError.write(Data("usage: contact_sheet.swift <output.png> [--height N] [--columns N] <image>...\n".utf8))
    exit(2)
}
let output = URL(fileURLWithPath: arguments.removeFirst())
var tileHeight = 700.0
var columns = 4
var inputs: [URL] = []
while !arguments.isEmpty {
    let argument = arguments.removeFirst()
    if argument == "--height", let value = arguments.first.flatMap(Double.init) {
        tileHeight = value
        arguments.removeFirst()
    } else if argument == "--columns", let value = arguments.first.flatMap(Int.init) {
        columns = max(1, value)
        arguments.removeFirst()
    } else {
        inputs.append(URL(fileURLWithPath: argument))
    }
}

let images: [(name: String, image: CGImage)] = inputs.compactMap { url in
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil), let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
        FileHandle.standardError.write(Data("skipping \(url.path)\n".utf8))
        return nil
    }
    return (url.deletingPathExtension().lastPathComponent, image)
}
guard !images.isEmpty else {
    exit(1)
}

let gap = 16.0
let labelHeight = 30.0
let widths = images.map { tileHeight * Double($0.image.width) / Double($0.image.height) }
let rows = stride(from: 0, to: images.count, by: columns).map { Array($0..<min($0 + columns, images.count)) }
let canvasWidth = rows.map { row in row.reduce(gap) { $0 + widths[$1] + gap } }.max() ?? 0
let canvasHeight = Double(rows.count) * (tileHeight + labelHeight + gap) + gap

let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
guard let context = CGContext(data: nil, width: Int(canvasWidth), height: Int(canvasHeight), bitsPerComponent: 8, bytesPerRow: 0, space: colorSpace, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else {
    exit(1)
}
context.setFillColor(CGColor(gray: 0.5, alpha: 1))
context.fill(CGRect(x: 0, y: 0, width: canvasWidth, height: canvasHeight))
context.interpolationQuality = .high

let font = CTFontCreateUIFontForLanguage(.system, 20, nil)!
for (rowIndex, row) in rows.enumerated() {
    // CoreGraphics' origin is bottom left: row 0 at the top.
    let top = canvasHeight - gap - Double(rowIndex) * (tileHeight + labelHeight + gap)
    var x = gap
    for index in row {
        let rect = CGRect(x: x, y: top - tileHeight, width: widths[index], height: tileHeight)
        context.draw(images[index].image, in: rect)
        let label = NSAttributedString(string: images[index].name, attributes: [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 1, alpha: 1),
        ])
        context.textPosition = CGPoint(x: x, y: top - tileHeight - labelHeight + 8)
        CTLineDraw(CTLineCreateWithAttributedString(label), context)
        x += widths[index] + gap
    }
}

guard let image = context.makeImage(),
      let destination = CGImageDestinationCreateWithURL(output as CFURL, UTType.png.identifier as CFString, 1, nil) else {
    exit(1)
}
CGImageDestinationAddImage(destination, image, nil)
guard CGImageDestinationFinalize(destination) else {
    exit(1)
}
print(output.path)
