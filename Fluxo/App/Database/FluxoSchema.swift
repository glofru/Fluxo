//
//  FluxoSchema.swift
//  Fluxo
//
//  The versions of the SwiftData schema and the migration plan between them (see docs/library-store.md).
//
//  - `FluxoSchemaV1` (1.0.0) is frozen: the models as the first builds stored them, in a single store
//    (`default.store`). SwiftData records 1.0.0 for a store written without a versioned schema, so this is the version
//    of every store those builds wrote. Never edit these copies: they must hash exactly as the stores on disk do.
//  - `FluxoSchemaV2` (2.0.0) is the current schema: the app's `@Model` classes, split over two stores (user data and
//    caches, `LibraryStore`). A relationship cannot span two stores, so `Playlist.groups` and its inverse
//    `PlaylistChannelGroup.playlist` are gone (groups were always deleted by `playlistID` anyway), and the guide's
//    redundant `[importID]` programme index is dropped (the compound index starts with `importID`).
//
//  Changing a model:
//  1. Copy the current models into a nested `FluxoSchemaV2` (as V1 is), so the stores at 2.0.0 keep a schema that
//     matches them, and point `FluxoSchemaV2.models` at the copies.
//  2. Add `FluxoSchemaV3` (3.0.0) listing the app's classes, with the change.
//  3. Add V3 to `FluxoMigrationPlan.schemas` and a stage V2 -> V3 (lightweight when SwiftData can infer it, custom
//     otherwise), and add a check of the migration to `Tools/LibraryCheck`.
//

import Foundation
import SwiftData

enum FluxoSchemaV2: VersionedSchema {
    static let versionIdentifier = Schema.Version(2, 0, 0)

    static var models: [any PersistentModel.Type] {
        ModelRegistry.all
    }
}

enum FluxoMigrationPlan: SchemaMigrationPlan {
    static var schemas: [any VersionedSchema.Type] {
        [FluxoSchemaV1.self, FluxoSchemaV2.self]
    }

    static var stages: [MigrationStage] {
        [migrateV1toV2]
    }

    /// Drops the playlist-groups relationship and one index: SwiftData infers it.
    static let migrateV1toV2 = MigrationStage.lightweight(fromVersion: FluxoSchemaV1.self, toVersion: FluxoSchemaV2.self)

    /// The newest schema version this build knows. A store at a higher version was written by a newer build of the
    /// app: it is never opened (an inferred migration back would drop what that build added), see `LibraryStore`.
    static var currentVersion: Schema.Version {
        FluxoSchemaV2.versionIdentifier
    }
}

/// The schema of the first builds, frozen. Only the stored properties, their attributes and indexes matter here:
/// they decide the hashes SwiftData matches a store with.
enum FluxoSchemaV1: VersionedSchema {
    static let versionIdentifier = Schema.Version(1, 0, 0)

    static var models: [any PersistentModel.Type] {
        [
            ChannelBookmark.self,
            EPGChannel.self,
            EPGChannelOverride.self,
            EPGProgramme.self,
            EPGSource.self,
            Playlist.self,
            PlaylistChannel.self,
            PlaylistChannelGroup.self,
            PlaylistSeries.self,
            ProgrammeReminder.self,
            SeriesBookmark.self,
        ]
    }

    @Model
    final class ChannelBookmark {
        #Index<ChannelBookmark>([\.playlistID], [\.isFavorite, \.favoritedOn], [\.lastWatchedAt])

        @Attribute(.unique)
        var key: String
        var playlistID: UUID
        var url: URL
        var channelID: UUID
        var name: String?
        var logo: String?
        var groupName: String
        var kindRawValue: Int = 0
        var tvgID: String?
        var isFavorite: Bool = false
        var favoritedOn: Date?
        var favoriteOrder: Double = 0
        var lastWatchedAt: Date?
        var watchCount: Int = 0
        var resumePosition: Double = 0
        var knownDuration: Double = 0
        var seriesKey: String?
        var seriesTitle: String?
        var seasonNumber: Int?
        var episodeNumber: Int?
        var episodeTitle: String?

