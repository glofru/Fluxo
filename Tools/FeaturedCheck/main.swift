//
//  main.swift
//  FeaturedCheck
//
//  Checks the featured billboard and the adult-content filter with the app's sources (Tools/FeaturedCheck/run.sh):
//  1. the classifier (`MatureContent`) on a broad list of names that are adult content and of names that only look
//     close to it ("Essex", "Adult Swim", "xXx (2002)");
//  2. the title keys (`FeaturedTitle`): the same title in other qualities and languages, franchises, channel families;
//  3. the picker (`FeaturedPicker`) on synthetic categories: one entry per category and franchise, kinds interleaved,
//     playlists mixed, the same pages for the same seed and other pages for others, the taste, what Continue Watching
//     shows left out, adult content left out unless it is all there is;
//  4. the loader (`FeaturedLoader`) and `MatureContentFilter.forScope` on an on-disk SwiftData store, with timings;
//  5. the rotation (`FeaturedRotation.isDue`).
//

import Foundation
import SwiftData

@main
@MainActor
enum FeaturedCheck {

    static var failures = 0

    static func expect(_ condition: Bool, _ message: @autoclosure () -> String) {
        if condition {
            print("  ok   \(message())")
        } else {
            failures += 1
            print("  FAIL \(message())")
        }
    }

    static func main() async throws {
        let arguments = CommandLine.arguments
        let storeURL = URL(fileURLWithPath: arguments.count > 1 ? arguments[1] : "/tmp/fluxo-featured-check.sqlite")
        let filler = arguments.count > 2 ? Int(arguments[2]) ?? 20_000 : 20_000

        print("== classifier")
        checkClassifier()
        print("== title keys")
        checkTitleKeys()
        print("== picker")
        checkPicker()
        print("== rotation")
        checkRotation()
        print("== store (\(filler) filler entries)")
        try await checkStore(url: storeURL, filler: filler)

        print(failures == 0 ? "\nAll checks passed." : "\n\(failures) check(s) FAILED.")
        exit(failures == 0 ? 0 : 1)
    }

    // MARK: - Classifier

    static func checkClassifier() {
        let missedGroups = ClassifierCases.adultGroups.filter { !MatureContent.isAdult(group: $0) }
        expect(missedGroups.isEmpty, "\(ClassifierCases.adultGroups.count) adult category names recognized" + (missedGroups.isEmpty ? "" : "; missed: \(missedGroups)"))
        let missedTitles = ClassifierCases.adultTitles.filter { !MatureContent.isAdult(title: $0.0, kind: $0.1) }
        expect(missedTitles.isEmpty, "\(ClassifierCases.adultTitles.count) adult titles recognized" + (missedTitles.isEmpty ? "" : "; missed: \(missedTitles.map(\.0))"))
        let falsePositives = ClassifierCases.ordinaryNames.filter { name, kind in
            kind == nil ? MatureContent.isAdult(group: name) : MatureContent.isAdult(title: name, kind: kind)
        }
        expect(falsePositives.isEmpty, "\(ClassifierCases.ordinaryNames.count) ordinary names left alone" + (falsePositives.isEmpty ? "" : "; flagged: \(falsePositives.map(\.0))"))
        // As titles, the ordinary category names stay ordinary too (Home reads both).
        let titleFalsePositives = ClassifierCases.ordinaryNames.filter { MatureContent.isAdult(title: $0.0, kind: $0.1) }
        expect(titleFalsePositives.isEmpty, "ordinary names are ordinary titles" + (titleFalsePositives.isEmpty ? "" : "; flagged: \(titleFalsePositives.map(\.0))"))

        let playlist = UUID()
        let inAdultGroup = item("Late Show", group: "XXX | Adult", kind: .movie, playlist: playlist)
        let adultTitle = item("Hot XXX Night", group: "Movies", kind: .movie, playlist: playlist)
        let ordinary = item("The Silent Harbor (2001)", group: "Movies", kind: .movie, playlist: playlist)
        expect(MatureContent.isAdult(inAdultGroup) && MatureContent.isAdult(adultTitle) && !MatureContent.isAdult(ordinary), "entries: by category and by title")
        let episode = ChannelItem(id: UUID(), playlistID: playlist, name: "Hentai Collection S01E01", logo: "https://x/p.png", url: URL(string: "https://x/1.mkv"), groupName: "Anime", kind: .series, series: EpisodeRef(seriesKey: "hentai collection", seriesTitle: "Hentai Collection", season: 1, episode: 1, episodeTitle: nil))
        expect(MatureContent.isAdult(episode), "episodes: by series title")
        expect(MatureContent.isAdult(programmeTitle: "Late Night", categories: ["Erotic"]) && !MatureContent.isAdult(programmeTitle: "Evening News", categories: ["News", "Adult Education"]), "programmes: by title and categories")
        let active = MatureContentFilter(isActive: true)
        expect(!active.allows(inAdultGroup) && active.allows(ordinary) && MatureContentFilter.inactive.allows(inAdultGroup), "filter: active leaves adult content out, inactive allows everything")

        let names = (0..<20_000).map { "IT | Sky Sport \($0 % 300) FHD Calcio Serie A" }
        let clock = ContinuousClock()
        let start = clock.now
        var count = 0
        for name in names where MatureContent.isAdult(title: name, kind: .live) {
            count += 1
        }
        let elapsed = clock.now - start
        expect(count == 0, "speed: 20,000 names in \(elapsed.formatted(.units(allowed: [.milliseconds])))")
    }

