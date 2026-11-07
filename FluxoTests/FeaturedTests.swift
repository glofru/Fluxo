//
//  FeaturedTests.swift
//  FluxoTests
//
//  Home's featured billboard: the adult-content classifier and filter (`MatureContent`, `MatureContentFilter`), the
//  title keys that make two entries the same page (`FeaturedTitle`), the diversity of a selection (`FeaturedPicker`),
//  the rotation (`FeaturedRotation`) and the loader on a store (`FeaturedLoader`). The names are in
//  Fixtures/MatureContentCases.swift, shared with Tools/FeaturedCheck.
//

import Foundation
import SwiftData
import Testing
@testable import Fluxo

@Suite("Featured billboard and adult content")
struct FeaturedTests {

    // MARK: - Classifier

    @Test("Adult category names are recognized, in many languages and scripts")
    func adultGroups() {
        let missed = ClassifierCases.adultGroups.filter { !MatureContent.isAdult(group: $0) }
        #expect(missed.isEmpty, "missed: \(missed)")
    }

    @Test("Adult titles of channels, movies and series are recognized")
    func adultTitles() {
        let missed = ClassifierCases.adultTitles.filter { !MatureContent.isAdult(title: $0.0, kind: $0.1) }
        #expect(missed.isEmpty, "missed: \(missed.map(\.0))")
    }

    @Test("Names that only look close to adult content are left alone (Essex, Adult Swim, xXx (2002), Canal+ 18)")
    func ordinaryNames() {
        let flagged = ClassifierCases.ordinaryNames.filter { name, kind in
            kind == nil ? MatureContent.isAdult(group: name) : MatureContent.isAdult(title: name, kind: kind)
        }
        #expect(flagged.isEmpty, "flagged: \(flagged.map(\.0))")
        let flaggedAsTitles = ClassifierCases.ordinaryNames.filter { MatureContent.isAdult(title: $0.0, kind: $0.1) }
        #expect(flaggedAsTitles.isEmpty, "as titles: \(flaggedAsTitles.map(\.0))")
    }

    @Test("Entries by category and by title, episodes by series, programmes by title and category; the filter")
    func entriesAndFilter() {
        let playlist = UUID()
        let inAdultGroup = Self.item("Late Show", group: "XXX | Adult", kind: .movie, playlist: playlist)
        let adultTitle = Self.item("Hot XXX Night", group: "Movies", kind: .movie, playlist: playlist)
        let ordinary = Self.item("The Silent Harbor (2001)", group: "Movies", kind: .movie, playlist: playlist)
        #expect(MatureContent.isAdult(inAdultGroup))
        #expect(MatureContent.isAdult(adultTitle))
        #expect(!MatureContent.isAdult(ordinary))
        let episode = ChannelItem(id: UUID(), playlistID: playlist, name: "Hentai Collection S01E01", logo: "https://x/p.png", url: URL(string: "https://x/1.mkv"), groupName: "Anime", kind: .series, series: EpisodeRef(seriesKey: "hentai collection", seriesTitle: "Hentai Collection", season: 1, episode: 1, episodeTitle: nil))
        #expect(MatureContent.isAdult(episode))
        #expect(MatureContent.isAdult(programmeTitle: "Late Night", categories: ["Erotic"]))
        #expect(!MatureContent.isAdult(programmeTitle: "Evening News", categories: ["News", "Adult Education"]))

        let active = MatureContentFilter(isActive: true)
        #expect(!active.allows(inAdultGroup))
        #expect(active.allows(ordinary))
        #expect(!active.allows(group: "XXX | Adult"))
        #expect(MatureContentFilter.inactive.allows(inAdultGroup))
    }

    // MARK: - Title keys

    @Test("The same title in other qualities and languages has one key", arguments: ClassifierCases.sameTitle)
    func sameTitle(_ lhs: String, _ rhs: String) {
        let kind: ChannelContentKind = lhs.contains("Sky Sport") ? .live : .movie
        #expect(FeaturedTitle.keys(title: lhs, kind: kind).duplicate == FeaturedTitle.keys(title: rhs, kind: kind).duplicate)
    }

    @Test("The films of a franchise share a franchise key", arguments: ClassifierCases.sameFranchise)
    func sameFranchise(_ lhs: String, _ rhs: String) {
        #expect(FeaturedTitle.keys(title: lhs, kind: .movie).franchise == FeaturedTitle.keys(title: rhs, kind: .movie).franchise)
    }