        init(key: String, playlistID: UUID, url: URL, channelID: UUID, name: String?, logo: String?, groupName: String) {
            self.key = key
            self.playlistID = playlistID
            self.url = url
            self.channelID = channelID
            self.name = name
            self.logo = logo
            self.groupName = groupName
        }
    }

    @Model
    final class EPGSource {
        #Index<EPGSource>([\.playlistID])

        @Attribute(.unique)
        var uuid: UUID
        var url: URL
        var name: String
        var playlistID: UUID?
        var isEnabled: Bool = true
        var addedOn: Date
        var currentImportID: UUID?
        var lastRefreshedOn: Date?
        var lastAttemptOn: Date?
        var lastError: String?
        var channelCount: Int = 0
        var contentHash: String?
        var entityTag: String?
        var lastModifiedHeader: String?
        var storedChannelCount: Int = 0
        var programmeCount: Int = 0

        init(uuid: UUID, url: URL, name: String, playlistID: UUID?, addedOn: Date) {
            self.uuid = uuid
            self.url = url
            self.name = name
            self.playlistID = playlistID
            self.addedOn = addedOn
        }
    }

    @Model
    final class EPGChannel {
        #Index<EPGChannel>([\.importID], [\.sourceID])

        var sourceID: UUID
        var importID: UUID
        var channelID: String
        var displayName: String
        var otherNames: String = ""
        var icon: String?
        var hasProgrammes: Bool = false

        init(sourceID: UUID, importID: UUID, channelID: String, displayName: String) {
            self.sourceID = sourceID
            self.importID = importID
            self.channelID = channelID
            self.displayName = displayName
        }
    }

    @Model
    final class EPGProgramme {
        #Index<EPGProgramme>([\.importID, \.channelID, \.start], [\.importID], [\.stop], [\.start])

        var sourceID: UUID
        var importID: UUID
        var channelID: String
        var start: Date
        var stop: Date
        var title: String
        var subtitle: String = ""
        var summary: String = ""
        var categories: String = ""
        var icon: String?
        var episode: String?

        init(sourceID: UUID, importID: UUID, channelID: String, start: Date, stop: Date, title: String) {
            self.sourceID = sourceID
            self.importID = importID
            self.channelID = channelID
            self.start = start
            self.stop = stop
            self.title = title
        }
    }

    @Model
    final class EPGChannelOverride {
        #Index<EPGChannelOverride>([\.playlistID])

        @Attribute(.unique)
        var key: String
        var playlistID: UUID
        var sourceID: UUID?
        var channelID: String
        var updatedOn: Date

        init(key: String, playlistID: UUID, sourceID: UUID?, channelID: String, updatedOn: Date) {
            self.key = key
            self.playlistID = playlistID
            self.sourceID = sourceID
            self.channelID = channelID
            self.updatedOn = updatedOn
        }
    }

    @Model
    final class ProgrammeReminder {
        #Index<ProgrammeReminder>([\.start])

        @Attribute(.unique)
        var key: String
        var title: String
        var subtitle: String
        var start: Date
        var stop: Date
        var fireDate: Date
        var playlistID: UUID
        var channelURL: URL
        var channelUUID: UUID
        var channelName: String?
        var channelLogo: String?
        var groupName: String
        var tvgID: String?

        init(key: String, title: String, subtitle: String, start: Date, stop: Date, fireDate: Date, playlistID: UUID, channelURL: URL, channelUUID: UUID, groupName: String) {
            self.key = key
            self.title = title
            self.subtitle = subtitle
            self.start = start
            self.stop = stop
            self.fireDate = fireDate
            self.playlistID = playlistID
            self.channelURL = channelURL
            self.channelUUID = channelUUID
            self.groupName = groupName
        }
    }

    @Model
    final class Playlist {
        #Index<Playlist>([\.createdOn])

