//
//  DownloadTransport.swift
//  Fluxo
//
//  The transfers of the offline downloads, in background URL sessions, so they go on while the app is suspended
//  or terminated (iOS relaunches the app in the background to deliver their results):
//
//  - files (MP4, and originals that are copied into MP4 afterwards) in a background `URLSession` of download
//    tasks: Pause keeps resume data, so it continues where it stopped, also after a relaunch;
//  - HLS streams in an `AVAssetDownloadURLSession`, with the variant of the chosen quality and the audio and
//    subtitle renditions of the user's languages. AVFoundation writes a `.movpkg` where it decides; Pause
//    suspends the task.
//
//  Each kind has two sessions, one that may use cellular data and one that may not (a session's setting is fixed
//  when it is created, and the stricter of the session and the request wins): a transfer runs in the one the
//  Cellular Data setting picks, and moves when the setting changes.
//
//  The class is not tied to an actor: URLSession calls its delegate methods on a private serial queue. Events are
//  sent to `DownloadCenter` on the main actor. Every task carries its download ID in `taskDescription`, so tasks
//  restored after a relaunch are matched to their records.
//

import AVFoundation
import Foundation
import os

/// What a transfer reports to `DownloadCenter`.
enum DownloadTransferEvent: Sendable {
    case progress(id: UUID, written: Int64, expected: Int64?, fraction: Double)
    /// Where AVFoundation writes an HLS download (known before it completes, so a partial download can be resumed
    /// or deleted).
    case hlsLocation(id: UUID, url: URL)
    /// A file transfer completed and the file was moved into the download's folder.
    case fileReceived(id: UUID, fileName: String)
    /// The transfer ended: nil on success. A cancellation (Pause, Delete) reports `.cancelled`.
    case finished(id: UUID, failure: DownloadTransferFailure?)
}

enum DownloadTransferFailure: Sendable {
    case cancelled
    case failed(DownloadFailure, isNetworkError: Bool)
}

/// The variant, renditions and expected size an HLS download was started with.
struct HLSDownloadPlan: Sendable {
    /// The picture height of the chosen variant (1080), when the stream offers several.
    var qualityHeight: Int?
    var expectedBytes: Int64?
    var duration: TimeInterval?
    /// The languages of the downloaded audio renditions and subtitles, as language codes ("en", "it").
    var audioLanguages: [String] = []
    var subtitleLanguages: [String] = []
}

/// Unchecked `Sendable`: URLSession calls the delegate on its own queues while the app calls in from the main actor,
/// so every mutable property is read and written under `lock` (the sessions themselves are thread-safe).
final class DownloadTransport: NSObject, @unchecked Sendable {

    static let shared = DownloadTransport()

    private static let logger = Logger(subsystem: "dev.watermelon.Fluxo", category: "Downloads")

    /// Prefix of every background session identifier of the downloads (the system wakes the app with it).
    static var identifierPrefix: String {
        #if DEBUG
        // An isolated debug run (`-FluxoDebugStore`) never adopts the transfers of the real library.
        if DebugEnvironment.shared != nil {
            return "dev.watermelon.Fluxo.downloads.debug"
        }
        #endif
        return "dev.watermelon.Fluxo.downloads"
    }

    enum SessionKind: CaseIterable, Sendable {
        case files
        case filesWiFiOnly
        case hls
        case hlsWiFiOnly

        var isHLS: Bool {
            self == .hls || self == .hlsWiFiOnly
        }

        var allowsCellular: Bool {
            self == .files || self == .hls
        }

        var suffix: String {
            switch self {
            case .files:
                return "files"
            case .filesWiFiOnly:
                return "files.wifi"
            case .hls:
                return "hls"
            case .hlsWiFiOnly:
                return "hls.wifi"
            }
        }

        static func forMethod(_ method: DownloadMethod, allowsCellular: Bool) -> SessionKind {
            switch method {
            case .hls:
                return allowsCellular ? .hls : .hlsWiFiOnly
            case .file, .remux:
                return allowsCellular ? .files : .filesWiFiOnly
            }
        }
    }

    /// Receives every event, on the main actor, in the order the transfers reported them (a file is received, or
    /// an HLS location known, before its transfer finishes). Set once by `DownloadCenter`.
    var onEvent: (@MainActor @Sendable (DownloadTransferEvent) -> Void)? {
        get { lock.withLock { eventHandler } }
        set {
            let startsDelivery = lock.withLock {
                eventHandler = newValue
                defer { isDeliveringEvents = true }
                return !isDeliveringEvents
            }
            if startsDelivery {
                deliverEvents()
            }
        }
    }

