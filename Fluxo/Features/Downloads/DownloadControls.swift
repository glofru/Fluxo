//
//  DownloadControls.swift
//  Fluxo
//
//  The download controls shown on content: the Download entries of every channel menu (`DownloadMenuItems`), the
//  round button of episode rows and the series page (`DownloadButton`, a progress ring while it downloads), the
//  badges of cards (`DownloadCardBadge`, `SeriesDownloadBadge`), and the Download Season button of the series page.
//
//  Every control reads `DownloadCenter` from the environment as an optional, and shows nothing without it (or for
//  live channels, which cannot be downloaded).
//

import SwiftUI

/// Texts shared by the download controls and lists.
enum DownloadText {
    static var download: String {
        String(localized: "Download.action", defaultValue: "Download", comment: "Button and menu item (verb): downloads a movie or episode to watch it offline.")
    }

    static var pause: String {
        String(localized: "Pause Download", comment: "Menu item: pauses a download in progress.")
    }

    static var resume: String {
        String(localized: "Resume Download", comment: "Menu item: continues a paused download.")
    }

    static var retry: String {
        String(localized: "Retry Download", comment: "Menu item: starts a failed download again.")
    }

    static var downloadAgain: String {
        String(localized: "Download Again", comment: "Menu item: downloads again a movie or episode whose download the system removed.")
    }

    static var cancel: String {
        String(localized: "Cancel Download", comment: "Menu item: stops a download in progress and deletes what was downloaded.")
    }

    static var delete: String {
        String(localized: "Delete Download", comment: "Menu item: deletes a downloaded movie or episode from the device.")
    }

    static var removeFailed: String {
        String(localized: "Remove Download", comment: "Menu item: removes a failed download from the list.")
    }

    static var downloaded: String {
        String(localized: "Downloaded", comment: "State of a movie or episode that is on the device and plays offline (VoiceOver, badges).")
    }

    static var downloads: String {
        String(localized: "Downloads", comment: "Title of the list of offline downloads (a Library section, a screen, a Settings section).")
    }

    /// "Downloading, 45 %" and the like, for VoiceOver and the row's status line.
    static func state(of record: DownloadRecord, fraction: Double?) -> String {
        let percent = (fraction ?? record.fraction).formatted(.percent.precision(.fractionLength(0)))
        switch record.status {
        case .queued:
            return String(localized: "Waiting to download", comment: "Status of a download that waits for another one to finish.")
        case .preparing:
            return String(localized: "Preparing download…", comment: "Status of a download that is about to start (the link is being checked).")
        case .downloading:
            return String(localized: "Downloading, \(percent)", comment: "Status of a download in progress; the placeholder is a percentage, such as 45 %.")
        case .paused:
            return String(localized: "Paused, \(percent)", comment: "Status of a paused download; the placeholder is how far it got, such as 45 %.")
        case .converting:
            return String(localized: "Preparing for offline playback…", comment: "Status of a download that is being converted into a format the device plays.")
        case .completed:
            return record.isMissing
                ? String(localized: "Removed from the device to free up space", comment: "Status of a download whose file the system deleted (storage was low).")
                : downloaded
        case .failed:
            return String(localized: "Download failed", comment: "Status of a download that stopped with an error.")
        }
    }

    static func bytes(_ count: Int64) -> String {
        count.formatted(.byteCount(style: .file))
    }

    static func duration(_ seconds: TimeInterval) -> String {
        Duration.seconds(max(60, seconds)).formatted(.units(allowed: [.hours, .minutes], width: .abbreviated))
    }
}

// MARK: - Menus

/// Download, Pause, Resume, Retry, Cancel or Delete for an item, depending on where its download is. Nothing for
/// what cannot be downloaded (live channels, links that are not http).
struct DownloadMenuItems: View {
    let item: ChannelItem

    @Environment(DownloadCenter.self) private var downloads: DownloadCenter?

