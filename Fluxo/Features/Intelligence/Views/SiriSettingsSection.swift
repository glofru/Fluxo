//
//  SiriSettingsSection.swift
//  Fluxo
//
//  Settings › Siri & Shortcuts: what to say to Siri, the tip of the system for one phrase, and a link to Fluxo's
//  shortcuts in the Shortcuts app. Most requests that "do not work" miss the app name, or name a channel Siri
//  does not know yet: the section says both.
//

import AppIntents
import SwiftUI

struct SiriSettingsSection: View {

    var body: some View {
        Section {
            #if os(iOS)
            SiriTipView(intent: ContinueWatchingIntent())
                .siriTipViewStyle(.automatic)
            #endif
            phrase(Text("“Play Rai 1 in Fluxo”", comment: "A Siri phrase shown in Settings: translate it as the Play Channel phrase people say to Siri in this language, keeping “Fluxo”."), detail: "A favorite, a channel you watched or one of the first channels of a playlist. For any other: “Watch TV in Fluxo”, then the name.", systemImage: "play.tv")
            phrase(Text("“What's on in Fluxo?”", comment: "A Siri phrase shown in Settings: translate it as the What's On phrase people say to Siri in this language, keeping “Fluxo”."), detail: "What your favorite channels show now.", systemImage: "tv.badge.wifi")
                // The harness scrolls here (`settings-section:siri-whats-on`) for screenshots without the first
                // phrase, whose example is a real channel.
                .id("siri-whats-on")
            phrase(Text("“Search Fluxo”", comment: "A Siri phrase shown in Settings: translate it as the Search phrase people say to Siri in this language, keeping “Fluxo”."), detail: "Then say what you are looking for: a channel, a film, “football tonight”.", systemImage: "magnifyingglass")
            phrase(Text("“Continue watching in Fluxo”", comment: "A Siri phrase shown in Settings: translate it as the Continue Watching phrase people say to Siri in this language, keeping “Fluxo”."), detail: "The movie or episode you were watching, where you left it.", systemImage: "play.circle")
            phrase(Text("“Open the TV guide in Fluxo”", comment: "A Siri phrase shown in Settings: translate it as the Open Screen phrase people say to Siri in this language, keeping “Fluxo”."), detail: "Also Favorites, Recently Watched, Recordings and Search.", systemImage: "calendar.day.timeline.left")
            #if os(iOS)
            ShortcutsLink()
                .shortcutsLinkStyle(.automaticOutline)
                .frame(maxWidth: .infinity)
                .listRowBackground(Color.clear)
            #endif
        } header: {
            Text("Siri & Shortcuts")
        } footer: {
            Text("Always say “Fluxo” in the request, in the language Siri speaks. Siri learns more channel names as you add favorites and watch channels. Every action is also in the Shortcuts app.", comment: "Footer of Settings › Siri & Shortcuts.")
        }
    }

    private func phrase(_ text: Text, detail: LocalizedStringKey, systemImage: String) -> some View {
        Label {
            VStack(alignment: .leading, spacing: 2) {
                text
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(Theme.secondaryText)
            }
        } icon: {
            Image(systemName: systemImage)
        }
        .accessibilityElement(children: .combine)
    }
}

#Preview {
    Form {
        SiriSettingsSection()
    }
    .formStyle(.grouped)
    .fluxoPreviewEnvironment()
}
