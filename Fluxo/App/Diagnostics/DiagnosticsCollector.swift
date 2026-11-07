//
//  DiagnosticsCollector.swift
//  Fluxo
//
//  Receives the diagnostic and metric reports MetricKit delivers and keeps them on the device
//  (`DiagnosticReportStore`). The system produces them only for people who share analytics with app developers
//  (Settings › Privacy & Security › Analytics & Improvements), on its own schedule: crashes and hangs at the next
//  launch, the metrics about once a day. Fluxo adds nothing to them, sends them nowhere, and keeps them only while
//  "Keep Diagnostic Reports" is on (Settings › About › Diagnostic Reports, `DiagnosticReportsView`).
//
//  iOS 27 and macOS 27: MetricKit's `MetricManager`. macOS 26: `MXMetricManager`. Apple TV has no MetricKit.
//

import Foundation
import os
#if !os(tvOS)
import MetricKit
#endif

@MainActor
final class DiagnosticsCollector {

    static let shared = DiagnosticsCollector()

    static let isCollectingKey = "diagnostics.isCollecting"
    static let isCollectingByDefault = true

    /// Whether this platform has MetricKit.
    nonisolated static var isSupported: Bool {
        #if os(tvOS)
        false
        #else
        true
        #endif
    }

    nonisolated static let logger = Logger(subsystem: "dev.watermelon.Fluxo", category: "Diagnostics")

    let store: DiagnosticReportStore

    private var tasks: [Task<Void, Never>] = []
    /// The MetricKit object the reports come from, kept while collecting.
    private var source: AnyObject?

    init(store: DiagnosticReportStore = .standard) {
        self.store = store
    }

    static var isCollecting: Bool {
        UserDefaults.fluxo.object(forKey: isCollectingKey) as? Bool ?? isCollectingByDefault
    }

    /// At launch: subscribes to MetricKit while the setting is on.
    func start() {
        guard Self.isSupported, Self.isCollecting, source == nil else {
            return
        }
        let store = store
        Task.detached(priority: .utility) {
            store.prune()
        }
        subscribe()
    }

    /// The setting changed. Turned off, the stored reports are deleted too.
    func setCollecting(_ isOn: Bool) {
        UserDefaults.fluxo.set(isOn, forKey: Self.isCollectingKey)
        if isOn {
            start()
        } else {
            stop()
            store.deleteAll()
        }
    }

    private func stop() {
        tasks.forEach { $0.cancel() }
        tasks = []
        #if os(macOS)
        if let subscriber = source as? LegacyMetricSubscriber {
            MXMetricManager.shared.remove(subscriber)
        }
        #endif
        source = nil
    }

    private func subscribe() {
        #if !os(tvOS)
        if #available(iOS 27, macOS 27, *) {
            let manager = MetricManager()
            source = manager
            let store = store
            tasks.append(Task.detached(priority: .utility) {
                for await report in manager.diagnosticReports {
                    Self.save(report, kind: Self.kind(of: report.result), in: store)
                }
            })
            tasks.append(Task.detached(priority: .utility) {
                for await report in manager.metricReports {
                    Self.save(report, kind: .metrics, in: store)
                }
            })
            return
        }
        #endif
        #if os(macOS)
        let subscriber = LegacyMetricSubscriber(store: store)
        MXMetricManager.shared.add(subscriber)
        source = subscriber
        #endif
    }

    // MARK: - Reports

    private nonisolated static func save(_ report: some Encodable, kind: DiagnosticReportEntry.Kind, in store: DiagnosticReportStore) {
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            try store.save(try encoder.encode(report), kind: kind)
            logger.notice("Kept a diagnostic report: \(kind.rawValue, privacy: .public)")
        } catch {
            logger.error("Could not keep a diagnostic report: \(error.localizedDescription, privacy: .public)")
        }
    }

    #if !os(tvOS)
    @available(iOS 27, macOS 27, *)
    private nonisolated static func kind(of result: DiagnosticResult) -> DiagnosticReportEntry.Kind {
        switch result {
        case .crash:
            .crash
        case .hang:
            .hang
        case .cpuException:
            .cpuException
        case .diskWriteException:
            .diskWriteException
        case .appLaunch:
            .launch
        case .memoryException:
            .memoryException
        @unknown default:
            .other
        }
    }
    #endif
}

#if os(macOS)
/// macOS 26, before `MetricManager`: the payloads of `MXMetricManager`, stored as their JSON representation. It calls
/// the subscriber on a queue of its own.
private final class LegacyMetricSubscriber: NSObject, MXMetricManagerSubscriber, Sendable {
    let store: DiagnosticReportStore

    init(store: DiagnosticReportStore) {
        self.store = store
    }

    func didReceive(_ payloads: [MXMetricPayload]) {
        for payload in payloads {
            keep(payload.jsonRepresentation(), kind: .metrics)
        }
    }

    func didReceive(_ payloads: [MXDiagnosticPayload]) {
        for payload in payloads {
            let kind: DiagnosticReportEntry.Kind
            if !(payload.crashDiagnostics ?? []).isEmpty {
                kind = .crash
            } else if !(payload.hangDiagnostics ?? []).isEmpty {
                kind = .hang
            } else if !(payload.cpuExceptionDiagnostics ?? []).isEmpty {
                kind = .cpuException
            } else if !(payload.diskWriteExceptionDiagnostics ?? []).isEmpty {
                kind = .diskWriteException
            } else {
                kind = .other
            }
            keep(payload.jsonRepresentation(), kind: kind)
        }
    }

    private func keep(_ json: Data, kind: DiagnosticReportEntry.Kind) {
        do {
            try store.save(json, kind: kind)
            DiagnosticsCollector.logger.notice("Kept a diagnostic report: \(kind.rawValue, privacy: .public)")
        } catch {
            DiagnosticsCollector.logger.error("Could not keep a diagnostic report: \(error.localizedDescription, privacy: .public)")
        }
    }
}
#endif
