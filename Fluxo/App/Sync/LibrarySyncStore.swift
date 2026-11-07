//
//  LibrarySyncStore.swift
//  Fluxo
//
//  The library as iCloud sync sees it: reads the playlists, the guides the user added, favorites, watch progress
//  and a few settings into sync records, and applies the records of other devices through the same objects the
//  screens use (`PlaylistImportCenter`, `EPGStore`, `ChannelLibrary`), so a synced change behaves like one made here.
//  Nothing is added to the SwiftData schema: what links a record to a row is kept by the reconciler (`SyncLinks`).
//

import CryptoKit
import Foundation
import os
import SwiftData

@MainActor
final class LibrarySyncStore: CloudSyncLocalStore {

    private static let logger = Logger(subsystem: "dev.watermelon.Fluxo", category: "CloudSync")

    /// A setting that follows the user to every device. Device-specific ones (downloads, Picture in Picture, the
    /// foldable layouts, the Home selection) stay on each device.
    struct SyncedPreference {
        enum ValueType {
            case bool
            case int
            case string
        }

        let key: String
        let type: ValueType
    }

    static let syncedPreferences: [SyncedPreference] = [
        SyncedPreference(key: PlayerPreferences.timeShiftMinutesKey, type: .int),
        SyncedPreference(key: PlayerPreferences.skipBackwardSecondsKey, type: .int),
        SyncedPreference(key: PlayerPreferences.skipForwardSecondsKey, type: .int),
        SyncedPreference(key: TrackPreferences.audioLanguageKey, type: .string),
        SyncedPreference(key: TrackPreferences.audioDescriptionKey, type: .bool),
        SyncedPreference(key: TrackPreferences.subtitleModeKey, type: .string),
        SyncedPreference(key: TrackPreferences.subtitleLanguageKey, type: .string),
        SyncedPreference(key: TrackPreferences.subtitleAccessibilityKey, type: .bool),
        SyncedPreference(key: ReminderCenter.leadMinutesKey, type: .int),
        SyncedPreference(key: FluxoIntelligence.enabledKey, type: .bool),
        SyncedPreference(key: MatureContent.hidesAdultContentKey, type: .bool),
    ]

    /// Whether a playlist or guide of another device may be added to this device now (the first-run choice, see
    /// `CloudSync`). Changes to playlists the device already has are always applied.
    var mayAddPlaylist: (_ recordName: String) -> Bool = { _ in true }
    /// A playlist of another device was added here and its import started.
    var playlistImportStarted: (_ recordName: String, _ playlistID: UUID, _ task: Task<PlaylistImportSummary, any Error>) -> Void = { _, _, _ in }

    /// Synced playlists and guide sources that still exist but can no longer sync (an address that is not
    /// `http(s)` any more): found by the last snapshot, reported as deleted (`deletionIntents()`).
    private var unsyncableLinkedIDs: Set<UUID> = []

    private let context: ModelContext
    private let importCenter: PlaylistImportCenter
    private let library: ChannelLibrary
    private let epg: EPGStore

    init(container: ModelContainer, importCenter: PlaylistImportCenter, library: ChannelLibrary, epg: EPGStore) {
        context = container.mainContext
        self.importCenter = importCenter
        self.library = library
        self.epg = epg
    }

    private var defaults: UserDefaults {
        .fluxo
    }

    /// Only playlists and guides on the network can be read by another device (a playlist imported from a file
    /// lives in this device's container).
    static func isSyncable(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased() else {
            return false
        }
        return scheme == "http" || scheme == "https"
    }

    // MARK: - Snapshot

