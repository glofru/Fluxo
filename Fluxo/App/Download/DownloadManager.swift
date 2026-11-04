//
//  DownloadManager.swift
//  Fluxo
//
//  Created by Gianluca Lofrumento on 2025-06-28.
//

import Foundation

/// A piece of a streamed download.
struct DownloadChunk: Sendable {
    let data: Data
    /// Fraction of the transfer completed, when the server announced a length.
    let fractionCompleted: Double?
}

enum DownloadError: LocalizedError {
    case httpStatus(Int)

    var errorDescription: String? {
        switch self {
        case .httpStatus(let status):
            return String(localized: "The server responded with HTTP \(String(status)) (\(HTTPURLResponse.localizedString(forStatusCode: status))).", comment: "Download error; the placeholders are the HTTP status code, such as 404, and its system description, such as 'not found'.")
        }
    }
}

/// Streams the body of a URL as it arrives instead of buffering the whole file.
///
/// Delegate callbacks run on a private serial queue, never on the main thread. Chunks flow through an
/// `AsyncThrowingStream` with simple flow control: when more than `highWaterMark` bytes have been delivered but
/// not yet consumed the data task is suspended, and it is resumed once the consumer drops below `lowWaterMark`,
/// so a slow consumer (e.g. database inserts) never makes the whole file pile up in memory.
/// Cancelling the consuming task cancels the network request.
enum DownloadManager {

    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.default
        // Playlists can be tens of MB: keep them out of URLCache (memory and disk) and always fetch fresh content.
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 60
        configuration.httpMaximumConnectionsPerHost = 2
        let queue = OperationQueue()
        queue.name = "fluxo.download.delegate"
        queue.maxConcurrentOperationCount = 1
        queue.qualityOfService = .userInitiated
        return URLSession(configuration: configuration, delegate: nil, delegateQueue: queue)
    }()

    /// - Parameter headers: extra request headers, e.g. `If-None-Match` for a conditional request (a 304 reply
    ///   ends the stream with `DownloadError.httpStatus(304)`).
    static func stream(from url: URL, headers: [String: String] = [:], highWaterMark: Int = 8 << 20, lowWaterMark: Int = 2 << 20) -> DownloadStream {
        var request = URLRequest(url: url)
        request.setValue("*/*", forHTTPHeaderField: "Accept")
        for (field, value) in headers {
            request.setValue(value, forHTTPHeaderField: field)
        }

        let task = session.dataTask(with: request)
        let handler = DownloadTaskHandler(highWaterMark: highWaterMark, lowWaterMark: lowWaterMark)
        let base = AsyncThrowingStream<DownloadChunk, Error> { continuation in
            handler.continuation = continuation
            continuation.onTermination = { termination in
                if case .cancelled = termination {
                    task.cancel()
                }
            }
        }
        handler.task = task
        task.delegate = handler
        task.resume()
        return DownloadStream(base: base, handler: handler)
    }
}

/// Async sequence of download chunks. Requesting the next chunk marks the previous one as consumed.
struct DownloadStream: AsyncSequence {
    typealias Element = DownloadChunk

    fileprivate let base: AsyncThrowingStream<DownloadChunk, Error>
    fileprivate let handler: DownloadTaskHandler

    /// The HTTP response, once it arrived (before the first chunk).
    var response: HTTPURLResponse? {
        handler.response
    }

    func makeAsyncIterator() -> Iterator {
        Iterator(base: base.makeAsyncIterator(), handler: handler)
    }

    struct Iterator: AsyncIteratorProtocol {
        fileprivate var base: AsyncThrowingStream<DownloadChunk, Error>.AsyncIterator
        fileprivate let handler: DownloadTaskHandler
        private var pendingBytes = 0

        fileprivate init(base: AsyncThrowingStream<DownloadChunk, Error>.AsyncIterator, handler: DownloadTaskHandler) {
            self.base = base
            self.handler = handler
        }

        mutating func next() async throws -> DownloadChunk? {
            if pendingBytes > 0 {
                handler.consumed(pendingBytes)
                pendingBytes = 0
            }
            let chunk = try await base.next()
            pendingBytes = chunk?.data.count ?? 0
            return chunk
        }
    }
}

private final class DownloadTaskHandler: NSObject, URLSessionDataDelegate, @unchecked Sendable {

    // All mutable state is guarded by `lock`: delegate callbacks arrive on the session queue,
    // `consumed(_:)` on the consumer's executor.
    private let lock = NSLock()
    private let highWaterMark: Int
    private let lowWaterMark: Int
    private var bufferedBytes = 0
    private var isSuspended = false
    private var isFinished = false
    private var receivedResponse: HTTPURLResponse?

    var continuation: AsyncThrowingStream<DownloadChunk, Error>.Continuation?
    weak var task: URLSessionDataTask?

    init(highWaterMark: Int, lowWaterMark: Int) {
        self.highWaterMark = highWaterMark
        self.lowWaterMark = lowWaterMark
    }

    var response: HTTPURLResponse? {
        lock.lock()
        defer {
            lock.unlock()
        }
        return receivedResponse
    }

    func consumed(_ count: Int) {
        lock.lock()
        bufferedBytes -= count
        let shouldResume = isSuspended && !isFinished && bufferedBytes <= lowWaterMark
        if shouldResume {
            isSuspended = false
        }
        lock.unlock()
        if shouldResume {
            task?.resume()
        }
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        lock.lock()
        receivedResponse = response as? HTTPURLResponse
        lock.unlock()
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            finish(throwing: DownloadError.httpStatus(http.statusCode))
            completionHandler(.cancel)
            return
        }
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        let expected = dataTask.countOfBytesExpectedToReceive
        let fraction = expected > 0 ? min(1, Double(dataTask.countOfBytesReceived) / Double(expected)) : nil

        lock.lock()
        bufferedBytes += data.count
        let shouldSuspend = !isSuspended && !isFinished && bufferedBytes >= highWaterMark
        if shouldSuspend {
            isSuspended = true
        }
        let continuation = isFinished ? nil : self.continuation
        lock.unlock()

        continuation?.yield(DownloadChunk(data: data, fractionCompleted: fraction))
        if shouldSuspend {
            dataTask.suspend()
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        finish(throwing: error)
    }

    private func finish(throwing error: Error?) {
        lock.lock()
        let continuation = isFinished ? nil : self.continuation
        isFinished = true
        self.continuation = nil
        lock.unlock()

        if let error {
            continuation?.finish(throwing: error)
        } else {
            continuation?.finish()
        }
    }
}