    var body: some View {
        if let downloads, downloads.canDownload(item) {
            DownloadRecordMenuItems(downloads: downloads, record: downloads.record(for: item)) {
                downloads.download(item)
            }
        }
    }
}

/// The actions of a download (or Download, without one).
struct DownloadRecordMenuItems: View {
    let downloads: DownloadCenter
    let record: DownloadRecord?
    let startDownload: () -> Void

    var body: some View {
        if let record {
            switch record.status {
            case .queued, .preparing, .downloading:
                Button(DownloadText.pause, systemImage: "pause.circle") {
                    downloads.pause(record.id)
                }
                Button(DownloadText.cancel, systemImage: "xmark.circle", role: .destructive) {
                    downloads.delete(record.id)
                }
            case .paused:
                Button(DownloadText.resume, systemImage: "arrow.down.circle") {
                    downloads.resume(record.id)
                }
                Button(DownloadText.cancel, systemImage: "xmark.circle", role: .destructive) {
                    downloads.delete(record.id)
                }
            case .converting:
                Button(DownloadText.cancel, systemImage: "xmark.circle", role: .destructive) {
                    downloads.delete(record.id)
                }
            case .failed:
                if !record.failureIsPermanent {
                    Button(DownloadText.retry, systemImage: "arrow.clockwise") {
                        downloads.retry(record.id)
                    }
                }
                Button(DownloadText.removeFailed, systemImage: "trash", role: .destructive) {
                    downloads.delete(record.id)
                }
            case .completed:
                if record.isMissing {
                    Button(DownloadText.downloadAgain, systemImage: "arrow.down.circle") {
                        downloads.retry(record.id)
                    }
                }
                Button(DownloadText.delete, systemImage: "trash", role: .destructive) {
                    downloads.delete(record.id)
                }
            }
        } else {
            Button(DownloadText.download, systemImage: "arrow.down.circle", action: startDownload)
        }
    }
}

// MARK: - Button

/// The download control at the end of an episode row: Download (an arrow to a line); a progress ring while it
/// downloads (a menu pauses or cancels); the device once downloaded, as the TV app shows it (a menu deletes it); a
/// warning when it failed. Not a circle when idle or done, so it does not read as a second play button next to
/// the row's play symbol.
struct DownloadButton: View {
    let item: ChannelItem

    @Environment(DownloadCenter.self) private var downloads: DownloadCenter?
    @ScaledMetric(relativeTo: .title2) private var size: CGFloat = 26

    var body: some View {
        if let downloads, downloads.canDownload(item) {
            let record = downloads.record(for: item)
            Group {
                if let record {
                    Menu {
                        Text(DownloadText.state(of: record, fraction: nil))
                        DownloadRecordMenuItems(downloads: downloads, record: record) {}
                    } label: {
                        DownloadStateIcon(record: record, progress: record.status.isPending ? downloads.progress(for: record) : nil, size: size, showsDevice: true)
                            .frame(width: size + 18, height: size + 18)
                            .contentShape(.rect)
                    }
                    .menuIndicator(.hidden)
                    .accessibilityLabel(Text(TextParts.spoken([DownloadText.download, DownloadText.state(of: record, fraction: record.status.isPending ? downloads.progress(for: record).fraction : nil)])))
                } else {
                    Button {
                        downloads.download(item)
                    } label: {
                        Image(systemName: "arrow.down.to.line")
                            .font(.system(size: size * 0.72, weight: .semibold))
                            .foregroundStyle(Theme.accent)
                            .frame(width: size + 18, height: size + 18)
                            .contentShape(.rect)
                    }
                    .accessibilityLabel(Text(DownloadText.download))
                    .help(DownloadText.download)
                }
            }
            .buttonStyle(.plain)
        }
    }
}

