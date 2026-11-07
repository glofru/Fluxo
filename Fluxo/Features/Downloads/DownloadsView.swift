//
//  DownloadsView.swift
//  Fluxo
//
//  The lists of offline downloads:
//
//  - `LibraryDownloadsSections`: in the Library tab, between Favorites / Recently Watched and the recordings (what the
//    user chose to keep comes before what was recorded live): the transfers in progress, then the downloaded movies
//    and series (a series is one row with its episodes behind it), the first few with See All.
//  - `DownloadsView`: every download (See All of the Library, and the Downloads entry of the Mac sidebar).
//  - `DownloadedSeriesView`: the downloaded episodes of a series, by season.
//
//  A downloaded row plays with a tap (from the file, offline too, where it stopped); swipes pause, resume and
//  delete; the context menu has every action. `OfflineHomeSection` puts the downloads at the top of Home when the
//  device is offline.
//

import SwiftUI

// MARK: - Library

/// The downloads in the Library: the transfers in progress, then the downloaded items. Nothing without downloads.
struct LibraryDownloadsSections: View {

    /// Downloaded rows shown before See All.
    static let limit = 5

    @Environment(DownloadCenter.self) private var downloads: DownloadCenter?
    @State private var prompts = DownloadPrompts()

    var body: some View {
        if let downloads, downloads.hasDownloads {
            DownloadsSections(downloads: downloads, limit: Self.limit, prompts: $prompts)
                .downloadPrompts($prompts, downloads: downloads)
        }
    }
}

/// The sections of a list of downloads: "Downloading" (the transfers, queued and paused ones), "Couldn't Download"
/// (the failed ones, each with its reason; Retry All) and "Downloads".
private struct DownloadsSections: View {
    let downloads: DownloadCenter
    /// Downloaded groups shown before See All (nil: all of them).
    let limit: Int?
    @Binding var prompts: DownloadPrompts

    var body: some View {
        let pending = downloads.records.filter { $0.status.isPending && $0.status != .failed }
        let failed = downloads.records.filter { $0.status == .failed }
        let groups = downloads.completedGroups()
        let shown = limit.map { Array(groups.prefix($0)) } ?? groups

        if !pending.isEmpty {
            Section {
                ForEach(pending) { record in
                    DownloadRow(record: record, prompts: $prompts)
                }
            } header: {
                HStack {
                    Text("Downloading", comment: "Header of the downloads in progress.")
                    Spacer()
                    if downloads.activeCount > 0 {
                        Button(String(localized: "Pause All", comment: "Pauses every download in progress.")) {
                            downloads.pauseAll()
                        }
                        .font(.footnote.weight(.semibold))
                        .textCase(nil)
                    } else if downloads.pausedCount > 0 {
                        Button(String(localized: "Resume All", comment: "Resumes every paused download.")) {
                            downloads.resumeAll()
                        }
                        .font(.footnote.weight(.semibold))
                        .textCase(nil)
                    }
                }
            } footer: {
                if groups.isEmpty && failed.isEmpty {
                    DownloadsFooter(downloads: downloads)
                }
            }
        }

        if !failed.isEmpty {
            Section {
                ForEach(failed) { record in
                    DownloadRow(record: record, prompts: $prompts)
                }
            } header: {
                // At the accessibility sizes Retry All goes under the header, which keeps the width.
                AdaptiveStack(spacing: 4) {
                    Text("Couldn't Download", comment: "Header of the downloads that stopped with an error (each row says why).")
                    Spacer(minLength: 0)
                    if downloads.retryableFailedCount > 1 {
                        Button(String(localized: "Retry All", comment: "Starts every failed download again.")) {
                            downloads.retryAllFailed()
                        }
                        .font(.footnote.weight(.semibold))
                        .textCase(nil)
                    }
                }
            } footer: {
                if groups.isEmpty {
                    DownloadsFooter(downloads: downloads)
                }
            }
        }

        if !groups.isEmpty {
            Section {
                ForEach(shown) { group in
                    switch group {
                    case .single(let record):
                        DownloadRow(record: record, prompts: $prompts)
                    case let .series(_, title, records):
                        DownloadSeriesRow(title: title, records: records, downloads: downloads, prompts: $prompts)
                    }
                }
                if let limit, groups.count > limit {
                    NavigationLink(value: ChannelRoute.downloads) {
                        Text(String(localized: "See All Downloads (\(groups.count))", comment: "Library: opens every download; the placeholder is how many movies and series are downloaded."))
                    }
                }
            } header: {
                Text(DownloadText.downloads)
            } footer: {
                DownloadsFooter(downloads: downloads)
            }
        }
    }
}

