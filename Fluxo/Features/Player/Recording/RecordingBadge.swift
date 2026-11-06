//
//  RecordingBadge.swift
//  Fluxo
//
//  "● REC 12:34": the channel is being recorded, and for how long. Drawn like the LIVE badge it sits next to (the
//  programme sheets of iPhone, iPad, Mac and Apple TV), in white on the deep recording red.
//

import SwiftUI

struct RecordingBadge: View {
    /// How long the recording is.
    let duration: TimeInterval

    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: "circle.fill")
                .imageScale(.small)
                .ambientSymbolEffect(.pulse)
            Text("REC \(PlayerTime.format(duration))")
                .monospacedDigit()
        }
        .font(Theme.Typography.badge)
        .lineLimit(1)
        .fixedSize()
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(Theme.recordingFill, in: .capsule)
        .overlay {
            if contrast == .increased {
                Capsule().strokeBorder(.white.opacity(0.8), lineWidth: 1)
            }
        }
        .foregroundStyle(.white)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("Recording"))
        .accessibilityValue(PlayerTime.spoken(duration))
        .accessibilityAddTraits(.isStaticText)
    }
}

#Preview {
    HStack {
        LiveBadge()
        RecordingBadge(duration: 754)
    }
    .padding()
}