    private let lock = NSLock()
    private var eventHandler: (@MainActor @Sendable (DownloadTransferEvent) -> Void)?
    /// One ordered queue of events, consumed by a single task on the main actor.
    private let events: AsyncStream<DownloadTransferEvent>
    private let eventContinuation: AsyncStream<DownloadTransferEvent>.Continuation
    private var isDeliveringEvents = false
    private var sessions: [SessionKind: URLSession] = [:]
    #if !os(tvOS)
    /// The HLS sessions, as created (`AVAssetDownloadURLSession` may hand back an object of another class).
    private var assetSessions: [SessionKind: AVAssetDownloadURLSession] = [:]
    #endif
    private var tasks: [UUID: (task: URLSessionTask, kind: SessionKind)] = [:]
    private var progressObservations: [UUID: NSKeyValueObservation] = [:]
    /// Throttles progress events to a few per second per download.
    private var lastProgressReport: [UUID: CFAbsoluteTime] = [:]
    /// Background events (iOS): the system waits for these until the session delivered everything.
    private var backgroundWaiters: [String: [CheckedContinuation<Void, Never>]] = [:]
    private var finishedBackgroundIdentifiers: Set<String> = []

    private let delegateQueue: OperationQueue = {
        let queue = OperationQueue()
        queue.name = "dev.watermelon.Fluxo.downloads.delegate"
        queue.maxConcurrentOperationCount = 1
        queue.qualityOfService = .utility
        return queue
    }()

    /// The folder the downloads live in (`DownloadCenter.defaultDirectory`).
    let rootDirectory: URL

    init(rootDirectory: URL = DownloadCenter.defaultDirectory) {
        self.rootDirectory = rootDirectory
        (events, eventContinuation) = AsyncStream.makeStream(of: DownloadTransferEvent.self, bufferingPolicy: .unbounded)
        super.init()
    }

    // MARK: - Sessions

    private func session(_ kind: SessionKind) -> URLSession {
        lock.lock()
        defer { lock.unlock() }
        if let session = sessions[kind] {
            return session
        }
        let configuration = URLSessionConfiguration.background(withIdentifier: "\(Self.identifierPrefix).\(kind.suffix)")
        configuration.allowsCellularAccess = kind.allowsCellular
        // Run now, not when the system finds it convenient: the user asked for it.
        configuration.isDiscretionary = false
        configuration.httpMaximumConnectionsPerHost = 2
        #if os(iOS)
        configuration.sessionSendsLaunchEvents = true
        #endif
        let session: URLSession
        #if os(tvOS)
        // No downloads on Apple TV (`PlatformFeatures.offlineDownloads`), so no HLS session either.
        session = URLSession(configuration: configuration, delegate: self, delegateQueue: delegateQueue)
        #else
        if kind.isHLS {
            let assetSession = AVAssetDownloadURLSession(configuration: configuration, assetDownloadDelegate: self, delegateQueue: delegateQueue)
            assetSessions[kind] = assetSession
            session = assetSession
        } else {
            session = URLSession(configuration: configuration, delegate: self, delegateQueue: delegateQueue)
        }
        #endif
        sessions[kind] = session
        return session
    }

    /// The transfers that survived a relaunch, by download ID (their sessions are created, so their events flow).
    @concurrent func restoreTasks() async -> [UUID: SessionKind] {
        var restored: [UUID: SessionKind] = [:]
        for kind in SessionKind.allCases {
            let tasks = await session(kind).allTasks
            for task in tasks {
                guard let id = Self.downloadID(of: task) else {
                    task.cancel()
                    continue
                }
                guard task.state == .running || task.state == .suspended else {
                    continue
                }
                if restored[id] != nil {
                    // Two transfers of one download (a move between sessions was interrupted): keep one.
                    task.cancel()
                    continue
                }
                register(task, id: id, kind: kind)
                restored[id] = kind
            }
        }
        return restored
    }

    /// The system woke the app for the events of a background session (iOS): returns once the session delivered
    /// them all, so the system can suspend the app again.
    @concurrent func handleBackgroundEvents(for identifier: String) async {
        guard let kind = SessionKind.allCases.first(where: { "\(Self.identifierPrefix).\($0.suffix)" == identifier }) else {
            return
        }
        _ = session(kind)
        await withCheckedContinuation { continuation in
            lock.lock()
            if finishedBackgroundIdentifiers.remove(identifier) != nil {
                lock.unlock()
                continuation.resume()
                return
            }
            backgroundWaiters[identifier, default: []].append(continuation)
            lock.unlock()
        }
    }

