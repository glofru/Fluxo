//
//  CloudPlaylistImportView.swift
//  Fluxo
//
//  "Your Playlists from iCloud": on a device that has no playlists yet (typically a new Apple TV, where typing an
//  address with the remote is slow), the playlists of the user's other devices are offered as soon as iCloud sync
//  finds them. The user picks them (all by default), and the sheet then shows each import's progress. Presented by
//  `cloudPlaylistImport()` at the root of the window, and from Settings › iCloud › Playlists in iCloud.
//

import Accessibility
import SwiftUI

extension View {
    /// Presents the iCloud playlist sheet when `CloudSync` offers it, and the questions sync asks once (turn sync
    /// on, restore a lost library, confirm a mass removal; `CloudSync.Prompt`). Apply once, at the root of the window.
    func cloudPlaylistImport() -> some View {
        modifier(CloudPlaylistImportPresenter())
            .modifier(CloudSyncPromptPresenter())
    }
}

/// The questions of `CloudSync.Prompt`, as system alerts: on Apple TV they take the screen with large focusable
/// buttons, the first one focused, and Menu picks the cancel button (Not Now); VoiceOver reads the title and message.
/// The mass-removal question is a page of its own on Apple TV, focused on Not Now (`HeldRemovalsQuestion`), and an
/// alert elsewhere whose cancel button is Not Now (on a Mac also the default button, Return).
private struct CloudSyncPromptPresenter: ViewModifier {
    @Environment(CloudSync.self) private var sync: CloudSync?

    func body(content: Content) -> some View {
        if let sync {
            content
                .alert(
                    Text(title(sync.prompt)),
                    // Every button answers; nothing else closes the alert (the buttons clear `prompt`).
                    isPresented: Binding(get: { sync.prompt.map(Self.usesAlert) ?? false }, set: { _ in }),
                    presenting: sync.prompt
                ) { prompt in
                    actions(prompt, sync: sync)
                } message: { prompt in
                    Text(message(prompt))
                }
                #if os(tvOS)
                // The mass-removal question on Apple TV: an alert there focuses its first button and always puts the
                // cancel button (Not Now) last, so this page focuses Not Now instead (`HeldRemovalsQuestion`). Menu
                // closes it, and that is Not Now. Presented with its item, which SwiftUI keeps for the page while it
                // slides away once answered (the prompt is already nil then: the page would go blank).
                .fullScreenCover(item: Binding(get: { sync.prompt.flatMap { Self.usesAlert($0) ? nil : $0 } }, set: { presented in
                    if presented == nil, let prompt = sync.prompt, !Self.usesAlert(prompt) {
                        sync.postponeHeldRemovals()
                    }
                })) { prompt in
                    HeldRemovalsQuestion(title: title(prompt), message: message(prompt), sync: sync)
                }
                #endif
                // A question that waited for the player, the Add Playlist sheet or the iCloud playlists sheet is
                // asked as soon as they close. (`mayPresentImportOffer` reads the player and the playlist actions,
                // which are observable: this view is updated when they change.)
                .onChange(of: sync.mayPresentImportOffer() && !sync.isImportSheetPresented) { _, mayAsk in
                    if mayAsk {
                        sync.updatePrompt()
                    }
                }
        } else {
            content
        }
    }

    /// Whether the question is a system alert (all of them, except the mass-removal question on Apple TV).
    private static func usesAlert(_ prompt: CloudSync.Prompt) -> Bool {
        #if os(tvOS)
        if case .confirmRemovals = prompt {
            return false
        }
        #endif
        return true
    }

    private func title(_ prompt: CloudSync.Prompt?) -> String {
        switch prompt {
        case .turnOn, nil:
            String(localized: "Sync Your Library with iCloud?", comment: "Title of the question asked once to a user who updates the app with playlists on the device: turn on iCloud sync?")
        case .restoreLibrary(let playlists) where playlists == 0:
            String(localized: "Restore Your TV Guides from iCloud?", comment: "Title of the question asked when TV guides this device had are missing (its library was reset) but iCloud still has them.")
        case .restoreLibrary:
            String(localized: "Restore Your Playlists from iCloud?", comment: "Title of the question asked when playlists this device had are missing (its library was reset) but iCloud still has them.")
        case .confirmRemovals(_, let history) where history == 0:
            String(localized: "Remove Favorites from All Your Devices?", comment: "Title of the question asked when many favorites vanished from this device at once: remove them from the user's other devices too?")
        case .confirmRemovals(let favorites, _) where favorites == 0:
            String(localized: "Remove Watch History from All Your Devices?", comment: "Title of the question asked when much of the watch history vanished from this device at once: remove it from the user's other devices too?")
        case .confirmRemovals:
            String(localized: "Remove from All Your Devices?", comment: "Title of the question asked when many favorites and watched items vanished from this device at once: remove them from the user's other devices too?")
        }
    }

