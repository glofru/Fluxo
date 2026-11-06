//
//  InflatingInputStream.swift
//  Fluxo
//
//  Created by Gianluca Lofrumento on 2026-11-02.
//

import Foundation
import zlib

/// Reads a file and, if it is gzip-compressed (`.xml.gz` guides are usually served as plain
/// `application/octet-stream`, so URLSession does not decode them), inflates it on the fly.
///
/// `XMLParser(stream:)` pulls from it a buffer at a time, so neither the compressed nor the decompressed guide
/// is ever held in memory. Concatenated gzip members are supported. Plain files pass through unchanged.
final class InflatingInputStream: InputStream {

    private let file: InputStream
    private var status: Stream.Status = .notOpen
    private var error: (any Error)?

    private var zStream = z_stream()
    private var isInflating = false
    private var isGzip = false
    private var inputBuffer: UnsafeMutablePointer<UInt8>
    private let inputCapacity = 256 * 1024
    /// Bytes of `inputBuffer` read from the file but not consumed yet.
    private var pendingInput = 0
    private var pendingOffset = 0
    private var fileEnded = false

    /// Decompressed (or passed through) bytes delivered so far.
    private(set) var totalBytesRead: Int64 = 0

    init?(fileURL url: URL) {
        guard let file = InputStream(url: url) else {
            return nil
        }
        self.file = file
        inputBuffer = .allocate(capacity: inputCapacity)
        super.init(data: Data())
    }

    deinit {
        if isInflating {
            inflateEnd(&zStream)
        }
        inputBuffer.deallocate()
    }

    // MARK: - InputStream

    override func open() {
        guard status == .notOpen else {
            return
        }
        file.open()
        if let fileError = file.streamError {
            fail(fileError)
            return
        }
        status = .open
        fillInput()
        // gzip magic: 1f 8b.
        isGzip = pendingInput >= 2 && inputBuffer[0] == 0x1F && inputBuffer[1] == 0x8B
        if isGzip {
            startInflating()
        }
    }

    override func close() {
        file.close()
        if isInflating {
            inflateEnd(&zStream)
            isInflating = false
        }
        status = .closed
    }

    override var streamStatus: Stream.Status {
        status
    }

    override var streamError: (any Error)? {
        error
    }

    override var hasBytesAvailable: Bool {
        status == .open
    }

    override func getBuffer(_ buffer: UnsafeMutablePointer<UnsafeMutablePointer<UInt8>?>, length len: UnsafeMutablePointer<Int>) -> Bool {
        false
    }

    override func read(_ buffer: UnsafeMutablePointer<UInt8>, maxLength len: Int) -> Int {
        guard status == .open || status == .reading else {
            return status == .atEnd ? 0 : -1
        }
        guard len > 0 else {
            return 0
        }
        status = .reading
        let count = isGzip ? inflate(into: buffer, maxLength: len) : passThrough(into: buffer, maxLength: len)
        if count > 0 {
            totalBytesRead += Int64(count)
            status = .open
        } else if count == 0 {
            status = .atEnd
        }
        return count
    }

    // Run-loop scheduling is not used: XMLParser reads synchronously.
    override func schedule(in aRunLoop: RunLoop, forMode mode: RunLoop.Mode) {}

    override func remove(from aRunLoop: RunLoop, forMode mode: RunLoop.Mode) {}

    override func property(forKey key: Stream.PropertyKey) -> Any? {
        nil
    }

    override func setProperty(_ property: Any?, forKey key: Stream.PropertyKey) -> Bool {
        false
    }

    // MARK: - Private

    private func fillInput() {
        if pendingInput > 0 && pendingOffset > 0 {
            memmove(inputBuffer, inputBuffer + pendingOffset, pendingInput)
        }
        pendingOffset = 0
        guard !fileEnded, pendingInput < inputCapacity else {
            return
        }
        let count = file.read(inputBuffer + pendingInput, maxLength: inputCapacity - pendingInput)
        if count > 0 {
            pendingInput += count
        } else {
            fileEnded = true
            if count < 0, let fileError = file.streamError {
                fail(fileError)
            }
        }
    }

    private func passThrough(into buffer: UnsafeMutablePointer<UInt8>, maxLength len: Int) -> Int {
        if pendingInput == 0 {
            fillInput()
        }
        guard pendingInput > 0 else {
            return error == nil ? 0 : -1
        }
        let count = min(len, pendingInput)
        memcpy(buffer, inputBuffer + pendingOffset, count)
        pendingOffset += count
        pendingInput -= count
        return count
    }

    private func startInflating() {
        zStream = z_stream()
        // 16 + MAX_WBITS: expect a gzip header and trailer.
        let result = inflateInit2_(&zStream, 16 + MAX_WBITS, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size))
        guard result == Z_OK else {
            fail(InflateError.zlib(result))
            return
        }
        isInflating = true
    }

    private func inflate(into buffer: UnsafeMutablePointer<UInt8>, maxLength len: Int) -> Int {
        guard isInflating else {
            return error == nil ? 0 : -1
        }
        var produced = 0
        while produced == 0 {
            if pendingInput == 0 {
                fillInput()
                if pendingInput == 0 {
                    if error != nil {
                        return -1
                    }
                    // The file ended inside a gzip member.
                    fail(InflateError.truncated)
                    return -1
                }
            }
            zStream.next_in = inputBuffer + pendingOffset
            zStream.avail_in = uInt(pendingInput)
            zStream.next_out = buffer
            zStream.avail_out = uInt(len)

            let result = zlib.inflate(&zStream, Z_NO_FLUSH)
            let consumed = pendingInput - Int(zStream.avail_in)
            pendingOffset += consumed
            pendingInput -= consumed
            produced = len - Int(zStream.avail_out)

            switch result {
            case Z_OK, Z_BUF_ERROR:
                if result == Z_BUF_ERROR && consumed == 0 && produced == 0 && fileEnded && pendingInput == 0 {
                    fail(InflateError.truncated)
                    return -1
                }
            case Z_STREAM_END:
                // Another gzip member may follow (concatenated files).
                if pendingInput == 0 {
                    fillInput()
                }
                if pendingInput >= 2 && inputBuffer[pendingOffset] == 0x1F && inputBuffer[pendingOffset + 1] == 0x8B {
                    inflateReset(&zStream)
                } else {
                    inflateEnd(&zStream)
                    isInflating = false
                    return produced
                }
            default:
                fail(InflateError.zlib(result))
                return -1
            }
        }
        return produced
    }

    private func fail(_ error: any Error) {
        self.error = error
        status = .error
    }

    enum InflateError: LocalizedError {
        case zlib(Int32)
        case truncated

        var errorDescription: String? {
            switch self {
            case .zlib(let code):
                return String(localized: "The guide file is damaged (zlib error \(code)).")
            case .truncated:
                return String(localized: "The guide file is incomplete.")
            }
        }
    }
}