    @Test("The channels of a family share a franchise key", arguments: ClassifierCases.sameLiveFamily)
    func sameLiveFamily(_ lhs: String, _ rhs: String) {
        #expect(FeaturedTitle.keys(title: lhs, kind: .live).franchise == FeaturedTitle.keys(title: rhs, kind: .live).franchise)
    }

    @Test("Different titles keep different keys", arguments: ClassifierCases.differentTitles)
    func differentTitles(_ lhs: String, _ rhs: String) {
        let left = FeaturedTitle.keys(title: lhs, kind: .movie)
        let right = FeaturedTitle.keys(title: rhs, kind: .movie)
        #expect(left.duplicate != right.duplicate)
        #expect(left.franchise != right.franchise)
    }

    @Test("Different channels keep different families", arguments: ClassifierCases.differentLiveFamilies)
    func differentLiveFamilies(_ lhs: String, _ rhs: String) {
        #expect(FeaturedTitle.keys(title: lhs, kind: .live).franchise != FeaturedTitle.keys(title: rhs, kind: .live).franchise)
    }

    // MARK: - Picker

    /// A synthetic library: a "Cinema" playlist (movie categories, one a franchise of near-duplicates, adult ones,
    /// series) and a "World" playlist (live categories in provider sections, one adult), every entry with artwork.
    struct Scope {
        var categories: [FeaturedPicker.Category] = []
        var entries: [String: [ChannelItem]] = [:]
        let cinema = UUID()
        let world = UUID()
        let cinemaImport = UUID()
        let worldImport = UUID()

        mutating func add(_ name: String, kind: ChannelContentKind, playlist: UUID, titles: [String]) {
            let importID = playlist == cinema ? cinemaImport : worldImport
            let category = FeaturedPicker.Category(importID: importID, playlistID: playlist, name: name, kind: kind, entryCount: titles.count)
            categories.append(category)
            entries[category.key] = titles.map { title in
                guard kind == .series else {
                    return FeaturedTests.item(title, group: name, kind: kind, playlist: playlist)
                }
                return ChannelItem(id: UUID(), playlistID: playlist, name: "\(title) S01E01", logo: "https://img/\(title).png", url: URL(string: "https://x/series/\(UUID().uuidString).mkv"), groupName: name, kind: .series,
                                   series: EpisodeRef(seriesKey: title.lowercased(), seriesTitle: title, season: 1, episode: 1, episodeTitle: nil))
            }
        }

        func fetch(_ category: FeaturedPicker.Category, offset: Int, limit: Int) -> [ChannelItem] {
            let all = entries[category.key] ?? []
            guard offset < all.count else {
                return []
            }
            return Array(all[offset..<min(all.count, offset + limit)])
        }

        func pick(seed: UInt64, filter: MatureContentFilter = MatureContentFilter(isActive: true), taste: FeaturedPicker.Taste = .none) -> [ChannelItem] {
            var picker = FeaturedPicker(categories: categories, count: 8, seed: seed, filter: filter, taste: taste)
            return picker.pick { fetch($0, offset: $1, limit: $2) }
        }

        static func library() -> Scope {
            var scope = Scope()
            let franchise = (1...10).flatMap { number in ["Fast & Furious \(number) (20\(10 + number))", "Fast & Furious \(number) [ITA]", "Fast & Furious \(number) 4K"] }
            scope.add("Action | Saga", kind: .movie, playlist: scope.cinema, titles: franchise)
            scope.add("Comedy", kind: .movie, playlist: scope.cinema, titles: (1...30).map { "Comedy Film \(["Alpha", "Bravo", "Delta", "Echo", "Foxtrot", "Golf"][$0 % 6]) \($0)" })
            scope.add("Drama", kind: .movie, playlist: scope.cinema, titles: ["Avatar (2009) [ITA]", "Avatar (2009)", "Avatar 4K", "Inception (2010)", "Inception [MULTI]", "Gravity (2013)"])
            scope.add("Thriller", kind: .movie, playlist: scope.cinema, titles: (1...20).map { "Thriller Night \(["Nova", "Orion", "Pulsar", "Quasar"][$0 % 4]) Part \($0)" })
            scope.add("Family", kind: .movie, playlist: scope.cinema, titles: ["Toy Story (1995)", "Toy Story 2 (1999)", "Toy Story 3 (2010)", "Up (2009)", "Coco (2017)"])
            scope.add("XXX | Adult", kind: .movie, playlist: scope.cinema, titles: (1...40).map { "Late Show \($0)" })
            scope.add("Movies 2024", kind: .movie, playlist: scope.cinema, titles: ["Hot XXX Night", "Hot XXX Night 2", "Erotic Stories"])
            scope.add("Series | Drama", kind: .series, playlist: scope.cinema, titles: ["Harbor Lights", "The Night Desk", "Paper Kings"])
            scope.add("Series | Comedy", kind: .series, playlist: scope.cinema, titles: ["Office Plants", "Second Breakfast"])
            scope.add("Series | Sci-Fi", kind: .series, playlist: scope.cinema, titles: ["Orbit", "Deep Field"])
            scope.add("UK | Sport", kind: .live, playlist: scope.world, titles: (1...10).map { "Sky Sports \($0)" })
            scope.add("UK | News", kind: .live, playlist: scope.world, titles: ["BBC News", "Sky News", "GB News"])
            scope.add("IT | Sport", kind: .live, playlist: scope.world, titles: ["Sky Sport F1", "Sky Sport MotoGP", "Sky Sport Calcio", "DAZN 1"])
            scope.add("IT | Rai", kind: .live, playlist: scope.world, titles: ["Rai 1 HD", "Rai 2 HD", "Rai 3 HD"])
            scope.add("FR | General", kind: .live, playlist: scope.world, titles: ["TF1", "France 2", "France 3", "M6"])
            scope.add("Adult Channels", kind: .live, playlist: scope.world, titles: ["Playboy TV", "Hustler TV", "Dorcel TV"])
            scope.add("US | Adult Swim", kind: .live, playlist: scope.world, titles: ["Adult Swim East", "Adult Swim West"])
            return scope
        }

