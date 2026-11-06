//
//  CloudPlaylistImportView.swift
//  Fluxo
//
//  "Your Playlists from iCloud": on a device that has no playlists yet (typically a new Apple TV, where typing an
//  address with the remote is slow), the playlists of the user's other devices are offered as soon as iCloud sync
//  finds them. The user picks them (all by default), and the sheet then shows each import's progress. Presented by
//  `cloudPlaylistImport()` at the root of the window, and from Settings › iCloud › Playlists in iCloud.
//

import SwiftUI

extension View {
    /// Presents the iCloud playlist sheet when `CloudSync` offers it. Apply once, at the root of the window.
    func cloudPlaylistImport() -> some View {
        modifier(CloudPlaylistImportPresenter())
    }
}

private struct CloudPlaylistImportPresenter: ViewModifier {
    @Environment(CloudSync.self) private var sync: CloudSync?

    func body(content: Content) -> some View {
        if let sync {
            @Bindable var sync = sync
            content
                #if !os(tvOS)
                // The debug harness's `cloud-privacy` (Apple TV pushes the page in Settings instead).
                .sheet(isPresented: $sync.isPrivacyPagePresented) {
                    NavigationStack {
                        CloudSyncPrivacyView()
                    }
                    #if os(macOS)
                    .frame(minWidth: 520, minHeight: 560)
                    #endif
                }
                #endif
                #if os(tvOS)
                .fullScreenCover(isPresented: $sync.isImportSheetPresented, onDismiss: sync.importSheetDidClose) {
                    CloudPlaylistImportView()
                }
                #else
                .sheet(isPresented: $sync.isImportSheetPresented, onDismiss: sync.importSheetDidClose) {
                    NavigationStack {
                        CloudPlaylistImportView()
                    }
                    #if os(macOS)
                    .frame(minWidth: 480, minHeight: 440)
                    #endif
                }
                #endif
        } else {
            content
        }
    }
}

struct CloudPlaylistImportView: View {

    @Environment(CloudSync.self) private var sync
    @Environment(PlaylistImportCenter.self) private var importCenter
    @Environment(\.dismiss) private var dismiss

    /// Record names the user unchecked (before Add; afterwards `CloudSync.importSession` says what was chosen).
    @State private var uncheckedBeforeStart: Set<String> = []
    /// The playlists listed before Add (playlists that arrive meanwhile join the list).
    @State private var offered: [CloudSync.CloudPlaylist] = []
    #if os(tvOS)
    @FocusState private var focusedRow: String?
    #endif

    var body: some View {
        content
            .onAppear {
                if offered.isEmpty {
                    offered = sync.cloudPlaylists
                }
            }
            #if DEBUG && os(tvOS)
            // Debug harness (`cloud-focus:`): the Siri Remote cannot be scripted, so screenshots of a focused row or
            // button move the focus here.
            .onReceive(NotificationCenter.default.publisher(for: .fluxoDebugCloudFocus)) { notification in
                guard let target = (notification.object as? String)?.lowercased() else {
                    return
                }
                focusedRow = shown.first { $0.name.lowercased() == target }?.id ?? target
            }
            #endif
            .onChange(of: sync.cloudPlaylists) { _, playlists in
                // Playlists that arrive while the sheet is open join the list.
                let known = Set(offered.map(\.id))
                offered += playlists.filter { !known.contains($0.id) }
            }
    }

    /// The import started (the user chose Add, here or in an earlier presentation of the sheet).
    private var didStart: Bool {
        sync.importSession != nil
    }

    /// The rows: what the sheet listed when Add was chosen, or the playlists offered now.
    private var shown: [CloudSync.CloudPlaylist] {
        sync.importSession?.playlists ?? offered
    }

    private var unchecked: Set<String> {
        if let session = sync.importSession {
            return Set(session.playlists.map(\.id)).subtracting(session.chosen)
        }
        return uncheckedBeforeStart
    }

    private var selected: [CloudSync.CloudPlaylist] {
        shown.filter { !unchecked.contains($0.id) }
    }

    private var isFinished: Bool {
        didStart && selected.allSatisfy { row in
            if let phase = sync.imports[row.id]?.phase {
                return phase != .importing
            }
            return false
        }
    }

    // MARK: - Layout

    @ViewBuilder
    private var content: some View {
        #if os(tvOS)
        tvLayout
        #else
        formLayout
        #endif
    }

