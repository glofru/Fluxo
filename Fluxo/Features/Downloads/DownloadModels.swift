//
//  DownloadModels.swift
//  Fluxo
//
//  The values of offline downloads: what was downloaded (a snapshot of the playlist entry, so a download plays and
//  shows its artwork, series and episode with no network and after the playlist changed), how (HLS, a file, or a
//  file copied into MP4), and where it is in its life (queued, downloading, paused, converting, done, failed).
//
//  Records are kept in one JSON manifest (`DownloadCenter`), not in SwiftData: they describe files on disk, and
//  must survive anything that happens to the library store (a reset, a failed migration, an isolated debug store).
//

import Foundation

/// How a download is fetched and stored.
enum DownloadMethod: String, Codable, Sendable {
    /// An HLS stream, through `AVAssetDownloadURLSession`: a `.movpkg` that stays where AVFoundation puts it, with
    /// the chosen variant, audio renditions and subtitles.
    case hls
    /// A file AVPlayer plays as it is (MP4, MOV, M4V, MP3, M4A…), through a background `URLSession`.
    case file
    /// A file AVPlayer cannot play (Matroska, MPEG-TS, FLV, MPEG-PS, AVI…): downloaded like `file`, then copied into
    /// an MP4 by the remux engine (what AVPlayer cannot decode is converted), so it plays and seeks like any local file.
    case remux
}

/// Where a download is in its life. Stored in the manifest.
enum DownloadStatus: String, Codable, Sendable {
    /// Waiting for one of the transfer slots.
    case queued
    /// Finding out what the link is (HLS or a file, its size) and starting the transfer.
    case preparing
    case downloading
    /// Stopped by the user; resumes where it stopped.
    case paused
    /// Downloaded; being copied into MP4.
    case converting
    case completed
    /// Stopped by an error (`DownloadRecord.failure`); Retry starts again where it stopped, when it can.
    case failed

    /// Uses a transfer slot or waits for one: counts as "downloading" in the Library.
    var isActive: Bool {
        switch self {
        case .queued, .preparing, .downloading, .converting:
            return true
        case .paused, .completed, .failed:
            return false
        }
    }

    /// Not finished: shown with its progress and transfer actions.
    var isPending: Bool {
        self != .completed
    }
}

/// The video quality HLS downloads choose (other links have a single quality). A Setting.
enum DownloadQuality: String, CaseIterable, Identifiable, Sendable {
    /// The highest the stream offers.
    case best
    /// Up to 1080p.
    case high
    /// Up to 720p.
    case standard
    /// Up to 480p, the smallest files.
    case dataSaver

    var id: String {
        rawValue
    }

    /// The tallest picture chosen, in pixels; nil for the best the stream offers.
    var maximumHeight: Int? {
        switch self {
        case .best:
            return nil
        case .high:
            return 1080
        case .standard:
            return 720
        case .dataSaver:
            return 480
        }
    }

    var title: String {
        switch self {
        case .best:
            return String(localized: "DownloadQuality.best", defaultValue: "Best Available", comment: "Download quality setting: the highest quality the stream offers.")
        case .high:
            return String(localized: "DownloadQuality.high", defaultValue: "High (1080p)", comment: "Download quality setting: up to 1080p.")
        case .standard:
            return String(localized: "DownloadQuality.standard", defaultValue: "Standard (720p)", comment: "Download quality setting: up to 720p.")
        case .dataSaver:
            return String(localized: "DownloadQuality.dataSaver", defaultValue: "Data Saver (480p)", comment: "Download quality setting: up to 480p, the smallest files.")
        }
    }
}

/// A snapshot of the downloaded playlist entry (`ChannelItem`), stored in the manifest.
struct DownloadedItem: Codable, Hashable, Sendable {
    let id: UUID
    let playlistID: UUID
    let name: String?
    /// The entry's artwork as the playlist gives it (an http URL or a `data:` URI); the download keeps a copy of
    /// its own (`DownloadRecord.artworkFileName`).
    let logo: String?
    let url: URL
    let groupName: String
    let kindRawValue: Int
    let tvgID: String?
    let number: Int?
    let seriesKey: String?
    let seriesTitle: String?
    let season: Int?
    let episode: Int?
    let episodeTitle: String?

