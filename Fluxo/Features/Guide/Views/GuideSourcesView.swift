//
//  GuideSourcesView.swift
//  Fluxo
//
//  Created by Gianluca Lofrumento on 2026-11-02.
//

import SwiftData
import SwiftUI

/// The guide sources with their status, Add Source, Refresh and the reminder lead time. A section of Settings,
/// and the content of the Guide Sources sheet of the Guide screen.
struct GuideSettingsSection: View {

    /// Off in the Guide Sources sheet, whose title already says it.
    var showsHeader = true

    @Query(EPGQueries.sources()) private var sources: [EPGSource]
    @Query(sort: \Playlist.createdOn) private var playlists: [Playlist]
    @Environment(EPGStore.self) private var epg
    @AppStorage(ReminderCenter.leadMinutesKey) private var leadMinutes = ReminderCenter.defaultLeadMinutes
    @State private var isAddingSource = false

    var body: some View {
        Section {
            // Sources being deleted leave at once, in the transaction of the confirmation (see `GuideSourceRow`).
            ForEach(epg.visibleSources(sources)) { source in
                GuideSourceRow(source: source, playlistName: playlists.first { $0.uuid == source.playlistID }?.name, progress: epg.progress[source.uuid])
            }

            Button("Add Guide Source…", systemImage: "plus") {
                isAddingSource = true
            }
            .sheet(isPresented: $isAddingSource) {
                AddGuideSourceView()
            }

            Button("Refresh Guide Now", systemImage: "arrow.clockwise") {
                epg.refreshAll()
            }
            .disabled(epg.visibleSources(sources).isEmpty || epg.isRefreshing)

            Picker("Remind Me", selection: $leadMinutes) {
                ForEach(ReminderCenter.leadChoices, id: \.self) { minutes in
                    Text(minutes == 0 ? "When It Starts" : "\(minutes) Minutes Before")
                        .tag(minutes)
                }
            }
            .onChange(of: leadMinutes) {
                Task {
                    await epg.reminders.rescheduleAll()
                }
            }
        } header: {
            if showsHeader {
                Text("TV Guide")
            }
        } footer: {
            Text("Guides listed by your playlists (url-tvg) are added automatically. Fluxo keeps 7 days of programmes for the live channels of your playlists and refreshes them twice a day.")
        }
    }
}

/// The Guide Sources sheet.
struct GuideSourcesView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        Form {
            GuideSettingsSection(showsHeader: false)
        }
        .formStyle(.grouped)
        .glassSheetContentBackground()
        .navigationTitle("Guide Sources")
        .inlineNavigationBar()
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button(role: .close) {
                    dismiss()
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 480, minHeight: 420)
        #endif
    }
}

private struct GuideSourceRow: View {
    let source: EPGSource
    let playlistName: String?
    let progress: EPGRefreshProgress?