    #if os(tvOS)
    /// Apple TV: the explanation on the leading side, the playlists and the buttons on the trailing side, as the
    /// system's setup screens are laid out.
    private var tvLayout: some View {
        HStack(alignment: .center, spacing: 90) {
            VStack(alignment: .leading, spacing: 28) {
                header
                Text(description)
                    .font(.body)
                    .foregroundStyle(Theme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
                Label {
                    Text(alongNote)
                } icon: {
                    Image(systemName: "star.fill")
                        .foregroundStyle(Theme.favorite)
                }
                .font(.callout)
                .foregroundStyle(Theme.secondaryText)
            }
            .frame(width: 720, alignment: .leading)

            VStack(spacing: 40) {
                ScrollView {
                    VStack(spacing: 18) {
                        ForEach(shown) { playlist in
                            Button {
                                toggle(playlist)
                            } label: {
                                row(for: playlist)
                                    .padding(.horizontal, 28)
                                    .padding(.vertical, 22)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .buttonStyle(.card)
                            // Not disabled once the import started: the focus walks down the rows (the scroll
                            // follows it) to the progress of each one; a click then does nothing.
                            .focused($focusedRow, equals: playlist.id)
                            .accessibilityAddTraits(isChecked(playlist) && !didStart ? .isSelected : [])
                        }
                    }
                    .padding(.vertical, 24)
                    .padding(.horizontal, 12)
                }
                .scrollClipDisabled()
                .frame(maxHeight: 620)

                buttons
            }
            .frame(width: 860)
        }
        .padding(80)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // A full-screen cover is not opaque on its own: the page under it would show through.
        .background {
            ZStack {
                Rectangle().fill(.background)
                Theme.brandGradient.opacity(0.22)
            }
            .ignoresSafeArea()
        }
        .defaultFocus($focusedRow, didStart ? "done" : "add")
        .onChange(of: didStart) { _, started in
            // Add is gone: the focus goes to the button that replaces it.
            if started {
                focusedRow = "done"
            }
        }
    }
    #else
    private var formLayout: some View {
        Form {
            Section {
                VStack(alignment: .leading, spacing: 12) {
                    header
                    Text(description)
                        .foregroundStyle(Theme.secondaryText)
                }
                .padding(.vertical, 6)
            }

            Section {
                ForEach(shown) { playlist in
                    Button {
                        toggle(playlist)
                    } label: {
                        row(for: playlist)
                            .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    // Not disabled once the import started: dimmed rows would hide the progress (taps do nothing).
                    .accessibilityAddTraits(isChecked(playlist) && !didStart ? .isSelected : [])
                }
            } footer: {
                Text(alongNote)
            }
        }
        .formStyle(.grouped)
        .navigationTitle(Text("Playlists from iCloud", comment: "Title of the sheet that offers the playlists of the user's other devices (navigation bar)."))
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar {
            if didStart {
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        dismiss()
                    } label: {
                        Text("Done")
                    }
                }
            } else {
                ToolbarItem(placement: .cancellationAction) {
                    Button {
                        sync.dismissImportOffer()
                    } label: {
                        Text("Not Now", comment: "Button of the iCloud playlists sheet: closes it without adding playlists.")
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        start()
                    } label: {
                        Text(addTitle)
                    }
                    .disabled(selected.isEmpty)
                }
            }
        }
    }
    #endif

    private var header: some View {
        VStack(alignment: .leading, spacing: 14) {
            Image(systemName: "icloud.and.arrow.down.fill")
                .symbolRenderingMode(.monochrome)
                .foregroundStyle(Theme.accent.gradient)
                #if os(tvOS)
                .font(.system(size: 96, weight: .semibold))
                #else
                .font(.system(size: 44, weight: .semibold))
                #endif
                .accessibilityHidden(true)
            Text("Your Playlists from iCloud", comment: "Title of the sheet that offers the playlists of the user's other devices.")
                #if os(tvOS)
                .font(.title2.bold())
                #else
                .font(.title2.bold())
                #endif
                .accessibilityAddTraits(.isHeader)
        }
    }

    #if os(tvOS)
    private var buttons: some View {
        HStack(spacing: 40) {
            if didStart {
                Button {
                    dismiss()
                } label: {
                    Text(isFinished ? String(localized: "Done") : String(localized: "Continue in Background", comment: "Button of the iCloud playlists sheet while playlists import: closes it, the imports go on."))
                        .frame(minWidth: 420)
                }
                .focused($focusedRow, equals: "done")
            } else {
                Button {
                    start()
                } label: {
                    Text(addTitle)
                        .frame(minWidth: 420)
                }
                .disabled(selected.isEmpty)
                .focused($focusedRow, equals: "add")
                Button {
                    sync.dismissImportOffer()
                } label: {
                    Text("Not Now", comment: "Button of the iCloud playlists sheet: closes it without adding playlists.")
                        .frame(minWidth: 240)
                }
                .focused($focusedRow, equals: "not-now")
            }
        }
    }
    #endif

    // MARK: - Rows

    private func row(for playlist: CloudSync.CloudPlaylist) -> some View {
        HStack(spacing: rowSpacing) {
            leadingIcon(for: playlist)
                .frame(width: iconWidth)
            VStack(alignment: .leading, spacing: 4) {
                Text(playlist.name)
                    .font(.headline)
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                detail(for: playlist)
                    .font(.subheadline)
                    .foregroundStyle(Theme.secondaryText)
                    .lineLimit(2)
            }
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
        .accessibilityHint(didStart ? Text(verbatim: "") : Text("Adds or leaves out this playlist.", comment: "VoiceOver hint of a playlist row of the iCloud playlists sheet."))
    }

    @ViewBuilder
    private func leadingIcon(for playlist: CloudSync.CloudPlaylist) -> some View {
        if !didStart || unchecked.contains(playlist.id) {
            Image(systemName: isChecked(playlist) ? "checkmark.circle.fill" : "circle")
                .font(iconFont)
                .foregroundStyle(isChecked(playlist) ? Theme.accent : Theme.tertiaryText)
                .accessibilityHidden(true)
        } else {
            switch sync.imports[playlist.id]?.phase {
            case .finished:
                Image(systemName: "checkmark.circle.fill")
                    .font(iconFont)
                    .foregroundStyle(.green)
                    .accessibilityHidden(true)
            case .failed:
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(iconFont)
                    .foregroundStyle(Theme.warning)
                    .accessibilityHidden(true)
            case .importing, nil:
                ProgressView()
            }
        }
    }

    @ViewBuilder
    private func detail(for playlist: CloudSync.CloudPlaylist) -> some View {
        if didStart, !unchecked.contains(playlist.id) {
            switch sync.imports[playlist.id] {
            case .some(let state):
                switch state.phase {
                case .importing:
                    if let progress = importCenter.progress[state.playlistID] {
                        VStack(alignment: .leading, spacing: 6) {
                            Text(progress.message)
                            if let fraction = progress.fractionCompleted {
                                ProgressView(value: fraction)
                                    .accessibilityHidden(true)
                            }
                        }
                    } else {
                        Text("Waiting…", comment: "iCloud playlists sheet: a playlist that has not started importing yet.")
                    }
                case .finished(let channelCount):
                    Text("\(channelCount) channels added", comment: "iCloud playlists sheet: a playlist was imported; the placeholder is its number of channels (plural variations).")
                case .failed(let message):
                    Text(message)
                }
            case .none:
                Text("Waiting…", comment: "iCloud playlists sheet: a playlist that has not started importing yet.")
            }
        } else if didStart {
            Text("Not added", comment: "iCloud playlists sheet: a playlist the user left out.")
        } else if let host = playlist.host {
            Text(verbatim: host)
        }
    }

    private func isChecked(_ playlist: CloudSync.CloudPlaylist) -> Bool {
        !unchecked.contains(playlist.id)
    }

    private func toggle(_ playlist: CloudSync.CloudPlaylist) {
        guard !didStart else {
            return
        }
        if uncheckedBeforeStart.contains(playlist.id) {
            uncheckedBeforeStart.remove(playlist.id)
        } else {
            uncheckedBeforeStart.insert(playlist.id)
        }
    }

    private func start() {
        guard !selected.isEmpty, !didStart else {
            return
        }
        sync.addPlaylists(Set(selected.map(\.id)))
    }

    // MARK: - Text

    private var addTitle: String {
        selected.count == shown.count && shown.count > 1
            ? String(localized: "Add All \(shown.count) Playlists", comment: "Button of the iCloud playlists sheet when every playlist is checked (always more than one); the placeholder is how many.")
            : String(localized: "Add \(selected.count) Playlists", comment: "Button of the iCloud playlists sheet; the placeholder is how many playlists are checked (one: Add Playlist).")
    }

    private var description: String {
        let single = shown.count == 1
        #if os(tvOS)
        return single
            ? String(localized: "This playlist is on your other devices. Add it to this Apple TV to watch it here, without typing a single address.", comment: "Description of the iCloud playlists sheet on Apple TV, when it lists one playlist.")
            : String(localized: "These playlists are on your other devices. Add them to this Apple TV to watch them here, without typing a single address.", comment: "Description of the iCloud playlists sheet on Apple TV.")
        #elseif os(macOS)
        return single
            ? String(localized: "This playlist is on your other devices. Add it to this Mac to watch it here too.", comment: "Description of the iCloud playlists sheet on a Mac, when it lists one playlist.")
            : String(localized: "These playlists are on your other devices. Add them to this Mac to watch them here too.", comment: "Description of the iCloud playlists sheet on a Mac.")
        #else
        if UIDevice.current.userInterfaceIdiom == .pad {
            return single
                ? String(localized: "This playlist is on your other devices. Add it to this iPad to watch it here too.", comment: "Description of the iCloud playlists sheet on an iPad, when it lists one playlist.")
                : String(localized: "These playlists are on your other devices. Add them to this iPad to watch them here too.", comment: "Description of the iCloud playlists sheet on an iPad.")
        }
        return single
            ? String(localized: "This playlist is on your other devices. Add it to this iPhone to watch it here too.", comment: "Description of the iCloud playlists sheet on an iPhone, when it lists one playlist.")
            : String(localized: "These playlists are on your other devices. Add them to this iPhone to watch them here too.", comment: "Description of the iCloud playlists sheet on an iPhone.")
        #endif
    }

    private var alongNote: String {
        shown.count == 1
            ? String(localized: "Its favorites, watch history and TV guides come along.", comment: "Note of the iCloud playlists sheet, when it lists one playlist: what is added with it.")
            : String(localized: "Their favorites, watch history and TV guides come along.", comment: "Note of the iCloud playlists sheet: what is added with the playlists.")
    }

    // MARK: - Metrics

    private var rowSpacing: CGFloat {
        #if os(tvOS)
        28
        #else
        14
        #endif
    }

    private var iconWidth: CGFloat {
        #if os(tvOS)
        56
        #else
        28
        #endif
    }

    private var iconFont: Font {
        #if os(tvOS)
        .title2
        #else
        .title3
        #endif
    }
}

/// Under "Add Playlist" on an empty Home: while iCloud sync looks for the playlists of the user's other devices, and
/// the way back to them after "Not Now". (The Apple TV welcome screen shows the button next to Add Playlist itself,
/// from `Status`.)
struct CloudSyncWelcomeNote: View {

    /// What the empty Home says of iCloud.
    enum Status: Equatable {
        case hidden
        /// Sync reads the cloud for the first time.
        case looking
        /// iCloud has playlists this device does not have.
        case playlists(Int)

        @MainActor
        init(_ sync: CloudSync?) {
            guard let sync, sync.isEnabled, sync.isConfigured, sync.availability == .available || sync.availability == .checking else {
                self = .hidden
                return
            }
            if !sync.cloudPlaylists.isEmpty {
                self = .playlists(sync.cloudPlaylists.count)
            } else if !sync.hasFetched || sync.isSyncing {
                self = .looking
            } else {
                self = .hidden
            }
        }

        var hasPlaylists: Bool {
            if case .playlists = self {
                return true
            }
            return false
        }
    }

    @Environment(CloudSync.self) private var sync: CloudSync?

    static func addTitle(count: Int) -> String {
        String(localized: "Add \(count) Playlists from iCloud", comment: "Empty Home: button that opens the playlists of the user's other devices; the placeholder is how many (one: Add Playlist from iCloud).")
    }

    var body: some View {
        switch Status(sync) {
        case .playlists(let count):
            Button {
                sync?.presentImportSheet()
            } label: {
                Label {
                    Text(Self.addTitle(count: count))
                } icon: {
                    Image(systemName: "icloud.and.arrow.down")
                }
            }
            .buttonStyle(.bordered)
        case .looking:
            HStack(spacing: 10) {
                ProgressView()
                Text("Looking for your playlists in iCloud…", comment: "Empty Home: shown while iCloud sync reads the playlists of the user's other devices.")
                    .foregroundStyle(Theme.secondaryText)
            }
            .font(.callout)
            .accessibilityElement(children: .combine)
        case .hidden:
            EmptyView()
        }
    }
}

#if DEBUG
extension Notification.Name {
    /// Debug harness (`cloud-focus:`): the row (a playlist name) or button (`add`, `not-now`, `done`) of the iCloud
    /// playlists sheet, or the row of Settings › iCloud (`sync-toggle`, `privacy`), to focus on Apple TV.
    static let fluxoDebugCloudFocus = Notification.Name("FluxoDebugCloudFocus")
    /// Debug harness (`cloud-privacy` on Apple TV): pushes What's Synced and Privacy in Settings.
    static let fluxoDebugCloudPrivacy = Notification.Name("FluxoDebugCloudPrivacy")
}
#endif
