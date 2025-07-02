//
//  DownloadManager.swift
//  Fluxo
//
//  Created by Gianluca Lofrumento on 2025-06-28.
//

import Foundation

struct DownloadProgress {
    let percentage: Double
    let isCompleted: Bool
    let error: Error?
    let data: Data?
}

class DownloadManager: NSObject, URLSessionDownloadDelegate {
    // swiftlint:disable:next implicitly_unwrapped_optional
    private var urlSession: URLSession!
    private var downloadTask: URLSessionDownloadTask?
    private var resumeData: Data?

    private var expectedContentLength: Int64 = 0
    private var receivedContentLength: Int64 = 0

    private var downloadContinuation: AsyncStream<DownloadProgress>.Continuation?

    override init() {
        super.init()
        let config = URLSessionConfiguration.default
        urlSession = URLSession(configuration: config, delegate: self, delegateQueue: .main)
    }

    func download(from url: URL) -> AsyncStream<DownloadProgress> {
        AsyncStream { continuation in
            self.downloadContinuation = continuation
            self.downloadTask = urlSession.downloadTask(with: url)
            self.downloadTask?.resume()
        }
    }

    // MARK: - URLSessionDownloadDelegate

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64) {
        let percentage = Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
        let progress = DownloadProgress(percentage: percentage, isCompleted: false, error: nil, data: nil)
        downloadContinuation?.yield(progress)
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL) {
        do {
            let data = try Data(contentsOf: location)
            let progress = DownloadProgress(percentage: 1.0, isCompleted: true, error: nil, data: data)
            downloadContinuation?.yield(progress)
            downloadContinuation?.finish()
        } catch {
            let progress = DownloadProgress(percentage: 1.0, isCompleted: true, error: error, data: nil)
            downloadContinuation?.yield(progress)
            downloadContinuation?.finish()
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let error else {
            return
        }
        let progress = DownloadProgress(percentage: 0.0, isCompleted: true, error: error, data: nil)
        downloadContinuation?.yield(progress)
        downloadContinuation?.finish()
    }
}
