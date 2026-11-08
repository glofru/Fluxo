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

            FormMenuPicker(selection: $leadMinutes, value: leadMinutes == 0
                ? String(localized: "When It Starts")
                : String(localized: "\(leadMinutes) Minutes Before")) {
                ForEach(ReminderCenter.leadChoices, id: \.self) { minutes in
                    Text(minutes == 0 ? "When It Starts" : "\(minutes) Minutes Before")
                        .tag(minutes)
                }
            } label: {
                Text("Remind Me")
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
    @Environment(\.linkCopyFeedback) private var linkCopyFeedback
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
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
                    .lineLimit(dynamicTypeSize.prefersStackedLayout ? 3 : 1)
                    .truncationMode(.middle)
                Text(origin)
                    .font(.caption)
                    .foregroundStyle(Theme.secondaryText)
                    .lineLimit(dynamicTypeSize.prefersStackedLayout ? 3 : 1)
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
        if PlatformFeatures.pasteboard, let link = StreamLink(source.url) {
            Button("Copy Address", systemImage: "doc.on.doc") {
                // As Copy Link of a channel: providers' guide addresses often carry the account's login
                // (`xmltv.php?username=…&password=…`), which then stays on this device for a short while, with the
                // warning.
                LinkCopyFeedback.copy(link, feedback: linkCopyFeedback)
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
}

/// Adds an XMLTV guide by its address, such as the one a provider gives with its playlist. Fluxo has no built-in guide
/// of its own: listings come only from the playlists (url-tvg) and from the addresses added here.
struct AddGuideSourceView: View {

    @Environment(EPGStore.self) private var epg
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    @State private var urlText = ""
    @State private var name = ""
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
                        ConfirmToolbarButton(title: String(localized: "Add"), textSize: dynamicTypeSize, action: save)
                            .disabled(validatedURL == nil)
                    }
                }
            }
            #endif
            .onAppear {
                isURLFocused = true
            }
        }
        .mediumAndLargeDetentsAdaptingToTextSize()
        #if os(macOS)
        .frame(minWidth: 460, minHeight: 380)
        #endif
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