    // MARK: - Title keys

    static func checkTitleKeys() {
        for (a, b) in ClassifierCases.sameTitle {
            let kind: ChannelContentKind = a.contains("Sky Sport") ? .live : .movie
            let ka = FeaturedTitle.keys(title: a, kind: kind)
            let kb = FeaturedTitle.keys(title: b, kind: kind)
            expect(ka.duplicate == kb.duplicate, "same title: \"\(a)\" = \"\(b)\" (\(ka.duplicate) / \(kb.duplicate))")
        }
        for (a, b) in ClassifierCases.sameFranchise {
            let ka = FeaturedTitle.keys(title: a, kind: .movie)
            let kb = FeaturedTitle.keys(title: b, kind: .movie)
            expect(ka.franchise == kb.franchise, "same franchise: \"\(a)\" ~ \"\(b)\" (\(ka.franchise) / \(kb.franchise))")
        }
        for (a, b) in ClassifierCases.sameLiveFamily {
            let ka = FeaturedTitle.keys(title: a, kind: .live)
            let kb = FeaturedTitle.keys(title: b, kind: .live)
            expect(ka.franchise == kb.franchise, "same channel family: \"\(a)\" ~ \"\(b)\" (\(ka.franchise) / \(kb.franchise))")
        }
        for (a, b) in ClassifierCases.differentTitles {
            let ka = FeaturedTitle.keys(title: a, kind: .movie)
            let kb = FeaturedTitle.keys(title: b, kind: .movie)
            expect(ka.duplicate != kb.duplicate && ka.franchise != kb.franchise, "different: \"\(a)\" ≠ \"\(b)\" (\(ka.franchise) / \(kb.franchise))")
        }
        for (a, b) in ClassifierCases.differentLiveFamilies {
            let ka = FeaturedTitle.keys(title: a, kind: .live)
            let kb = FeaturedTitle.keys(title: b, kind: .live)
            expect(ka.franchise != kb.franchise, "different channels: \"\(a)\" ≠ \"\(b)\" (\(ka.franchise) / \(kb.franchise))")
        }
    }

    // MARK: - Picker

    /// A synthetic scope: the "Cinema" playlist (movie categories, one a franchise of near-duplicates, an adult one,
    /// series), the "World" playlist (live categories in provider sections), each entry with artwork.
    struct Scope {
        let categories: [FeaturedPicker.Category]
        let entries: [String: [ChannelItem]]
        let cinema: UUID
        let world: UUID

