//
//  GuideIntents.swift
//  Fluxo
//
//  Siri and Shortcuts actions for the TV guide: what's on, guide search, reminders, and opening a screen.
//

import AppIntents
import Foundation
import UserNotifications

/// "What's on Sky Sport F1?" (now and next), or, without a channel, what the favorite channels show now.
struct WhatsOnIntent: AppIntent {

    static let title: LocalizedStringResource = "What's On"
    static let description = IntentDescription("Tells what a channel shows now and next. Without a channel, tells what your favorite channels show now.", categoryName: "TV Guide")
    static let supportedModes: IntentModes = .background

    @Parameter(title: "Channel", description: "Leave empty for your favorite channels.")
    var channel: ChannelEntity?

    @Dependency
    var services: AppServices

    static var parameterSummary: some ParameterSummary {
        Summary("What's on \(\.$channel)")
    }

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<[ProgramEntity]> & ProvidesDialog & ShowsSnippetView {
        guard await services.waitForGuide() else {
            throw FluxoIntentError.noGuide
        }
        let names = ChannelEntityQuery.playlistNames(services.container)
        if let channel {
            let item = channel.item
            guard let nowNext = await services.epg.nowNext(for: item) else {
                throw FluxoIntentError.noGuide
            }
            let entities = [nowNext.current, nowNext.next].compactMap { $0 }.compactMap { ProgramEntity($0, channel: item, playlistName: names[item.playlistID]) }
            let dialog: IntentDialog
            if let current = nowNext.current {
                if let next = nowNext.next {
                    dialog = "On \(item.displayName) now: \(current.title), until \(GuideFormat.time(current.stop)). Then \(next.title)."
                } else {
                    dialog = "On \(item.displayName) now: \(current.title), until \(GuideFormat.time(current.stop))."
                }
            } else if let next = nowNext.next {
                dialog = "Nothing is listed on \(item.displayName) now. Next: \(next.title) at \(GuideFormat.time(next.start))."
            } else {
                throw FluxoIntentError.noGuide
            }
            return .result(value: entities, dialog: dialog, view: NowNextSnippetView(channelName: item.displayName, kind: item.kind, nowNext: nowNext))
        }

        // No channel: the favorites (or the last watched channels) that have a guide.
        var rows: [ProgrammeListSnippetView.Row] = []
        var entities: [ProgramEntity] = []
        for suggestion in try await ChannelEntityQuery.suggestions(container: services.container, limit: 20) where suggestion.item.kind == .live {
            guard let current = await services.epg.nowNext(for: suggestion.item)?.current else {
                continue
            }
            if let entity = ProgramEntity(current, channel: suggestion.item, playlistName: names[suggestion.item.playlistID]) {
                entities.append(entity)
                rows.append(.init(id: entity.id, programme: current, channelName: suggestion.name))
            }
            if entities.count == 6 {
                break
            }
        }
        guard let first = entities.first else {
            throw FluxoIntentError.noGuide
        }
        let dialog: IntentDialog = entities.count == 1
            ? "On \(first.channel.name) now: \(first.title)."
            : "On \(first.channel.name) now: \(first.title). Here is what else is on your channels."
        return .result(value: entities, dialog: dialog, view: ProgrammeListSnippetView(rows: rows))
    }
}

/// Searches the TV guide; with Apple Intelligence it understands "football tonight" or "films tomorrow".
struct SearchProgrammesIntent: AppIntent {

    static let title: LocalizedStringResource = "Search TV Guide"
    static let description = IntentDescription("Finds programmes in the TV guide. With Apple Intelligence it understands requests like “football tonight”.", categoryName: "TV Guide")
    static let supportedModes: IntentModes = .background

    @Parameter(title: "Search", requestValueDialog: "Which programme are you looking for?")
    var query: String

    @Dependency
    var services: AppServices

    static var parameterSummary: some ParameterSummary {
        Summary("Search the TV guide for \(\.$query)")
    }

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<[ProgramEntity]> & ProvidesDialog & ShowsSnippetView {
        guard await services.waitForGuide() else {
            throw FluxoIntentError.noGuide
        }
        let importIDs = services.allImportIDs()
        var results = await services.epg.searchProgrammes(query, importIDs: importIDs, limit: 30)
        if SmartSearch.isNaturalLanguage(query) || results.isEmpty {
            var plan = await SmartSearch.plan(for: query, useModel: services.intelligence.isAvailable)
            plan.wantsProgrammes = true
            // A kind alone is a search too: "films tomorrow" lists the films of the guide.
            if !plan.isEmpty {
                let smart = await SmartSearch.run(plan, query: query, importIDs: importIDs, container: services.container, epg: services.epg)
                if !smart.programmes.isEmpty {
                    results = smart.programmes
                }
            }
        }
        let names = ChannelEntityQuery.playlistNames(services.container)
        let entities = results.compactMap { ProgramEntity($0.programme, channel: $0.channel, playlistName: names[$0.channel.playlistID]) }
        guard let first = entities.first else {
            throw FluxoIntentError.noProgrammes(query)
        }
        let rows = results.prefix(6).map { ProgrammeListSnippetView.Row(id: $0.id, programme: $0.programme, channelName: $0.channel.displayName, note: GuideFormat.day($0.programme.start)) }
        let when = first.programme.isOnAir(at: .now) ? String(localized: "on now") : GuideFormat.dayAndTime(first.programme)
        let dialog: IntentDialog = entities.count == 1
            ? "\(first.title) is \(when) on \(first.channel.name)."
            : "I found \(entities.count) programmes. The first is \(first.title), \(when) on \(first.channel.name)."
        return .result(value: entities, dialog: dialog, view: ProgrammeListSnippetView(rows: rows))
    }
}

