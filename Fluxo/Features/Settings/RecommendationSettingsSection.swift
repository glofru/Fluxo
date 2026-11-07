//
//  RecommendationSettingsSection.swift
//  Fluxo
//
//  Settings › Recommendations: whether what Fluxo puts forward on its own leaves out adult content
//  (`MatureContent`, `MatureContentFilter`). On every platform; the setting follows the user to their other devices.
//

import SwiftUI

struct RecommendationSettingsSection: View {

    @AppStorage(MatureContent.hidesAdultContentKey) private var hidesAdultContent = MatureContent.hidesAdultContentByDefault
    @Environment(FluxoIntelligence.self) private var intelligence: FluxoIntelligence?

    var body: some View {
        Section {
            Toggle(isOn: $hidesAdultContent) {
                #if os(tvOS)
                Label(String(localized: "Hide adult content from recommendations"), systemImage: "eye.slash")
                #else
                SettingsLabel("Hide adult content from recommendations", systemImage: "eye.slash", tint: Theme.pink)
                #endif
            }
            .onChange(of: hidesAdultContent) {
                // Lists made with the other setting are not shown again.
                intelligence?.recommendations.invalidate()
            }
        } header: {
            Text("Recommendations", comment: "Settings: header of the section about what Fluxo suggests (featured items, For You, On Now).")
        } footer: {
            Text(footer)
        }
    }

    private var footer: String {
        #if os(tvOS)
        String(localized: "Featured items, On Now, suggestions and the Top Shelf leave out channels, movies and categories for adults, such as XXX or 18+. Search and the categories still show them, and a playlist with nothing else is shown as it is.", comment: "Apple TV Settings, footer of the Recommendations section: what 'Hide adult content from recommendations' does.")
        #else
        String(localized: "Featured items, For You, Because You Watched, On Now and For You Tonight leave out channels, movies and categories for adults, such as XXX or 18+. Search and the categories still show them, and a playlist with nothing else is shown as it is.", comment: "Settings, footer of the Recommendations section: what 'Hide adult content from recommendations' does. For You, Because You Watched, On Now and For You Tonight are the names of sections of the Home page and the TV guide.")
        #endif
    }
}

#Preview {
    Form {
        RecommendationSettingsSection()
    }
    .formStyle(.grouped)
    .fluxoPreviewEnvironment()
}