/// The icon of a download's state: a ring of its progress while it is pending, the downloaded arrow, or a warning.
struct DownloadStateIcon: View {
    let record: DownloadRecord
    /// The live progress, for pending downloads.
    let progress: DownloadProgress?
    let size: CGFloat
    /// Downloaded: the device it is on (episode rows), rather than the filled arrow (the downloads list).
    var showsDevice = false

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Group {
            switch record.status {
            case .completed where showsDevice && !record.isMissing:
                Image(systemName: Self.deviceSymbol)
                    .font(.system(size: size * 0.78))
                    .foregroundStyle(Theme.secondaryText)
            case .completed:
                // A state, not a call to action: gray, unlike the accent Download button.
                Image(systemName: record.isMissing ? "exclamationmark.arrow.circlepath" : "arrow.down.circle.fill")
                    .font(.system(size: size * 0.92))
                    .symbolRenderingMode(.monochrome)
                    .foregroundStyle(record.isMissing ? Theme.warning : Theme.secondaryText)
            case .failed:
                Image(systemName: "exclamationmark.circle")
                    .font(.system(size: size * 0.92))
                    .foregroundStyle(Theme.warning)
            case .queued, .preparing, .downloading, .paused, .converting:
                DownloadProgressRing(fraction: progress?.fraction ?? record.fraction, status: record.status, size: size)
            }
        }
        .accessibilityHidden(true)
    }
}

extension DownloadStateIcon {
    /// This device, for "downloaded": a phone, an iPad or a Mac.
    @MainActor static var deviceSymbol: String {
        #if os(macOS)
        return "laptopcomputer"
        #else
        return UIDevice.current.userInterfaceIdiom == .pad ? "ipad" : "iphone"
        #endif
    }
}

/// A ring that fills with the progress, a stop square in it (a tap pauses or cancels), an arrow while paused, and
/// a spinning arc while the link is checked or the file converted.
struct DownloadProgressRing: View {
    let fraction: Double
    let status: DownloadStatus
    let size: CGFloat

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isSpinning = false

    private var isIndeterminate: Bool {
        status == .preparing || status == .converting || (status == .queued && fraction == 0)
    }

