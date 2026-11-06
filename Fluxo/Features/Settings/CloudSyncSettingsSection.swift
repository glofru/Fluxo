//
//  CloudSyncSettingsSection.swift
//  Fluxo
//
//  Settings › iCloud: the sync switch, its status, the playlists of iCloud this device does not have, and what is
//  synced and how it is protected (`CloudSyncPrivacyView`). Shared by the iPhone, iPad and Mac Settings and the Apple
//  TV's.
//

import SwiftUI

struct CloudSyncSettingsSection: View {

    @Environment(CloudSync.self) private var sync
    #if os(macOS)
    @State private var showsPrivacy = false
    #endif
    #if DEBUG
    @FocusState private var debugFocus: String?
    #endif

    var body: some View {
        #if DEBUG
        section
        #else
        // A build without the iCloud capability (the ad hoc signed Mac build) has nothing to offer here.
        if sync.isConfigured {
            section
        }
        #endif
    }

    private var section: some View {
        Section {
            Toggle(isOn: Binding(get: { sync.isEnabled }, set: { sync.setEnabled($0) })) {
                #if os(tvOS)
                // As the other rows of the Apple TV Settings: a plain symbol, no tile.
                Label {
                    Text("Sync with iCloud", comment: "Settings › iCloud: the switch that turns iCloud sync on or off.")
                } icon: {
                    Image(systemName: "icloud")
                }
                #else
                SettingsLabel("Sync with iCloud", systemImage: "icloud.fill", tint: Theme.accent)
                #endif
            }
            .disabled(!sync.isConfigured)
            #if DEBUG
            .focused($debugFocus, equals: "sync-toggle")
            #endif

            if sync.isEnabled || !sync.isConfigured {
                LabeledContent {
                    CloudSyncStatusText()
                } label: {
                    rowTitle(Text("Status", comment: "Settings › iCloud: label of the sync status (Up to Date, Syncing…, the problem)."), systemImage: statusSymbol)
                }
                .accessibilityElement(children: .combine)
                #if os(tvOS)
                // Focusable, so the remote (and VoiceOver) reaches the status between the switch and the rows under it.
                .focusable()
                #endif
            }

            if sync.isEnabled && sync.isConfigured {
                if !sync.cloudPlaylists.isEmpty {
                    Button {
                        sync.presentImportSheet()
                    } label: {
                        LabeledContent {
                            Text("\(sync.cloudPlaylists.count) not on this device", comment: "Settings › iCloud: how many playlists of the user's other devices this device does not have; the row opens the list to add them.")
                        } label: {
                            rowTitle(Text("Playlists in iCloud", comment: "Settings › iCloud: opens the playlists of the user's other devices, to add them to this one."), systemImage: "square.and.arrow.down.on.square")
                        }
                    }
                }

                Button {
                    sync.syncNow()
                } label: {
                    rowTitle(Text("Sync Now", comment: "Settings › iCloud: button that syncs with iCloud at once."), systemImage: "arrow.triangle.2.circlepath.icloud")
                }
                .disabled(sync.isSyncing || sync.availability != .available)
            }

            privacyRow
                #if DEBUG
                .focused($debugFocus, equals: "privacy")
                #endif
        } header: {
            Text("iCloud", comment: "Settings: title of the iCloud sync section.")
        } footer: {
            Text("Your playlists, the TV guides you added, favorites, watch progress and player settings stay the same on your iPhone, iPad, Mac and Apple TV. Playlist addresses are encrypted before they leave this device.", comment: "Settings › iCloud: footer that says what sync does.")
        }
        .id("icloud")
        #if os(macOS)
        .sheet(isPresented: $showsPrivacy) {
            NavigationStack {
                CloudSyncPrivacyView()
            }
            .frame(minWidth: 520, minHeight: 560)
        }
        #endif
        #if DEBUG
        .onReceive(NotificationCenter.default.publisher(for: .fluxoDebugCloudFocus)) { notification in
            debugFocus = notification.object as? String
        }
        #endif
    }

    /// The status row's symbol follows the status: synced, a problem, or no sync.
    private var statusSymbol: String {
        if !sync.isConfigured || sync.availability == .noAccount || sync.availability == .restricted || sync.availability == .notConfigured {
            return "icloud.slash"
        }
        if sync.lastError != nil || sync.availability == .temporarilyUnavailable {
            return "exclamationmark.icloud"
        }
        return sync.isSyncing ? "arrow.triangle.2.circlepath.icloud" : "checkmark.icloud"
    }

    private var privacyTitle: Text {
        Text("What's Synced and Privacy", comment: "Settings › iCloud: opens the page that lists what iCloud sync stores and how stream addresses are protected.")
    }