    // MARK: - Files

    /// Starts (or continues from `resumeData`) the transfer of a file into the download's folder as `fileName`.
    func startFile(id: UUID, url: URL, fileName: String, allowsCellular: Bool, resumeData: Data?) {
        let kind: SessionKind = allowsCellular ? .files : .filesWiFiOnly
        let session = session(kind)
        let task: URLSessionDownloadTask
        if let resumeData {
            task = session.downloadTask(withResumeData: resumeData)
        } else {
            var request = URLRequest(url: url)
            request.setValue("*/*", forHTTPHeaderField: "Accept")
            task = session.downloadTask(with: request)
        }
        task.taskDescription = "\(id.uuidString)|\(fileName)"
        register(task, id: id, kind: kind)
        task.resume()
    }

    /// Stops a file transfer and calls `completion` with the data to continue it later (nil when the server cannot
    /// continue). The task is detached at once, so a transfer started for the same download right after is never
    /// the one cancelled.
    func pauseFile(id: UUID, completion: @escaping @Sendable (Data?) -> Void) {
        guard let task = task(for: id) as? URLSessionDownloadTask else {
            completion(nil)
            return
        }
        unregister(id)
        task.cancel(byProducingResumeData: completion)
    }

    // MARK: - HLS

    /// Loads the stream's variants and renditions, checks the space, and starts its download. `partialLocation`
    /// continues a download whose task was lost (AVFoundation keeps what the package already has).
    @concurrent func startHLS(
        id: UUID,
        url: URL,
        partialLocation: URL?,
        title: String,
        artwork: Data?,
        quality: DownloadQuality,
        allowsCellular: Bool,
        availableBytes: Int64?
    ) async throws -> HLSDownloadPlan {
        #if os(tvOS)
        // `AVAssetDownloadURLSession` does not exist on tvOS (`PlatformFeatures.offlineDownloads`).
        throw DownloadFailure.incomplete
        #else
        let options: [String: Any] = [AVURLAssetAllowsCellularAccessKey: allowsCellular]
        var asset = AVURLAsset(url: url, options: options)
        if let partialLocation, FileManager.default.fileExists(atPath: partialLocation.path) {
            let partial = AVURLAsset(url: partialLocation, options: options)
            if (try? await partial.load(.variants))?.isEmpty == false {
                asset = partial
            } else {
                try? FileManager.default.removeItem(at: partialLocation)
            }
        }

        let variants: [AVAssetVariant]
        do {
            variants = try await asset.load(.variants)
        } catch {
            throw Self.failure(from: error)
        }
        let duration = (try? await asset.load(.duration)).map(\.seconds).flatMap { $0.isFinite && $0 > 0 ? $0 : nil }

        var plan = HLSDownloadPlan(duration: duration)
        let configuration = AVAssetDownloadConfiguration(asset: asset, title: title)
        if let artwork {
            configuration.artworkData = artwork
        }
        // Only what plays offline: the primary variant and the chosen renditions (no extra multichannel copy).
        configuration.auxiliaryContentConfigurations = []

        let maximumHeight = quality.maximumHeight.map(CGFloat.init)
        let videoVariants = variants.filter { $0.videoAttributes != nil }
        let allowed = videoVariants.filter { variant in
            guard let maximumHeight, let height = variant.videoAttributes?.presentationSize.height, height > 0 else {
                return true
            }
            return height <= maximumHeight + 1
        }
        func bitRate(_ variant: AVAssetVariant) -> Double {
            variant.peakBitRate ?? variant.averageBitRate ?? 0
        }
        // The best variant within the quality, or the smallest if even that is larger.
        let chosen = allowed.max(by: { bitRate($0) < bitRate($1) }) ?? videoVariants.min(by: { bitRate($0) < bitRate($1) })
        if let chosen {
            var predicates: [NSPredicate] = []
            if let maximumHeight {
                predicates.append(AVAssetVariantQualifier.predicate(forPresentationHeight: maximumHeight, operatorType: .lessThanOrEqualTo))
            }
            let rate = bitRate(chosen)
            if rate > 0 {
                predicates.append(NSPredicate(format: "peakBitRate >= %f", rate * 0.999))
            }
            if !predicates.isEmpty {
                // Evaluated against the variants this device plays; automatic selection when none matches.
                configuration.primaryContentConfiguration.variantQualifiers = [
                    AVAssetVariantQualifier(predicate: NSCompoundPredicate(andPredicateWithSubpredicates: predicates)),
                ]
            }
            if let height = chosen.videoAttributes?.presentationSize.height, height > 0, videoVariants.count > 1 {
                plan.qualityHeight = Int(height.rounded())
            }
            if let duration, rate > 0 {
                plan.expectedBytes = Int64(rate / 8 * duration * 1.05)
            }
        }

        // The renditions: the automatic selection (the user's language, accessibility settings), plus every other
        // audio language in the user's languages and every subtitle (text, a few KB), so they can be switched
        // offline.
        if let selections = await mediaSelections(for: asset, plan: &plan), !selections.isEmpty {
            configuration.primaryContentConfiguration.mediaSelections = selections
        }

        if let expected = plan.expectedBytes, let availableBytes, expected + DownloadPreferences.freeSpaceMargin > availableBytes {
            throw DownloadFailure.insufficientSpace
        }

        let kind: SessionKind = allowsCellular ? .hls : .hlsWiFiOnly
        _ = session(kind)
        guard let session = lock.withLock({ assetSessions[kind] }) else {
            throw DownloadFailure.incomplete
        }
        let task = session.makeAssetDownloadTask(downloadConfiguration: configuration)
        Self.logger.info("HLS download: \(variants.count) variants, \(plan.qualityHeight.map { "\($0)p" } ?? "automatic", privacy: .public), \(configuration.primaryContentConfiguration.mediaSelections.count) selections")
        task.taskDescription = id.uuidString
        register(task, id: id, kind: kind)
        task.resume()
        return plan
        #endif
    }

