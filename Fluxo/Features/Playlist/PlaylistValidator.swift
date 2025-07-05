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

    func validate(playlist: Playlist, content: Data, playlistChannels: inout [PlaylistChannel], playlistChannelGroups: inout [PlaylistChannelGroup]) -> AsyncThrowingStream<PlaylistValidationProgress, Error> {
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
            var groups: [String: [PlaylistChannel]] = [:]

            for i in startIndex..<lines.count {
                let line = lines[i]

                if line.hasPrefix(m3uLinePrefix) {
                    // Extract track info
                    currentInfo = line
                } else if line.hasPrefix("#") {
                    // Other comments/metadata - skip for basic validation
                    continue
                } else if !line.isEmpty && currentInfo != nil {
                    // This should be a URL or file path
                    let lineSplit = currentInfo?.replacingOccurrences(of: m3uLinePrefix, with: "").components(separatedBy: ",")
                    let infoSplit = lineSplit?.first?.split(separator: " ")
                    let duration = Int(infoSplit?.first ?? "-1") ?? -1
                    let properties = infoSplit?[1...].reduce(into: [String: String]()) {
                        let propertySplit = $1.split(separator: "=")
                        guard propertySplit.count == 2 else {
                            return
                        }
                        $0[String(propertySplit.first ?? "")] = String(propertySplit.last?.replacingOccurrences(of: "\"", with: "") ?? "")
                    }
                    let group = properties?.first(where: { $0.key.contains("group-") })?.value ?? ""
                    let entry = PlaylistChannel(
                        uuid: UUID(),
                        name: lineSplit?.last as? String,
                        logo: properties?.first(where: { $0.key.contains("logo") })?.value ?? "invalid-:+%$#@!~*|",
                        duration: duration >= 0 ? duration : nil,
                        group: group,
                        url: URL(string: line),
                        playlist: playlist,
                    )
                    playlistChannels.append(entry)
                    currentInfo = nil

                    if groups[group] == nil {
                        groups[group] = []
                    }

                    groups[group]?.append(entry)

                    let count = playlistChannels.count
                    if count.isMultiple(of: 100) {
                        continuation.yield(.init(percentage: Double(i) / Double(lines.count), count: count))
                    }
                }
            }

            guard !playlistChannels.isEmpty else {
                continuation.finish(throwing: PlaylistValidationError.invalidFormat)
                return
            }

            groups.forEach({ key, value in
                playlistChannelGroups.append(PlaylistChannelGroup(uuid: UUID(), name: key, playlistChannels: value))
            })

            continuation.yield(.init(percentage: 1, count: playlistChannels.count))

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
