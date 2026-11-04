//
//  GuideChannelPicker.swift
//  Fluxo
//
//  Created by Gianluca Lofrumento on 2026-11-02.
//

import SwiftUI

/// Chooses the guide channel of a playlist channel by hand: automatic matching, no guide, or any channel of
/// the guide sources (searchable).
struct GuideChannelPicker: View {

    let item: ChannelItem

    @Environment(EPGStore.self) private var epg
    @Environment(\.dismiss) private var dismiss
    @State private var searchText = ""
    @State private var choices: [GuideChannelChoice] = []
    @State private var automatic: GuideChannelChoice?
    @State private var current: GuideChannelRef?
    @State private var isManual = false
    @State private var isLoaded = false

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Button {
                        epg.setMatch(nil, automatic: true, for: item)
                        dismiss()
                    } label: {
                        row(
                            title: Text("Automatic"),
                            subtitle: automatic.map { Text("Matches \($0.displayName) · \($0.sourceName)") } ?? Text("No matching guide channel found"),
                            icon: nil,
                            isSelected: !isManual
                        )
                    }
                    Button {
                        epg.setMatch(nil, for: item)
                        dismiss()
                    } label: {
                        row(title: Text("No Guide"), subtitle: Text("Don't show programmes for this channel"), icon: nil, isSelected: isManual && current == nil)
                    }
                } footer: {
                    Text("Fluxo matches channels by tvg-id, then by name. Pick a guide channel if the match is wrong or missing.")
                }

                Section(searchText.isEmpty ? "Guide Channels" : "Results") {
                    if isLoaded && choices.isEmpty {
                        Text(searchText.isEmpty ? "The guide sources have no channels yet." : "No guide channel matches \"\(searchText)\".")
                            .foregroundStyle(Theme.secondaryText)
                    }
                    ForEach(choices) { choice in
                        Button {
                            epg.setMatch(choice, for: item)
                            dismiss()
                        } label: {
                            row(
                                title: Text(verbatim: choice.displayName),
                                subtitle: choice.hasProgrammes ? Text(verbatim: choice.sourceName) : Text("\(choice.sourceName) · loads with the next refresh"),
                                icon: choice.icon,
                                isSelected: isManual && current?.sourceID == choice.ref.sourceID && current?.channelID == choice.ref.channelID
                            )
                        }
                    }
                }
            }
            .navigationTitle(item.displayName)
            .inlineNavigationBar()
            .searchable(text: $searchText, prompt: "Guide channels")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(role: .cancel) {
                        dismiss()
                    }
                }
            }
            .task {
                isManual = epg.hasManualMatch(for: item)
                current = await epg.guideRef(for: item)
                if let ref = await epg.automaticRef(for: item) {
                    automatic = await epg.choice(for: ref)
                }
                if searchText.isEmpty {
                    searchText = ChannelNameNormalizer.tokens(item.displayName).filter { $0 != "+" }.prefix(2).joined(separator: " ")
                }
            }
            .task(id: searchText) {
                try? await Task.sleep(for: .milliseconds(200))
                guard !Task.isCancelled else {
                    return
                }
                choices = await epg.channelChoices(term: searchText.trimmingCharacters(in: .whitespacesAndNewlines))
                isLoaded = true
            }
        }
        .mediumAndLargeDetentsAdaptingToTextSize()
        #if os(macOS)
        .frame(minWidth: 420, minHeight: 460)
        #endif
    }

    private func row(title: Text, subtitle: Text, icon: String?, isSelected: Bool) -> some View {
        HStack(spacing: 12) {
            if let icon {
                LogoImage(source: icon, size: CGSize(width: 40, height: 26)) { _ in
                    Image(systemName: "tv")
                        .foregroundStyle(Theme.secondaryText)
                }
                .accessibilityHidden(true)
            }
            VStack(alignment: .leading, spacing: 2) {
                title
                    .foregroundStyle(.primary)
                subtitle
                    .font(.caption)
                    .foregroundStyle(Theme.secondaryText)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            if isSelected {
                Image(systemName: "checkmark")
                    .foregroundStyle(.tint)
                    .fontWeight(.semibold)
            }
        }
        .contentShape(.rect)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

extension View {
    /// The guide UI any screen can ask for: the matching picker (`EPGStore.matchingTarget`) and refresh errors.
    /// Applied once at the root of the window.
    func guideManagement(_ epg: EPGStore) -> some View {
        modifier(GuideManagement(epg: epg))
    }
}

private struct GuideManagement: ViewModifier {
    @Bindable var epg: EPGStore

    /// With several windows (iPad), the picker and the alert show in one of them (see `WindowCoordinator`).
    @Environment(WindowCoordinator.self) private var coordinator: WindowCoordinator?
    @Environment(\.windowID) private var windowID

    func body(content: Content) -> some View {
        content
            .windowPresentation(.guideMatching, isActive: epg.matchingTarget != nil)
            .windowPresentation(.guideFailure, isActive: epg.failure != nil)
            .sheet(item: matchingBinding) { item in
                GuideChannelPicker(item: item)
            }
            .alert(
                "Could Not Load the TV Guide",
                isPresented: Binding(get: { shows(.guideFailure, isActive: epg.failure != nil) }, set: { if !$0 { epg.failure = nil } }),
                presenting: epg.failure
            ) { _ in
                Button("OK", role: .cancel) {}
            } message: { failure in
                Text("\(failure.sourceName): \(failure.message)")
            }
    }

    private func shows(_ presentation: WindowCoordinator.Presentation, isActive: Bool) -> Bool {
        coordinator?.shows(presentation, in: windowID, isActive: isActive) ?? isActive
    }

    private var matchingBinding: Binding<ChannelItem?> {
        Binding(
            get: { shows(.guideMatching, isActive: epg.matchingTarget != nil) ? epg.matchingTarget : nil },
            set: { epg.matchingTarget = $0 }
        )
    }
}

#Preview {
    GuideChannelPicker(item: PreviewSampleData.sampleItems[0])
        .fluxoPreviewEnvironment(GuidePreviewData.container)
}