        @Attribute(.unique)
        var uuid: UUID
        var name: String
        var url: URL
        var createdOn: Date
        var currentImportID: UUID?
        var lastRefreshedOn: Date?
        var channelCount: Int = 0
        var groupCount: Int = 0
        var guideURLString: String?
        var guideHeaderCheckedOn: Date?
        var seriesIndexVersion: Int = 0

        @Relationship(deleteRule: .cascade, inverse: \PlaylistChannelGroup.playlist)
        var groups: [PlaylistChannelGroup]? = []

        init(uuid: UUID, name: String, url: URL, createdOn: Date) {
            self.uuid = uuid
            self.name = name
            self.url = url
            self.createdOn = createdOn
        }
    }

    @Model
    final class PlaylistChannel {
        #Index<PlaylistChannel>([\.importID, \.groupName, \.sortIndex], [\.importID, \.sortIndex], [\.playlistID])

        var uuid: UUID
        var name: String?
        var logo: String?
        var tvgID: String?
        var duration: Int?
        @Attribute(originalName: "group")
        var groupName: String
        var url: URL?
        var sortIndex: Int = 0
        var playlistID: UUID = UUID()
        var importID: UUID = UUID()
        var kindRawValue: Int = 0
        var seriesKey: String?
        var episodeData: String?
        var isListed: Bool = true

        init(uuid: UUID, groupName: String, playlistID: UUID, importID: UUID) {
            self.uuid = uuid
            self.groupName = groupName
            self.playlistID = playlistID
            self.importID = importID
        }
    }

    @Model
    final class PlaylistChannelGroup {
        #Index<PlaylistChannelGroup>([\.importID, \.sortIndex], [\.importID, \.kindRawValue, \.sortIndex], [\.playlistID])

        var uuid: UUID
        var name: String
        var sortIndex: Int = 0
        var channelCount: Int = 0
        var playlistID: UUID = UUID()
        var importID: UUID = UUID()
        var kindRawValue: Int = 0
        var listedCount: Int = 0
        var seriesCount: Int = 0

        var playlist: Playlist?

        init(uuid: UUID, name: String, playlistID: UUID, importID: UUID) {
            self.uuid = uuid
            self.name = name
            self.playlistID = playlistID
            self.importID = importID
        }
    }

    @Model
    final class PlaylistSeries {
        #Index<PlaylistSeries>([\.importID, \.sortIndex], [\.importID, \.key], [\.playlistID])

        var key: String
        var title: String
        var year: Int?
        var artwork: String?
        var groupName: String
        var playlistID: UUID
        var importID: UUID
        var sortIndex: Int
        var lastSortIndex: Int
        var episodeCount: Int
        var seasonCount: Int

        init(key: String, title: String, groupName: String, playlistID: UUID, importID: UUID, sortIndex: Int, lastSortIndex: Int, episodeCount: Int, seasonCount: Int) {
            self.key = key
            self.title = title
            self.groupName = groupName
            self.playlistID = playlistID
            self.importID = importID
            self.sortIndex = sortIndex
            self.lastSortIndex = lastSortIndex
            self.episodeCount = episodeCount
            self.seasonCount = seasonCount
        }
    }

    @Model
    final class SeriesBookmark {
        #Index<SeriesBookmark>([\.playlistID], [\.isFavorite, \.favoritedOn], [\.lastWatchedAt])

        @Attribute(.unique)
        var key: String
        var playlistID: UUID
        var seriesKey: String
        var title: String
        var artwork: String?
        var groupName: String
        var isFavorite: Bool = false
        var favoritedOn: Date?
        var favoriteOrder: Double = 0
        var lastWatchedAt: Date?
        var lastEpisodeURL: URL?
        var lastSeason: Int?
        var lastEpisode: Int?
        var watchedEpisodeCodes: [String] = []

        init(key: String, playlistID: UUID, seriesKey: String, title: String, groupName: String) {
            self.key = key
            self.playlistID = playlistID
            self.seriesKey = seriesKey
            self.title = title
            self.groupName = groupName
        }
    }
}
