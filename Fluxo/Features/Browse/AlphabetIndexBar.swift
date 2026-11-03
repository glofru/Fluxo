//
//  AlphabetIndexBar.swift
//  Fluxo
//

import SwiftUI

/// The quick scroller of long A–Z lists: the index letters along the trailing edge. Touch a letter, or slide
/// along the bar, to jump to it; the letter under the finger shows in a bubble next to the bar.
struct AlphabetIndexBar: View {

    let letters: [String]
    let onSelect: (String) -> Void

    @State private var activeLetter: String?
    @GestureState private var isDragging = false

    var body: some View {
        VStack(spacing: 0) {
            ForEach(letters, id: \.self) { letter in
                Text(letter)
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(letter == activeLetter ? AnyShapeStyle(Color.white) : AnyShapeStyle(.tint))
                    .frame(width: 18, height: 15)
                    .background {
                        if letter == activeLetter {
                            Circle()
                                .fill(Theme.accent)
                                .frame(width: 17, height: 17)
                        }
                    }
            }
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 2)
        .background(.ultraThinMaterial, in: .capsule)
        .contentShape(.rect)
        .gesture(
            DragGesture(minimumDistance: 0)
                .updating($isDragging) { _, state, _ in
                    state = true
                }
                .onChanged { value in
                    select(atY: value.location.y)
                }
        )
        .overlay(alignment: .leading) {
            if isDragging, let activeLetter {
                Text(activeLetter)
                    .font(.largeTitle.bold())
                    .foregroundStyle(.white)
                    .frame(width: 64, height: 64)
                    .background(Theme.accent.gradient, in: .rect(cornerRadius: 16, style: .continuous))
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
            let current = activeLetter.flatMap { letters.firstIndex(of: $0) } ?? -1
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

    private func select(atY y: CGFloat) {
        guard !letters.isEmpty else {
            return
        }
        // 6 points of padding above the first letter, 15 per letter.
        let index = min(letters.count - 1, max(0, Int((y - 6) / 15)))
        let letter = letters[index]
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
