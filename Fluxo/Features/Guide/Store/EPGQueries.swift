//
//  EPGQueries.swift
//  Fluxo
//
//  Created by Gianluca Lofrumento on 2026-11-02.
//

import Foundation
import SwiftData

/// Every fetch of the TV guide, in one place so the predicates can be checked against a real store outside the
/// app (`Tools/GuideCheck`). Programme fetches always filter on `importID` (indexed with `channelID` and `start`)
/// and have a fetch limit.
enum EPGQueries {

    static func source(uuid: UUID) -> FetchDescriptor<EPGSource> {
        var descriptor = FetchDescriptor<EPGSource>(predicate: #Predicate { $0.uuid == uuid })
        descriptor.fetchLimit = 1
        return descriptor
    }

    static func sources() -> FetchDescriptor<EPGSource> {
        FetchDescriptor<EPGSource>(sortBy: [SortDescriptor(\.addedOn)])
    }

    static func sources(playlistID: UUID) -> FetchDescriptor<EPGSource> {
        let playlistID: UUID? = playlistID
        return FetchDescriptor<EPGSource>(predicate: #Predicate { $0.playlistID == playlistID }, sortBy: [SortDescriptor(\.addedOn)])
    }

    /// Guide channels of an import that have programmes (the ones matching can lead to).
    static func matchableChannels(importID: UUID) -> FetchDescriptor<EPGChannel> {
        var descriptor = FetchDescriptor<EPGChannel>(predicate: #Predicate { $0.importID == importID && $0.hasProgrammes == true })
        descriptor.propertiesToFetch = [\.channelID, \.displayName, \.otherNames]
        return descriptor
    }

    /// Guide channels of the given imports whose name contains `term` (all of them when `term` is empty).
    static func channels(importIDs: [UUID], term: String, limit: Int) -> FetchDescriptor<EPGChannel> {
        let predicate: Predicate<EPGChannel>
        if term.isEmpty {
            predicate = #Predicate { importIDs.contains($0.importID) }
        } else {
            predicate = #Predicate { importIDs.contains($0.importID) && ($0.displayName.localizedStandardContains(term) || $0.channelID.localizedStandardContains(term)) }
        }
        var descriptor = FetchDescriptor<EPGChannel>(predicate: predicate, sortBy: [SortDescriptor(\.displayName)])
        descriptor.fetchLimit = limit
        return descriptor
    }

    /// Programmes of one channel that overlap `interval`, in order.
    static func programmes(ref: GuideChannelRef, overlapping interval: DateInterval, limit: Int = 400) -> FetchDescriptor<EPGProgramme> {
        let importID = ref.importID
        let channelID = ref.channelID
        let start = interval.start
        let end = interval.end
        var descriptor = FetchDescriptor<EPGProgramme>(
            predicate: #Predicate { $0.importID == importID && $0.channelID == channelID && $0.start < end && $0.stop > start },
            sortBy: [SortDescriptor(\.start)]
        )
        descriptor.fetchLimit = limit
        return descriptor
    }

    /// The programme on air at `date` and the ones after it.
    static func upcoming(ref: GuideChannelRef, from date: Date, limit: Int) -> FetchDescriptor<EPGProgramme> {
        let importID = ref.importID
        let channelID = ref.channelID
        var descriptor = FetchDescriptor<EPGProgramme>(
            predicate: #Predicate { $0.importID == importID && $0.channelID == channelID && $0.stop > date },
            sortBy: [SortDescriptor(\.start)]
        )
        descriptor.fetchLimit = limit
        return descriptor
    }

    /// Programmes not over yet whose title, subtitle or description contains every word of `term` (up to three
    /// words, in any order and in any of the three fields), soonest first: "f1 sky" finds "Sky Sport F1 Show".
    static func search(term: String, importIDs: [UUID], after date: Date, limit: Int) -> FetchDescriptor<EPGProgramme> {
        let words = term.split(whereSeparator: \.isWhitespace).map(String.init)
        let predicate: Predicate<EPGProgramme>
        switch words.count {
        case 0, 1:
            let word = words.first ?? term
            predicate = #Predicate { programme in
                importIDs.contains(programme.importID) && programme.stop > date
                    && (programme.title.localizedStandardContains(word)
                        || programme.subtitle.localizedStandardContains(word)
                        || programme.summary.localizedStandardContains(word))
            }
        case 2:
            let first = words[0]
            let second = words[1]
            predicate = #Predicate { programme in
                importIDs.contains(programme.importID) && programme.stop > date
                    && (programme.title.localizedStandardContains(first)
                        || programme.subtitle.localizedStandardContains(first)
                        || programme.summary.localizedStandardContains(first))
                    && (programme.title.localizedStandardContains(second)
                        || programme.subtitle.localizedStandardContains(second)
                        || programme.summary.localizedStandardContains(second))
            }
        default:
            let first = words[0]
            let second = words[1]
            // Further words are matched together as the third one.
            let rest = words.dropFirst(2).joined(separator: " ")
            predicate = #Predicate { programme in
                importIDs.contains(programme.importID) && programme.stop > date
                    && (programme.title.localizedStandardContains(first)
                        || programme.subtitle.localizedStandardContains(first)
                        || programme.summary.localizedStandardContains(first))
                    && (programme.title.localizedStandardContains(second)
                        || programme.subtitle.localizedStandardContains(second)
                        || programme.summary.localizedStandardContains(second))
                    && (programme.title.localizedStandardContains(rest)
                        || programme.subtitle.localizedStandardContains(rest)
                        || programme.summary.localizedStandardContains(rest))
            }
        }
        var descriptor = FetchDescriptor<EPGProgramme>(predicate: predicate, sortBy: [SortDescriptor(\.start)])
        descriptor.fetchLimit = limit
        return descriptor
    }