        func fetch(_ category: FeaturedPicker.Category, offset: Int, limit: Int) -> [ChannelItem] {
            let all = entries[category.key] ?? []
            guard offset < all.count else {
                return []
            }
            return Array(all[offset..<min(all.count, offset + limit)])
        }
    }

    static func makeScope(adultOnly: Bool = false) -> Scope {
        let cinema = UUID()
        let world = UUID()
        let importCinema = UUID()
        let importWorld = UUID()
        var categories: [FeaturedPicker.Category] = []
        var entries: [String: [ChannelItem]] = [:]
        func add(_ name: String, kind: ChannelContentKind, playlist: UUID, importID: UUID, titles: [String]) {
            let category = FeaturedPicker.Category(importID: importID, playlistID: playlist, name: name, kind: kind, entryCount: titles.count)
            categories.append(category)
            entries[category.key] = titles.map { title in
                if kind == .series {
                    let show = title
                    return ChannelItem(id: UUID(), playlistID: playlist, name: "\(show) S01E01", logo: "https://img/\(show).png", url: URL(string: "https://x/series/\(UUID().uuidString).mkv"), groupName: name, kind: .series, series: EpisodeRef(seriesKey: show.lowercased(), seriesTitle: show, season: 1, episode: 1, episodeTitle: nil))
                }
                return item(title, group: name, kind: kind, playlist: playlist)
            }
        }
        if adultOnly {
            add("XXX | Adult", kind: .movie, playlist: cinema, importID: importCinema, titles: (1...20).map { "Late Show \($0)" })
            add("Adulti 18+", kind: .live, playlist: world, importID: importWorld, titles: (1...10).map { "Night Channel \($0)" })
            return Scope(categories: categories, entries: entries, cinema: cinema, world: world)
        }
        let franchise = (1...10).flatMap { number in ["Fast & Furious \(number) (20\(10 + number))", "Fast & Furious \(number) [ITA]", "Fast & Furious \(number) 4K"] }
        add("Action | Saga", kind: .movie, playlist: cinema, importID: importCinema, titles: franchise)
        add("Comedy", kind: .movie, playlist: cinema, importID: importCinema, titles: (1...30).map { "Comedy Film \(["Alpha", "Bravo", "Delta", "Echo", "Foxtrot", "Golf"][$0 % 6]) \($0)" })
        add("Drama", kind: .movie, playlist: cinema, importID: importCinema, titles: ["Avatar (2009) [ITA]", "Avatar (2009)", "Avatar 4K", "Inception (2010)", "Inception [MULTI]", "Gravity (2013)"])
        add("Thriller", kind: .movie, playlist: cinema, importID: importCinema, titles: (1...20).map { "Thriller Night \(["Nova", "Orion", "Pulsar", "Quasar"][$0 % 4]) Part \($0)" })
        add("Family", kind: .movie, playlist: cinema, importID: importCinema, titles: ["Toy Story (1995)", "Toy Story 2 (1999)", "Toy Story 3 (2010)", "Up (2009)", "Coco (2017)"])
        add("XXX | Adult", kind: .movie, playlist: cinema, importID: importCinema, titles: (1...40).map { "Late Show \($0)" })
        add("Movies 2024", kind: .movie, playlist: cinema, importID: importCinema, titles: ["Hot XXX Night", "Hot XXX Night 2", "Erotic Stories"])
        add("Series | Drama", kind: .series, playlist: cinema, importID: importCinema, titles: ["Harbor Lights", "The Night Desk", "Paper Kings"])
        add("Series | Comedy", kind: .series, playlist: cinema, importID: importCinema, titles: ["Office Plants", "Second Breakfast"])
        add("Series | Sci-Fi", kind: .series, playlist: cinema, importID: importCinema, titles: ["Orbit", "Deep Field"])
        add("UK | Sport", kind: .live, playlist: world, importID: importWorld, titles: (1...10).map { "Sky Sports \($0)" })
        add("UK | News", kind: .live, playlist: world, importID: importWorld, titles: ["BBC News", "Sky News", "GB News"])
        add("IT | Sport", kind: .live, playlist: world, importID: importWorld, titles: ["Sky Sport F1", "Sky Sport MotoGP", "Sky Sport Calcio", "DAZN 1"])
        add("IT | Rai", kind: .live, playlist: world, importID: importWorld, titles: ["Rai 1 HD", "Rai 2 HD", "Rai 3 HD"])
        add("FR | General", kind: .live, playlist: world, importID: importWorld, titles: ["TF1", "France 2", "France 3", "M6"])
        add("Adult Channels", kind: .live, playlist: world, importID: importWorld, titles: ["Playboy TV", "Hustler TV", "Dorcel TV"])
        add("US | Adult Swim", kind: .live, playlist: world, importID: importWorld, titles: ["Adult Swim East", "Adult Swim West"])
        return Scope(categories: categories, entries: entries, cinema: cinema, world: world)
    }