/// "12 downloads · 8.4 GB · 41 GB free".
struct DownloadsFooter: View {
    let downloads: DownloadCenter

    var body: some View {
        Text(TextParts.line([
            downloads.completedCount == 0 ? nil : String(localized: "\(downloads.completedCount) downloads", comment: "How many movies and episodes are downloaded, followed by their size (the footer of the downloads list, also with the free space, and Settings)."),
            downloads.totalBytes > 0 ? DownloadText.bytes(downloads.totalBytes) : nil,
            downloads.availableBytes.map { String(localized: "\(DownloadText.bytes($0)) free", comment: "Free space on the device, in the downloads footer; the placeholder is a size such as 41 GB.") },
        ]))
    }
}

// MARK: - Screens

/// Every download, with the transfers first. See All of the Library; Downloads in the Mac sidebar.
struct DownloadsView: View {

    @Environment(DownloadCenter.self) private var downloads: DownloadCenter?
    @State private var prompts = DownloadPrompts()

    var body: some View {
        Group {
            if let downloads, downloads.hasDownloads {
                List {
                    DownloadsSections(downloads: downloads, limit: nil, prompts: $prompts)
                }
                #if os(iOS)
                .listStyle(.insetGrouped)
                #endif
                .toolbar {
                    ToolbarItem(placement: .primaryAction) {
                        DownloadsMoreMenu(downloads: downloads, prompts: $prompts)
                    }
                }
                .downloadPrompts($prompts, downloads: downloads)
            } else {
                DownloadsEmptyState()
            }
        }
        .navigationTitle(Text(DownloadText.downloads))
        .largeTitleAdaptingToTextSize()
    }
}

/// The downloaded episodes of a series, by season, with the way to the series page.
struct DownloadedSeriesView: View {
    let playlistID: UUID
    let seriesKey: String
    let title: String

    @Environment(DownloadCenter.self) private var downloads: DownloadCenter?
    @State private var prompts = DownloadPrompts()

    var body: some View {
        let records = downloads?.records(ofSeries: playlistID, key: seriesKey) ?? []
        let seasons = Array(Set(records.compactMap { $0.item.series?.code.season })).sorted()
        Group {
            if let downloads, !records.isEmpty {
                List {
                    ForEach(seasons, id: \.self) { season in
                        Section {
                            ForEach(records.filter { $0.item.series?.code.season == season }) { record in
                                DownloadRow(record: record, prompts: $prompts, showsSeriesTitle: false)
                            }
                        } header: {
                            Text(EpisodeFormat.seasonTitle(season))
                        }
                    }
                    Section {
                        NavigationLink(value: ChannelRoute.series(playlistID: playlistID, key: seriesKey, title: title)) {
                            Label(String(localized: "All Episodes", comment: "Downloads of a series: opens the series page with every episode."), systemImage: "square.stack")
                        }
                    } footer: {
                        Text(TextParts.line([
                            String(localized: "\(records.filter { $0.status == .completed }.count) episodes downloaded", comment: "Footer of the downloads of a series; the placeholder is a number."),
                            DownloadText.bytes(records.reduce(0) { $0 + $1.displayBytes }),
                        ]))
                    }
                }
                #if os(iOS)
                .listStyle(.insetGrouped)
                #endif
                .toolbar {
                    ToolbarItem(placement: .primaryAction) {
                        Menu {
                            Button(String(localized: "Delete All Episodes…", comment: "Downloads of a series: deletes every downloaded episode of the series (after a confirmation)."), systemImage: "trash", role: .destructive) {
                                prompts.recordsToDelete = records.map(\.id)
                            }
                        } label: {
                            Label(String(localized: "More", comment: "Toolbar menu with more actions."), systemImage: "ellipsis")
                        }
                    }
                }
                .downloadPrompts($prompts, downloads: downloads)
            } else {
                DownloadsEmptyState()
            }
        }
        .navigationTitle(title)
        .inlineNavigationBar()
    }
}