    /// The media selections to download, and the languages of their renditions for the list.
    @concurrent private func mediaSelections(for asset: AVURLAsset, plan: inout HLSDownloadPlan) async -> [AVMediaSelection]? {
        guard let preferred = try? await asset.load(.preferredMediaSelection) else {
            return nil
        }
        let audible = try? await asset.loadMediaSelectionGroup(for: .audible)
        let legible = try? await asset.loadMediaSelectionGroup(for: .legible)
        let languages = Set(Locale.preferredLanguages.compactMap { Locale(identifier: $0).language.languageCode?.identifier })

        func isWanted(_ option: AVMediaSelectionOption) -> Bool {
            guard let code = option.locale?.language.languageCode?.identifier else {
                return true
            }
            return languages.contains(code)
        }

        var selections = [preferred]
        var audioLanguages: [String] = []
        var subtitleLanguages: [String] = []
        // Language codes, not names: the list shows them in the language of the moment.
        func add(_ option: AVMediaSelectionOption, to languages: inout [String]) {
            if let language = TrackPreferences.language(of: option), !languages.contains(language) {
                languages.append(language)
            }
        }
        if let audible {
            let playable = AVMediaSelectionGroup.playableMediaSelectionOptions(from: audible.options)
            let selected = preferred.selectedMediaOption(in: audible)
            for option in playable {
                if option == selected || isWanted(option) {
                    add(option, to: &audioLanguages)
                }
                guard option != selected, isWanted(option), let selection = preferred.mutableCopy() as? AVMutableMediaSelection else {
                    continue
                }
                selection.select(option, in: audible)
                selections.append(selection)
            }
        }
        if let legible {
            let playable = AVMediaSelectionGroup.playableMediaSelectionOptions(from: legible.options)
            let selected = preferred.selectedMediaOption(in: legible)
            for option in playable {
                let isForced = option.hasMediaCharacteristic(.containsOnlyForcedSubtitles)
                if !isForced {
                    add(option, to: &subtitleLanguages)
                }
                guard option != selected, let selection = preferred.mutableCopy() as? AVMutableMediaSelection else {
                    continue
                }
                selection.select(option, in: legible)
                selections.append(selection)
            }
        }
        plan.audioLanguages = audioLanguages
        plan.subtitleLanguages = subtitleLanguages
        return selections
    }

    func suspend(id: UUID) {
        task(for: id)?.suspend()
    }

    /// Resumes a suspended transfer. False when there is none (it was lost): start it again.
    func resume(id: UUID) -> Bool {
        guard let task = task(for: id) else {
            return false
        }
        task.resume()
        return true
    }

    // MARK: - Every kind

    func hasTask(id: UUID) -> Bool {
        task(for: id) != nil
    }

