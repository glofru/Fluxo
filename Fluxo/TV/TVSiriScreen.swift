//
//  TVSiriScreen.swift
//  Fluxo
//
//  Settings › Siri and Voice Search on Apple TV: what to say to Siri for Fluxo (holding the microphone button of the
//  Siri Remote), and how to search by voice in the app. Apple TV has no Shortcuts app, so this page is where the
//  phrases are found. Laid out like Settings itself: the mark on the leading side, the lines on the other; each line is
//  focusable, so the remote walks through the page and VoiceOver reads each line as it is focused.
//
//  The phrases are the App Shortcuts of `FluxoShortcuts` (translate them as those phrases are in each language).
//

#if os(tvOS)
import SwiftUI

struct TVSiriScreen: View {

    #if DEBUG
    @Environment(AppNavigation.self) private var navigation
    #endif

    var body: some View {
        HStack(alignment: .top, spacing: 60) {
            header
                .frame(width: 560)
                .padding(.top, 120)
            ScrollViewReader { proxy in
                list
                #if DEBUG
                    // Debug harness (`focus:<name>`): brings a line of the lazy list in, so it can take the focus.
                    .onChange(of: navigation.debugFocusName, initial: true) { _, name in
                        if let name, name.hasPrefix("siri-") {
                            proxy.scrollTo(name, anchor: .center)
                        }
                    }
                #endif
            }
        }
        .padding(.leading, TVLayout.margin)
    }

    private var list: some View {
        List {
            Section {
                // No `SiriTipView`: it is in the tvOS SDK, but in the tvOS 27.2 Simulator it drew nothing (no
                // height, no focus) in this list, so the phrases are lines of their own.
                TVSiriLine(
                    Text("“Play Rai 1 in Fluxo”", comment: "A Siri phrase shown in Settings: translate it as the Play Channel phrase people say to Siri in this language, keeping “Fluxo”."),
                    detail: Text("A favorite, a channel you watched or one of the first channels of a playlist. For any other: “Watch TV in Fluxo”, then the name."),
                    systemImage: "play.tv",
                    debugName: "siri-play"
                )
                TVSiriLine(
                    Text("“Continue watching in Fluxo”", comment: "A Siri phrase shown in Settings: translate it as the Continue Watching phrase people say to Siri in this language, keeping “Fluxo”."),
                    detail: Text(String(localized: "TV.siri.continue.detail", defaultValue: "The movie or episode you were watching, where you left it, even if you started it on your iPhone, iPad or Mac (with iCloud sync on). Otherwise, the channel you watched last.", comment: "Apple TV, Settings › Siri: what the Continue Watching phrase does. Watch progress follows the user through iCloud sync; with no movie or episode in progress, the last watched channel plays.")),
                    systemImage: "play.circle",
                    debugName: "siri-continue"
                )
                TVSiriLine(
                    Text("“What's on in Fluxo?”", comment: "A Siri phrase shown in Settings: translate it as the What's On phrase people say to Siri in this language, keeping “Fluxo”."),
                    detail: Text("What your favorite channels show now."),
                    systemImage: "tv.badge.wifi",
                    debugName: "siri-whats-on"
                )
                TVSiriLine(
                    Text("“Search Fluxo”", comment: "A Siri phrase shown in Settings: translate it as the Search phrase people say to Siri in this language, keeping “Fluxo”."),
                    detail: Text("Then say what you are looking for: a channel, a film, “football tonight”."),
                    systemImage: "magnifyingglass",
                    debugName: "siri-search"
                )
                TVSiriLine(
                    Text("“Open the TV guide in Fluxo”", comment: "A Siri phrase shown in Settings: translate it as the Open Screen phrase people say to Siri in this language, keeping “Fluxo”."),
                    detail: Text(String(localized: "TV.siri.open.detail", defaultValue: "Also Movies, Series, Library, Favorites, Recordings and Settings.", comment: "Apple TV, Settings › Siri: the other screens the Open Screen phrase opens (the names of the app's tabs and pages).")),
                    systemImage: "calendar.day.timeline.left",
                    debugName: "siri-open"
                )
                TVSiriLine(
                    Text(String(localized: "TV.siri.record.phrase", defaultValue: "“Record this in Fluxo”", comment: "Apple TV, Settings › Siri: a Siri phrase; translate it as the Recording phrase people say to Siri in this language (“Record this in Fluxo”), keeping “Fluxo”.")),
                    detail: Text(String(localized: "TV.siri.record.detail", defaultValue: "The live channel that plays. Say “Stop recording in Fluxo” to save it.", comment: "Apple TV, Settings › Siri: what the Recording phrase does. Translate the phrase in quotes as the Stop Recording phrase of this language.")),
                    systemImage: "record.circle",
                    debugName: "siri-record"
                )
                TVSiriLine(
                    Text(String(localized: "TV.siri.favorite.phrase", defaultValue: "“Add this channel to my Fluxo favorites”", comment: "Apple TV, Settings › Siri: a Siri phrase; translate it as the Add to Favorites phrase people say to Siri in this language, keeping “Fluxo”.")),
                    detail: Text(String(localized: "TV.siri.favorite.detail", defaultValue: "The channel that plays, or the one you watched last.", comment: "Apple TV, Settings › Siri: what the Add to Favorites phrase adds (the playing channel, else the last watched one).")),
                    systemImage: "star",
                    debugName: "siri-favorite"
                )
                TVSiriLine(
                    Text(String(localized: "TV.siri.reminder.phrase", defaultValue: "“Remind me about a show in Fluxo”", comment: "Apple TV, Settings › Siri: a Siri phrase; translate it as one of the Set Reminder phrases of this language in AppShortcuts.xcstrings without ${program} (such as “Set a reminder in Fluxo”), so that Siri knows it, keeping “Fluxo”.")),
                    detail: Text(String(localized: "TV.siri.reminder.detail", defaultValue: "Siri asks which one. Fluxo reminds you shortly before it starts, while it's open.", comment: "Apple TV, Settings › Siri: what the Set Reminder phrase does. On Apple TV reminders are alerts shown by the app while it is open.")),
                    systemImage: "bell.badge",
                    debugName: "siri-reminder"
                )
            } header: {
                Text(String(localized: "TV.siri.say.header", defaultValue: "Say to Siri", comment: "Apple TV, Settings › Siri: header of the list of Siri phrases."))
            } footer: {
                // As the system draws a footer in Settings: smaller and secondary, under the lines.
                Text(String(localized: "TV.siri.say.footer", defaultValue: "Always say “Fluxo”, in the language Siri speaks. Siri learns more channel names as you add favorites and watch channels.", comment: "Apple TV, Settings › Siri: footer of the list of Siri phrases."))
                    .font(.caption)
                    .foregroundStyle(Theme.secondaryText)
            }
            Section {
                TVSiriLine(
                    Text(String(localized: "TV.siri.voiceSearch.title", defaultValue: "Hold the microphone button in Search", comment: "Apple TV, Settings › Siri: how to search by voice in the app (the microphone button of the Siri Remote, while the Search tab's keyboard shows).")),
                    detail: Text(String(localized: "TV.siri.voiceSearch.detail", defaultValue: "Say a channel, a film or a series, or a sentence such as “football tonight” or “italian news channels”: Fluxo shows what matches.", comment: "Apple TV, Settings › Siri: what can be said to the app's Search. Translate the examples in quotes as searches people say in this language.")),
                    systemImage: "mic.fill",
                    debugName: "siri-voice-search"
                )
            } header: {
                Text(String(localized: "TV.siri.voiceSearch.header", defaultValue: "Search with Your Voice", comment: "Apple TV, Settings › Siri: header of the section about voice search in the app."))
            }
        }
        .padding(.top, 60)
        // The focused platter's trailing edge a little inside the 80-point safe area, clear of overscan.
        .padding(.trailing, 10)
    }

