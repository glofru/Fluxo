//
//  DownloadCenter+Conversion.swift
//  Fluxo
//
//  The conversion of downloaded files AVPlayer cannot play into MP4 (DownloadCenter), with the remux engine.
//

import AVFoundation
import Foundation
import Observation
import os
import SwiftData
#if canImport(UIKit)
import UIKit
#endif

extension DownloadCenter {
    // MARK: - Conversion

    /// Copies a downloaded original into MP4 (stream copy), then deletes the original.
    func convert(_ id: UUID) {
        guard convertingID == nil, let record = record(id: id), let sourceName = record.transferFileName else {
            if let record = record(id: id), record.transferFileName == nil {
                fail(id, .incomplete, isNetworkError: false)
            }
            return
        }
        let folder = folder(of: id)
        let source = folder.appendingPathComponent(sourceName)
        let destination = folder.appendingPathComponent("media.mp4")
        guard FileManager.default.fileExists(atPath: source.path) else {
            fail(id, .incomplete, isNetworkError: false)
            return
        }
        convertingID = id
        #if canImport(UIKit)
        // A few more seconds to finish if the app goes to the background meanwhile. When they run out, the
        // background task ends at once (the system terminates an app that keeps it past its time): the conversion
        // is then suspended with the app and continues when it comes back. If the app is terminated meanwhile,
        // the record is still Converting and the conversion starts again at the next launch.
        let backgroundTask = BackgroundActivity(name: "Convert download")
        #endif
        Task {
            let result = await Task.detached(priority: .utility) {
                DownloadConversion.convert(source, to: destination)
            }.value
            #if canImport(UIKit)
            backgroundTask.end()
            #endif
            convertingID = nil
            guard self.record(id: id)?.status == .converting else {
                // Deleted meanwhile: the result goes, and the next conversion may start.
                try? FileManager.default.removeItem(at: destination)
                pump()
                return
            }
            switch result {
            case .converted(let duration):
                try? FileManager.default.removeItem(at: source)
                let size = Self.allocatedSize(of: destination)
                update(id) {
                    $0.status = .completed
                    $0.completedOn = .now
                    $0.location = destination.lastPathComponent
                    $0.transferFileName = destination.lastPathComponent
                    $0.bytesOnDisk = size
                    $0.duration = duration > 0 ? duration : $0.duration
                    $0.failureReason = nil
                    $0.isMissing = false
                }
                didComplete(id)
            case .failed(let failure):
                try? FileManager.default.removeItem(at: source)
                fail(id, failure, isNetworkError: false)
            case .later:
                // Still Converting, with its original: converted again once the app is active.
                Self.logger.info("The video encoder is unavailable: the conversion waits for the app to be active")
                conversionsWaitForActiveApp = true
                resumeConversionsLaterIfActive()
            }
            pump()
        }
    }

    /// The encoder was refused although the app is active (it became active during the conversion, or a passing
    /// failure): conversions start again after a while rather than at the next activation.
    private func resumeConversionsLaterIfActive() {
        #if canImport(UIKit)
        guard UIApplication.shared.applicationState == .active else {
            return
        }
        #endif
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(30))
            guard let self, self.conversionsWaitForActiveApp else {
                return
            }
            self.conversionsWaitForActiveApp = false
            self.pump()
        }
    }
}

/// Copies a downloaded file into MP4 with the remux engine: streams AVPlayer plays are copied, the others converted
/// (audio to AAC, video to H.264, every picture kept).
enum DownloadConversion {
    enum Outcome: Sendable {
        case converted(TimeInterval)
        case failed(DownloadFailure)
        /// The video must be converted and the system refuses to encode it now (the app is in the background): the
        /// original is kept, to be converted again once the app is active.
        case later
    }

    nonisolated static func convert(_ source: URL, to destination: URL) -> Outcome {
        // Written under a hidden name and renamed when complete, so a partial MP4 is never taken for a finished one.
        let temporary = destination.deletingLastPathComponent().appendingPathComponent(".converting.mp4")
        try? FileManager.default.removeItem(at: temporary)
        var duration: Double = 0
        var buffer = [CChar](repeating: 0, count: 512)
        let result = source.path.withCString { sourcePointer in
            temporary.path.withCString { destinationPointer in
                buffer.withUnsafeMutableBufferPointer { pointer in
                    fluxo_remux_convert_file(sourcePointer, destinationPointer, &duration, pointer.baseAddress, Int32(pointer.count))
                }
            }
        }
        guard result == 0 else {
            try? FileManager.default.removeItem(at: temporary)
            if result == Int32(FLUXO_REMUX_ERROR_ENCODER_UNAVAILABLE) {
                return .later
            }
            // The engine's message stays in English in the record; it is localized when shown.
            let message = buffer.withUnsafeBufferPointer { String(cString: $0.baseAddress!) }
            return .failed(.unsupportedFormat(engineMessage: message))
        }
        do {
            _ = try FileManager.default.replaceItemAt(destination, withItemAt: temporary)
        } catch {
            try? FileManager.default.removeItem(at: temporary)
            return .failed(.other(error))
        }
        return .converted(duration)
    }
}