        static func adultOnly() -> Scope {
            var scope = Scope()
            scope.add("XXX | Adult", kind: .movie, playlist: scope.cinema, titles: (1...20).map { "Late Show \($0)" })
            scope.add("Adulti 18+", kind: .live, playlist: scope.world, titles: (1...10).map { "Night Channel \($0)" })
            return scope
        }
    }

    static let seeds: [UInt64] = (1...200).map { UInt64($0) &* 0x9E37_79B9 }

    @Test("Every selection is diverse: one page per category, title and franchise; every kind; both playlists")
    func diversity() {
        let scope = Scope.library()
        for seed in Self.seeds {
            let picks = scope.pick(seed: seed)
            #expect(picks.count == 8, "seed \(seed)")
            #expect(Set(picks.map { "\($0.playlistID)|\($0.groupName)" }).count == picks.count, "one page per category, seed \(seed): \(picks.map(\.displayName))")
            let keys = picks.map { FeaturedTitle.keys(of: $0) }
            #expect(Set(keys.map(\.duplicate)).count == picks.count, "one page per title, seed \(seed): \(picks.map(\.displayName))")
            #expect(Set(zip(picks, keys).map { "\($0.kind == .live)|\($1.franchise)" }).count == picks.count, "one page per franchise and channel family, seed \(seed): \(picks.map(\.displayName))")
            #expect(Set(picks.map(\.kind)) == Set(ChannelContentKind.allCases), "seed \(seed)")
            #expect(Set(picks.map(\.playlistID)).count == 2, "seed \(seed)")
            let sameKindInARow = zip(picks, picks.dropFirst()).filter { $0.kind == $1.kind }.count
            #expect(sameKindInARow <= 2, "kinds alternate, seed \(seed): \(picks.map(\.kind))")
        }
    }

    @Test("Adult content is never featured while there is anything else; Adult Swim is not adult content")
    func noAdultContent() {
        let scope = Scope.library()
        var everPicked: Set<String> = []
        for seed in Self.seeds {
            let picks = scope.pick(seed: seed)
            #expect(!picks.contains(where: MatureContent.isAdult), "seed \(seed): \(picks.map(\.displayName))")
            everPicked.formUnion(picks.map(\.displayName))
        }
        #expect(everPicked.contains { $0.hasPrefix("Adult Swim") })
    }

    @Test("With the setting off adult content may be featured; a library of only adult content is featured as it is")
    func adultContentWhenItIsAllThereIs() {
        let unfiltered = Self.seeds.prefix(60).flatMap { Scope.library().pick(seed: $0, filter: .inactive) }
        #expect(unfiltered.contains(where: MatureContent.isAdult))
        let adult = Scope.adultOnly()
        let onlyAdult = adult.categories.allSatisfy { MatureContent.isAdult(group: $0.name) }
        #expect(onlyAdult)
        let picks = adult.pick(seed: 7, filter: MatureContentFilter(isActive: !onlyAdult))
        #expect(picks.count == 2, "one page per category: \(picks.map(\.displayName))")
    }