    /// The session kind a transfer runs in, if it runs.
    func sessionKind(of id: UUID) -> SessionKind? {
        lock.withLock { tasks[id]?.kind }
    }

    /// Cancels a transfer (its `.finished(.cancelled)` follows).
    func cancel(id: UUID) {
        let task = task(for: id)
        unregister(id)
        task?.cancel()
    }

    // MARK: - Bookkeeping

    private func task(for id: UUID) -> URLSessionTask? {
        lock.withLock { tasks[id]?.task }
    }

    private func register(_ task: URLSessionTask, id: UUID, kind: SessionKind) {
        lock.lock()
        tasks[id] = (task, kind)
        lock.unlock()
        guard kind.isHLS else {
            return
        }
        // Asset download tasks report through their progress (the time-range callbacks are deprecated).
        let observation = task.progress.observe(\.fractionCompleted, options: [.new]) { [weak self] progress, _ in
            self?.reportProgress(id: id, written: progress.completedUnitCount, expected: nil, fraction: progress.fractionCompleted)
        }
        lock.withLock {
            progressObservations[id] = observation
        }
    }

    private func unregister(_ id: UUID) {
        lock.lock()
        tasks[id] = nil
        let observation = progressObservations.removeValue(forKey: id)
        lastProgressReport[id] = nil
        lock.unlock()
        observation?.invalidate()
    }

    private func reportProgress(id: UUID, written: Int64, expected: Int64?, fraction: Double) {
        let now = CFAbsoluteTimeGetCurrent()
        let shouldReport: Bool = lock.withLock {
            if let last = lastProgressReport[id], now - last < 0.4, fraction < 1 {
                return false
            }
            lastProgressReport[id] = now
            return true
        }
        if shouldReport {
            send(.progress(id: id, written: written, expected: expected, fraction: fraction))
        }
    }

    private func send(_ event: DownloadTransferEvent) {
        // `DownloadCenter` attaches once the library opens: after a background relaunch while it opens, upgrades or
        // waits for the first unlock, the events that change a record (a file received, a location, an end) wait in
        // the queue for it, a few per transfer. Progress is only shown, so it is dropped until then.
        if case .progress = event, onEvent == nil {
            return
        }
        eventContinuation.yield(event)
    }

    private func deliverEvents() {
        let events = events
        Task { @MainActor [weak self] in
            for await event in events {
                self?.onEvent?(event)
            }
        }
    }

    private static func downloadID(of task: URLSessionTask) -> UUID? {
        guard let description = task.taskDescription else {
            return nil
        }
        return UUID(uuidString: String(description.prefix { $0 != "|" }))
    }

    private static func fileName(of task: URLSessionTask) -> String? {
        guard let description = task.taskDescription, let separator = description.firstIndex(of: "|") else {
            return nil
        }
        let name = String(description[description.index(after: separator)...])
        // Only a plain name inside the download's folder.
        return name.isEmpty || name.contains("/") || name.hasPrefix(".") ? nil : name
    }

    private static let networkErrorCodes: Set<Int> = Set([
        URLError.Code.timedOut, .networkConnectionLost, .notConnectedToInternet, .cannotConnectToHost, .cannotFindHost,
        .dnsLookupFailed, .internationalRoamingOff, .dataNotAllowed, .secureConnectionFailed,
    ].map(\.rawValue))

    /// A timeout, a dropped connection or no route, also when AVFoundation wraps it (an HLS stream that fails to
    /// load reports an AVError whose underlying error is the URL error).
    static func isNetworkError(_ error: any Error) -> Bool {
        if let failure = error as? DownloadFailure {
            return failure.isNetworkError
        }
        var current: NSError? = error as NSError
        for _ in 0..<4 {
            guard let nsError = current else {
                break
            }
            if nsError.domain == NSURLErrorDomain, networkErrorCodes.contains(nsError.code) {
                return true
            }
            current = nsError.userInfo[NSUnderlyingErrorKey] as? NSError
        }
        return false
    }

    static func failure(from error: any Error) -> DownloadFailure {
        if let failure = error as? DownloadFailure {
            return failure
        }
        if isNetworkError(error) {
            return .network(error)
        }
        let nsError = error as NSError
        if nsError.domain == NSURLErrorDomain, nsError.code == NSURLErrorBadServerResponse,
           let status = (nsError.userInfo["NSErrorFailingURLResponseKey"] as? HTTPURLResponse)?.statusCode {
            return .http(status)
        }
        if nsError.domain == NSPOSIXErrorDomain, nsError.code == Int(ENOSPC) {
            return .insufficientSpace
        }
        if nsError.domain == AVFoundationErrorDomain, nsError.code == AVError.Code.diskFull.rawValue {
            return .insufficientSpace
        }
        if nsError.domain == AVFoundationErrorDomain {
            return .streamUnavailable
        }
        return .network(error)
    }
}