    static func pick(_ scope: Scope, seed: UInt64, filter: MatureContentFilter = MatureContentFilter(isActive: true), taste: FeaturedPicker.Taste = .none) -> [ChannelItem] {
        var picker = FeaturedPicker(categories: scope.categories, count: 8, seed: seed, filter: filter, taste: taste)
        return picker.pick { scope.fetch($0, offset: $1, limit: $2) }
    }

    static func checkPicker() {
        let scope = makeScope()
        let seeds: [UInt64] = (1...200).map { UInt64($0) &* 0x9E37_79B9 }
        var everPicked: Set<String> = []
        var allGood = (count: true, groups: true, titles: true, franchises: true, kinds: true, playlists: true, adult: true, interleaved: true)
        for seed in seeds {
            let picks = pick(scope, seed: seed)
            everPicked.formUnion(picks.map(\.displayName))
            allGood.count = allGood.count && picks.count == 8
            allGood.groups = allGood.groups && Set(picks.map { "\($0.playlistID)|\($0.groupName)" }).count == picks.count
            let keys = picks.map { FeaturedTitle.keys(of: $0) }
            allGood.titles = allGood.titles && Set(keys.map(\.duplicate)).count == picks.count
            allGood.franchises = allGood.franchises && Set(zip(picks, keys).map { "\($0.kind == .live)|\($1.franchise)" }).count == picks.count
            allGood.kinds = allGood.kinds && Set(picks.map(\.kind)) == Set(ChannelContentKind.allCases)
            allGood.playlists = allGood.playlists && Set(picks.map(\.playlistID)).count == 2
            allGood.adult = allGood.adult && !picks.contains(where: MatureContent.isAdult)
            // No two pages of the same kind in a row while other kinds have pages left.
            let runs = zip(picks, picks.dropFirst()).filter { $0.kind == $1.kind }.count
            allGood.interleaved = allGood.interleaved && runs <= 2
            if !allGood.franchises || !allGood.groups {
                print("    seed \(seed): \(picks.map(\.displayName))")
                break
            }
        }
        expect(allGood.count, "200 seeds: 8 pages each")
        expect(allGood.groups, "one page per category")
        expect(allGood.titles, "one page per title (qualities and languages count once)")
        expect(allGood.franchises, "one page per franchise and channel family (\"Fast & Furious\", \"Sky Sport\", \"Rai\")")
        expect(allGood.kinds, "movies, series and live channels in every selection")
        expect(allGood.playlists, "both playlists in every selection")
        expect(allGood.adult, "no adult content (\"XXX | Adult\", \"Adult Channels\", \"Hot XXX Night\")")
        expect(allGood.interleaved, "kinds alternate (at most two pages of a kind in a row)")
        expect(everPicked.contains { $0.hasPrefix("Adult Swim") }, "\"Adult Swim\" is not adult content: it is featured too")
        expect(everPicked.count >= 40, "rotation: \(everPicked.count) different pages over 200 seeds")

        let first = pick(scope, seed: 42).map(\.id)
        expect(pick(scope, seed: 42).map(\.id) == first, "the same seed gives the same pages")
        let other = pick(scope, seed: 43).map(\.id)
        expect(Set(other).intersection(first).count < 6, "another seed gives other pages (\(Set(other).intersection(first).count) of 8 in common)")
        let firstPages = Set(seeds.prefix(60).map { pick(scope, seed: $0).first?.kind })
        expect(firstPages.count == 3, "the first page is of any kind across seeds")

        // Adult content: off when the setting is off; on when it is all there is.
        let unfiltered = seeds.prefix(60).flatMap { pick(scope, seed: $0, filter: .inactive) }
        expect(unfiltered.contains(where: MatureContent.isAdult), "setting off: adult content may be featured")
        let adultScope = makeScope(adultOnly: true)
        let onlyAdult = adultScope.categories.allSatisfy { MatureContent.isAdult(group: $0.name) }
        let adultPicks = pick(adultScope, seed: 7, filter: MatureContentFilter(isActive: !onlyAdult))
        expect(onlyAdult && adultPicks.count == 2, "only adult content: it is featured (\(adultPicks.count) pages, one per category)")

        // Taste: the watched category comes up more often; what Continue Watching shows is never featured.
        let comedyKey = "\(scope.cinema.uuidString)|Comedy"
        let watched = scope.entries[comedyKey]!.first!
        let taste = FeaturedPicker.Taste(categoryWeights: [comedyKey: 1], kindWeights: [.movie: 1], excludedKeys: [watched.bookmarkKey!])
        let baseline = seeds.filter { pick(scope, seed: $0).contains { $0.groupName == "Comedy" } }.count
        var withTaste = 0
        var showedWatched = false
        for seed in seeds {
            let picks = pick(scope, seed: seed, taste: taste)
            if picks.contains(where: { $0.groupName == "Comedy" }) {
                withTaste += 1
            }
            showedWatched = showedWatched || picks.contains { $0.id == watched.id }
        }
        expect(withTaste > baseline, "taste: the watched category in \(withTaste) of 200 selections (\(baseline) without)")
        expect(!showedWatched, "taste: what Continue Watching shows is not featured")
        // Another copy of a watched title is left out too ("IT | Sky Sport F1 FHD" for "Sky Sport F1").
        let copy = item("IT | Sky Sport F1 FHD", group: "IT | Sport", kind: .live, playlist: scope.world)
        let watchedTaste = FeaturedPicker.Taste(excludedKeys: [FeaturedPicker.titleKey(of: item("Sky Sport F1", group: "Sport", kind: .live, playlist: UUID()))])
        let picker = FeaturedPicker(categories: [], count: 8, seed: 1, filter: .inactive, taste: watchedTaste)
        expect(!picker.isAcceptable(copy) && picker.isAcceptable(item("Sky Sport MotoGP", group: "IT | Sport", kind: .live, playlist: scope.world)), "taste: other copies of what Continue Watching shows are not featured")
        let movieShare = seeds.prefix(60).map { seed in pick(scope, seed: seed, taste: taste).filter { $0.kind == .movie }.count }.reduce(0, +)
        let baseShare = seeds.prefix(60).map { seed in pick(scope, seed: seed).filter { $0.kind == .movie }.count }.reduce(0, +)
        expect(movieShare > baseShare, "taste: more movies for a movie viewer (\(movieShare) vs \(baseShare) of 480 pages)")
        expect(seeds.prefix(60).allSatisfy { Set(pick(scope, seed: $0, taste: taste).map(\.kind)).count == 3 }, "taste: still every kind")

        // Only live channels: every page is live, still one per category and family.
        let liveOnly = Scope(categories: scope.categories.filter { $0.kind == .live }, entries: scope.entries, cinema: scope.cinema, world: scope.world)
        let livePicks = pick(liveOnly, seed: 3)
        expect(livePicks.allSatisfy { $0.kind == .live } && livePicks.count == 6, "live only: \(livePicks.count) pages from 6 usable categories: \(livePicks.map(\.displayName))")

        // Slots: interleaved quotas.
        var generator = SeededGenerator(seed: 1)
        let slots = FeaturedPicker.slots(kinds: Set(ChannelContentKind.allCases), taste: .none, count: 8, generator: &generator)
        let quota = Dictionary(grouping: slots, by: \.self).mapValues(\.count)
        expect(slots.count == 8 && quota[.movie] == 3 && quota[.series] == 3 && quota[.live] == 2, "slots: 3 movies, 3 series, 2 live: \(slots.map(\.rawValue))")

        // Artwork: a placeholder is passed over for real artwork.
        expect(FeaturedPicker.artworkScore("https://img/poster.jpg") > FeaturedPicker.artworkScore("https://img/no_image.png"), "artwork: real posters before placeholders")
    }