    @Test("Selections rotate: the same seed gives the same pages, other seeds other pages")
    func rotation() {
        let scope = Scope.library()
        let first = scope.pick(seed: 42).map(\.id)
        #expect(scope.pick(seed: 42).map(\.id) == first)
        #expect(Set(scope.pick(seed: 43).map(\.id)).intersection(first).count < 6)
        let distinct = Set(Self.seeds.flatMap { scope.pick(seed: $0).map(\.displayName) })
        #expect(distinct.count >= 40, "\(distinct.count) different pages over \(Self.seeds.count) seeds")
        #expect(Set(Self.seeds.prefix(60).map { scope.pick(seed: $0).first?.kind }).count == 3, "the first page is of any kind")
    }

    @Test("Taste: watched categories come up more often; what Continue Watching shows is never featured, in any copy")
    func taste() throws {
        let scope = Scope.library()
        let comedyKey = "\(scope.cinema.uuidString)|Comedy"
        let watched = try #require(scope.entries[comedyKey]?.first)
        let taste = FeaturedPicker.Taste(categoryWeights: [comedyKey: 1], kindWeights: [.movie: 1], excludedKeys: [try #require(watched.bookmarkKey)])
        let baseline = Self.seeds.filter { scope.pick(seed: $0).contains { $0.groupName == "Comedy" } }.count
        let withTaste = Self.seeds.filter { scope.pick(seed: $0, taste: taste).contains { $0.groupName == "Comedy" } }.count
        #expect(withTaste > baseline)
        #expect(!Self.seeds.contains { scope.pick(seed: $0, taste: taste).contains { $0.id == watched.id } })
        #expect(Self.seeds.prefix(60).allSatisfy { Set(scope.pick(seed: $0, taste: taste).map(\.kind)).count == 3 }, "still every kind")

        let copy = Self.item("IT | Sky Sport F1 FHD", group: "IT | Sport", kind: .live, playlist: scope.world)
        let watchedChannel = Self.item("Sky Sport F1", group: "Sport", kind: .live, playlist: UUID())
        let picker = FeaturedPicker(categories: [], count: 8, seed: 1, filter: .inactive, taste: FeaturedPicker.Taste(excludedKeys: [FeaturedPicker.titleKey(of: watchedChannel)]))
        #expect(!picker.isAcceptable(copy))
        #expect(picker.isAcceptable(Self.item("Sky Sport MotoGP", group: "IT | Sport", kind: .live, playlist: scope.world)))
    }

    @Test("Only live channels: every page is live, still one per category and family")
    func liveOnly() {
        var scope = Scope.library()
        scope.categories = scope.categories.filter { $0.kind == .live }
        let picks = scope.pick(seed: 3)
        #expect(picks.allSatisfy { $0.kind == .live })
        #expect(picks.count == 6, "6 usable live categories: \(picks.map(\.displayName))")
    }

    @Test("Slots interleave the kinds: 3 movies, 3 series and 2 live channels in 8 pages")
    func slots() {
        var generator = SeededGenerator(seed: 1)
        let slots = FeaturedPicker.slots(kinds: Set(ChannelContentKind.allCases), taste: .none, count: 8, generator: &generator)
        let quota = Dictionary(grouping: slots, by: \.self).mapValues(\.count)
        #expect(slots.count == 8)
        #expect(quota[.movie] == 3 && quota[.series] == 3 && quota[.live] == 2, "\(slots.map(\.rawValue))")
    }

    @Test("Real artwork comes before placeholders; entries without artwork or a link are never featured")
    func artwork() {
        #expect(FeaturedPicker.artworkScore("https://img/poster.jpg") > FeaturedPicker.artworkScore("https://img/no_image.png"))
        let picker = FeaturedPicker(categories: [], count: 8, seed: 1, filter: .inactive)
        let playlist = UUID()
        #expect(!picker.isAcceptable(ChannelItem(id: UUID(), playlistID: playlist, name: "No Logo", logo: nil, url: URL(string: "https://x/1.mp4"), groupName: "Movies", kind: .movie)))
        #expect(!picker.isAcceptable(ChannelItem(id: UUID(), playlistID: playlist, name: "No Link", logo: "https://img/1.jpg", url: nil, groupName: "Movies", kind: .movie)))
    }

    @Test("The rotation draws new pages after six hours, on a new day, or when the clock went back")
    func rotationIsDue() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "Europe/Rome"))
        let morning = try #require(calendar.date(from: DateComponents(year: 2026, month: 11, day: 7, hour: 9)))
        #expect(!FeaturedRotation.isDue(drawnAt: morning, now: morning.addingTimeInterval(2 * 3_600), calendar: calendar))
        #expect(FeaturedRotation.isDue(drawnAt: morning, now: morning.addingTimeInterval(6 * 3_600), calendar: calendar))
        let lateEvening = try #require(calendar.date(from: DateComponents(year: 2026, month: 11, day: 7, hour: 23, minute: 30)))
        #expect(FeaturedRotation.isDue(drawnAt: lateEvening, now: lateEvening.addingTimeInterval(3_600), calendar: calendar))
        #expect(FeaturedRotation.isDue(drawnAt: morning, now: morning.addingTimeInterval(-60), calendar: calendar))
    }

    // MARK: - Loader

    @Test("The loader reads a diverse selection from a store, and the filter follows the scope and the setting")
    func loader() async throws {
        let container = try LibraryStore.makeInMemoryContainer()
        let scope = Scope.library()
        let adult = Scope.adultOnly()
        try Self.store(scope, in: container)
        try Self.store(adult, in: container)
        let importIDs = [scope.cinemaImport, scope.worldImport]
        let adultImportIDs = [adult.cinemaImport, adult.worldImport]

        let picks = await FeaturedLoader.load(importIDs: importIDs, seed: 99, hidesAdultContent: true, container: container)
        #expect(picks.count == 8)
        #expect(!picks.contains(where: MatureContent.isAdult))
        #expect(Set(picks.map(\.groupName)).count == 8)
        #expect(Set(picks.map(\.kind)) == Set(ChannelContentKind.allCases))
        #expect(picks.filter { $0.kind == .series }.allSatisfy { $0.series != nil }, "series pages carry their series")
        #expect(await FeaturedLoader.load(importIDs: importIDs, seed: 99, hidesAdultContent: true, container: container).map(\.id) == picks.map(\.id))

        let adultPicks = await FeaturedLoader.load(importIDs: adultImportIDs, seed: 5, hidesAdultContent: true, container: container)
        #expect(!adultPicks.isEmpty && adultPicks.allSatisfy(MatureContent.isAdult), "a scope of only adult content is featured as it is")

        #expect(MatureContentFilter.forScope(importIDs: importIDs, container: container, hidesAdultContent: true).isActive)
        #expect(!MatureContentFilter.forScope(importIDs: adultImportIDs, container: container, hidesAdultContent: true).isActive)
        #expect(MatureContentFilter.forScope(importIDs: importIDs + adultImportIDs, container: container, hidesAdultContent: true).isActive)
        #expect(!MatureContentFilter.forScope(importIDs: importIDs, container: container, hidesAdultContent: false).isActive)
    }

    // MARK: - Helpers

    static func item(_ name: String, group: String, kind: ChannelContentKind, playlist: UUID) -> ChannelItem {
        let path = kind == .live ? "live" : "movie"
        return ChannelItem(id: UUID(), playlistID: playlist, name: name, logo: "https://img/\(abs(name.hashValue)).jpg", url: URL(string: "https://x/\(path)/\(UUID().uuidString)\(kind == .live ? "" : ".mp4")"), groupName: group, kind: kind)
    }

    /// The scope's playlists, categories and entries as an import stores them.
    static func store(_ scope: Scope, in container: ModelContainer) throws {
        let context = ModelContext(container)
        var sortIndex = 0
        for category in scope.categories {
            let group = PlaylistChannelGroup(uuid: UUID(), name: category.name, sortIndex: sortIndex, channelCount: category.entryCount, importID: category.importID, playlistID: category.playlistID, kind: category.kind)
            group.listedCount = category.entryCount
            context.insert(group)
            for entry in scope.entries[category.key] ?? [] {
                let channel = PlaylistChannel(uuid: entry.id, name: entry.name, logo: entry.logo, groupName: category.name, url: entry.url, sortIndex: sortIndex, importID: category.importID, playlistID: category.playlistID, kind: entry.kind)
                if let series = entry.series {
                    channel.seriesKey = series.seriesKey
                    channel.episodeData = StoredEpisode(EpisodeInfo(seriesTitle: series.seriesTitle, seriesKey: series.seriesKey, year: nil, season: series.season, episode: series.episode, episodeTitle: series.episodeTitle, strength: .strong)).rawValue
                }
                context.insert(channel)
                sortIndex += 1
            }
        }
        for (playlistID, importID, name) in [(scope.cinema, scope.cinemaImport, "Cinema"), (scope.world, scope.worldImport, "World")] {
            let playlist = Playlist(uuid: playlistID, name: name, url: URL(fileURLWithPath: "/tmp/\(playlistID).m3u"), createdOn: .now)
            playlist.currentImportID = importID
            context.insert(playlist)
        }
        try context.save()
    }
}