    init?(_ item: ChannelItem) {
        guard let url = item.url else {
            return nil
        }
        id = item.id
        playlistID = item.playlistID
        name = item.name
        // A data URI can be tens of KB: the copy on disk stands for it.
        logo = item.logo?.hasPrefix("data:") == true ? nil : item.logo
        self.url = url
        groupName = item.groupName
        kindRawValue = item.kind.rawValue
        tvgID = item.tvgID
        number = item.number
        seriesKey = item.series?.seriesKey
        seriesTitle = item.series?.seriesTitle
        season = item.series?.season
        episode = item.series?.episode
        episodeTitle = item.series?.episodeTitle
    }

    var kind: ChannelContentKind {
        ChannelContentKind(rawValue: kindRawValue) ?? .movie
    }

    var series: EpisodeRef? {
        guard let seriesKey, let seriesTitle, let episode else {
            return nil
        }
        return EpisodeRef(seriesKey: seriesKey, seriesTitle: seriesTitle, season: season, episode: episode, episodeTitle: episodeTitle)
    }

    /// The entry, to play it (its bookmark key, so its resume position and watched state, are the playlist entry's).
    func channelItem(logo artwork: String?) -> ChannelItem {
        ChannelItem(id: id, playlistID: playlistID, name: name, logo: artwork ?? logo, url: url, groupName: groupName, kind: kind, tvgID: tvgID, number: number, series: series)
    }

    var key: String {
        ChannelBookmark.key(playlistID: playlistID, url: url)
    }
}

/// One download, as the manifest stores it.
struct DownloadRecord: Codable, Identifiable, Hashable, Sendable {
    let id: UUID
    var item: DownloadedItem
    var status: DownloadStatus
    /// nil until the link was probed.
    var method: DownloadMethod?
    let addedOn: Date
    var completedOn: Date?
    /// The last progress seen (0...1), for the list while the transfer is not reporting (paused, relaunched).
    var fraction: Double = 0
    var bytesWritten: Int64 = 0
    /// The size announced by the server, or estimated from the HLS variant's bit rate and the duration.
    var bytesExpected: Int64?
    /// The size on disk once completed.
    var bytesOnDisk: Int64 = 0
    /// Why it failed, in the user's language at the time.
    var failure: String?
    /// Retrying cannot help (the format cannot be played, the link is not a video): Retry is not offered.
    var failureIsPermanent = false
    /// The media: for `.hls` the `.movpkg` path relative to the home directory (the container moves between
    /// launches and updates); for files the file name in the download's own folder.
    var location: String?
    /// The file name the transfer writes, in the download's folder ("source.mkv", "media.mp4").
    var transferFileName: String?
    /// The artwork kept with the download (in its folder), so it shows offline.
    var artworkFileName: String?
    var duration: TimeInterval?
    /// "1080p", for HLS downloads with several qualities.
    var qualityLabel: String?
    /// The audio languages and subtitles downloaded with an HLS stream, as shown names ("English", "Italiano").
    var audioNames: [String] = []
    var subtitleNames: [String] = []
    /// The transfer may use cellular data (the setting when it started or resumed).
    var allowsCellular = false
    /// Automatic retries after network failures, since the last start by the user.
    var automaticRetries = 0
    /// Played to the end (for "Delete Watched Downloads").
    var watchedOn: Date?
    /// The system removed the media (storage pressure) or it went missing: it can be downloaded again.
    var isMissing = false

    var key: String {
        item.key
    }

    var title: String {
        if let series = item.series {
            return series.seriesTitle
        }
        guard let name = item.name, !name.isEmpty else {
            return String(localized: "No channel name", comment: "Shown instead of the name of a channel that has none.")
        }
        return name
    }

    /// For an episode: "S1 E3 · Pilot"; otherwise nil.
    var episodeLine: String? {
        item.series.map { TextParts.line([EpisodeFormat.code($0), $0.episodeTitle]) }
    }

    /// The series an episode belongs to, for grouping.
    var seriesID: String? {
        item.seriesKey.map { "\(item.playlistID.uuidString)|\($0)" }
    }

    /// The size to show: on disk once complete, otherwise what is expected.
    var displayBytes: Int64 {
        status == .completed ? bytesOnDisk : max(bytesWritten, bytesExpected ?? 0)
    }
}

/// Why a download could not start, shown in an alert.
struct DownloadNotice: Identifiable, Equatable {
    let id = UUID()
    let title: String
    let message: String
}
