//
//  DownloadCenter+Transfers.swift
//  Fluxo
//
//  The queue of the offline downloads (DownloadCenter) and their transfers: probing a link, the free space, the
//  events of DownloadTransport, completion, failures and retries.
//

import AVFoundation
import Foundation
import Observation
import os
import SwiftData

extension DownloadCenter {
    // MARK: - Queue

    /// Starts queued downloads while transfer slots are free, and the next conversion.
    func pump() {
        // Not before the restored transfers are matched: a record could be started twice.
        guard isReady else {
            return
        }
        if convertingID == nil, !conversionsWaitForActiveApp, let next = records.first(where: { $0.status == .converting }) {
            convert(next.id)
        }
        guard NetworkMonitor.shared.isOnline else {
            // Transfers wait; they start when the network returns.
            return
        }
        var running = records.count(where: { ($0.status == .downloading || $0.status == .preparing) })
        let now = Date.now
        for record in records where record.status == .queued && !stopping.contains(record.id) {
            if let notBefore = retryNotBefore[record.id], notBefore > now {
                // Waiting for its automatic retry: the queue goes on with the next ones meanwhile.
                continue
            }
            guard running < DownloadPreferences.maximumConcurrentTransfers else {
                break
            }
            running += 1
            begin(record.id)
        }
    }

    /// Probes the link if needed, checks the space and starts the transfer.
    private func begin(_ id: UUID) {
        guard !starting.contains(id) else {
            return
        }
        starting.insert(id)
        retryNotBefore[id] = nil
        update(id) { $0.status = .preparing }
        Task {
            defer {
                starting.remove(id)
            }
            do {
                try await startTransfer(id)
            } catch {
                guard record(id: id)?.status == .preparing else {
                    return
                }
                // The probe and the HLS loading wrap their errors: a timeout or a dropped connection there is
                // retried like one during the transfer.
                let failure = DownloadTransport.failure(from: error)
                fail(id, failure, isNetworkError: failure.isNetworkError || DownloadTransport.isNetworkError(error))
            }
        }
    }

    private func startTransfer(_ id: UUID) async throws {
        guard var record = record(id: id) else {
            return
        }
        let allowsCellular = DownloadPreferences.allowsCellular

        // A suspended HLS task (paused in this run, or restored after a relaunch) continues as it is, unless it
        // runs in the session of the other Cellular Data setting: then it starts again from its partial package.
        if record.method == .hls, transport.hasTask(id: id) {
            if transport.sessionKind(of: id)?.allowsCellular == allowsCellular, transport.resume(id: id) {
                update(id) { $0.status = .downloading }
                return
            }
            transport.cancel(id: id)
        }

        if record.method == nil || (record.method != .hls && record.transferFileName == nil) {
            let probe: DownloadProbe
            do {
                probe = try await DownloadProbe.probe(record.item.url)
            } catch let failure as DownloadFailure where failure.isExpiredLink {
                if let renewed = await renewedItem(for: record), renewed.url != record.item.url {
                    update(id) { $0.item = renewed }
                    record.item = renewed
                    probe = try await DownloadProbe.probe(renewed.url)
                } else {
                    throw failure
                }
            }
            if probe.kind == .remux("bin") {
                Self.logger.info("Unrecognized content; it will be converted")
            }
            if let expected = probe.expectedBytes, let available = PlatformStorage.availableCapacity(at: directory) {
                // A converted file needs room for the original and the MP4 until the original is deleted.
                let needed = expected * (probe.method == .remux ? 2 : 1) + DownloadPreferences.freeSpaceMargin
                if needed > available {
                    throw DownloadFailure.insufficientSpace
                }
            }
            update(id) {
                $0.method = probe.method
                $0.transferFileName = probe.transferFileName
                $0.bytesExpected = probe.expectedBytes
            }
            record = self.record(id: id) ?? record
        }
        guard self.record(id: id)?.status == .preparing else {
            return
        }

        if record.artworkFileName == nil, let name = await saveArtwork(for: record) {
            update(id) { $0.artworkFileName = name }
        }
        guard self.record(id: id)?.status == .preparing, let method = record.method else {
            return
        }

        switch method {
        case .hls:
            let partial = record.location.map(Self.homeURL(forRelativePath:))
            let plan = try await transport.startHLS(
                id: id,
                url: record.item.url,
                partialLocation: partial,
                title: TextParts.line([record.title, record.episodeLine]),
                artwork: artworkData(for: record),
                quality: DownloadPreferences.quality,
                allowsCellular: allowsCellular,
                availableBytes: PlatformStorage.availableCapacity(at: directory)
            )
            guard self.record(id: id)?.status == .preparing else {
                // Paused or deleted while the stream was loading.
                if self.record(id: id)?.status == .paused {
                    transport.suspend(id: id)
                } else {
                    transport.cancel(id: id)
                }
                return
            }
            update(id) {
                $0.status = .downloading
                $0.allowsCellular = allowsCellular
                $0.qualityHeight = plan.qualityHeight ?? $0.qualityHeight
                $0.bytesExpected = plan.expectedBytes ?? $0.bytesExpected
                $0.duration = plan.duration ?? $0.duration
                $0.audioLanguages = plan.audioLanguages
                $0.subtitleLanguages = plan.subtitleLanguages
            }
            progress(for: self.record(id: id) ?? record).bytesExpected = plan.expectedBytes
        case .file, .remux:
            guard let fileName = record.transferFileName else {
                throw DownloadFailure.notVideo
            }
            let resumeURL = folder(of: id).appendingPathComponent(Self.resumeDataFileName)
            let resumeData = try? Data(contentsOf: resumeURL)
            try? FileManager.default.removeItem(at: resumeURL)
            transport.startFile(id: id, url: record.item.url, fileName: fileName, allowsCellular: allowsCellular, resumeData: resumeData)
            update(id) {
                $0.status = .downloading
                $0.allowsCellular = allowsCellular
            }
        }
    }