    @ViewBuilder
    private func actions(_ prompt: CloudSync.Prompt, sync: CloudSync) -> some View {
        switch prompt {
        case .turnOn:
            Button {
                sync.answerSyncChoice(turnOn: true)
            } label: {
                Text("Turn On iCloud Sync", comment: "Button of the turn-on-sync question: turns iCloud sync on for this device.")
            }
            Button(role: .cancel) {
                sync.answerSyncChoice(turnOn: false)
            } label: {
                Text("Not Now", comment: "Button of the turn-on-sync question: keeps sync off (Settings › iCloud can turn it on later).")
            }
        case .restoreLibrary:
            Button {
                sync.restoreLostLibrary()
            } label: {
                Text("Restore", comment: "Button of the restore question: adds back, from iCloud, the playlists and guides this device lost.")
            }
            Button(role: .cancel) {
                sync.postponeRestore()
            } label: {
                Text("Not Now", comment: "Button of the restore question: nothing is restored now (Settings › iCloud can restore later); nothing is deleted.")
            }
        case .confirmRemovals:
            Button {
                sync.resolveHeldRemovals(remove: false)
            } label: {
                HeldRemovalsQuestion.restoreLabel
            }
            Button(role: .destructive) {
                sync.resolveHeldRemovals(remove: true)
            } label: {
                HeldRemovalsQuestion.removeLabel
            }
            // The safe answer: it changes nothing anywhere, so it neither undoes a removal the user meant (Restore
            // Them) nor removes anything elsewhere, and it asks again a day later (`SyncHeldRemovalsReminder`). The
            // cancel button (last; Escape), and on the Mac the default one too (Return). Not the preferred action on
            // iPhone and iPad: iOS 27.2 draws that as a blue capsule with its title in the app's violet tint, about
            // 1.1:1, unreadable (checked in the Simulator). Apple TV shows `HeldRemovalsQuestion`, focused on it.
            Button(role: .cancel) {
                sync.postponeHeldRemovals()
            } label: {
                HeldRemovalsQuestion.notNowLabel
            }
            #if os(macOS)
            .keyboardShortcut(.defaultAction)
            #endif
        }
    }

    private func message(_ prompt: CloudSync.Prompt) -> String {
        switch prompt {
        case .turnOn:
            String(localized: "Keep your playlists, TV guides, favorites and watch progress the same on all your devices. Playlist addresses are encrypted before they leave this device. You can change this in Settings.", comment: "Message of the question asked once to a user who updates the app with playlists on the device: what iCloud sync does and how addresses are protected.")
        case .restoreLibrary(let playlists) where playlists == 0:
            String(localized: "TV guides that were on this device are missing, but they're still in iCloud and on your other devices. Nothing was deleted from them.", comment: "Message of the restore question when only TV guides are missing.")
        case .restoreLibrary(let playlists):
            String(localized: "\(playlists) playlists that were on this device are missing, but they're still in iCloud and on your other devices. Restore them with their favorites, watch history and TV guides?", comment: "Message of the restore question; the placeholder is how many playlists are missing (one: 1 playlist that was on this device is missing).")
        case .confirmRemovals(let favorites, let history) where history == 0:
            String(localized: "\(favorites) favorites are missing on this device at once. If you removed them, remove them from your other devices too. If not, restore them from iCloud.", comment: "Message of the mass-removal question when only favorites vanished; the placeholder is how many (always 3 or more).")
        case .confirmRemovals(let favorites, let history) where favorites == 0:
            String(localized: "\(history) watched items are missing from the history on this device at once. If you cleared them, clear them on your other devices too. If not, restore them from iCloud.", comment: "Message of the mass-removal question when only watch history vanished; the placeholder is how many watched items (always 3 or more).")
        case .confirmRemovals(let favorites, let history):
            String(localized: "\(favorites + history) favorites and watched items are missing on this device at once. If you removed them, remove them from your other devices too. If not, restore them from iCloud.", comment: "Message of the mass-removal question; the placeholder is how many favorites and watched items vanished (always 3 or more).")
        }
    }
}