/// "No Downloads", and how to make one.
struct DownloadsEmptyState: View {
    var body: some View {
        ContentUnavailableView {
            Label(String(localized: "No Downloads", comment: "Empty state of the downloads list."), systemImage: "arrow.down.circle")
        } description: {
            Text("Movies and episodes you download play without an internet connection. Use Download in their menu, or on a series page.", comment: "Empty state of the downloads list: how to download.")
        }
    }
}

/// Pause All, Resume All, Delete Watched and Delete All.
struct DownloadsMoreMenu: View {
    let downloads: DownloadCenter
    @Binding var prompts: DownloadPrompts

    var body: some View {
        Menu {
            if downloads.activeCount > 0 {
                Button(String(localized: "Pause All", comment: "Pauses every download in progress."), systemImage: "pause.circle") {
                    downloads.pauseAll()
                }
            }
            if downloads.pausedCount > 0 {
                Button(String(localized: "Resume All", comment: "Resumes every paused download."), systemImage: "arrow.down.circle") {
                    downloads.resumeAll()
                }
            }
            if downloads.watchedCount > 0 {
                Button(String(localized: "Delete Watched Downloads", comment: "Deletes the downloads that were played to the end."), systemImage: "eye.slash") {
                    downloads.deleteWatched(onlyIfIdle: true)
                }
            }
            Divider()
            Button(String(localized: "Delete All Downloads…", comment: "Deletes every download (after a confirmation)."), systemImage: "trash", role: .destructive) {
                prompts.recordsToDelete = downloads.records.map(\.id)
            }
            .disabled(!downloads.hasDownloads)
        } label: {
            Label(String(localized: "More", comment: "Toolbar menu with more actions."), systemImage: "ellipsis")
        }
    }
}

// MARK: - Rows

/// A download: its artwork, title, episode, and its state (a progress bar and the size while it downloads; the
/// size, quality and languages once downloaded). A tap plays a downloaded item.
struct DownloadRow: View {
    let record: DownloadRecord
    @Binding var prompts: DownloadPrompts
    /// The series title above an episode (off in a series' own list).
    var showsSeriesTitle = true

    @Environment(DownloadCenter.self) private var downloads: DownloadCenter?
    @Environment(ChannelLibrary.self) private var library
    @Environment(\.playChannel) private var playChannel
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @ScaledMetric(relativeTo: .body) private var artworkWidth: CGFloat = 44
    @ScaledMetric(relativeTo: .title2) private var iconSize: CGFloat = 26

    private var isPlayable: Bool {
        record.status == .completed && !record.isMissing
    }

    /// The poster grows with the text up to 80 points, so at the largest sizes the title keeps the room it needs.
    private var posterWidth: CGFloat {
        min(artworkWidth, 80)
    }

    /// A failed download has Retry next to its menu, so less room: its title may take two lines.
    private var titleLineLimit: Int {
        if dynamicTypeSize.prefersStackedLayout {
            return 4
        }
        return record.status == .failed && !record.failureIsPermanent ? 2 : 1
    }