    /// A pushed page where Settings is a navigation stack (iPhone, iPad, Apple TV); a sheet in the Mac's Settings
    /// window.
    @ViewBuilder
    private var privacyRow: some View {
        #if os(macOS)
        Button {
            showsPrivacy = true
        } label: {
            rowTitle(privacyTitle, systemImage: "lock.icloud")
        }
        #elseif os(tvOS)
        // A route of the Settings stack (`TVSettingsScreen`), which the debug harness can push too.
        NavigationLink(value: TVSettingsRoute.cloudPrivacy) {
            rowTitle(privacyTitle, systemImage: "lock.icloud")
        }
        #else
        NavigationLink {
            CloudSyncPrivacyView(isModal: false)
        } label: {
            rowTitle(privacyTitle, systemImage: "lock.icloud")
        }
        #endif
    }

    private func rowTitle(_ title: Text, systemImage: String) -> some View {
        Label {
            title
        } icon: {
            Image(systemName: systemImage)
        }
    }
}

/// The sync status in one line.
struct CloudSyncStatusText: View {

    @Environment(CloudSync.self) private var sync

    var body: some View {
        Group {
            if !sync.isConfigured {
                Text("Not available in this build", comment: "Settings › iCloud status: the app was built without the iCloud capability (unsigned or ad hoc signed builds).")
            } else if !sync.isEnabled {
                Text("Off", comment: "Settings › iCloud status: sync is turned off.")
            } else {
                switch sync.availability {
                case .checking:
                    Text("Checking…", comment: "Settings › iCloud status: the app is checking the iCloud account.")
                case .noAccount:
                    Text("Sign in to iCloud to sync", comment: "Settings › iCloud status: the device is not signed in to an Apple Account with iCloud.")
                case .restricted:
                    Text("iCloud is restricted on this device", comment: "Settings › iCloud status: Screen Time or a device management profile does not allow iCloud.")
                case .temporarilyUnavailable:
                    Text("iCloud is not available right now", comment: "Settings › iCloud status: the account is temporarily unavailable (for example while it is being set up).")
                case .notConfigured:
                    Text("Not available in this build")
                case .available:
                    if sync.isSyncing {
                        Text("Syncing…", comment: "Settings › iCloud status: a sync is running.")
                    } else if let error = sync.lastError {
                        Text(error)
                            .foregroundStyle(Theme.error)
                    } else if let date = sync.lastSyncedOn {
                        Text("Synced \(date, format: .relative(presentation: .named))", comment: "Settings › iCloud status: when the last sync finished; the placeholder is a relative time such as '2 minutes ago'.")
                    } else {
                        Text("Up to Date", comment: "Settings › iCloud status: nothing to sync.")
                    }
                }
            }
        }
        .foregroundStyle(Theme.secondaryText)
        .multilineTextAlignment(.trailing)
    }
}

/// What iCloud sync stores, what it does not, how stream addresses are protected, and Delete iCloud Data.
struct CloudSyncPrivacyView: View {

    /// Presented as a sheet (with Done), or pushed.
    var isModal = true

    @Environment(CloudSync.self) private var sync
    @Environment(\.dismiss) private var dismiss
    @State private var confirmsDeletion = false
    @State private var deletionError: String?
    @State private var isDeleting = false