/// "Remove … from All Your Devices?" (`CloudSync.Prompt.confirmRemovals`). On Apple TV a page that looks like the
/// system alert, with Not Now focused: a click on the remote changes nothing anywhere, rather than restoring what the
/// user may have removed on purpose (an alert would focus its first button, and put Not Now, the cancel button, last).
private struct HeldRemovalsQuestion: View {
    static var notNowLabel: Text {
        Text("Not Now", comment: "Button of the mass-removal question: decides later; nothing is removed from the other devices meanwhile.")
    }

    static var restoreLabel: Text {
        Text("Restore Them", comment: "Button of the mass-removal question: brings the missing favorites and watched items back from iCloud.")
    }

    static var removeLabel: Text {
        Text("Remove Everywhere", comment: "Button of the mass-removal question: removes the missing favorites and watched items from the user's other devices too.")
    }

    let title: String
    let message: String
    let sync: CloudSync

    #if os(tvOS)
    private enum Choice: Hashable {
        case notNow, restore, remove
    }

    @FocusState private var focused: Choice?

    var body: some View {
        VStack(spacing: 48) {
            VStack(spacing: 24) {
                Text(title)
                    .font(.title2.bold())
                    .accessibilityAddTraits(.isHeader)
                Text(message)
                    .font(.body)
                    .foregroundStyle(.secondary)
            }
            .multilineTextAlignment(.center)
            .frame(maxWidth: 1_100)
            VStack(spacing: 20) {
                Button {
                    sync.postponeHeldRemovals()
                } label: {
                    Self.notNowLabel.frame(minWidth: 620)
                }
                .tvActionButton(prominent: true)
                .focused($focused, equals: .notNow)
                // VoiceOver lands on Not Now, the focused button, and reads only the buttons of a page: the question
                // comes with it (its title is announced as the page opens, below).
                .accessibilityHint(Text(message))
                Button {
                    sync.resolveHeldRemovals(remove: false)
                } label: {
                    Self.restoreLabel.frame(minWidth: 620)
                }
                .tvActionButton()
                .focused($focused, equals: .restore)
                Button(role: .destructive) {
                    sync.resolveHeldRemovals(remove: true)
                } label: {
                    Self.removeLabel
                        .foregroundStyle(TVActionLabelStyle(isProminent: false, isDestructive: true))
                        .frame(minWidth: 620)
                }
                .tvActionButton()
                .focused($focused, equals: .remove)
            }
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
        .defaultFocus($focused, .notNow)
        .task {
            // A full-screen page of its own: VoiceOver says what it asks once the cover is up (posted earlier, the
            // presentation's own screen change would cut it off).
            try? await Task.sleep(for: .milliseconds(700))
            AccessibilityNotification.ScreenChanged(title).post()
        }
    }
    #else
    var body: some View {
        EmptyView()
    }
    #endif
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
                .tvActionButton(prominent: true)
                .focused($focusedRow, equals: "done")
            } else {
                Button {
                    start()
                } label: {
                    Text(addTitle)
                        .frame(minWidth: 420)
                }
                .tvActionButton(prominent: true)
                .disabled(selected.isEmpty)
                .focused($focusedRow, equals: "add")
                Button {
                    sync.dismissImportOffer()
                } label: {
                    Text("Not Now", comment: "Button of the iCloud playlists sheet: closes it without adding playlists.")
                        .frame(minWidth: 240)
                }
                .tvActionButton()
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
        guard selected.count == shown.count, shown.count > 1 else {
            return String(localized: "Add \(selected.count) Playlists", comment: "Button of the iCloud playlists sheet; the placeholder is how many playlists are checked (one: Add Playlist).")
        }
        // "Add All 2 Playlists" is not how anyone says it.
        return shown.count == 2
            ? String(localized: "Add Both Playlists", comment: "Button of the iCloud playlists sheet when it lists two playlists and both are checked.")
            : String(localized: "Add All \(shown.count) Playlists", comment: "Button of the iCloud playlists sheet when every playlist is checked (always three or more); the placeholder is how many.")
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