    func snapshot(identity: inout SyncIdentityResolver) throws -> [SyncRecordID: SyncPayload] {
        var result: [SyncRecordID: SyncPayload] = [:]
        let allPlaylists = try context.fetch(FetchDescriptor<Playlist>(sortBy: [SortDescriptor(\.createdOn)]))
        let allSources = try context.fetch(FetchDescriptor<EPGSource>(sortBy: [SortDescriptor(\.addedOn)]))
        identity.setPresent(playlists: Set(allPlaylists.map(\.uuid)), guideSources: Set(allSources.map(\.uuid)))
        var unsyncable: Set<UUID> = []

        for playlist in allPlaylists {
            guard Self.isSyncable(playlist.url) else {
                if identity.linkedPlaylistName(localID: playlist.uuid) != nil {
                    unsyncable.insert(playlist.uuid)
                }
                continue
            }
            // A playlist added here is published once its first import worked (a failed one is deleted again).
            guard identity.linkedPlaylistName(localID: playlist.uuid) != nil || playlist.currentImportID != nil else {
                continue
            }
            let name = identity.playlistName(localID: playlist.uuid, url: playlist.url)
            result[SyncRecordID(.playlist, name)] = .playlist(PlaylistPayload(name: playlist.name, url: playlist.url, createdOn: playlist.createdOn.syncRounded))
        }

        for source in allSources {
            guard source.isUserAdded, !epg.deletingSourceIDs.contains(source.uuid), Self.isSyncable(source.url) else {
                if identity.links.guideSourceName(forLocalID: source.uuid) != nil, !epg.deletingSourceIDs.contains(source.uuid) {
                    unsyncable.insert(source.uuid)
                }
                continue
            }
            let name = identity.guideSourceName(localID: source.uuid, url: source.url)
            result[SyncRecordID(.guideSource, name)] = .guideSource(GuideSourcePayload(name: source.name, url: source.url, isEnabled: source.isEnabled, addedOn: source.addedOn.syncRounded))
        }

        let bookmarks = try context.fetch(FetchDescriptor<ChannelBookmark>(predicate: #Predicate { $0.isFavorite == true || $0.lastWatchedAt != nil || $0.resumePosition > 0 }))
        for bookmark in bookmarks {
            guard let playlist = identity.linkedPlaylistName(localID: bookmark.playlistID) else {
                continue
            }
            let channel = ChannelSnapshot(
                playlist: playlist,
                url: bookmark.url,
                name: bookmark.name,
                logo: bookmark.logo,
                groupName: bookmark.groupName,
                kind: bookmark.kindRawValue,
                tvgID: bookmark.tvgID,
                episode: bookmark.episodeRef.map(EpisodeSnapshot.init)
            )
            let name = SyncIdentity.channelName(playlist: playlist, url: bookmark.url)
            if bookmark.isFavorite {
                result[SyncRecordID(.channelFavorite, name)] = .channelFavorite(ChannelFavoritePayload(channel: channel, favoritedOn: bookmark.favoritedOn?.syncRounded, order: bookmark.favoriteOrder))
            }
            if bookmark.lastWatchedAt != nil || bookmark.resumePosition > 0 {
                result[SyncRecordID(.channelProgress, name)] = .channelProgress(ChannelProgressPayload(
                    channel: channel,
                    lastWatchedAt: bookmark.lastWatchedAt?.syncRounded,
                    watchCount: bookmark.watchCount,
                    resumePosition: bookmark.resumePosition,
                    knownDuration: bookmark.knownDuration
                ))
            }
        }

        for bookmark in try context.fetch(FetchDescriptor<SeriesBookmark>()) {
            guard let playlist = identity.linkedPlaylistName(localID: bookmark.playlistID) else {
                continue
            }
            let series = SeriesSnapshot(playlist: playlist, seriesKey: bookmark.seriesKey, title: bookmark.title, artwork: bookmark.artwork, groupName: bookmark.groupName)
            let name = SyncIdentity.seriesName(playlist: playlist, seriesKey: bookmark.seriesKey)
            if bookmark.isFavorite {
                result[SyncRecordID(.seriesFavorite, name)] = .seriesFavorite(SeriesFavoritePayload(series: series, favoritedOn: bookmark.favoritedOn?.syncRounded, order: bookmark.favoriteOrder))
            }
            if Self.hasProgress(bookmark) {
                result[SyncRecordID(.seriesProgress, name)] = .seriesProgress(SeriesProgressPayload(
                    series: series,
                    lastWatchedAt: bookmark.lastWatchedAt?.syncRounded,
                    lastEpisodeURL: bookmark.lastEpisodeURL,
                    lastSeason: bookmark.lastSeason,
                    lastEpisode: bookmark.lastEpisode,
                    watchedEpisodeCodes: bookmark.watchedEpisodeCodes.sorted()
                ))
            }
        }

        for preference in Self.syncedPreferences {
            if let value = preferenceValue(preference) {
                result[SyncRecordID(.preference, preference.key)] = .preference(value)
            }
        }
        unsyncableLinkedIDs = unsyncable
        return result
    }

    // MARK: - Deletion intents

    func deletionIntents() -> SyncDeletionIntents {
        var intents = SyncDeletionJournal.intents(in: defaults)
        intents.localIDs.formUnion(unsyncableLinkedIDs)
        return intents
    }

    func forgetDeletionIntents(_ intents: SyncDeletionIntents) {
        SyncDeletionJournal.forget(intents, in: defaults)
    }

    private func preferenceValue(_ preference: SyncedPreference) -> PreferenceValue? {
        guard let object = defaults.object(forKey: preference.key) else {
            return nil
        }
        switch preference.type {
        case .bool:
            return (object as? NSNumber).map { .bool($0.boolValue) }
        case .int:
            return (object as? NSNumber).map { .int($0.intValue) }
        case .string:
            return (object as? String).map { .string($0) }
        }
    }

    private static func hasProgress(_ bookmark: SeriesBookmark) -> Bool {
        bookmark.lastWatchedAt != nil || bookmark.lastEpisodeURL != nil || !bookmark.watchedEpisodeCodes.isEmpty
    }

    // MARK: - Apply

    func apply(_ records: [SyncRecord], links: inout SyncLinks) async -> Set<SyncRecordID> {
        var deferred: Set<SyncRecordID> = []
        var bookmarksChanged = false
        var remindersChanged = false
        var playlists: [UUID: Playlist] = [:]
        var channelIndex: [String: ChannelBookmark]?
        var seriesIndex: [String: SeriesBookmark]?
        do {
            for playlist in try context.fetch(FetchDescriptor<Playlist>()) {
                playlists[playlist.uuid] = playlist
            }
        } catch {
            Self.logger.error("Could not read the playlists for sync: \(error.localizedDescription, privacy: .public)")
            return Set(records.map(\.id))
        }

        for record in records {
            let applied: Bool
            switch record.id.kind {
            case .playlist:
                applied = await applyPlaylist(record, links: &links, playlists: &playlists)
            case .guideSource:
                applied = await applyGuideSource(record, links: &links)
            case .preference:
                applied = applyPreference(record)
                remindersChanged = remindersChanged || (applied && record.id.name == ReminderCenter.leadMinutesKey)
            case .channelFavorite, .channelProgress:
                if channelIndex == nil {
                    channelIndex = makeChannelIndex(links: links)
                }
                applied = applyChannelBookmark(record, links: links, playlists: playlists, index: &channelIndex!)
                bookmarksChanged = bookmarksChanged || applied
            case .seriesFavorite, .seriesProgress:
                if seriesIndex == nil {
                    seriesIndex = makeSeriesIndex(links: links)
                }
                applied = applySeriesBookmark(record, links: links, playlists: playlists, index: &seriesIndex!)
                bookmarksChanged = bookmarksChanged || applied
            }
            if !applied {
                deferred.insert(record.id)
            }
        }

        if context.hasChanges {
            do {
                try context.save()
            } catch {
                Self.logger.error("Could not save synced changes: \(error.localizedDescription, privacy: .public)")
            }
        }
        if bookmarksChanged {
            library.reloadFromStore()
        }
        if remindersChanged {
            let reminders = epg.reminders
            Task {
                await reminders.rescheduleAll()
            }
        }
        return deferred
    }

    // MARK: Playlists

    private func applyPlaylist(_ record: SyncRecord, links: inout SyncLinks, playlists: inout [UUID: Playlist]) async -> Bool {
        let name = record.id.name
        var local = links.playlists[name].flatMap { playlists[$0] }
        if local == nil {
            // The row is gone (deleted here while the deletion was not synced yet).
            links.playlists[name] = nil
        }
        guard case .playlist(let payload) = record.payload else {
            if let local {
                delete(local)
                playlists[local.uuid] = nil
            }
            links.playlists[name] = nil
            return true
        }
        if local == nil {
            // The same playlist, added on this device too before sync was on.
            let linked = Set(links.playlists.values)
            let address = SyncIdentity.normalized(payload.url)
            local = playlists.values.first { !linked.contains($0.uuid) && SyncIdentity.normalized($0.url) == address }
            if let local {
                links.playlists[name] = local.uuid
            }
        }
        if let local {
            if local.name != payload.name {
                local.name = payload.name
            }
            if local.url != payload.url {
                // A new address (edited on another device): download it again, as editing it here does.
                local.url = payload.url
                try? context.save()
                importCenter.restartRefresh(local)
            }
            return true
        }
        guard mayAddPlaylist(name) else {
            return false
        }
        let uuid = UUID()
        do {
            let task = try await importCenter.addSyncedPlaylist(uuid: uuid, name: payload.name, url: payload.url, createdOn: payload.createdOn)
            links.playlists[name] = uuid
            playlistImportStarted(name, uuid, task)
            return true
        } catch {
            Self.logger.error("Could not add a synced playlist: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    /// What deleting a playlist from its menu does (`PlaylistManagementPresenter`), without the confirmation: it was
    /// confirmed on the device it was deleted on.
    private func delete(_ playlist: Playlist) {
        let uuid = playlist.uuid
        if PlaylistSelection(rawValue: defaults.string(forKey: PlaylistSelection.storageKey) ?? "") == .playlist(uuid) {
            defaults.set(PlaylistSelection.all.rawValue, forKey: PlaylistSelection.storageKey)
        }
        library.forgetPlaylist(uuid)
        LocalPlaylistFiles.remove(playlist.url)
        importCenter.delete(playlist)
    }

    // MARK: Guide sources

    private func applyGuideSource(_ record: SyncRecord, links: inout SyncLinks) async -> Bool {
        let name = record.id.name
        let sources: [EPGSource]
        do {
            sources = try context.fetch(FetchDescriptor<EPGSource>()).filter(\.isUserAdded)
        } catch {
            return false
        }
        var local = links.guideSources[name].flatMap { id in sources.first { $0.uuid == id } }
        if local == nil {
            links.guideSources[name] = nil
        }
        guard case .guideSource(let payload) = record.payload else {
            if let local, !epg.deletingSourceIDs.contains(local.uuid) {
                epg.deleteSource(local.uuid)
            }
            links.guideSources[name] = nil
            return true
        }
        if local == nil {
            let linked = Set(links.guideSources.values)
            let address = SyncIdentity.normalized(payload.url)
            local = sources.first { !linked.contains($0.uuid) && SyncIdentity.normalized($0.url) == address }
            if let local {
                links.guideSources[name] = local.uuid
            }
        }
        if let local {
            if local.name != payload.name {
                local.name = payload.name
            }
            if local.isEnabled != payload.isEnabled {
                epg.setEnabled(payload.isEnabled, sourceID: local.uuid)
            }
            return true
        }
        guard mayAddPlaylist(name) else {
            return false
        }
        do {
            links.guideSources[name] = try await epg.addSyncedSource(url: payload.url, name: payload.name, isEnabled: payload.isEnabled)
            return true
        } catch {
            Self.logger.error("Could not add a synced guide: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    // MARK: Preferences

    private func applyPreference(_ record: SyncRecord) -> Bool {
        guard let preference = Self.syncedPreferences.first(where: { $0.key == record.id.name }) else {
            // A setting of a newer version of the app.
            return false
        }
        switch (record.payload, preference.type) {
        case (nil, _):
            defaults.removeObject(forKey: preference.key)
        case (.preference(.bool(let value)), .bool):
            defaults.set(value, forKey: preference.key)
        case (.preference(.int(let value)), .int):
            defaults.set(value, forKey: preference.key)
        case (.preference(.string(let value)), .string):
            defaults.set(value, forKey: preference.key)
        default:
            return false
        }
        return true
    }

    // MARK: Favorites and progress

    /// Bookmarks of synced playlists by record name (the name of a deleted favorite says nothing else).
    private func makeChannelIndex(links: SyncLinks) -> [String: ChannelBookmark] {
        let playlistNames = Dictionary(links.playlists.map { ($0.value, $0.key) }, uniquingKeysWith: { first, _ in first })
        var index: [String: ChannelBookmark] = [:]
        for bookmark in (try? context.fetch(FetchDescriptor<ChannelBookmark>())) ?? [] {
            if let playlist = playlistNames[bookmark.playlistID] {
                index[SyncIdentity.channelName(playlist: playlist, url: bookmark.url)] = bookmark
            }
        }
        return index
    }

    private func makeSeriesIndex(links: SyncLinks) -> [String: SeriesBookmark] {
        let playlistNames = Dictionary(links.playlists.map { ($0.value, $0.key) }, uniquingKeysWith: { first, _ in first })
        var index: [String: SeriesBookmark] = [:]
        for bookmark in (try? context.fetch(FetchDescriptor<SeriesBookmark>())) ?? [] {
            if let playlist = playlistNames[bookmark.playlistID] {
                index[SyncIdentity.seriesName(playlist: playlist, seriesKey: bookmark.seriesKey)] = bookmark
            }
        }
        return index
    }

    private func applyChannelBookmark(_ record: SyncRecord, links: SyncLinks, playlists: [UUID: Playlist], index: inout [String: ChannelBookmark]) -> Bool {
        let name = record.id.name
        let channel: ChannelSnapshot?
        switch record.payload {
        case .channelFavorite(let favorite): channel = favorite.channel
        case .channelProgress(let progress): channel = progress.channel
        default: channel = nil
        }
        guard let channel else {
            // Removed from the favorites or the history on another device.
            guard let bookmark = index[name] else {
                return true
            }
            if record.id.kind == .channelFavorite {
                bookmark.isFavorite = false
                bookmark.favoritedOn = nil
            } else {
                bookmark.lastWatchedAt = nil
                bookmark.resumePosition = 0
            }
            if !bookmark.isFavorite && bookmark.lastWatchedAt == nil {
                context.delete(bookmark)
                index[name] = nil
            }
            return true
        }
        guard let playlistID = links.playlists[channel.playlist], playlists[playlistID] != nil else {
            // Its playlist is not on this device (yet).
            return false
        }
        let bookmark: ChannelBookmark
        if let existing = index[name] {
            bookmark = existing
        } else {
            let key = ChannelBookmark.key(playlistID: playlistID, url: channel.url)
            bookmark = ChannelBookmark(
                key: key,
                playlistID: playlistID,
                url: channel.url,
                channelID: Self.stableID(for: key),
                name: channel.name,
                logo: channel.logo,
                groupName: channel.groupName,
                kind: ChannelContentKind(rawValue: channel.kind) ?? .live
            )
            context.insert(bookmark)
            index[name] = bookmark
        }
        bookmark.name = channel.name
        bookmark.logo = channel.logo
        bookmark.groupName = channel.groupName
        bookmark.kindRawValue = channel.kind
        bookmark.tvgID = channel.tvgID
        if let episode = channel.episode {
            bookmark.setEpisode(EpisodeRef(seriesKey: episode.seriesKey, seriesTitle: episode.seriesTitle, season: episode.season, episode: episode.episode, episodeTitle: episode.episodeTitle))
        }
        switch record.payload {
        case .channelFavorite(let favorite):
            bookmark.isFavorite = true
            bookmark.favoritedOn = favorite.favoritedOn
            bookmark.favoriteOrder = favorite.order
        case .channelProgress(let progress):
            bookmark.lastWatchedAt = progress.lastWatchedAt
            bookmark.watchCount = progress.watchCount
            bookmark.resumePosition = progress.resumePosition
            bookmark.knownDuration = progress.knownDuration
        default:
            break
        }
        return true
    }

    private func applySeriesBookmark(_ record: SyncRecord, links: SyncLinks, playlists: [UUID: Playlist], index: inout [String: SeriesBookmark]) -> Bool {
        let name = record.id.name
        let series: SeriesSnapshot?
        switch record.payload {
        case .seriesFavorite(let favorite): series = favorite.series
        case .seriesProgress(let progress): series = progress.series
        default: series = nil
        }
        guard let series else {
            guard let bookmark = index[name] else {
                return true
            }
            if record.id.kind == .seriesFavorite {
                bookmark.isFavorite = false
                bookmark.favoritedOn = nil
            } else {
                bookmark.lastWatchedAt = nil
                bookmark.lastEpisodeURL = nil
                bookmark.lastSeason = nil
                bookmark.lastEpisode = nil
                bookmark.watchedEpisodeCodes = []
            }
            if !bookmark.isFavorite && !Self.hasProgress(bookmark) {
                context.delete(bookmark)
                index[name] = nil
            }
            return true
        }
        guard let playlistID = links.playlists[series.playlist], playlists[playlistID] != nil else {
            return false
        }
        let bookmark: SeriesBookmark
        if let existing = index[name] {
            bookmark = existing
        } else {
            bookmark = SeriesBookmark(
                key: SeriesBookmark.key(playlistID: playlistID, seriesKey: series.seriesKey),
                playlistID: playlistID,
                seriesKey: series.seriesKey,
                title: series.title,
                artwork: series.artwork,
                groupName: series.groupName
            )
            context.insert(bookmark)
            index[name] = bookmark
        }
        bookmark.title = series.title
        if let artwork = series.artwork {
            bookmark.artwork = artwork
        }
        bookmark.groupName = series.groupName
        switch record.payload {
        case .seriesFavorite(let favorite):
            bookmark.isFavorite = true
            bookmark.favoritedOn = favorite.favoritedOn
            bookmark.favoriteOrder = favorite.order
        case .seriesProgress(let progress):
            bookmark.lastWatchedAt = progress.lastWatchedAt
            bookmark.lastEpisodeURL = progress.lastEpisodeURL
            bookmark.lastSeason = progress.lastSeason
            bookmark.lastEpisode = progress.lastEpisode
            bookmark.watchedEpisodeCodes = progress.watchedEpisodeCodes
        default:
            break
        }
        return true
    }

    /// The channel ID of a bookmark created by sync, the same on every pass (the channel row of this device is not
    /// looked up: that would read the whole playlist; playing the channel sets the row's ID).
    private static func stableID(for key: String) -> UUID {
        let bytes = Array(SHA256.hash(data: Data(key.utf8)).prefix(16))
        return UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
                           bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]))
    }
}

private extension EpisodeSnapshot {
    init(_ ref: EpisodeRef) {
        self.init(seriesKey: ref.seriesKey, seriesTitle: ref.seriesTitle, season: ref.season, episode: ref.episode, episodeTitle: ref.episodeTitle)
    }
}