    @Environment(EPGStore.self) private var epg
    /// The name of the source the delete confirmation asks about, taken when it was asked.
    @State private var deletionName: String?

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: source.isUserAdded ? "link" : "list.bullet.rectangle")
                .foregroundStyle(.tint)
                .frame(width: 24)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(source.name)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(origin)
                    .font(.caption)
                    .foregroundStyle(Theme.secondaryText)
                    .lineLimit(1)
                status
                    .font(.caption)
                    .lineLimit(2)
            }
            Spacer(minLength: 8)
            Toggle("Use This Guide", isOn: Binding(get: { source.isEnabled }, set: { epg.setEnabled($0, sourceID: source.uuid) }))
                .labelsHidden()
                .toggleStyle(.switch)
        }
        .accessibilityElement(children: .combine)
        .contextMenu {
            menuItems
        }
        .rowSwipeActions(edge: .trailing) {
            if source.isUserAdded {
                // Not `role: .destructive`: a destructive swipe action makes the list remove the row at once,
                // expecting the data to follow in the same update. Here it only asks first, so the list and its
                // data disagreed and UICollectionView raised "invalid number of items" (the crash when deleting a
                // guide). The row goes when the deletion is confirmed, together with its data.
                Button("Delete", systemImage: "trash") {
                    askToDelete()
                }
                .tint(.red)
            }
            Button("Refresh", systemImage: "arrow.clockwise") {
                epg.refresh(source.uuid)
            }
            .tint(Theme.accentFill)
        }
        .confirmationDialog(
            Text("Delete \(deletionName ?? "")?"),
            isPresented: Binding(get: { deletionName != nil }, set: { if !$0 { deletionName = nil } }),
            titleVisibility: .visible
        ) {
            Button("Delete Guide Source", role: .destructive) {
                let sourceID = source.uuid
                withAnimation {
                    epg.deleteSource(sourceID)
                }
            }
        } message: {
            Text("Its programmes are removed. Reminders you set stay.")
        }
    }

    private func askToDelete() {
        deletionName = source.name
    }

    @ViewBuilder
    private var menuItems: some View {
        Button("Refresh", systemImage: "arrow.clockwise") {
            epg.refresh(source.uuid)
        }
        .disabled(progress != nil)
        if PlatformFeatures.pasteboard {
            Button("Copy Address", systemImage: "doc.on.doc") {
                copy(source.url.absoluteString)
            }
        }
        if source.isUserAdded {
            Divider()
            Button("Delete…", systemImage: "trash", role: .destructive) {
                askToDelete()
            }
        }
    }

    /// "From Freeview · guide.xml.gz", "Added by you · guide.xml.gz".
    private var origin: String {
        let from: String
        if let playlistName {
            from = String(localized: "From \(playlistName)")
        } else {
            from = source.isUserAdded ? String(localized: "Added by you") : String(localized: "From a playlist")
        }
        guard let file = EPGImporter.fileName(of: source.url) else {
            return from
        }
        return TextParts.line([from, file])
    }

    @ViewBuilder
    private var status: some View {
        if let progress {
            HStack(spacing: 6) {
                ProgressView()
                    .controlSize(.mini)
                Text(progress.message)
                    .monospacedDigit()
            }
            .foregroundStyle(Theme.secondaryText)
        } else if !source.isEnabled {
            Text("Off")
                .foregroundStyle(Theme.secondaryText)
        } else if let error = source.lastErrorMessage {
            Label(error, systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(Theme.warning)
        } else if let refreshed = source.lastRefreshedOn {
            Text(TextParts.line([
                String(localized: "\(source.programmeCount) programmes", comment: "Status of a TV guide source: how many programmes it has."),
                String(localized: "\(source.storedChannelCount) of \(source.channelCount) channels", comment: "Status of a TV guide source: channels used by the playlists out of all its channels."),
                String(localized: "updated \(refreshed.formatted(.relative(presentation: .named)))", comment: "Status of a TV guide source: when it was downloaded, as in 'updated 2 hours ago'. Lowercase: it follows other parts of the line."),
            ]))
                .foregroundStyle(Theme.secondaryText)
        } else {
            Text("Not loaded yet")
                .foregroundStyle(Theme.secondaryText)
        }
    }

    private func copy(_ string: String) {
        #if os(macOS)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(string, forType: .string)
        #elseif os(iOS)
        UIPasteboard.general.string = string
        #endif
    }
}

/// Adds an XMLTV guide by URL, or one of the free country guides of epgshare01.
struct AddGuideSourceView: View {

    /// Free XMLTV guides by country published by epgshare01 (https://epgshare01.online), updated daily, gzip.
    /// Region code → file code (some countries have a newer second edition).
    struct FreeGuide: Hashable {
        let region: String
        let file: String

        init(_ region: String, _ file: String) {
            self.region = region
            self.file = file
        }
    }

    static let freeGuides: [FreeGuide] = [
        FreeGuide("AE", "AE1"), FreeGuide("AL", "AL1"), FreeGuide("AR", "AR1"), FreeGuide("AT", "AT1"), FreeGuide("AU", "AU1"), FreeGuide("BA", "BA1"), FreeGuide("BB", "BB1"), FreeGuide("BE", "BE2"),
        FreeGuide("BG", "BG1"), FreeGuide("BR", "BR1"), FreeGuide("CA", "CA2"), FreeGuide("CH", "CH1"), FreeGuide("CL", "CL1"), FreeGuide("CO", "CO1"), FreeGuide("CR", "CR1"), FreeGuide("CY", "CY1"),
        FreeGuide("CZ", "CZ1"), FreeGuide("DE", "DE1"), FreeGuide("DK", "DK1"), FreeGuide("DO", "DO1"), FreeGuide("EC", "EC1"), FreeGuide("EG", "EG1"), FreeGuide("ES", "ES1"), FreeGuide("FI", "FI1"),
        FreeGuide("FR", "FR1"), FreeGuide("GB", "UK1"), FreeGuide("GR", "GR1"), FreeGuide("HK", "HK1"), FreeGuide("HR", "HR1"), FreeGuide("HU", "HU1"), FreeGuide("ID", "ID1"), FreeGuide("IE", "IE1"),
        FreeGuide("IL", "IL1"), FreeGuide("IN", "IN1"), FreeGuide("IT", "IT1"), FreeGuide("JM", "JM1"), FreeGuide("JP", "JP1"), FreeGuide("KE", "KE1"), FreeGuide("KR", "KR1"), FreeGuide("LT", "LT1"),
        FreeGuide("LU", "LU1"), FreeGuide("LV", "LV1"), FreeGuide("MN", "MN1"), FreeGuide("MT", "MT1"), FreeGuide("MX", "MX1"), FreeGuide("MY", "MY1"), FreeGuide("NG", "NG1"), FreeGuide("NL", "NL1"),
        FreeGuide("NO", "NO1"), FreeGuide("NZ", "NZ1"), FreeGuide("PA", "PA1"), FreeGuide("PE", "PE1"), FreeGuide("PL", "PL1"), FreeGuide("PT", "PT1"), FreeGuide("RO", "RO1"), FreeGuide("RS", "RS1"),
        FreeGuide("SA", "SA2"), FreeGuide("SE", "SE1"), FreeGuide("SG", "SG1"), FreeGuide("SK", "SK1"), FreeGuide("SV", "SV1"), FreeGuide("TH", "TH1"), FreeGuide("TR", "TR1"), FreeGuide("UA", "UA1"),
        FreeGuide("US", "US2"), FreeGuide("UY", "UY1"), FreeGuide("VN", "VN1"), FreeGuide("ZA", "ZA1"),
    ]