    private var header: some View {
        VStack(spacing: 30) {
            Image(systemName: "appletvremote.gen4.fill")
                .font(.system(size: 132, weight: .regular))
                .foregroundStyle(.white)
                .frame(width: 280, height: 280)
                .background(Theme.brandGradient, in: .rect(cornerRadius: 60, style: .continuous))
                .shadow(color: .black.opacity(0.3), radius: 30, y: 16)
                .accessibilityHidden(true)
            VStack(spacing: 12) {
                Text(TVSiriScreen.title)
                    .font(.title2.bold())
                Text(String(localized: "TV.siri.subtitle", defaultValue: "Hold the microphone button on the Siri Remote, say what you want, then let go.", comment: "Apple TV, Settings › Siri: how to talk to Siri with the Siri Remote."))
                    .font(.callout)
                    .foregroundStyle(Theme.secondaryText)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 480)
            }
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
    }

    static var title: String {
        String(localized: "TV.siri.title", defaultValue: "Siri and Voice Search", comment: "Apple TV Settings: the page about Siri and voice search (also the name of its row in Settings).")
    }
}

/// A line of the page: what to say, and what it does underneath. Focusable, so the remote reaches every line and the
/// page scrolls with it. The focused line is on a white platter with dark text, as the focused rows of the system's
/// Settings are (readable at 10 feet in light and dark mode); it is not a button, since selecting it does nothing. No
/// scale: the List clips its rows, so a grown platter would lose its rounded corners at the sides.
/// The symbols sit in a column of one width, so the phrases line up whatever the symbol's shape.
private struct TVSiriLine: View {
    let phrase: Text
    let detail: Text
    let systemImage: String
    let debugName: String

    @FocusState private var isFocused: Bool

    init(_ phrase: Text, detail: Text, systemImage: String, debugName: String) {
        self.phrase = phrase
        self.detail = detail
        self.systemImage = systemImage
        self.debugName = debugName
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 24) {
            Image(systemName: systemImage)
                .font(.headline)
                .imageScale(.large)
                .foregroundStyle(Theme.accent)
                .frame(width: 56)
            VStack(alignment: .leading, spacing: 6) {
                phrase
                    .font(.headline)
                    .foregroundStyle(isFocused ? Color.black : Color.primary)
                detail
                    .font(.callout)
                    .foregroundStyle(isFocused ? Color.black.opacity(0.65) : Theme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 12)
        .accessibilityElement(children: .combine)
        .id(debugName)
        .focusable()
        .focused($isFocused)
        .listRowBackground(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .fill(.white)
                .shadow(color: .black.opacity(0.3), radius: 18, y: 10)
                .opacity(isFocused ? 1 : 0)
        )
        .animation(.easeOut(duration: 0.15), value: isFocused)
        .tvDebugFocus(debugName, focus: $isFocused)
    }
}
#endif