    // MARK: - Rotation

    static func checkRotation() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Rome")!
        let morning = calendar.date(from: DateComponents(year: 2026, month: 11, day: 7, hour: 9))!
        expect(!FeaturedRotation.isDue(drawnAt: morning, now: morning.addingTimeInterval(2 * 3_600), calendar: calendar), "rotation: the same pages two hours later")
        expect(FeaturedRotation.isDue(drawnAt: morning, now: morning.addingTimeInterval(6 * 3_600), calendar: calendar), "rotation: new pages after six hours")
        let lateEvening = calendar.date(from: DateComponents(year: 2026, month: 11, day: 7, hour: 23, minute: 30))!
        expect(FeaturedRotation.isDue(drawnAt: lateEvening, now: lateEvening.addingTimeInterval(3_600), calendar: calendar), "rotation: new pages on a new day")
        expect(FeaturedRotation.isDue(drawnAt: morning, now: morning.addingTimeInterval(-60), calendar: calendar), "rotation: new pages when the clock went back")
    }

    // MARK: - Store

    static func checkStore(url: URL, filler: Int) async throws {
        for suffix in ["", "-wal", "-shm"] {
            try? FileManager.default.removeItem(atPath: url.path + suffix)
        }
        let schema = Schema(ModelRegistry.all)
        let container = try ModelContainer(for: schema, configurations: ModelConfiguration(schema: schema, url: url))
        let context = ModelContext(container)
        let scope = makeScope()
        let adultScope = makeScope(adultOnly: true)

        // The synthetic scopes as playlists, plus filler categories of live channels.
        func store(_ scope: Scope, names: [UUID: String], filler: Int) throws -> [UUID] {
            var importIDs: [UUID: UUID] = [:]
            var sortIndex = 0
            for category in scope.categories {
                importIDs[category.playlistID] = category.importID
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
            if filler > 0, let world = importIDs[scope.world] {
                let groups = 100
                for index in 0..<groups {
                    let name = "ZZ | Filler \(index)"
                    let group = PlaylistChannelGroup(uuid: UUID(), name: name, sortIndex: sortIndex, channelCount: filler / groups, importID: world, playlistID: scope.world, kind: .live)
                    group.listedCount = filler / groups
                    context.insert(group)
                    for number in 0..<(filler / groups) {
                        context.insert(PlaylistChannel(uuid: UUID(), name: "Filler \(index) Channel \(number)", logo: number.isMultiple(of: 3) ? "https://img/filler.png" : nil, groupName: name, url: URL(string: "https://x/live/\(index)/\(number)"), sortIndex: sortIndex, importID: world, playlistID: scope.world, kind: .live))
                        sortIndex += 1
                    }
                }
            }
            for (playlistID, importID) in importIDs {
                let playlist = Playlist(uuid: playlistID, name: names[playlistID] ?? "Playlist", url: URL(string: "https://example.invalid/\(playlistID).m3u")!, createdOn: .now)
                playlist.currentImportID = importID
                context.insert(playlist)
            }
            try context.save()
            return Array(importIDs.values)
        }
        let importIDs = try store(scope, names: [scope.cinema: "Cinema", scope.world: "World"], filler: filler)
        let adultImportIDs = try store(adultScope, names: [adultScope.cinema: "Late Cinema", adultScope.world: "Late World"], filler: 0)

        let clock = ContinuousClock()
        var started = clock.now
        let picks = await FeaturedLoader.load(importIDs: importIDs, seed: 99, hidesAdultContent: true, container: container)
        let elapsed = clock.now - started
        expect(picks.count == 8 && !picks.contains(where: MatureContent.isAdult) && Set(picks.map(\.groupName)).count == 8, "loader: 8 pages from 8 categories, no adult content, in \(elapsed.formatted(.units(allowed: [.milliseconds])))")
        expect(Set(picks.map(\.kind)) == Set(ChannelContentKind.allCases), "loader: every kind: \(picks.map(\.displayName))")
        let again = await FeaturedLoader.load(importIDs: importIDs, seed: 99, hidesAdultContent: true, container: container)
        expect(again.map(\.id) == picks.map(\.id), "loader: the same seed gives the same pages")
        let series = picks.filter { $0.kind == .series }
        expect(series.allSatisfy { $0.series != nil }, "loader: series pages carry their series")
        var adultSeen = false
        for seed in UInt64(1)...40 where !adultSeen {
            adultSeen = await FeaturedLoader.load(importIDs: importIDs, seed: seed, hidesAdultContent: false, container: container).contains(where: MatureContent.isAdult)
        }
        expect(adultSeen, "loader: setting off, adult content may be featured")
        started = clock.now
        let adultPicks = await FeaturedLoader.load(importIDs: adultImportIDs, seed: 5, hidesAdultContent: true, container: container)
        expect(!adultPicks.isEmpty && adultPicks.allSatisfy(MatureContent.isAdult), "loader: a scope of only adult content is featured as it is (\(adultPicks.count) pages) in \((clock.now - started).formatted(.units(allowed: [.milliseconds])))")

        started = clock.now
        let filter = MatureContentFilter.forScope(importIDs: importIDs, container: container, hidesAdultContent: true)
        let first = clock.now - started
        started = clock.now
        _ = MatureContentFilter.forScope(importIDs: importIDs, container: container, hidesAdultContent: true)
        let cached = clock.now - started
        expect(filter.isActive, "filter: active for a scope with other content (\(first.formatted(.units(allowed: [.milliseconds, .microseconds])))), then from the cache (\(cached.formatted(.units(allowed: [.microseconds]))))")
        expect(!MatureContentFilter.forScope(importIDs: adultImportIDs, container: container, hidesAdultContent: true).isActive, "filter: inactive for a scope of only adult content")
        expect(MatureContentFilter.forScope(importIDs: importIDs + adultImportIDs, container: container, hidesAdultContent: true).isActive, "filter: active for both scopes together")
        expect(!MatureContentFilter.forScope(importIDs: importIDs, container: container, hidesAdultContent: false).isActive, "filter: inactive with the setting off")
    }

    // MARK: - Helpers

    static func item(_ name: String, group: String, kind: ChannelContentKind, playlist: UUID) -> ChannelItem {
        let path = kind == .live ? "live" : "movie"
        return ChannelItem(id: UUID(), playlistID: playlist, name: name, logo: "https://img/\(abs(name.hashValue)).jpg", url: URL(string: "https://x/\(path)/\(UUID().uuidString)\(kind == .live ? "" : ".mp4")"), groupName: group, kind: kind)
    }
}
