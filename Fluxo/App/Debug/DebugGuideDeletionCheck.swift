//
//  DebugGuideDeletionCheck.swift
//  Fluxo
//
//  Debug harness: the regression check of "deleting a TV guide crashes" (route `delete-guide-source`). It deletes a
//  guide source through `EPGStore.deleteSource` as the Delete button does, while the main actor keeps ticking, and
//  fails the route (the step file of the harness reports it) when anything of the source is left or the guide
//  still shows it. The touch paths (swipe, context menu, the Guide Sources sheet) are covered by
//  `GestureTests.testDeleteGuideSource…`. Compiled out of release builds.
//

#if DEBUG
import SwiftData
import SwiftUI

@MainActor
enum DebugGuideDeletionCheck {

    struct Failure: LocalizedError {
        let problems: [String]

        var errorDescription: String? {
            "Guide deletion check failed: " + problems.joined(separator: "; ")
        }
    }

    static func run(context: DebugRouteContext, sourceName: String) async throws {
        let epg = context.epg
        let modelContext = context.modelContext
        let sources = try modelContext.fetch(EPGQueries.sources())
        guard let source = sources.first(where: { $0.name.caseInsensitiveCompare(sourceName) == .orderedSame })
            ?? sources.first(where: { $0.name.localizedStandardContains(sourceName) }) else {
            throw DebugRouteError.notFound("guide source", sourceName)
        }
        let sourceID = source.uuid
        let optionalSourceID: UUID? = sourceID
        let otherSources = sources.filter { $0.uuid != sourceID && $0.isEnabled && $0.currentImportID != nil }.map(\.uuid)
        let importIDs = ((try? modelContext.fetch(FetchDescriptor<Playlist>())) ?? []).compactMap(\.currentImportID)
        let programmesBefore = try modelContext.fetchCount(FetchDescriptor<EPGProgramme>(predicate: #Predicate { $0.sourceID == sourceID }))
        var problems: [String] = []

        // The main actor must stay responsive: measure the longest gap between 20 ms ticks while deleting.
        let clock = ContinuousClock()
        var longestStall = Duration.zero
        let ticker = Task { @MainActor in
            var last = clock.now
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(20))
                let now = clock.now
                longestStall = max(longestStall, now - last - .milliseconds(20))
                last = now
            }
        }

        let started = clock.now
        withAnimation {
            epg.deleteSource(sourceID)
        }
        if epg.visibleSources(sources).contains(where: { $0.uuid == sourceID }) {
            problems.append("the source is still listed right after Delete")
        }
        await context.wait(timeout: 120) { !epg.deletingSourceIDs.contains(sourceID) }
        let duration = clock.now - started
        ticker.cancel()
        if epg.deletingSourceIDs.contains(sourceID) {
            problems.append("the deletion did not finish within 120 s")
        }

        // A fresh context: the store, not what the main context remembers.
        let check = ModelContext(modelContext.container)
        if try check.fetchCount(EPGQueries.source(uuid: sourceID)) > 0 {
            problems.append("the source row is left")
        }
        let programmes = try check.fetchCount(FetchDescriptor<EPGProgramme>(predicate: #Predicate { $0.sourceID == sourceID }))
        if programmes > 0 {
            problems.append("\(programmes) programmes are left")
        }
        let channels = try check.fetchCount(FetchDescriptor<EPGChannel>(predicate: #Predicate { $0.sourceID == sourceID }))
        if channels > 0 {
            problems.append("\(channels) guide channels are left")
        }
        if try check.fetchCount(FetchDescriptor<EPGChannelOverride>(predicate: #Predicate { $0.sourceID == optionalSourceID })) > 0 {
            problems.append("manual matches to it are left")
        }
        // The main context and the screens: the @Query of the sources no longer has it, the guide no longer uses it.
        if ((try? modelContext.fetch(EPGQueries.sources())) ?? []).contains(where: { $0.uuid == sourceID }) {
            problems.append("the main context still lists the source")
        }
        if epg.hasGuide != !otherSources.isEmpty {
            problems.append("hasGuide is \(epg.hasGuide) with \(otherSources.count) other guides")
        }
        if await epg.guideChannels(importIDs: importIDs).contains(where: { $0.ref.sourceID == sourceID }) {
            problems.append("guide channels still point to it")
        }

        let message = "Deleted guide \(sourceName): \(programmesBefore) programmes in \(duration.formatted(.units(allowed: [.seconds, .milliseconds]))), longest main-actor stall \(longestStall.formatted(.units(allowed: [.milliseconds])))"
        DebugLaunchOptions.logger.notice("\(message, privacy: .public)")
        guard problems.isEmpty else {
            throw Failure(problems: problems)
        }
    }
}
#endif