    var body: some View {
        if let downloads {
            let item = downloads.playableItem(for: record)
            let progress = record.status.isPending ? downloads.progress(for: record) : nil
            // At the accessibility sizes Retry and the menu go under the text, which keeps the row's width.
            AdaptiveStack(spacing: 12) {
                Button {
                    if isPlayable {
                        playChannel(item)
                    }
                } label: {
                    rowContent(item: item, downloads: downloads, progress: progress)
                }
                .buttonStyle(.plain)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(Text(accessibilityLabel(item: item, downloads: downloads, progress: progress)))
                .accessibilityHint(isPlayable ? Text("Plays the download", comment: "VoiceOver hint of a downloaded movie or episode.") : Text(verbatim: ""))
                .accessibilityAddTraits(isPlayable ? .isButton : [])

                HStack(spacing: 12) {
                    if record.status == .failed && !record.failureIsPermanent {
                        // Retry in sight, not only in the menu and the swipe actions.
                        Button {
                            downloads.retry(record.id)
                        } label: {
                            Image(systemName: "arrow.clockwise")
                                .font(.system(size: iconSize * 0.7, weight: .semibold))
                                .frame(width: iconSize + 14, height: iconSize + 14)
                                .contentShape(.rect)
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.tint)
                        .accessibilityLabel(Text(DownloadText.retry))
                        .help(DownloadText.retry)
                    }

                    Menu {
                        menuItems(item: item, downloads: downloads)
                    } label: {
                        Group {
                            if isPlayable {
                                // Downloaded: the row plays; this is only the menu of its actions.
                                Image(systemName: "ellipsis.circle")
                                    .font(.system(size: iconSize * 0.85))
                                    .foregroundStyle(Theme.secondaryText)
                            } else {
                                DownloadStateIcon(record: record, progress: progress, size: iconSize)
                            }
                        }
                        .frame(width: iconSize + 14, height: iconSize + 14)
                        .contentShape(.rect)
                    }
                    .menuIndicator(.hidden)
                    .buttonStyle(.plain)
                    .accessibilityLabel(Text(String(localized: "Download Actions", comment: "VoiceOver label of the menu of a download (pause, resume, delete).")))
                }
            }
            .contentShape(.rect)
            .rowSwipeActions(edge: .trailing) {
                Button(record.status == .completed ? DownloadText.delete : DownloadText.cancel, systemImage: "trash", role: .destructive) {
                    prompts.recordsToDelete = [record.id]
                }
            }
            .rowSwipeActions(edge: .leading) {
                if record.status.isActive && record.status != .converting {
                    Button(DownloadText.pause, systemImage: "pause.fill") {
                        downloads.pause(record.id)
                    }
                    .tint(Theme.secondaryText)
                } else if record.status == .paused || (record.status == .failed && !record.failureIsPermanent) {
                    Button(record.status == .paused ? DownloadText.resume : DownloadText.retry, systemImage: "arrow.down") {
                        downloads.retry(record.id)
                    }
                    .tint(Theme.accentFill)
                }
            }
            .contextMenu {
                menuItems(item: item, downloads: downloads)
            }
            .accessibilityActions {
                menuItems(item: item, downloads: downloads)
            }
        }
    }

    @ViewBuilder
    private func menuItems(item: ChannelItem, downloads: DownloadCenter) -> some View {
        if isPlayable {
            if library.watchProgress(for: item) != nil {
                Button(String(localized: "Resume", comment: "Menu item: resumes a movie or episode where it stopped."), systemImage: "play.fill") {
                    playChannel(item)
                }
                Button(String(localized: "Play from Beginning", comment: "Menu item: plays a movie or episode from its start."), systemImage: "arrow.counterclockwise") {
                    library.saveWatchProgress(for: item, position: 0, duration: library.watchProgress(for: item)?.duration ?? 1)
                    playChannel(item)
                }
            } else {
                Button(String(localized: "Play", comment: "Menu item: plays a movie or episode."), systemImage: "play.fill") {
                    playChannel(item)
                }
            }
            Divider()
        }
        if record.status == .completed {
            if record.isMissing {
                Button(DownloadText.downloadAgain, systemImage: "arrow.down.circle") {
                    downloads.retry(record.id)
                }
            }
            Button(DownloadText.delete, systemImage: "trash", role: .destructive) {
                prompts.recordsToDelete = [record.id]
            }
        } else {
            DownloadRecordMenuItems(downloads: downloads, record: record) {}
        }
    }

