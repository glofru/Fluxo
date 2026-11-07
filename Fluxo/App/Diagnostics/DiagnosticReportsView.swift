//
//  DiagnosticReportsView.swift
//  Fluxo
//
//  Settings › About › Diagnostic Reports (iPhone, iPad and Mac; Apple TV has no MetricKit): whether Fluxo keeps the
//  reports the system gives it (`DiagnosticsCollector`), the reports kept on this device, and the two things the user
//  can do with them: share them (one JSON file, through the share sheet, wherever the user chooses), or delete them.
//  Nothing is sent anywhere by the app.
//

#if !os(tvOS)
import SwiftUI

struct DiagnosticReportsView: View {

    /// Presented as a sheet (with Done; the Mac's Settings window), or pushed.
    var isModal = false

    @Environment(\.dismiss) private var dismiss
    @AppStorage(DiagnosticsCollector.isCollectingKey) private var isCollecting = DiagnosticsCollector.isCollectingByDefault
    @State private var entries: [DiagnosticReportEntry] = []
    @State private var exportURL: URL?
    @State private var confirmsDeletion = false

    private let store = DiagnosticsCollector.shared.store

    var body: some View {
        Form {
            Section {
                Toggle(isOn: $isCollecting) {
                    Text("Keep Diagnostic Reports", comment: "Settings › About › Diagnostic Reports: the switch that lets Fluxo keep the crash and performance reports the system gives it.")
                }
            } footer: {
                Text("If you share analytics with app developers (Settings › Privacy & Security › Analytics & Improvements), the system gives Fluxo reports about its crashes, hangs and performance. Fluxo keeps the latest ones on this device only and never sends them anywhere: they leave it only if you share them yourself.", comment: "Settings › About › Diagnostic Reports: footer of the switch. Name the system settings as the system does in the user's language.")
            }

            Section {
                if entries.isEmpty {
                    Text("No reports. The system delivers them at most once a day, and only on devices that share analytics with app developers.", comment: "Settings › About › Diagnostic Reports: shown when no report has been kept.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(entries) { entry in
                        DiagnosticReportRow(entry: entry)
                    }
                    #if !os(macOS)
                    .onDelete { offsets in
                        offsets.map { entries[$0] }.forEach(store.delete)
                        refresh()
                    }
                    #endif
                }
            } header: {
                Text("Reports", comment: "Settings › About › Diagnostic Reports: header of the list of kept reports.")
            }

            if !entries.isEmpty {
                Section {
                    if let exportURL {
                        ShareLink(item: exportURL) {
                            Label {
                                Text("Share Reports…", comment: "Settings › About › Diagnostic Reports: shares the kept reports as one file (share sheet).")
                            } icon: {
                                Image(systemName: "square.and.arrow.up")
                            }
                        }
                    }
                    Button(role: .destructive) {
                        confirmsDeletion = true
                    } label: {
                        Label {
                            Text("Delete All Reports", comment: "Settings › About › Diagnostic Reports: deletes every kept report.")
                        } icon: {
                            Image(systemName: "trash")
                        }
                    }
                } footer: {
                    Text("The file holds the reports as the system writes them: the app and system versions, the device model, and the code addresses involved. It holds nothing from your library, such as channel names or playlist addresses.", comment: "Settings › About › Diagnostic Reports: what the shared file contains.")
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle(Text("Diagnostic Reports", comment: "Title of Settings › About › Diagnostic Reports."))
        .largeTitleAdaptingToTextSize()
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
        .confirmationDialog(Text("Delete All Diagnostic Reports?", comment: "Settings › About › Diagnostic Reports: title of the confirmation before deleting them."), isPresented: $confirmsDeletion, titleVisibility: .visible) {
            Button(role: .destructive) {
                store.deleteAll()
                refresh()
            } label: {
                Text("Delete All Reports", comment: "Settings › About › Diagnostic Reports: deletes every kept report.")
            }
            Button("Cancel", role: .cancel) {}
        }
        .onAppear(perform: refresh)
        .onChange(of: isCollecting) { _, isOn in
            DiagnosticsCollector.shared.setCollecting(isOn)
            refresh()
        }
    }

    private func refresh() {
        entries = store.entries()
        exportURL = try? store.makeExport(appVersion: SettingsViewModel.appVersion)
    }
}

private struct DiagnosticReportRow: View {
    let entry: DiagnosticReportEntry

    var body: some View {
        Label {
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.kind.title)
                Text(entry.receivedOn, format: .dateTime.year().month().day().hour().minute())
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        } icon: {
            Image(systemName: entry.kind.systemImage)
                .foregroundStyle(entry.kind == .metrics ? Theme.cyan : .orange)
        }
        .accessibilityElement(children: .combine)
    }
}

extension DiagnosticReportEntry.Kind {
    var title: String {
        switch self {
        case .crash:
            String(localized: "Crash", comment: "Settings › About › Diagnostic Reports: a report of the app quitting unexpectedly.")
        case .hang:
            String(localized: "Hang", comment: "Settings › About › Diagnostic Reports: a report of the app not responding for a while.")
        case .cpuException:
            String(localized: "High Processor Use", comment: "Settings › About › Diagnostic Reports: a report of the app using the processor heavily for a long time.")
        case .diskWriteException:
            String(localized: "Heavy Storage Writes", comment: "Settings › About › Diagnostic Reports: a report of the app writing a lot of data to storage.")
        case .launch:
            String(localized: "Slow Launch", comment: "Settings › About › Diagnostic Reports: a report of the app taking long to open.")
        case .memoryException:
            String(localized: "Memory Limit Reached", comment: "Settings › About › Diagnostic Reports: a report of the app using more memory than the system allows.")
        case .metrics:
            String(localized: "Daily Performance Metrics", comment: "Settings › About › Diagnostic Reports: the system's daily summary of the app's performance (launch time, battery, memory, network use).")
        case .other:
            String(localized: "Other Report", comment: "Settings › About › Diagnostic Reports: a kind of report this version does not know.")
        }
    }

    var systemImage: String {
        switch self {
        case .crash:
            "exclamationmark.triangle"
        case .hang:
            "hourglass"
        case .cpuException:
            "cpu"
        case .diskWriteException:
            "internaldrive"
        case .launch:
            "timer"
        case .memoryException:
            "memorychip"
        case .metrics:
            "chart.bar"
        case .other:
            "doc.text"
        }
    }
}
#endif
