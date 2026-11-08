//
//  IntelligenceSettingsSection.swift
//  Fluxo
//
//  Settings › Apple Intelligence: the switch for the on-device features and why they are unavailable.
//

import SwiftUI

struct IntelligenceSettingsSection: View {

    @Environment(FluxoIntelligence.self) private var intelligence: FluxoIntelligence?

    var body: some View {
        if let intelligence {
            Section {
                Toggle(isOn: binding(intelligence)) {
                    Label {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Personal Suggestions and Smart Search")
                            Text("For You, For You Tonight, natural-language search and programme summaries.")
                                .font(.caption)
                                .foregroundStyle(Theme.secondaryText)
                        }
                    } icon: {
                        Image(systemName: "sparkles")
                    }
                }
                .disabled(!systemIsAvailable)

                if let explanation = intelligence.status.explanation, intelligence.status != .turnedOff {
                    Label(explanation, systemImage: "info.circle")
                        .font(.footnote)
                        .foregroundStyle(Theme.secondaryText)
                }
            } header: {
                Text("Apple Intelligence")
            } footer: {
                Text("Everything runs on this device. What you watch and search is never sent anywhere.")
            }
            .id("intelligence")
            .onAppear {
                intelligence.refreshAvailability()
            }
        }
    }

    private var systemIsAvailable: Bool {
        FluxoIntelligence.systemStatus() == .available
    }

    private func binding(_ intelligence: FluxoIntelligence) -> Binding<Bool> {
        Binding {
            intelligence.isEnabled && systemIsAvailable
        } set: { isOn in
            intelligence.isEnabled = isOn
            intelligence.recommendations.invalidate()
        }
    }
}

#Preview {
    Form {
        IntelligenceSettingsSection()
    }
    .formStyle(.grouped)
    .fluxoPreviewEnvironment()
}