    static func freeGuideURL(file: String) -> URL? {
        URL(string: "https://epgshare01.online/epgshare01/epg_ripper_\(file).xml.gz")
    }

    @Environment(EPGStore.self) private var epg
    @Environment(\.dismiss) private var dismiss

    @State private var urlText = ""
    @State private var name = ""
    @State private var region = Locale.current.region?.identifier ?? "US"
    @State private var isSaving = false
    @State private var errorMessage: String?
    @FocusState private var isURLFocused: Bool

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Guide Address", text: $urlText, prompt: Text(verbatim: "https://example.com/guide.xml.gz"))
                        .urlKeyboard()
                        .focused($isURLFocused)
                        .onSubmit(save)
                    TextField("Name (Optional)", text: $name)
                } header: {
                    Text("XMLTV Guide")
                } footer: {
                    if let errorMessage {
                        Text(errorMessage)
                            .foregroundStyle(Theme.error)
                    } else {
                        Text("An XMLTV file (.xml or .xml.gz), for example the guide address your provider gives you.")
                    }
                }

                #if os(tvOS)
                // Apple TV: the sheet's bar is too narrow for the title and two buttons, so Add follows the address
                // (and Menu on the remote cancels, as everywhere on tvOS).
                Section {
                    if isSaving {
                        ProgressView()
                    } else {
                        Button("Add", systemImage: "plus", action: save)
                            .disabled(validatedURL == nil)
                    }
                }
                #endif

                Section {
                    Picker("Country", selection: $region) {
                        ForEach(sortedGuides, id: \.region) { guide in
                            Text(Self.countryName(guide.region))
                                .tag(guide.region)
                        }
                    }
                    Button("Use Free Guide for \(Self.countryName(region))", systemImage: "globe") {
                        if let file = Self.freeGuides.first(where: { $0.region == region })?.file, let url = Self.freeGuideURL(file: file) {
                            urlText = url.absoluteString
                            name = TextParts.line(["epgshare01", Self.countryName(region)])
                        }
                    }
                } header: {
                    Text("Free Guides")
                } footer: {
                    Text("epgshare01 publishes free guides by country, updated every day. Use them for channels you are allowed to watch.")
                }
            }
            .formStyle(.grouped)
            .glassSheetContentBackground()
            .navigationTitle("Add Guide Source")
            .inlineNavigationBar()
            #if !os(tvOS)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(role: .cancel) {
                        dismiss()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if isSaving {
                        ProgressView()
                    } else {
                        Button("Add", role: .confirm, action: save)
                            .disabled(validatedURL == nil)
                    }
                }
            }
            #endif
            .onAppear {
                if !Self.freeGuides.contains(where: { $0.region == region }) {
                    region = "US"
                }
                isURLFocused = true
            }
        }
        .mediumAndLargeDetentsAdaptingToTextSize()
        #if os(macOS)
        .frame(minWidth: 460, minHeight: 380)
        #endif
    }

    private var sortedGuides: [FreeGuide] {
        Self.freeGuides.sorted { Self.countryName($0.region).localizedStandardCompare(Self.countryName($1.region)) == .orderedAscending }
    }

    static func countryName(_ region: String) -> String {
        Locale.current.localizedString(forRegionCode: region) ?? region
    }

    private var validatedURL: URL? {
        let trimmed = urlText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed), let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http", url.host() != nil else {
            return nil
        }
        return url
    }

    private func save() {
        guard let url = validatedURL, !isSaving else {
            errorMessage = urlText.isEmpty ? nil : String(localized: "Enter an http or https address.")
            return
        }
        isSaving = true
        Task {
            do {
                try await epg.addSource(url: url, name: name)
                dismiss()
            } catch {
                errorMessage = error.localizedDescription
                isSaving = false
            }
        }
    }
}

#Preview("Sources") {
    NavigationStack {
        GuideSourcesView()
    }
    .fluxoPreviewEnvironment(GuidePreviewData.container)
}

#Preview("Add source") {
    AddGuideSourceView()
        .fluxoPreviewEnvironment()
}
