//
//  ProgramEntity.swift
//  Fluxo
//
//  A TV guide programme for Siri and Shortcuts ("What's on", reminders, guide search).
//
//  Its identifier joins the programme's reminder key (guide source, guide channel, start time; stable across
//  guide refreshes) and the opaque identifier of the playlist channel that airs it (`ChannelEntityID`).
//

import AppIntents
import Foundation
import SwiftData

struct ProgramEntity: AppEntity {

    static var typeDisplayRepresentation: TypeDisplayRepresentation {
        TypeDisplayRepresentation(name: "TV Programme", numericFormat: "\(placeholder: .int) programmes")
    }

    static let defaultQuery = ProgramEntityQuery()

    /// Separates the two keys of the identifier (neither contains it).
    static let separator: Character = "\u{1F}"

    let id: String

    @Property(title: "Title")
    var title: String

    @Property(title: "Episode")
    var episode: String?

    @Property(title: "Start")
    var start: Date

    @Property(title: "End")
    var end: Date

    @Property(title: "Description")
    var summary: String

    @Property(title: "Categories")
    var categories: [String]

    @Property(title: "Channel")
    var channel: ChannelEntity

    let programme: GuideProgramme

    init?(_ programme: GuideProgramme, channel item: ChannelItem, playlistName: String? = nil) {
        guard let channel = ChannelEntity(item, playlistName: playlistName) else {
            return nil
        }
        id = "\(programme.reminderKey)\(Self.separator)\(channel.id)"
        self.programme = programme
        self.title = programme.title
        self.episode = programme.detailLine
        self.start = programme.start
        self.end = programme.stop
        self.summary = programme.summary
        self.categories = programme.categories
        self.channel = channel
    }

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(
            title: "\(title)",
            subtitle: "\(TextParts.line([channel.name, GuideFormat.dayAndTime(programme)]))",
            image: DisplayRepresentation.Image(systemName: "calendar.day.timeline.left")
        )
    }
}

/// Finds programmes: by identifier, by text (the guide's programme search over every playlist), and
/// suggestions (what the favorite channels show now and next).
struct ProgramEntityQuery: EntityStringQuery {

    @Dependency
    var services: AppServices

    @concurrent func entities(for identifiers: [ProgramEntity.ID]) async throws -> [ProgramEntity] {
        let container = services.container
        let names = ChannelEntityQuery.playlistNames(container)
        return identifiers.compactMap { identifier in
            let parts = identifier.split(separator: ProgramEntity.separator, maxSplits: 1).map(String.init)
            guard parts.count == 2,
                  let programme = ProgrammeLookup.programme(reminderKey: parts[0], in: container),
                  let key = ChannelEntityID.key(for: parts[1], in: container),
                  let channel = LibraryLookup.channel(forKey: key, in: container) else {
                return nil
            }
            return ProgramEntity(programme, channel: channel, playlistName: names[channel.playlistID])
        }
    }

    @MainActor
    func entities(matching string: String) async throws -> [ProgramEntity] {
        _ = await services.waitForGuide()
        let names = ChannelEntityQuery.playlistNames(services.container)
        let results = await services.epg.searchProgrammes(string, importIDs: services.allImportIDs(), limit: 30)
        return results.compactMap { ProgramEntity($0.programme, channel: $0.channel, playlistName: names[$0.channel.playlistID]) }
    }

    @MainActor
    func suggestedEntities() async throws -> [ProgramEntity] {
        guard await services.waitForGuide() else {
            return []
        }
        let names = ChannelEntityQuery.playlistNames(services.container)
        var entities: [ProgramEntity] = []
        for suggestion in try await ChannelEntityQuery.suggestions(container: services.container, limit: 12) where suggestion.item.kind == .live {
            guard let nowNext = await services.epg.nowNext(for: suggestion.item) else {
                continue
            }
            for programme in [nowNext.current, nowNext.next].compactMap({ $0 }) {
                if let entity = ProgramEntity(programme, channel: suggestion.item, playlistName: names[suggestion.item.playlistID]) {
                    entities.append(entity)
                }
            }
        }
        return entities
    }
}

/// Reads one programme by its reminder key, from the current import of its guide.
enum ProgrammeLookup {

    /// `GuideProgramme.reminderKey` is "<source UUID>|<guide channel id>|<start, seconds since 1970>"; the guide
    /// channel id may itself contain "|".
    static func programme(reminderKey: String, in container: ModelContainer) -> GuideProgramme? {
        guard let first = reminderKey.firstIndex(of: "|"), let last = reminderKey.lastIndex(of: "|"), first < last,
              let sourceID = UUID(uuidString: String(reminderKey[..<first])),
              let seconds = TimeInterval(reminderKey[reminderKey.index(after: last)...]) else {
            return nil
        }
        let channelID = String(reminderKey[reminderKey.index(after: first)..<last])
        let start = Date(timeIntervalSince1970: seconds)
        let context = LibraryLookup.makeContext(container)
        guard let importID = try? context.fetch(EPGQueries.source(uuid: sourceID)).first?.currentImportID else {
            return nil
        }
        // The key keeps whole seconds: match the start within that second.
        let lower = start
        let upper = start.addingTimeInterval(1)
        var descriptor = FetchDescriptor<EPGProgramme>(
            predicate: #Predicate { $0.importID == importID && $0.channelID == channelID && $0.start >= lower && $0.start < upper }
        )
        descriptor.fetchLimit = 1
        return (try? context.fetch(descriptor).first).map(GuideProgramme.init)
    }
}
