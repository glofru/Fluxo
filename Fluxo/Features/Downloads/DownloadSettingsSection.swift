//
//  DownloadSettingsSection.swift
//  Fluxo
//
//  The Downloads section of Settings: cellular data (iOS), the video quality of HLS downloads, the automatic
//  deletion of watched downloads, downloading the next episode, and the space they take.
//

import SwiftUI

struct DownloadSettingsSection: View {

    @Environment(DownloadCenter.self) private var downloads: DownloadCenter?

    @AppStorage(DownloadPreferences.allowsCellularKey) private var allowsCellular = DownloadPreferences.defaultAllowsCellular
    @AppStorage(DownloadPreferences.qualityKey) private var qualityRawValue = DownloadPreferences.defaultQuality.rawValue
    @AppStorage(DownloadPreferences.deletesWatchedKey) private var deletesWatched = DownloadPreferences.defaultDeletesWatched
    @AppStorage(DownloadPreferences.downloadsNextEpisodeKey) private var downloadsNextEpisode = DownloadPreferences.defaultDownloadsNextEpisode

    @State private var isConfirmingDeleteAll = false

    var body: some View {
        Section {
            if let downloads {
                LabeledContent {
                    Text(TextParts.line([downloads.completedCount.formatted(), DownloadText.bytes(downloads.totalBytes)]))
                        .monospacedDigit()
                } label: {
                    SettingsLabel(localized: DownloadText.downloads, systemImage: "arrow.down.circle", tint: Theme.accentFill)
                }
            }

            #if os(iOS)
            Toggle(isOn: $allowsCellular) {
                SettingsLabel(localized: String(localized: "Use Cellular Data", comment: "Settings toggle: downloads may use cellular data (otherwise they wait for Wi-Fi)."), systemImage: "antenna.radiowaves.left.and.right", tint: .green)
            }
            .onChange(of: allowsCellular) {
                downloads?.cellularSettingDidChange()
            }
            #endif

            Picker(selection: $qualityRawValue) {
                ForEach(DownloadQuality.allCases) { quality in
                    Text(quality.title)
                        .tag(quality.rawValue)
                }
            } label: {
                SettingsLabel(localized: String(localized: "Video Quality", comment: "Settings picker: the quality of downloaded videos."), systemImage: "sparkles.tv", tint: Theme.cyan)
            }

            Toggle(isOn: $deletesWatched) {
                SettingsLabel(localized: String(localized: "Delete Watched Downloads", comment: "Settings toggle: downloads played to the end are deleted automatically."), systemImage: "eye.slash", tint: .gray)
            }
            .onChange(of: deletesWatched) { _, isOn in
                if isOn {
                    downloads?.deleteWatched(onlyIfIdle: true)
                }
            }

            Toggle(isOn: $downloadsNextEpisode) {
                SettingsLabel(localized: String(localized: "Download Next Episode", comment: "Settings toggle: finishing a downloaded episode downloads the next one of the series."), systemImage: "forward.end", tint: Theme.pink)
            }

            if let downloads, downloads.hasDownloads {
                Button(String(localized: "Delete All Downloads…", comment: "Deletes every download (after a confirmation)."), systemImage: "trash", role: .destructive) {
                    isConfirmingDeleteAll = true
                }
            }
        } header: {
            Text(DownloadText.downloads)
        } footer: {
            Text(footer)
        }
        .confirmationDialog(String(localized: "Delete All Downloads?", comment: "Title of the confirmation in Settings."), isPresented: $isConfirmingDeleteAll, titleVisibility: .visible) {
            Button(String(localized: "Delete All Downloads", comment: "Confirmation button: deletes every download."), role: .destructive) {
                downloads?.deleteAll()
            }
            Button(String(localized: "Cancel", comment: "Cancels a confirmation."), role: .cancel) {}
        } message: {
            if let downloads {
                Text("\(downloads.records.count) downloads (\(DownloadText.bytes(downloads.totalBytes))) will be deleted from this device.", comment: "Message of the confirmation to delete every download; the placeholders are their number and size.")
            }
        }
    }

    private var footer: String {
        let quality = String(localized: "The quality applies to streams that offer several; other videos download as they are.", comment: "Settings footer of the downloads: what the video quality setting changes.")
        let free = downloads?.availableBytes.map { String(localized: "\(DownloadText.bytes($0)) available on this device.", comment: "Settings footer of the downloads: the free space; the placeholder is a size such as 41 GB.") }
        return [quality, free].compactMap { $0 }.joined(separator: " ")
    }
}
