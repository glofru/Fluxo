//
//  ProgrammeSummaryView.swift
//  Fluxo
//
//  A short summary of a long programme description, written on the device by Apple Intelligence and streamed
//  in as it is written. Shows nothing for short descriptions, without Apple Intelligence, or when the model fails
//  (the full description is always shown below it).
//

import SwiftUI

struct ProgrammeSummaryView: View {

    let programme: GuideProgramme

    @Environment(FluxoIntelligence.self) private var intelligence: FluxoIntelligence?
    @State private var text = ""
    /// The programme whose summary failed: only that one hides the card (the view may show another one next).
    @State private var failedID: String?

    private let shape = RoundedRectangle(cornerRadius: 16, style: .continuous)

    var body: some View {
        if let intelligence, intelligence.isAvailable, ProgrammeSummarizer.needsSummary(programme), failedID != programme.id {
            VStack(alignment: .leading, spacing: 6) {
                Label("Summary", systemImage: "sparkles")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tint)
                if text.isEmpty {
                    // Placeholder lines while the model starts.
                    Text(String(repeating: "— ", count: 40))
                        .lineLimit(2)
                        .redacted(reason: .placeholder)
                        .accessibilityLabel("Writing a summary")
                } else {
                    Text(text)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                        .contentTransition(.opacity)
                }
            }
            .font(.callout)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .background(Theme.surface, in: shape)
            .overlay {
                shape.strokeBorder(Theme.surfaceStroke)
            }
            .accessibilityElement(children: .combine)
            .task(id: programme.id) {
                text = intelligence.summaries.cachedSummary(for: programme) ?? ""
                guard text.isEmpty else {
                    return
                }
                do {
                    for try await partial in intelligence.summaries.summarize(programme) {
                        text = partial
                    }
                } catch {
                    if !(error is CancellationError) {
                        failedID = programme.id
                    }
                }
            }
        }
    }
}

#Preview {
    let programme = GuideProgramme(
        sourceID: UUID(),
        channelID: "demo",
        start: .now,
        stop: .now.addingTimeInterval(5_400),
        title: "The Long Voyage",
        summary: String(repeating: "A crew sets out across the northern sea to find a lost expedition, facing storms, ice and their own doubts. ", count: 4)
    )
    ProgrammeSummaryView(programme: programme)
        .padding()
        .fluxoPreviewEnvironment()
}
