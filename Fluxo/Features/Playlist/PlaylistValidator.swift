//
//  PlaylistValidator.swift
//  Fluxo
//
//  Created by Gianluca Lofrumento on 2025-06-08.
//

import Foundation

private let m3uLinePrefix = "#EXTINF:"

struct PlaylistValidationProgress {
    let percentage: Double
    let count: Int
}

class PlaylistValidator {
    enum PlaylistValidationError: Error {
        case invalidFormat
        case emptyFile
    }

    func validate(playlist: Playlist, content: Data, playlistEntries: inout [PlaylistEntry]) -> AsyncThrowingStream<PlaylistValidationProgress, Error> {
        return AsyncThrowingStream { continuation in
            guard let content = String(data: content, encoding: .utf8) else {
                continuation.finish(throwing: PlaylistValidationError.invalidFormat)
                return
            }

            let lines = content.components(separatedBy: .newlines)
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }

            guard !lines.isEmpty else {
                continuation.finish(throwing: PlaylistValidationError.emptyFile)
                return
            }

            // Check if it starts with M3U header (optional but common)
            let hasHeader = lines.first?.uppercased() == "#EXTM3U"
            let startIndex = hasHeader ? 1 : 0

            var currentInfo: String?

            for i in startIndex..<lines.count {
                let line = lines[i]

                if line.hasPrefix("#EXTINF:") {
                    // Extract track info
                    currentInfo = line
                } else if line.hasPrefix("#") {
                    // Other comments/metadata - skip for basic validation
                    continue
                } else if !line.isEmpty && currentInfo != nil {
                    // This should be a URL or file path
                    let lineSplit = currentInfo?.replacingOccurrences(of: m3uLinePrefix, with: "").split(separator: ",")
                    let infoSplit = lineSplit?.first?.split(separator: " ")
                    let duration = Int(infoSplit?.first ?? "-1") ?? -1
                    let properties = infoSplit?[1...].reduce(into: [String: String]()) {
                        let propertySplit = $1.split(separator: "=")
                        guard propertySplit.count == 2 else {
                            return
                        }
                        $0[String(propertySplit.first ?? "")] = String(propertySplit.last ?? "")
                    }
                    let entry = PlaylistEntry(
                        uuid: UUID(),
                        name: lineSplit?.last as? String,
                        logo: URL(string: properties?.first(where: { $0.key.contains("logo") })?.value ?? "invalid-:+%$#@!~*|"),
                        duration: duration >= 0 ? duration : nil,
                        group: properties?.first(where: { $0.key.contains("group-") })?.value,
                        url: URL(string: line),
                        playlist: playlist,
                    )
                    playlistEntries.append(entry)
                    currentInfo = nil

                    let count = playlistEntries.count
                    if count.isMultiple(of: 100) {
                        continuation.yield(.init(percentage: Double(i) / Double(lines.count), count: count))
                    }
                }
            }

            guard !playlistEntries.isEmpty else {
                continuation.finish(throwing: PlaylistValidationError.invalidFormat)
                return
            }

            continuation.yield(.init(percentage: 1, count: playlistEntries.count))

            continuation.finish()
        }
    }
}

extension PlaylistValidator.PlaylistValidationError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .emptyFile: return "Empty file"
        case .invalidFormat: return "Invalid format"
        }
    }
}
