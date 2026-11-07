//
//  LibraryRecoveryView.swift
//  Fluxo
//
//  Shown in every window when the library store cannot be opened (`LibrarySession`). It says why, in words, and
//  offers what can help: Try Again (and on its own once the device is unlocked), Export a Copy (to keep the file or
//  send it for help), Start with an Empty Library (the library goes to a backup on this device, never deleted; iCloud
//  sync then offers to restore what it has). Nothing else of the app runs meanwhile.
//

import SwiftUI
import UniformTypeIdentifiers

struct LibraryRecoveryView: View {

    let session: LibrarySession
    let failure: LibraryOpenFailure

    @State private var confirmsStartOver = false
    #if !os(tvOS)
    @State private var archive: LibraryArchive?
    @State private var isExporting = false
    #endif
    @State private var errorMessage: String?
    @State private var attempts = 0
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    #if os(tvOS)
    private static let textWidth: CGFloat = 1_100
    private static let buttonWidth: CGFloat = 640
    #else
    private static let textWidth: CGFloat = 520
    private static let buttonWidth: CGFloat = 360
    #endif

    /// At accessibility sizes the text is long: the actions stay pinned at the bottom, always in reach, and the text
    /// reads from the leading edge.
    private var pinsActions: Bool {
        dynamicTypeSize.isAccessibilitySize
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                Image(systemName: symbol)
                    .font(.system(size: 56, weight: .regular))
                    .foregroundStyle(Theme.warning)
                    .accessibilityHidden(true)
                VStack(spacing: 12) {
                    Text(title)
                        .font(.title2.bold())
                        .accessibilityAddTraits(.isHeader)
                    Text(message)
                        .foregroundStyle(.secondary)
                    if attempts > 0, session.failure == failure {
                        Text("Still not possible. Try again later.", comment: "Library recovery screen: shown under the explanation after Try Again failed once more.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
                .multilineTextAlignment(pinsActions ? .leading : .center)
                .frame(maxWidth: .infinity, alignment: pinsActions ? .leading : .center)
                .fixedSize(horizontal: false, vertical: true)

                actions

                Text(footnote)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(pinsActions ? .leading : .center)
                    .frame(maxWidth: .infinity, alignment: pinsActions ? .leading : .center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: Self.textWidth)
            .padding(.horizontal, 24)
            .padding(.vertical, pinsActions ? 24 : 48)
            .frame(maxWidth: .infinity)
        }
        .scrollBounceBehavior(.basedOnSize)
        .safeAreaInset(edge: .bottom) {
            if pinsActions {
                tryAgainButton
                    .frame(maxWidth: Self.buttonWidth)
                    .padding(.horizontal, 24)
                    .padding(.vertical, 12)
                    .frame(maxWidth: .infinity)
                    .background(.regularMaterial)
            }
        }
        .tint(Theme.accent)
        .confirmationDialog(
            String(localized: "Start with an Empty Library?", comment: "Library recovery screen: title of the confirmation before starting over with an empty library."),
            isPresented: $confirmsStartOver,
            titleVisibility: .visible
        ) {
            Button(String(localized: "Start with an Empty Library", comment: "Library recovery screen: confirms starting over with an empty library (the current one is kept as a backup)."), role: .destructive) {
                startOver()
            }
            Button(String(localized: "Cancel", comment: "Cancels a confirmation."), role: .cancel) {}
        } message: {
            Text("Your current library is kept as a backup on this device, so nothing is deleted. If iCloud sync was on, Fluxo then offers to restore your playlists, guides and favorites from iCloud.", comment: "Library recovery screen: message of the confirmation before starting over with an empty library.")
        }
        .alert(
            String(localized: "Something Went Wrong", comment: "Library recovery screen: title of an alert when exporting or starting over failed."),
            isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } }),
            presenting: errorMessage
        ) { _ in
            Button(String(localized: "OK", comment: "Dismisses an alert.")) {}
        } message: { message in
            Text(message)
        }
        #if !os(tvOS)
        .fileExporter(isPresented: $isExporting, document: archive, contentType: .zip, defaultFilename: archive?.fileName) { result in
            if case .failure(let error) = result {
                errorMessage = error.localizedDescription
            }
            archive = nil
        }
        #endif
    }

    @ViewBuilder
    private var actions: some View {
        VStack(spacing: 12) {
            if !pinsActions {
                tryAgainButton
            }

            #if !os(tvOS)
            if canExport {
                Button {
                    export()
                } label: {
                    Text("Export a Copy…", comment: "Library recovery screen: saves a copy of the library file (for example in Files), to keep it or send it for help.")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
                .disabled(session.isWorking)
            }
            #endif

            Button(role: .destructive) {
                confirmsStartOver = true
            } label: {
                Text("Start with an Empty Library…", comment: "Library recovery screen: starts over with an empty library; the current one is kept as a backup (asks first).")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .controlSize(.large)
            // The one destructive action stands out (the screen's tint would make it look like the others).
            .tint(Theme.error)
            .disabled(session.isWorking || session.location == nil)
        }
        .frame(maxWidth: Self.buttonWidth)
    }

    private var tryAgainButton: some View {
        Button {
            attempts += 1
            session.retry()
        } label: {
            Text("Try Again", comment: "Library recovery screen: tries to open the library again.")
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
        .disabled(session.isWorking)
    }

    // MARK: - Text

    private var symbol: String {
        switch failure {
        case .newerVersion:
            return "arrow.down.app"
        case .temporarilyUnavailable:
            return "lock"
        case .notEnoughSpace:
            return "externaldrive.badge.exclamationmark"
        case .damaged, .cannotOpen:
            return "exclamationmark.triangle"
        }
    }

    private var title: String {
        switch failure {
        case .newerVersion:
            return String(localized: "Update Fluxo to Open Your Library", comment: "Library recovery screen title: the library was last used by a newer version of the app.")
        case .temporarilyUnavailable:
            return String(localized: "Your Library Can't Be Read Right Now", comment: "Library recovery screen title: the library file cannot be read at the moment (the device is locked, or a storage error).")
        case .notEnoughSpace:
            return String(localized: "Not Enough Space to Open Your Library", comment: "Library recovery screen title: the library needs to be updated and the device is almost full.")
        case .damaged:
            return String(localized: "Your Library Is Damaged", comment: "Library recovery screen title: the library file is damaged and cannot be read.")
        case .cannotOpen:
            return String(localized: "Fluxo Can't Open Your Library", comment: "Library recovery screen title: the library cannot be opened for another reason.")
        }
    }

    private var message: String {
        switch failure {
        case .newerVersion:
            return String(localized: "Your library was last used by a newer version of Fluxo, and this version can't open it without losing what the newer one added. Update Fluxo from the App Store, then open it again.", comment: "Library recovery screen: explanation when the library was written by a newer version of the app.")
        case .temporarilyUnavailable:
            return String(localized: "Fluxo couldn't read its library file. This happens while the device is locked after a restart. Unlock it, then try again. If it keeps happening, restart the device.", comment: "Library recovery screen: explanation when the library file cannot be read right now.")
        case .notEnoughSpace:
            return String(localized: "This version of Fluxo needs to update your library, and there isn't enough free space on this device to do it. Free up some space, then try again.", comment: "Library recovery screen: explanation when there is not enough free space to update the library.")
        case .damaged:
            #if os(tvOS)
            return String(localized: "Fluxo's library file is damaged and can't be read. You can start with an empty library: the damaged one is kept on this Apple TV.", comment: "Apple TV library recovery screen: explanation when the library file is damaged (there is no export on Apple TV).")
            #else
            if canExport {
                return String(localized: "Fluxo's library file is damaged and can't be read. You can export a copy to keep it, or start with an empty library.", comment: "Library recovery screen: explanation when the library file is damaged.")
            }
            return String(localized: "Fluxo's library file is damaged and can't be read. You can start with an empty library.", comment: "Library recovery screen: explanation when the library is damaged and there is no library file left to export.")
            #endif
        case .cannotOpen:
            return String(localized: "Something prevented Fluxo from opening its library. Nothing has been deleted. Try again, or check for an update to Fluxo.", comment: "Library recovery screen: explanation when the library cannot be opened for an unknown reason.")
        }
    }

    private var footnote: String {
        #if os(tvOS)
        String(localized: "Your library holds your playlists, TV guides, favorites, watch history and reminders. Fluxo never deletes it on its own. Recordings are kept separately and aren't affected.", comment: "Apple TV library recovery screen: footnote explaining what the library is and that it is never deleted automatically (Apple TV has recordings but no offline downloads).")
        #else
        String(localized: "Your library holds your playlists, TV guides, favorites, watch history and reminders. Fluxo never deletes it on its own. Offline downloads and recordings are kept separately and aren't affected.", comment: "Library recovery screen: footnote explaining what the library is and that it is never deleted automatically.")
        #endif
    }

    // MARK: - Actions

    #if !os(tvOS)
    private var canExport: Bool {
        guard failure != .temporarilyUnavailable, let location = session.location else {
            return false
        }
        return FileManager.default.fileExists(atPath: location.userStoreURL.path)
    }

    private func export() {
        guard let location = session.location else {
            return
        }
        do {
            archive = LibraryArchive(url: try LibraryStore.makeArchive(of: location.userStoreURL))
            isExporting = true
        } catch {
            errorMessage = error.localizedDescription
        }
    }
    #endif

    private func startOver() {
        do {
            try session.startOver()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

/// Shown while the store of an earlier version is split (`LibrarySession.State.upgrading`), once, for a few seconds.
struct LibraryUpgradeView: View {
    /// The launch that only compacts the library takes a moment: no progress flashes by for it.
    @State private var showsProgress = false

    var body: some View {
        VStack(spacing: 16) {
            ProgressView()
                .controlSize(.large)
            Text("Updating Your Library…", comment: "Shown once, for a few seconds, while the app prepares the library saved by an earlier version.")
                .font(.headline)
            Text("This happens once, after an update.", comment: "Under 'Updating Your Library…': the wait happens only once.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .multilineTextAlignment(.center)
        .padding(32)
        .opacity(showsProgress ? 1 : 0)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .combine)
        .accessibilityHidden(!showsProgress)
        .task {
            try? await Task.sleep(for: .milliseconds(600))
            withAnimation(.easeIn(duration: 0.2)) {
                showsProgress = true
            }
        }
    }
}

#if !os(tvOS)
/// A ZIP archive of a library, for `fileExporter`.
struct LibraryArchive: FileDocument {
    static let readableContentTypes: [UTType] = [.zip]

    let url: URL

    var fileName: String {
        url.deletingPathExtension().lastPathComponent
    }

    init(url: URL) {
        self.url = url
    }

    init(configuration: ReadConfiguration) throws {
        throw CocoaError(.featureUnsupported)
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        try FileWrapper(url: url, options: .immediate)
    }
}
#endif