    var body: some View {
        Form {
            Section {
                bullet(Text("Playlists: their names and addresses", comment: "iCloud privacy page: an item of the list of what iCloud sync stores."), systemImage: "list.bullet.rectangle", debugName: "privacy-playlists")
                bullet(Text("TV guides you added, and whether they're on", comment: "iCloud privacy page: an item of the list of what iCloud sync stores."), systemImage: "calendar.day.timeline.left")
                bullet(Text("Favorites, in your order", comment: "iCloud privacy page: an item of the list of what iCloud sync stores."), systemImage: "star")
                bullet(Text("Watch history and where you stopped each movie and episode", comment: "iCloud privacy page: an item of the list of what iCloud sync stores."), systemImage: "clock.arrow.circlepath")
                bullet(Text("Time-shift and skip intervals, audio and subtitle languages, reminder time", comment: "iCloud privacy page: an item of the list of what iCloud sync stores."), systemImage: "slider.horizontal.3")
            } header: {
                Text("What's Synced", comment: "iCloud privacy page: title of the list of what is synced.")
            } footer: {
                Text("Channels, programmes and artwork are downloaded by each device from your providers. Downloads, recordings and settings that belong to one device stay on it.", comment: "iCloud privacy page: what is not synced.")
            }

            Section {
                Text("Stream addresses can contain the account name and password of your provider. Fluxo keeps them in your private iCloud database, which only your Apple Account can read, and encrypts them on this device before they're sent. They're encrypted in transit and on Apple's servers.", comment: "iCloud privacy page: how stream addresses are protected with standard iCloud data protection.")
                    .readableWithRemote()
                Text("Turn on Advanced Data Protection for iCloud to have them end-to-end encrypted: only your trusted devices then have the keys, and not even Apple can read them. Without it, Apple keeps the keys, so it can help you recover your data.", comment: "iCloud privacy page: what Advanced Data Protection changes for the synced stream addresses.")
                    .readableWithRemote()
                Text(adpLocation)
                    .foregroundStyle(Theme.secondaryText)
                    .readableWithRemote(debugName: "privacy-adp")
            } header: {
                Text("How Your Addresses Are Protected", comment: "iCloud privacy page: title of the section about encryption.")
            }

            Section {
                Button(role: .destructive) {
                    confirmsDeletion = true
                } label: {
                    if isDeleting {
                        HStack {
                            Text("Deleting…", comment: "iCloud privacy page: shown while the synced data is being deleted from iCloud.")
                            Spacer()
                            ProgressView()
                        }
                    } else {
                        Text("Delete iCloud Data…", comment: "iCloud privacy page: button that deletes everything Fluxo stored in iCloud.")
                    }
                }
                .disabled(!sync.isConfigured || isDeleting || sync.availability != .available)
            } footer: {
                if let deletionError {
                    Text(deletionError)
                        .foregroundStyle(Theme.error)
                } else {
                    Text("Removes your playlists, guides, favorites, history and settings from iCloud and turns sync off. Nothing is removed from your devices.", comment: "iCloud privacy page: what Delete iCloud Data does.")
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle(Text("iCloud Sync", comment: "Title of the iCloud privacy page."))
        .toolbar {
            if isModal {
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        dismiss()
                    } label: {
                        Text("Done")
                    }
                }
            }
        }
        .confirmationDialog(
            Text("Delete Fluxo's Data from iCloud?", comment: "Title of the confirmation of Delete iCloud Data."),
            isPresented: $confirmsDeletion,
            titleVisibility: .visible
        ) {
            Button(role: .destructive) {
                deleteCloudData()
            } label: {
                Text("Delete iCloud Data", comment: "Confirmation button of Delete iCloud Data.")
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Your other devices keep their playlists and stop syncing. Turn sync on again to upload this device's library.", comment: "Message of the confirmation of Delete iCloud Data.")
        }
    }

    private func bullet(_ title: Text, systemImage: String, debugName: String? = nil) -> some View {
        Label {
            title
        } icon: {
            Image(systemName: systemImage)
                .foregroundStyle(Theme.accent)
        }
        .readableWithRemote(debugName: debugName)
    }

    private var adpLocation: String {
        #if os(macOS)
        return String(localized: "On a Mac: System Settings › your name › iCloud › Advanced Data Protection.", comment: "iCloud privacy page: where to turn on Advanced Data Protection on a Mac. Use the names System Settings shows in this language.")
        #elseif os(tvOS)
        return String(localized: "Turn it on from your iPhone or iPad (Settings › your name › iCloud › Advanced Data Protection) or your Mac (System Settings › your name › iCloud › Advanced Data Protection).", comment: "iCloud privacy page on Apple TV: Advanced Data Protection is turned on from another device. Use the names the Settings app (iPhone, iPad) and System Settings (Mac) show in this language.")
        #else
        return String(localized: "On this device: Settings › your name › iCloud › Advanced Data Protection.", comment: "iCloud privacy page: where to turn on Advanced Data Protection on an iPhone or iPad. Use the names the Settings app shows in this language.")
        #endif
    }

    private func deleteCloudData() {
        isDeleting = true
        deletionError = nil
        Task {
            do {
                try await sync.deleteCloudData()
            } catch {
                deletionError = error.localizedDescription
            }
            isDeleting = false
        }
    }
}

private extension View {
    /// Apple TV: the focus engine scrolls only to what can be focused, so each line of a page to read is focusable
    /// (the remote then walks through it; VoiceOver reads it as it is focused), and the focused line is tinted, so
    /// the reader sees where they are. Nothing elsewhere.
    @ViewBuilder
    func readableWithRemote(debugName: String? = nil) -> some View {
        #if os(tvOS)
        modifier(ReadableWithRemote(debugName: debugName))
        #else
        self
        #endif
    }
}

#if os(tvOS)
private struct ReadableWithRemote: ViewModifier {
    /// The debug harness's name of the line (`cloud-focus:<name>`), for screenshots of the focused state.
    let debugName: String?

    @FocusState private var isFocused: Bool

    func body(content: Content) -> some View {
        content
            .focusable()
            .focused($isFocused)
            // The system's row platter, tinted while the line has the focus.
            .listRowBackground(isFocused ? RoundedRectangle(cornerRadius: 24, style: .continuous).fill(Theme.accent.opacity(0.3)) : nil)
            .animation(.easeOut(duration: 0.15), value: isFocused)
            #if DEBUG
            .onReceive(NotificationCenter.default.publisher(for: .fluxoDebugCloudFocus)) { notification in
                if let debugName, notification.object as? String == debugName {
                    isFocused = true
                }
            }
            #endif
    }
}
#endif