    var body: some View {
        let lineWidth = max(2, size * 0.1)
        ZStack {
            Circle()
                .stroke(Theme.secondaryText.opacity(0.3), lineWidth: lineWidth)
            if isIndeterminate {
                Circle()
                    .trim(from: 0, to: 0.25)
                    .stroke(Theme.accent, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                    .rotationEffect(.degrees(isSpinning ? 360 : 0))
                    .animation(reduceMotion ? nil : .linear(duration: 1).repeatForever(autoreverses: false), value: isSpinning)
                    .onAppear {
                        isSpinning = true
                    }
            } else {
                Circle()
                    .trim(from: 0, to: max(0.02, min(1, fraction)))
                    .stroke(status == .paused ? Theme.secondaryText : Theme.accent, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .animation(reduceMotion ? nil : .smooth(duration: 0.3), value: fraction)
            }
            Image(systemName: status == .paused ? "arrow.down" : "stop.fill")
                .font(.system(size: size * (status == .paused ? 0.42 : 0.3), weight: .bold))
                .foregroundStyle(status == .paused ? Theme.secondaryText : Theme.accent)
        }
        .frame(width: size, height: size)
    }
}

// MARK: - Badges

/// On a movie or episode card: a downloaded arrow, or a small ring while it downloads.
struct DownloadCardBadge: View {
    let item: ChannelItem

    @Environment(DownloadCenter.self) private var downloads: DownloadCenter?

    var body: some View {
        if let downloads, item.kind != .live, let record = downloads.record(for: item), record.status != .failed {
            Group {
                if record.status == .completed {
                    Image(systemName: record.isMissing ? "exclamationmark.arrow.circlepath" : "arrow.down.circle.fill")
                        .font(.caption.bold())
                        .foregroundStyle(record.isMissing ? Theme.warning : Theme.accent)
                } else {
                    DownloadProgressRing(fraction: downloads.progress(for: record).fraction, status: record.status, size: 14)
                }
            }
            .padding(5)
            .background(.thinMaterial, in: .circle)
            .accessibilityHidden(true)
        }
    }

    /// For the card's VoiceOver label: "Downloaded", "Downloading, 45 %".
    @MainActor
    static func accessibilityText(for item: ChannelItem, downloads: DownloadCenter?) -> String? {
        guard let downloads, let record = downloads.record(for: item), record.status != .failed else {
            return nil
        }
        return DownloadText.state(of: record, fraction: record.status.isPending ? downloads.progress(for: record).fraction : nil)
    }
}

/// On a series card: how many of its episodes are downloaded.
struct SeriesDownloadBadge: View {
    let series: SeriesItem

    @Environment(DownloadCenter.self) private var downloads: DownloadCenter?

    var body: some View {
        if let downloads, downloads.hasDownloads {
            let count = downloads.completedCount(ofSeries: series)
            if count > 0 {
                HStack(spacing: 3) {
                    Image(systemName: "arrow.down.circle.fill")
                        .foregroundStyle(Theme.accent)
                    Text(count, format: .number)
                        .monospacedDigit()
                }
                .font(.caption2.bold())
                .padding(.horizontal, 6)
                .padding(.vertical, 4)
                .background(.thinMaterial, in: .capsule)
                .accessibilityHidden(true)
            }
        }
    }

    /// "3 episodes downloaded", for the card's VoiceOver label.
    @MainActor
    static func accessibilityText(for series: SeriesItem, downloads: DownloadCenter?) -> String? {
        guard let downloads else {
            return nil
        }
        let count = downloads.completedCount(ofSeries: series)
        guard count > 0 else {
            return nil
        }
        return String(localized: "\(count) episodes downloaded", comment: "VoiceOver: how many episodes of a series are on the device; the placeholder is a number.")
    }
}

// MARK: - Season

/// Above the episodes of a season: Download Season, its progress, or "Season Downloaded" with a menu to delete.
struct SeasonDownloadButton: View {
    let episodes: [ChannelItem]
    let seasonTitle: String

    @Environment(DownloadCenter.self) private var downloads: DownloadCenter?

    var body: some View {
        if let downloads {
            let downloadable = episodes.filter(downloads.canDownload)
            if !downloadable.isEmpty {
                content(downloads: downloads, episodes: downloadable)
            }
        }
    }

    @ViewBuilder
    private func content(downloads: DownloadCenter, episodes: [ChannelItem]) -> some View {
        let records = episodes.compactMap(downloads.record(for:))
        let completed = records.filter { $0.status == .completed && !$0.isMissing }.count
        let pending = records.filter { $0.status.isActive }.count
        let missing = episodes.filter { downloads.record(for: $0) == nil || downloads.record(for: $0)?.isMissing == true }
        let label = Label {
            Text(title(completed: completed, pending: pending, total: episodes.count))
                .lineLimit(2)
        } icon: {
            Image(systemName: completed == episodes.count ? "arrow.down.circle.fill" : "arrow.down.circle")
        }
        .font(.subheadline.weight(.semibold))
        .foregroundStyle(Theme.accent)
        Group {
            if missing.isEmpty {
                // Everything is downloaded or on its way: a tap shows what can be done with them.
                Menu {
                    menuItems(downloads: downloads, records: records, missing: missing, pending: pending)
                } label: {
                    label
                }
            } else {
                // A tap downloads the rest; the menu (long press) has the other actions.
                Menu {
                    menuItems(downloads: downloads, records: records, missing: missing, pending: pending)
                } label: {
                    label
                } primaryAction: {
                    downloads.download(missing)
                }
            }
        }
        .menuIndicator(.hidden)
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityHint(Text(missing.isEmpty ? "" : String(localized: "Downloads the episodes of \(seasonTitle) to watch them offline", comment: "VoiceOver hint of Download Season; the placeholder is the season, such as Season 1.")))
    }

    @ViewBuilder
    private func menuItems(downloads: DownloadCenter, records: [DownloadRecord], missing: [ChannelItem], pending: Int) -> some View {
        if !missing.isEmpty {
            Button(String(localized: "Download \(missing.count) Episodes", comment: "Menu item of a season: downloads the episodes that are not downloaded yet; the placeholder is their number."), systemImage: "arrow.down.circle") {
                downloads.download(missing)
            }
        }
        if pending > 0 {
            Button(String(localized: "Pause Season Downloads", comment: "Menu item of a season: pauses the downloads of its episodes."), systemImage: "pause.circle") {
                for record in records where record.status.isActive {
                    downloads.pause(record.id)
                }
            }
        }
        if !records.isEmpty {
            Button(String(localized: "Delete Season Downloads", comment: "Menu item of a season: deletes the downloaded episodes of the season, and stops those in progress."), systemImage: "trash", role: .destructive) {
                downloads.delete(records.map(\.id))
            }
        }
    }

    private func title(completed: Int, pending: Int, total: Int) -> String {
        if completed == total {
            return String(localized: "Season Downloaded", comment: "Series page: every episode of the season is on the device (a button with a menu to delete them).")
        }
        let downloaded = String(localized: "\(completed) of \(total) Downloaded", comment: "Series page: some episodes of the season are downloaded; the placeholders are numbers.")
        if pending > 0 {
            guard completed > 0 else {
                return String(localized: "Downloading \(pending) of \(total)", comment: "Series page: episodes of a season are downloading; the placeholders are how many are downloading or waiting, and the number of episodes in the season.")
            }
            return TextParts.line([downloaded, String(localized: "\(pending) Downloading", comment: "Series page, after '2 of 3 Downloaded': how many episodes of the season are downloading or waiting.")])
        }
        if completed > 0 {
            return downloaded
        }
        return String(localized: "Download Season", comment: "Series page: button that downloads every episode of the season shown.")
    }
}

/// Next to a title in a row: a small downloaded arrow, or a ring while it downloads. Spoken with the row.
struct DownloadInlineIndicator: View {
    let item: ChannelItem

    @Environment(DownloadCenter.self) private var downloads: DownloadCenter?

    var body: some View {
        if let downloads, let record = downloads.record(for: item), record.status != .failed {
            Group {
                if record.status == .completed {
                    Image(systemName: record.isMissing ? "exclamationmark.arrow.circlepath" : "arrow.down.circle.fill")
                        .font(.caption2)
                        .foregroundStyle(record.isMissing ? Theme.warning : Theme.accent)
                } else {
                    DownloadProgressRing(fraction: downloads.progress(for: record).fraction, status: record.status, size: 11)
                }
            }
            .accessibilityElement()
            .accessibilityLabel(Text(DownloadText.state(of: record, fraction: record.status.isPending ? downloads.progress(for: record).fraction : nil)))
        }
    }
}

// MARK: - Offline availability

/// Offline, a stream that is not downloaded cannot play: its card is dimmed and says so to VoiceOver. (Local files
/// and loopback links, such as the debug test streams, still play.)
@MainActor
enum OfflineAvailability {
    static let dimmedOpacity = 0.45

    static var unavailableText: String {
        String(localized: "Not Available Offline", comment: "VoiceOver, on a card while the device is offline: this channel or video is not downloaded and cannot play.")
    }

    static func isUnavailable(_ item: ChannelItem, downloads: DownloadCenter?) -> Bool {
        guard NetworkMonitor.shared.isOffline, let url = item.url, !url.isFileURL else {
            return false
        }
        if let host = url.host()?.lowercased(), host == "localhost" || host == "::1" || host.hasPrefix("127.") {
            return false
        }
        guard let record = downloads?.record(for: item) else {
            return true
        }
        return record.status != .completed || record.isMissing
    }
}