    /// At the accessibility sizes the poster goes above the text, which keeps the whole width of the row.
    private func rowContent(item: ChannelItem, downloads: DownloadCenter, progress: DownloadProgress?) -> some View {
        AdaptiveStack(spacing: dynamicTypeSize.prefersStackedLayout ? 8 : 12) {
            ChannelArtwork(logo: item.logo, name: record.title, kind: record.item.kind == .live ? .movie : record.item.kind, size: CGSize(width: posterWidth, height: posterWidth * 1.5))
                .frame(width: posterWidth, height: posterWidth * 1.5)
                .background(Color.artworkPlaceholder.opacity(0.4))
                .clipShape(.rect(cornerRadius: 6, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(Theme.surfaceStroke)
                }
                .opacity(isPlayable || record.status.isPending ? 1 : 0.6)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 3) {
                if showsSeriesTitle || record.item.series == nil {
                    Text(record.title)
                        .font(.headline)
                        .lineLimit(titleLineLimit)
                }
                if let episode = record.episodeLine {
                    Text(episode)
                        .font(showsSeriesTitle ? .subheadline : .headline)
                        .foregroundStyle(showsSeriesTitle ? Theme.secondaryText : Color.primary)
                        .lineLimit(titleLineLimit)
                }
                DownloadStatusLine(record: record, progress: progress, waiting: downloads.waitingReason(for: record), watchProgress: library.watchProgress(for: item))
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .contentShape(.rect)
    }

    private func accessibilityLabel(item: ChannelItem, downloads: DownloadCenter, progress: DownloadProgress?) -> String {
        TextParts.spoken([
            record.title,
            record.item.series.map(EpisodeFormat.spokenCode),
            record.item.series?.episodeTitle,
            downloads.waitingReason(for: record) ?? DownloadText.state(of: record, fraction: progress?.fraction),
            record.status == .failed ? record.failureMessage : nil,
            record.status == .completed ? DownloadText.bytes(record.bytesOnDisk) : nil,
            library.watchProgress(for: item).map(WatchProgressFormat.remaining),
        ])
    }
}

/// The state under a download's title.
private struct DownloadStatusLine: View {
    let record: DownloadRecord
    let progress: DownloadProgress?
    let waiting: String?
    let watchProgress: WatchProgress?

    var body: some View {
        switch record.status {
        case .queued, .preparing, .downloading, .paused, .converting:
            VStack(alignment: .leading, spacing: 4) {
                if record.status == .downloading || record.status == .paused, let progress {
                    ProgrammeProgressBar(progress: progress.fraction, tint: record.status == .paused ? Theme.secondaryText : Theme.accent, height: 4)
                        .frame(maxWidth: 220)
                        .frame(height: 4)
                }
                Text(detail)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(waiting == nil ? Theme.secondaryText : Theme.warning)
                    .lineLimit(2)
            }
        case .completed:
            VStack(alignment: .leading, spacing: 4) {
                if let watchProgress {
                    HStack(spacing: 8) {
                        ProgrammeProgressBar(progress: watchProgress.fraction, tint: Theme.accent, height: 3)
                            .frame(maxWidth: 120)
                            .frame(height: 3)
                        Text(WatchProgressFormat.remaining(watchProgress))
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(Theme.secondaryText)
                    }
                }
                Text(record.isMissing ? DownloadText.state(of: record, fraction: nil) : completedDetail)
                    .font(.caption)
                    .foregroundStyle(record.isMissing ? Theme.warning : Theme.secondaryText)
                    .lineLimit(2)
            }
        case .failed:
            // The whole reason: it says what to do.
            Text(record.failureMessage ?? DownloadText.state(of: record, fraction: nil))
                .font(.caption)
                .foregroundStyle(Theme.warning)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// "1.2 GB of 3.4 GB · 4 min left", "Paused · 45 %", "Waiting for Wi-Fi".
    private var detail: String {
        if let waiting {
            return waiting
        }
        switch record.status {
        case .downloading:
            guard let progress else {
                return DownloadText.state(of: record, fraction: nil)
            }
            let sizes: String?
            if let expected = progress.bytesExpected ?? record.bytesExpected, expected > 0 {
                let written = progress.bytesWritten > 0 ? progress.bytesWritten : Int64(Double(expected) * progress.fraction)
                sizes = String(localized: "\(DownloadText.bytes(written)) of \(DownloadText.bytes(expected))", comment: "Progress of a download: the size downloaded and the whole size, such as 1.2 GB of 3.4 GB.")
            } else {
                sizes = progress.fraction.formatted(.percent.precision(.fractionLength(0)))
            }
            let remaining = progress.remaining.map { String(localized: "\(DownloadText.duration($0)) left", comment: "Time left of a download, such as 4 min left.") }
            return TextParts.line([sizes, remaining])
        default:
            return DownloadText.state(of: record, fraction: progress?.fraction)
        }
    }

    /// "1.2 GB · 1 hr 42 min · 1080p · English, Italian".
    private var completedDetail: String {
        let audio = record.audioLanguageNames
        let subtitleNames = record.subtitleLanguageNames
        let languages = audio.count > 1 ? ListFormatter.localizedString(byJoining: audio) : nil
        let subtitles = subtitleNames.isEmpty ? nil : String(localized: "Subtitles: \(ListFormatter.localizedString(byJoining: subtitleNames))", comment: "The subtitle languages of a download; the placeholder is a list such as English, Italian.")
        return TextParts.line([
            DownloadText.bytes(record.bytesOnDisk),
            record.duration.map(DownloadText.duration),
            record.qualityText,
            languages,
            subtitles,
        ])
    }
}

/// A series with downloaded episodes: its poster, title, how many episodes and their size. Opens their list.
private struct DownloadSeriesRow: View {
    let title: String
    let records: [DownloadRecord]
    let downloads: DownloadCenter
    @Binding var prompts: DownloadPrompts

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @ScaledMetric(relativeTo: .body) private var scaledArtworkWidth: CGFloat = 44

    /// As in `DownloadRow`: up to 80 points, above the text at the accessibility sizes.
    private var artworkWidth: CGFloat {
        min(scaledArtworkWidth, 80)
    }

    var body: some View {
        if let first = records.first, let key = first.item.seriesKey {
            NavigationLink(value: ChannelRoute.downloadedSeries(playlistID: first.item.playlistID, key: key, title: title)) {
                AdaptiveStack(spacing: dynamicTypeSize.prefersStackedLayout ? 8 : 12) {
                    ChannelArtwork(logo: downloads.artworkSource(for: first), name: title, kind: .series, size: CGSize(width: artworkWidth, height: artworkWidth * 1.5))
                        .frame(width: artworkWidth, height: artworkWidth * 1.5)
                        .background(Color.artworkPlaceholder.opacity(0.4))
                        .clipShape(.rect(cornerRadius: 6, style: .continuous))
                        .overlay {
                            RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(Theme.surfaceStroke)
                        }
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(title)
                            .font(.headline)
                            .lineLimit(dynamicTypeSize.prefersStackedLayout ? 4 : 1)
                        Text(TextParts.line([
                            String(localized: "\(records.count) episodes", comment: "Downloads: how many episodes of a series are downloaded; the placeholder is a number."),
                            DownloadText.bytes(records.reduce(0) { $0 + $1.displayBytes }),
                        ]))
                        .font(.caption)
                        .foregroundStyle(Theme.secondaryText)
                    }
                }
            }
            .rowSwipeActions(edge: .trailing) {
                Button(DownloadText.delete, systemImage: "trash", role: .destructive) {
                    prompts.recordsToDelete = records.map(\.id)
                }
            }
            .contextMenu {
                Button(String(localized: "Delete All Episodes…", comment: "Downloads of a series: deletes every downloaded episode of the series (after a confirmation)."), systemImage: "trash", role: .destructive) {
                    prompts.recordsToDelete = records.map(\.id)
                }
            }
        }
    }
}

// MARK: - Confirmations

/// The deletions a list of downloads confirms first.
struct DownloadPrompts {
    var recordsToDelete: [UUID]?
}

extension View {
    /// The confirmation of `DownloadPrompts.recordsToDelete`.
    func downloadPrompts(_ prompts: Binding<DownloadPrompts>, downloads: DownloadCenter) -> some View {
        modifier(DownloadPromptsModifier(prompts: prompts, downloads: downloads))
    }

    /// The alert of a download that could not start (no space, not a video), over the window.
    func downloadNotices() -> some View {
        modifier(DownloadNoticeModifier())
    }
}

private struct DownloadPromptsModifier: ViewModifier {
    @Binding var prompts: DownloadPrompts
    let downloads: DownloadCenter

    func body(content: Content) -> some View {
        content
            .confirmationDialog(title, isPresented: isPresented, titleVisibility: .visible, presenting: prompts.recordsToDelete) { ids in
                Button(ids.count == 1 ? DownloadText.delete : String(localized: "Delete \(ids.count) Downloads", comment: "Confirmation button: deletes several downloads; the placeholder is their number."), role: .destructive) {
                    downloads.delete(ids)
                }
                Button(String(localized: "Cancel", comment: "Cancels a confirmation."), role: .cancel) {}
            } message: { ids in
                let bytes = ids.compactMap(downloads.record(id:)).reduce(Int64(0)) { $0 + $1.displayBytes }
                Text("\(DownloadText.bytes(bytes)) will be freed on this device. You can download them again while you're online.", comment: "Message of the confirmation to delete downloads; the placeholder is a size such as 2.1 GB.")
            }
    }

    private var title: String {
        guard let ids = prompts.recordsToDelete else {
            return ""
        }
        if ids.count == 1, let record = downloads.record(id: ids[0]) {
            return String(localized: "Delete “\(TextParts.line([record.title, record.episodeLine]))”?", comment: "Title of the confirmation to delete a download; the placeholder is the movie or episode.")
        }
        return String(localized: "Delete \(ids.count) Downloads?", comment: "Title of the confirmation to delete several downloads; the placeholder is their number.")
    }

    private var isPresented: Binding<Bool> {
        Binding(get: { prompts.recordsToDelete != nil }, set: { if !$0 { prompts.recordsToDelete = nil } })
    }
}

private struct DownloadNoticeModifier: ViewModifier {
    @Environment(DownloadCenter.self) private var downloads: DownloadCenter?

    func body(content: Content) -> some View {
        content
            .alert(downloads?.notice?.title ?? "", isPresented: isPresented, presenting: downloads?.notice) { _ in
                Button(String(localized: "OK", comment: "Dismisses an alert."), role: .cancel) {
                    downloads?.notice = nil
                }
            } message: { notice in
                Text(notice.message)
            }
    }

    private var isPresented: Binding<Bool> {
        Binding(get: { downloads?.notice != nil }, set: { if !$0 { downloads?.notice = nil } })
    }
}

// MARK: - Offline Home

/// At the top of Home while the device is offline: says so, and lists the downloads, which play without a network.
struct OfflineHomeSection: View {

    @Environment(DownloadCenter.self) private var downloads: DownloadCenter?
    @Environment(AppNavigation.self) private var navigation: AppNavigation?

    var body: some View {
        let network = NetworkMonitor.shared
        if network.isOffline {
            // A series is one card (its downloaded episodes behind it), as in the Library; movies are their own.
            let groups = Array((downloads?.completedGroups(excludingMissing: true) ?? []).prefix(24))
            VStack(alignment: .leading, spacing: 14) {
                OfflineBanner(hasDownloads: !groups.isEmpty) {
                    navigation?.show(.downloads)
                }
                .padding(.horizontal, HomeLayout.horizontalMargin)

                if let downloads, !groups.isEmpty {
                    ScrollView(.horizontal) {
                        LazyHStack(alignment: .top, spacing: 14) {
                            ForEach(groups) { group in
                                card(for: group, downloads: downloads)
                            }
                        }
                        .scrollTargetLayout()
                    }
                    .contentMargins(.horizontal, HomeLayout.horizontalMargin, for: .scrollContent)
                    .scrollIndicators(.hidden)
                    .accessibilityElement(children: .contain)
                    .accessibilityLabel(Text(DownloadText.downloads))
                }
            }
            .transition(.opacity)
        }
    }

    @ViewBuilder
    private func card(for group: DownloadGroup, downloads: DownloadCenter) -> some View {
        switch group {
        case .single(let record):
            ChannelPreview(item: downloads.playableItem(for: record), presentsSeries: false)
        case let .series(_, title, records):
            if let first = records.first, let key = first.item.seriesKey {
                SeriesCard(
                    series: SeriesItem(playlistID: first.item.playlistID, key: key, title: title, artwork: downloads.artworkSource(for: first), groupName: first.item.groupName),
                    subtitle: String(localized: "\(records.count) episodes downloaded", comment: "Offline Home: under a series card, how many of its episodes are downloaded; the placeholder is a number."),
                    destination: .downloadedSeries(playlistID: first.item.playlistID, key: key, title: title)
                )
            }
        }
    }
}

/// "You're offline", and the way to the downloads.
struct OfflineBanner: View {
    let hasDownloads: Bool
    let showDownloads: () -> Void

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        AdaptiveStack(verticalAlignment: .center, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "wifi.slash")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(Theme.warning)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text("You're Offline", comment: "Home, without a network connection: title of the banner.")
                        .font(.headline)
                    Text(hasDownloads
                         ? String(localized: "Your downloads play without a connection.", comment: "Home, without a network connection, with downloads.")
                         : String(localized: "Live TV and videos need a connection. Download movies and episodes to watch them offline.", comment: "Home, without a network connection and without downloads."))
                        .font(.subheadline)
                        .foregroundStyle(Theme.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            if !dynamicTypeSize.prefersStackedLayout {
                Spacer(minLength: 0)
            }
            if hasDownloads {
                Button(action: showDownloads) {
                    Text(DownloadText.downloads)
                        .font(.subheadline.weight(.semibold))
                }
                .buttonStyle(.glass)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.warning.opacity(0.12), in: .rect(cornerRadius: 16, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Theme.warning.opacity(0.3))
        }
        .accessibilityElement(children: .combine)
    }
}