/// Sets a reminder: a notification shortly before the programme starts, which plays the channel when tapped.
struct SetReminderIntent: AppIntent {

    static let title: LocalizedStringResource = "Set Programme Reminder"
    static let description = IntentDescription("Reminds you shortly before a programme starts. Tap the notification to watch it.", categoryName: "TV Guide")
    /// In the background, except the first time: the system asks for notification permission only for an app
    /// in front, so the intent opens Fluxo when the permission was never asked.
    static let supportedModes: IntentModes = [.background, .foreground(.dynamic)]

    @Parameter(title: "Programme", requestValueDialog: "Which programme?")
    var program: ProgramEntity

    @Dependency
    var services: AppServices

    static var parameterSummary: some ParameterSummary {
        Summary("Remind me about \(\.$program)")
    }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog & ShowsSnippetView {
        let programme = program.programme
        guard ReminderCenter.canRemind(programme) else {
            throw FluxoIntentError.programmeStarted(programme.title)
        }
        let reminders = services.epg.reminders
        if !reminders.isScheduled(programme) {
            if await UNUserNotificationCenter.current().notificationSettings().authorizationStatus == .notDetermined {
                try await continueInForeground(alwaysConfirm: false)
            }
            guard await reminders.schedule(programme, on: program.channel.item) else {
                reminders.isShowingPermissionHint = false
                throw FluxoIntentError.notificationsOff
            }
        }
        let lead = ReminderCenter.leadMinutes
        let dialog: IntentDialog = lead > 0
            ? "OK, I'll remind you \(lead) minutes before \(programme.title) starts."
            : "OK, I'll remind you when \(programme.title) starts."
        return .result(
            dialog: dialog,
            view: ConfirmationSnippetView(systemImage: "bell.fill", title: programme.title, subtitle: TextParts.line([program.channel.name, GuideFormat.dayAndTime(programme)]))
        )
    }
}

/// The screens an intent can open.
enum FluxoDestination: String, AppEnum {
    case home
    case guide
    case search
    case favorites
    case history
    case recordings
    /// The Library tab (favorites, recently watched and recordings; on the Mac, its Recordings item).
    case library

    static var typeDisplayRepresentation: TypeDisplayRepresentation {
        "Fluxo Screen"
    }

    static var caseDisplayRepresentations: [FluxoDestination: DisplayRepresentation] {
        [
            .home: DisplayRepresentation(title: "Home", image: .init(systemName: "play.tv")),
            .guide: DisplayRepresentation(title: "TV Guide", image: .init(systemName: "calendar.day.timeline.left"), synonyms: ["Guide", "EPG", "Programme Guide", "Program Guide", "Schedule"]),
            .search: DisplayRepresentation(title: "Search", image: .init(systemName: "magnifyingglass")),
            .favorites: DisplayRepresentation(title: "Favorites", image: .init(systemName: "star"), synonyms: ["Favourites"]),
            .history: DisplayRepresentation(title: "Recently Watched", image: .init(systemName: "clock"), synonyms: ["History", "Continue Watching"]),
            .recordings: DisplayRepresentation(title: "Recordings", image: .init(systemName: "film.stack")),
            .library: DisplayRepresentation(title: "Library", image: .init(systemName: "rectangle.stack")),
        ]
    }

    var destination: AppNavigation.Destination {
        switch self {
        case .home:
            return .home
        case .guide:
            return .guide
        case .search:
            return .search
        case .favorites:
            return .favorites
        case .history:
            return .history
        case .recordings:
            return .recordings
        case .library:
            return .library
        }
    }
}

/// Opens a screen of Fluxo ("Open the TV guide in Fluxo").
struct OpenFluxoIntent: OpenIntent {

    static let title: LocalizedStringResource = "Open Screen"
    static let description = IntentDescription("Opens the TV guide, search, favorites, recently watched or recordings.", categoryName: "Navigation")

    @Parameter(title: "Screen", requestValueDialog: "Which screen?")
    var target: FluxoDestination

    @Dependency
    var services: AppServices

    init() {}

    init(target: FluxoDestination) {
        self.target = target
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        services.reveal(target.destination)
        return .result()
    }
}

/// Opens the schedule of a channel: today's programmes and the next days, from the TV guide, with reminders.
struct ShowScheduleIntent: AppIntent {

    static let title: LocalizedStringResource = "Show Channel Schedule"
    static let description = IntentDescription("Opens the TV guide schedule of a channel: today and the next days, where you can set reminders.", categoryName: "TV Guide", searchKeywords: ["Guide", "EPG", "Programmes", "Listings", "Schedule"])
    static let supportedModes: IntentModes = .foreground(.immediate)

    @Parameter(title: "Channel", description: "Leave empty for the channel that is playing.", requestValueDialog: "Which channel?")
    var channel: ChannelEntity?

    @Dependency
    var services: AppServices

    static var parameterSummary: some ParameterSummary {
        Summary("Show the schedule of \(\.$channel)")
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        guard let item = channel?.item ?? services.currentOrLastChannel() else {
            throw FluxoIntentError.nothingPlaying
        }
        guard item.kind == .live else {
            throw FluxoIntentError.noGuide
        }
        services.showSchedule(of: item)
        return .result()
    }
}