    // MARK: - Transfer events

    func handle(_ event: DownloadTransferEvent) {
        switch event {
        case let .progress(id, written, expected, fraction):
            guard let record = record(id: id) else {
                return
            }
            progress(for: record).update(written: written, expected: expected, fraction: fraction, countsUnits: record.method == .hls,
                                         estimatedSize: record.bytesExpected)
        case let .hlsLocation(id, url):
            // The first location reported wins (`willDownloadTo`; the asset's URL at completion is a fallback).
            update(id) {
                if $0.location == nil || $0.status != .downloading {
                    $0.location = Self.relativePathFromHome(url)
                }
            }
        case let .fileReceived(id, fileName):
            update(id) { $0.transferFileName = fileName }
        case let .finished(id, failure):
            transferDidFinish(id, failure: failure)
        }
    }

    func transferDidFinish(_ id: UUID, failure: DownloadTransferFailure?) {
        guard let record = record(id: id) else {
            return
        }
        Self.logger.info("Transfer finished (\(record.status.rawValue, privacy: .public)): \(failure.map { String(describing: $0) } ?? "success", privacy: .public)")
        switch failure {
        case .cancelled:
            // Pause, Delete, or a move to the other session: whoever cancelled already updated the record.
            return
        case .failed(let failure, let isNetworkError):
            guard record.status == .downloading else {
                return
            }
            fail(id, failure, isNetworkError: isNetworkError)
        case nil:
            guard record.status == .downloading || record.status == .paused else {
                return
            }
            switch record.method {
            case .hls:
                completeHLS(id)
            case .file:
                completeFile(id)
            case .remux:
                update(id) {
                    $0.status = .converting
                    $0.fraction = 1
                }
                pump()
            case nil:
                fail(id, .incomplete, isNetworkError: false)
            }
        }
        pump()
    }

    private func completeHLS(_ id: UUID) {
        guard let record = record(id: id), let relative = record.location else {
            Self.logger.error("HLS download finished without a location")
            fail(id, .incomplete, isNetworkError: false)
            return
        }
        let url = Self.homeURL(forRelativePath: relative)
        let asset = AVURLAsset(url: url)
        guard asset.assetCache?.isPlayableOffline ?? FileManager.default.fileExists(atPath: url.path) else {
            Self.logger.error("HLS download not playable offline at \(url.path, privacy: .public)")
            fail(id, .incomplete, isNetworkError: false)
            return
        }
        #if !os(tvOS)
        // Kept before downloads the system may purge first under storage pressure.
        let policy = AVMutableAssetDownloadStorageManagementPolicy()
        policy.priority = .important
        policy.expirationDate = .distantFuture
        AVAssetDownloadStorageManager.shared().setStorageManagementPolicy(policy, for: url)
        #endif
        let size = Self.allocatedSize(of: url)
        update(id) {
            $0.status = .completed
            $0.completedOn = .now
            $0.fraction = 1
            $0.bytesOnDisk = size
            $0.isMissing = false
            $0.failureReason = nil
        }
        didComplete(id)
    }

