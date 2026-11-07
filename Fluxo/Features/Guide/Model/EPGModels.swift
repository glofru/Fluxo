//
//  EPGModels.swift
//  Fluxo
//
//  Created by Gianluca Lofrumento on 2026-11-02.
//

import Foundation
import SwiftData

/// An XMLTV guide that Fluxo downloads: either announced by a playlist header (`url-tvg` / `x-tvg-url`) or
/// added by the user in Settings.
///
/// Like playlists, the channels and programmes of a source are tagged with the `importID` of the download that
/// wrote them, and only rows whose `importID` equals `currentImportID` are read. A refresh writes a complete new
/// copy and switches over when it is stored, so a failed or cancelled refresh keeps the previous guide.
@Model
final class EPGSource {
    #Index<EPGSource>([\.playlistID])

    @Attribute(.unique)
    private(set) var uuid: UUID
    var url: URL
    var name: String
    /// Playlist whose header listed this guide; nil for a guide the user added.
    var playlistID: UUID?
    var isEnabled: Bool = true
    private(set) var addedOn: Date

    var currentImportID: UUID?
    var lastRefreshedOn: Date?
    var lastAttemptOn: Date?
    /// Why the last refresh failed, as a `GuideRefreshFailure` code (shown with `lastErrorMessage`); cleared
    /// by a successful one.
    var lastError: String?
    /// Channels listed by the file.
    var channelCount: Int = 0
    /// "<SHA-256 of the last file>|<fingerprint of the wanted channels>" of the last complete import: an
    /// unchanged guide is not read again for the same channels.
    var contentHash: String?
    /// HTTP validators of the last complete download, for a conditional request (`If-None-Match`,
    /// `If-Modified-Since`): an unchanged guide is then not even downloaded.
    var entityTag: String?
    var lastModifiedHeader: String?
    /// Channels whose programmes were stored (the ones that match a playlist channel).
    var storedChannelCount: Int = 0
    var programmeCount: Int = 0

    init(uuid: UUID = UUID(), url: URL, name: String, playlistID: UUID?, addedOn: Date = .now) {
        self.uuid = uuid
        self.url = url
        self.name = name
        self.playlistID = playlistID
        self.addedOn = addedOn
    }

    var isUserAdded: Bool {
        playlistID == nil
    }
}

/// A `<channel>` of an XMLTV guide.
@Model
final class EPGChannel {
    #Index<EPGChannel>([\.importID], [\.sourceID])

    var sourceID: UUID
    var importID: UUID
    /// The XMLTV `id` attribute, as written in the file (programmes refer to it).
    var channelID: String
    var displayName: String
    /// Further `<display-name>`s, newline-separated.
    var otherNames: String = ""
    var icon: String?
    /// Whether the programmes of this channel were stored (only channels that match a playlist channel are).
    var hasProgrammes: Bool = false

    init(sourceID: UUID, importID: UUID, channelID: String, displayName: String, otherNames: String, icon: String?, hasProgrammes: Bool) {
        self.sourceID = sourceID
        self.importID = importID
        self.channelID = channelID
        self.displayName = displayName
        self.otherNames = otherNames
        self.icon = icon
        self.hasProgrammes = hasProgrammes
    }
}

/// A `<programme>` of an XMLTV guide, kept only inside the guide window (6 hours back, 7 days ahead).
///
/// Indexes: what a channel shows (`importID`, `channelID`, `start`; its `importID` prefix also serves the deletes of an
/// import, so `importID` has no index of its own: every index costs time on each of the hundreds of thousands of
/// inserts of a guide), the prune of ended programmes (`stop`) and what is on now (`start`).
@Model
final class EPGProgramme {
    #Index<EPGProgramme>([\.importID, \.channelID, \.start], [\.stop], [\.start])

    var sourceID: UUID
    var importID: UUID
    var channelID: String
    var start: Date
    var stop: Date
    var title: String
    var subtitle: String = ""
    /// `<desc>`.
    var summary: String = ""
    /// `<category>` values, newline-separated.
    var categories: String = ""
    var icon: String?
    /// Season / episode as the guide's `onscreen` text, or "S2 E5" / "E5" / "S2" from its `xmltv_ns` numbers
    /// (stored in that language-independent form, and localized by `GuideFormat.episode(_:)` when shown).
    var episode: String?

    init(
        sourceID: UUID,
        importID: UUID,
        channelID: String,
        start: Date,
        stop: Date,
        title: String,
        subtitle: String,
        summary: String,
        categories: String,
        icon: String?,
        episode: String?
    ) {
        self.sourceID = sourceID
        self.importID = importID
        self.channelID = channelID
        self.start = start
        self.stop = stop
        self.title = title
        self.subtitle = subtitle
        self.summary = summary
        self.categories = categories
        self.icon = icon
        self.episode = episode
    }
}

/// The guide channel the user picked for a playlist channel, overriding the automatic match.
///
/// Keyed like `ChannelBookmark` (playlist + stream URL), because channel rows get new UUIDs on every refresh.
/// An empty `channelID` means "no guide for this channel".
@Model
final class EPGChannelOverride {
    #Index<EPGChannelOverride>([\.playlistID])

    /// `ChannelBookmark.key(playlistID:url:)`.
    @Attribute(.unique)
    private(set) var key: String
    private(set) var playlistID: UUID
    var sourceID: UUID?
    var channelID: String
    var updatedOn: Date

    init(key: String, playlistID: UUID, sourceID: UUID?, channelID: String) {
        self.key = key
        self.playlistID = playlistID
        self.sourceID = sourceID
        self.channelID = channelID
        self.updatedOn = .now
    }
}

/// A reminder for a programme: a local notification fires `ReminderCenter.leadMinutes` before it starts, and
/// tapping it plays the channel. The channel is kept as a snapshot so the reminder survives guide and playlist
/// refreshes.
@Model
final class ProgrammeReminder {
    #Index<ProgrammeReminder>([\.start])

    /// `GuideProgramme.reminderKey`; also the notification request identifier.
    @Attribute(.unique)
    private(set) var key: String
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

    init(key: String, programme: GuideProgramme, channel: ChannelItem, channelURL: URL, fireDate: Date) {
        self.key = key
        self.title = programme.title
        self.subtitle = programme.subtitle
        self.start = programme.start
        self.stop = programme.stop
        self.fireDate = fireDate
        self.playlistID = channel.playlistID
        self.channelURL = channelURL
        self.channelUUID = channel.id
        self.channelName = channel.name
        self.channelLogo = channel.logo
        self.groupName = channel.groupName
        self.tvgID = channel.tvgID
    }

    var channel: ChannelItem {
        ChannelItem(id: channelUUID, playlistID: playlistID, name: channelName, logo: channelLogo, url: channelURL, groupName: groupName, kind: .live, tvgID: tvgID)
    }
}
