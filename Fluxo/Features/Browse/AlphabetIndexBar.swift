//
//  AlphabetIndexBar.swift
//  Fluxo
//

import SwiftUI

/// The quick scroller of long A–Z lists: the index letters along the trailing edge. Touch a letter, or slide
/// along the bar, to jump to it; the letter under the finger shows in a bubble next to the bar.
///
/// The bar fills the height it is given at most. When there are more letters than fit (a short window,
/// large text, or a list with many index letters), it shows some of them with dots in between, as the
/// system's indexed lists do; sliding over a dot still reaches each letter it stands for.
struct AlphabetIndexBar: View {

    let letters: [String]
    let onSelect: (String) -> Void

    @State private var activeLetter: String?
    @GestureState private var isDragging = false

    /// A row of the bar: one letter, or a dot that stands for the letters of `range`.
    struct Row: Hashable {
        let label: String
        let range: Range<Int>
    }

    private static let rowHeight: CGFloat = 15
    private static let verticalPadding: CGFloat = 6
    /// The space kept free above and below the bar.
    private static let margin: CGFloat = 8

    var body: some View {
        GeometryReader { geometry in
            bar(rows: Self.rows(for: letters, fitting: geometry.size.height))
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .trailing)
        }
        .frame(width: 22)
    }

    private func bar(rows: [Row]) -> some View {
        let activeIndex = activeLetter.flatMap { letters.firstIndex(of: $0) }
        return VStack(spacing: 0) {
            ForEach(rows, id: \.self) { row in
                let isActive = activeIndex.map(row.range.contains) ?? false
                Text(row.label)
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(isActive ? AnyShapeStyle(Color.white) : AnyShapeStyle(.tint))
                    .frame(width: 18, height: Self.rowHeight)
                    .background {
                        if isActive {
                            Circle()
                                .fill(Theme.accentFill)
                                .frame(width: 17, height: 17)
                        }
                    }
            }
        }
        .padding(.vertical, Self.verticalPadding)
        .padding(.horizontal, 2)
        .background(.ultraThinMaterial, in: .capsule)
        .contentShape(.rect)
        #if !os(tvOS)
        // A finger or the pointer slides along the bar (there is no touch on Apple TV).
        .gesture(
            DragGesture(minimumDistance: 0)
                .updating($isDragging) { _, state, _ in
                    state = true
                }
                .onChanged { value in
                    select(atY: value.location.y, rows: rows)
                }
        )
        #endif
        .overlay(alignment: .leading) {
            if isDragging, let activeLetter {
                Text(activeLetter)
                    .font(.largeTitle.bold())
                    .foregroundStyle(.white)
                    .frame(width: 64, height: 64)
                    .background(Theme.accentFill.gradient, in: .rect(cornerRadius: 16, style: .continuous))
                    .shadow(color: .black.opacity(0.25), radius: 10, y: 4)
                    .offset(x: -80)
                    .transition(.scale.combined(with: .opacity))
                    .accessibilityHidden(true)
            }
        }
        .animation(.snappy(duration: 0.2), value: isDragging)
        .onChange(of: isDragging) { _, dragging in
            if !dragging {
                activeLetter = nil
            }
        }
        .sensoryFeedback(.selection, trigger: activeLetter) { _, new in
            new != nil
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Section Index")
        .accessibilityValue(activeLetter ?? letters.first ?? "")
        .accessibilityAdjustableAction { direction in
            let current = activeIndex ?? -1
            let next: Int
            switch direction {
            case .increment:
                next = min(letters.count - 1, current + 1)
            case .decrement:
                next = max(0, current - 1)
            @unknown default:
                return
            }
            guard letters.indices.contains(next) else {
                return
            }
            activeLetter = letters[next]
            onSelect(letters[next])
        }
    }

    /// Every letter on its own row when they fit in `height`; otherwise an odd number of rows that alternate
    /// a letter and a dot, from the first letter to the last.
    static func rows(for letters: [String], fitting height: CGFloat) -> [Row] {
        let capacity = Int((height - 2 * (verticalPadding + margin)) / rowHeight)
        guard letters.count > capacity, capacity >= 3 else {
            return letters.indices.map { Row(label: letters[$0], range: $0..<($0 + 1)) }
        }
        let count = capacity.isMultiple(of: 2) ? capacity - 1 : capacity
        return (0..<count).map { row in
            let lower = row * letters.count / count
            let upper = max(lower + 1, (row + 1) * letters.count / count)
            let label = row == count - 1 ? letters[letters.count - 1] : row.isMultiple(of: 2) ? letters[lower] : "•"
            return Row(label: label, range: lower..<upper)
        }
    }

    private func select(atY y: CGFloat, rows: [Row]) {
        guard !rows.isEmpty else {
            return
        }
        let position = max(0, (y - Self.verticalPadding) / Self.rowHeight)
        let row = rows[min(rows.count - 1, Int(position))]
        // Within a dot, the finger's place picks one of the letters it stands for.
        let fraction = min(max(position - position.rounded(.down), 0), 0.999)
        let index = row.range.lowerBound + Int(fraction * CGFloat(row.range.count))
        let letter = letters[min(index, row.range.upperBound - 1)]
        if letter != activeLetter {
            activeLetter = letter
            onSelect(letter)
        }
    }
}

#Preview {
    HStack {
        Spacer()
        AlphabetIndexBar(letters: ["#", "A", "B", "C", "D", "E", "F", "G", "M", "R", "S", "Z"]) { _ in }
    }
    .padding()
}

#Preview("Many letters") {
    // More index letters than fit: the bar shows dots between some of them.
    HStack {
        Spacer()
        AlphabetIndexBar(letters: ["#"] + (0..<26).map { String(UnicodeScalar(65 + $0)!) } + ["ㄱ", "ㄴ", "ㄷ", "ㄹ", "ㅁ", "ㅂ", "ㅅ", "ㅇ", "ㅈ", "ㅊ", "ㅋ", "ㅌ", "ㅍ", "ㅎ"]) { _ in }
    }
    .frame(height: 360)
    .padding()
}