    private func completeFile(_ id: UUID) {
        guard let record = record(id: id), let name = record.transferFileName else {
            fail(id, .incomplete, isNetworkError: false)
            return
        }
        let url = folder(of: id).appendingPathComponent(name)
        guard FileManager.default.fileExists(atPath: url.path) else {
            fail(id, .incomplete, isNetworkError: false)
            return
        }
        try? FileManager.default.removeItem(at: folder(of: id).appendingPathComponent(Self.resumeDataFileName))
        let status = record.status
        // An MP4 / MOV whose tracks AVPlayer cannot all play (DTS or TrueHD audio, which AVFoundation leaves out,
        // `hev1` HEVC, MPEG-4 Part 2 on iPhone) would play silently or without a picture offline: it is converted
        // like a Matroska download. Streaming it does the same through the engine.
        Task {
            let reason = await PlaybackRoute.engineReason(for: AVURLAsset(url: url))
            guard let current = self.record(id: id), current.status == status, current.transferFileName == name else {
                return
            }
            guard let reason else {
                self.finishFile(id, url: url, name: name)
                return
            }
            Self.logger.info("The downloaded file is converted: \(reason, privacy: .public)")
            let source = url.deletingLastPathComponent().appendingPathComponent("source.\(url.pathExtension)")
            do {
                try? FileManager.default.removeItem(at: source)
                try FileManager.default.moveItem(at: url, to: source)
            } catch {
                self.finishFile(id, url: url, name: name)
                return
            }
            self.update(id) {
                $0.status = .converting
                $0.fraction = 1
                $0.transferFileName = source.lastPathComponent
            }
            self.pump()
        }
    }

    private func finishFile(_ id: UUID, url: URL, name: String) {
        let size = Self.allocatedSize(of: url)
        update(id) {
            $0.status = .completed
            $0.completedOn = .now
            $0.fraction = 1
            $0.location = name
            $0.bytesOnDisk = size
            $0.isMissing = false
            $0.failureReason = nil
        }
        loadDuration(of: id, url: url)
        didComplete(id)
    }

    func didComplete(_ id: UUID) {
        progressObjects[id] = nil
        if let record = record(id: id) {
            AccessibilityAnnouncer.announce(String(localized: "\(record.spokenName) downloaded", comment: "VoiceOver announcement: a download finished; the placeholder is the movie, or the series and the episode, as in 'Breaking Bad, Season 1, episode 3, Pilot'."))
        }
    }

    func fail(_ id: UUID, _ failure: DownloadFailure, isNetworkError: Bool) {
        guard let record = record(id: id) else {
            return
        }
        if isNetworkError, record.automaticRetries < Self.maximumAutomaticRetries {
            update(id) {
                $0.status = .queued
                $0.automaticRetries += 1
            }
            retryNotBefore[id] = .now.addingTimeInterval(Double(5 << min(4, record.automaticRetries * 2)))
            scheduleRetry()
            return
        }
        Self.logger.error("Download failed: \(failure.message, privacy: .public)")
        if record.status == .preparing, !isNetworkError {
            // It could not even start (no space, not a video, refused): said at once, not only in the list.
            let name = TextParts.line([record.title, record.episodeLine])
            notice = DownloadNotice(
                title: String(localized: "Can't Download “\(name)”", comment: "Title of the alert when a download cannot start; the placeholder is the movie or episode."),
                message: failure.message
            )
        }
        update(id) {
            $0.status = .failed
            $0.failureReason = failure.reason
            $0.failureIsPermanent = failure.isPermanent
        }
        if failure.isPermanent || record.method == nil {
            // Nothing worth keeping (the probe failed, or the format cannot be played).
            removeFolderContents(of: id, keepingArtwork: true)
        }
        pump()
    }

    /// Runs the queue again when the earliest waiting retry is due.
    private func scheduleRetry() {
        retryTask?.cancel()
        retryTask = nil
        let now = Date.now
        retryNotBefore = retryNotBefore.filter { $0.value > now && record(id: $0.key)?.status == .queued }
        guard let due = retryNotBefore.values.min() else {
            return
        }
        retryTask = Task {
            try? await Task.sleep(for: .seconds(max(0, due.timeIntervalSinceNow)))
            guard !Task.isCancelled else {
                return
            }
            pump()
            scheduleRetry()
        }
    }

    func networkDidReturn() {
        // Network failures count again from zero once the network is back, and wait no longer.
        retryNotBefore.removeAll()
        retryTask?.cancel()
        retryTask = nil
        for record in records where record.status == .failed && !record.failureIsPermanent && record.automaticRetries > 0 && record.automaticRetries <= Self.maximumAutomaticRetries {
            update(record.id) {
                $0.status = .queued
                $0.failureReason = nil
                $0.automaticRetries = 0
            }
        }
        pump()
    }
}
