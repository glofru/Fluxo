//
//  PartsLine.swift
//  Fluxo
//
//  Created by Gianluca Lofrumento on 2026-11-08.
//

import SwiftUI

/// A line of parts joined by the language's separator ("2021 · 2 seasons · 10 episodes · Drama", see
/// `TextParts.line(_:)`) that never breaks inside a part at the accessibility text sizes.
///
/// Below them it is one `Text` that wraps where it needs to, as before. At the accessibility sizes a part and its
/// no-break spaces ("2 Staffeln ·") can be wider than the line, and the text system then hyphenates the word to make
/// it fit ("2 Staf-" then "feln"). There each part is a `Text` of its own, with the separator at its end, and the
/// parts flow onto as many lines as they need: a part moves to the next line whole, and only a part wider than the
/// whole line wraps, on lines of its own, at its own spaces (a time range after its dash). Right to left, the parts
/// flow from the right (the layout is mirrored).
struct PartsLine: View {
    let parts: [String]
    var lineLimit: Int?
    var alignment: HorizontalAlignment = .leading

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    /// About the width of a space of the text, at every text size.
    @ScaledMetric(relativeTo: .subheadline) private var spacing: CGFloat = 4

    /// Nil and empty parts are left out.
    init(_ parts: [String?], lineLimit: Int? = nil, alignment: HorizontalAlignment = .leading) {
        self.parts = parts.compactMap { $0 }.filter { !$0.isEmpty }
        self.lineLimit = lineLimit
        self.alignment = alignment
    }

    var body: some View {
        if dynamicTypeSize.isAccessibilitySize && parts.count > 1 {
            FlowLayout(alignment: alignment, spacing: spacing) {
                ForEach(Array(TextParts.flowPieces(parts).enumerated()), id: \.offset) { _, piece in
                    Text(piece)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            // One element for VoiceOver, read as the line is.
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text(TextParts.spoken(parts)))
        } else {
            Text(TextParts.line(parts))
                .lineLimit(lineLimit)
        }
    }
}

/// Lays its subviews out from the leading edge, starting a new line when the next one does not fit. A subview wider
/// than the line is a line of its own: it starts at the leading edge, gets the whole width (and wraps inside), and the
/// next subview starts the line after it. Right to left, SwiftUI mirrors the placement, so the lines start at the
/// right.
struct FlowLayout: Layout {
    var alignment: HorizontalAlignment = .leading
    /// Between two subviews of a line.
    var spacing: CGFloat = 4
    /// Between two lines.
    var lineSpacing: CGFloat = 0

    struct Row {
        var indices: [Int] = []
        var sizes: [CGSize] = []
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = rows(width: proposal.width, subviews: subviews)
        let width = rows.map(\.width).max() ?? 0
        let height = rows.map(\.height).reduce(0, +) + lineSpacing * CGFloat(max(0, rows.count - 1))
        return CGSize(width: proposal.width.map { min($0, width) } ?? width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in rows(width: bounds.width, subviews: subviews) {
            var x: CGFloat
            switch alignment {
            case .center:
                x = bounds.minX + (bounds.width - row.width) / 2
            case .trailing:
                x = bounds.maxX - row.width
            default:
                x = bounds.minX
            }
            for (index, size) in zip(row.indices, row.sizes) {
                subviews[index].place(at: CGPoint(x: x, y: y), anchor: .topLeading, proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
            y += row.height + lineSpacing
        }
    }

    /// The subviews of each line, by index, for subviews of these ideal (one-line) widths: as many as fit next to each
    /// other within `maxWidth`, and a subview wider than `maxWidth` alone on its line, which ends there (the one
    /// before it ends its line too). A pure function of the widths, so that it can be tested.
    static func lines(widths: [CGFloat], maxWidth: CGFloat, spacing: CGFloat) -> [[Int]] {
        var lines: [[Int]] = []
        var line: [Int] = []
        var lineWidth: CGFloat = 0
        for (index, width) in widths.enumerated() {
            if width > maxWidth {
                if !line.isEmpty {
                    lines.append(line)
                }
                lines.append([index])
                line = []
                lineWidth = 0
                continue
            }
            if !line.isEmpty && lineWidth + spacing + width > maxWidth {
                lines.append(line)
                line = []
            }
            lineWidth = line.isEmpty ? width : lineWidth + spacing + width
            line.append(index)
        }
        if !line.isEmpty {
            lines.append(line)
        }
        return lines
    }

    private func rows(width: CGFloat?, subviews: Subviews) -> [Row] {
        let maxWidth = width ?? .infinity
        let idealSizes = subviews.map { $0.sizeThatFits(.unspecified) }
        return Self.lines(widths: idealSizes.map(\.width), maxWidth: maxWidth, spacing: spacing).map { indices in
            var row = Row()
            for index in indices {
                var size = idealSizes[index]
                if size.width > maxWidth {
                    // Alone on its line (see `lines`): it takes the whole width and wraps.
                    size = subviews[index].sizeThatFits(ProposedViewSize(width: maxWidth, height: nil))
                    size.width = min(size.width, maxWidth)
                }
                row.width = row.indices.isEmpty ? size.width : row.width + spacing + size.width
                row.height = max(row.height, size.height)
                row.indices.append(index)
                row.sizes.append(size)
            }
            return row
        }
    }
}