    /// Programmes that overlap `interval` and have a category containing `term` ("film" finds "Film" and
    /// "Movie / Drama" finds "movie"), soonest first.
    static func programmes(category term: String, importIDs: [UUID], overlapping interval: DateInterval, limit: Int) -> FetchDescriptor<EPGProgramme> {
        let start = interval.start
        let end = interval.end
        var descriptor = FetchDescriptor<EPGProgramme>(
            predicate: #Predicate { programme in
                importIDs.contains(programme.importID) && programme.start < end && programme.stop > start
                    && programme.categories.localizedStandardContains(term)
            },
            sortBy: [SortDescriptor(\.start)]
        )
        descriptor.fetchLimit = limit
        return descriptor
    }

    /// Live channels of an import, a page at a time, in playlist order (only the keys matching needs).
    static func liveChannels(importID: UUID, offset: Int, limit: Int) -> FetchDescriptor<PlaylistChannel> {
        let live = ChannelContentKind.live.rawValue
        var descriptor = FetchDescriptor<PlaylistChannel>(
            predicate: #Predicate { $0.importID == importID && $0.kindRawValue == live },
            sortBy: [SortDescriptor(\.sortIndex)]
        )
        descriptor.fetchOffset = offset
        descriptor.fetchLimit = limit
        return descriptor
    }

    static func overrides() -> FetchDescriptor<EPGChannelOverride> {
        FetchDescriptor<EPGChannelOverride>()
    }

    static func override(key: String) -> FetchDescriptor<EPGChannelOverride> {
        var descriptor = FetchDescriptor<EPGChannelOverride>(predicate: #Predicate { $0.key == key })
        descriptor.fetchLimit = 1
        return descriptor
    }

    static func overrides(sourceID: UUID) -> FetchDescriptor<EPGChannelOverride> {
        let sourceID: UUID? = sourceID
        return FetchDescriptor<EPGChannelOverride>(predicate: #Predicate { $0.sourceID == sourceID })
    }

    static func reminders() -> FetchDescriptor<ProgrammeReminder> {
        FetchDescriptor<ProgrammeReminder>(sortBy: [SortDescriptor(\.start)])
    }

    static func reminder(key: String) -> FetchDescriptor<ProgrammeReminder> {
        var descriptor = FetchDescriptor<ProgrammeReminder>(predicate: #Predicate { $0.key == key })
        descriptor.fetchLimit = 1
        return descriptor
    }
}