// MARK: - URLSession delegate

extension DownloadTransport: URLSessionDownloadDelegate {

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        guard let id = Self.downloadID(of: downloadTask) else {
            return
        }
        let expected = totalBytesExpectedToWrite > 0 ? totalBytesExpectedToWrite : nil
        let fraction = expected.map { Double(totalBytesWritten) / Double($0) } ?? 0
        reportProgress(id: id, written: totalBytesWritten, expected: expected, fraction: min(1, fraction))
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        guard let id = Self.downloadID(of: downloadTask), let fileName = Self.fileName(of: downloadTask) else {
            return
        }
        // An error page is not the video: `didCompleteWithError` reports the status.
        if let status = (downloadTask.response as? HTTPURLResponse)?.statusCode, !(200..<300).contains(status) {
            return
        }
        // The file must be moved before this method returns: the system deletes it afterwards.
        let folder = rootDirectory.appendingPathComponent(id.uuidString, isDirectory: true)
        let destination = folder.appendingPathComponent(fileName)
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            if FileManager.default.fileExists(atPath: destination.path) {
                try FileManager.default.removeItem(at: destination)
            }
            try FileManager.default.moveItem(at: location, to: destination)
            send(.fileReceived(id: id, fileName: fileName))
        } catch {
            Self.logger.error("Could not keep a download: \(error.localizedDescription, privacy: .public)")
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        guard let id = Self.downloadID(of: task) else {
            return
        }
        // A task of another session (moved, or replaced) must not end the current transfer.
        let isCurrent: Bool = lock.withLock { tasks[id]?.task === task || tasks[id] == nil }
        if lock.withLock({ tasks[id]?.task === task }) {
            unregister(id)
        }
        guard isCurrent else {
            return
        }
        if let error {
            let nsError = error as NSError
            Self.logger.info("Transfer ended: \(nsError.domain, privacy: .public) \(nsError.code) \(nsError.localizedDescription, privacy: .public)")
            if nsError.domain == NSURLErrorDomain, nsError.code == NSURLErrorCancelled {
                send(.finished(id: id, failure: .cancelled))
                return
            }
            if let resumeData = nsError.userInfo[NSURLSessionDownloadTaskResumeData] as? Data {
                // Kept for Retry (and the automatic retry): the transfer continues where it stopped.
                let url = rootDirectory.appendingPathComponent(id.uuidString, isDirectory: true).appendingPathComponent(DownloadCenter.resumeDataFileName)
                try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try? resumeData.write(to: url, options: .atomic)
            }
            send(.finished(id: id, failure: .failed(Self.failure(from: error), isNetworkError: Self.isNetworkError(error))))
            return
        }
        #if !os(tvOS)
        // The package of a completed asset download, in case `willDownloadTo` was not delivered.
        if let assetTask = task as? AVAssetDownloadTask, assetTask.urlAsset.url.isFileURL {
            send(.hlsLocation(id: id, url: assetTask.urlAsset.url))
        }
        #endif
        // Only file transfers have a response: an asset download task throws when it is asked for one.
        if task is URLSessionDownloadTask, let status = (task.response as? HTTPURLResponse)?.statusCode, !(200..<300).contains(status) {
            send(.finished(id: id, failure: .failed(.http(status), isNetworkError: false)))
            return
        }
        send(.finished(id: id, failure: nil))
    }

    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        guard let identifier = session.configuration.identifier else {
            return
        }
        lock.lock()
        let waiters = backgroundWaiters.removeValue(forKey: identifier) ?? []
        if waiters.isEmpty {
            finishedBackgroundIdentifiers.insert(identifier)
        }
        lock.unlock()
        for waiter in waiters {
            waiter.resume()
        }
    }
}

#if !os(tvOS)
extension DownloadTransport: AVAssetDownloadDelegate {

    func urlSession(_ session: URLSession, assetDownloadTask: AVAssetDownloadTask, willDownloadTo location: URL) {
        guard let id = Self.downloadID(of: assetDownloadTask) else {
            return
        }
        send(.hlsLocation(id: id, url: location))
    }
}
#endif
