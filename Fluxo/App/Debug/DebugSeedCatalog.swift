//
//  DebugSeedCatalog.swift
//  Fluxo
//
//  Debug harness: the content of `-FluxoDebugSeed`. It is written as M3U files and imported through the real
//  import pipeline (download, parser, content-kind classification, batched storage), so seeded libraries look
//  exactly like imported ones.
//
//  `sample` has four playlists (376 entries in 33 groups): Italian and international live TV with realistic IPTV names
//  (quality tags, "IT | " prefixes, CJK, Arabic and Greek names, a very long name), a movies and series
//  catalogue with Xtream-style URLs, and a "Loopback Test" playlist whose channels play the streams of
//  Tools/Simulator/test-stream.sh. Live channels have tvg-id attributes in the iptv-org style.
//  `large` adds two generated playlists with about 46,000 entries in 330 groups, whose logos and posters are http
//  URLs of the test-stream server.
//

#if DEBUG
import Foundation

struct DebugSeedPlaylist {
    struct Entry {
        let name: String
        let group: String
        let url: String
        var tvgID: String?
        var logo: String?
    }

    let name: String
    var entries: [Entry] = []

    /// The playlist as M3U text.
    var m3u: String {
        var text = "#EXTM3U\n"
        text.reserveCapacity(entries.count * 160)
        for entry in entries {
            text += "#EXTINF:-1"
            if let tvgID = entry.tvgID {
                text += " tvg-id=\"\(tvgID)\""
            }
            text += " tvg-name=\"\(entry.name)\""
            if let logo = entry.logo {
                text += " tvg-logo=\"\(logo)\""
            }
            text += " group-title=\"\(entry.group)\",\(entry.name)\n\(entry.url)\n"
        }
        return text
    }
}

enum DebugSeedCatalog {

    /// Host of every seeded stream that is not a loopback test stream. `.invalid` never resolves (RFC 6761), so
    /// playing one fails fast with the player's error card.
    static let host = "http://seed.fluxo.invalid"

    /// Favorites and watch history of the sample library: names, or name prefixes, of seeded entries.
    static let favoriteNames = ["Sky Sport F1", "Rai 1 HD", "BBC One HD", "Test Pattern (HLS)", "Sky Cinema Uno", "NHK総合", "The Silent Harbor", "Orbit S01E01"]
    static let historyNames = ["Test Pattern (MPEG-TS)", "Sky Sport F1", "Sky TG24", "Canale 5", "BBC News", "TF1", "Orbit S01E02", "Crimson Signal", "Rai Sport HD", "Eurosport 1"]
    /// Titles of the fake recordings.
    static let recordingTitles = ["Sky Sport F1", "BBC One HD", "Rai 1 HD"]

    static func playlists(_ seed: DebugLaunchOptions.Seed, testStreamBaseURL: URL) -> [DebugSeedPlaylist] {
        let sample = [skyItalia(), worldTV(), cinemaClub(), loopbackTest(baseURL: testStreamBaseURL)]
        switch seed {
        case .sample:
            return sample
        case .large:
            return sample + [megaLive(artworkBase: base(of: testStreamBaseURL)), megaOnDemand(artworkBase: base(of: testStreamBaseURL))]
        }
    }

    // MARK: - Sample

    private static func skyItalia() -> DebugSeedPlaylist {
        live("Sky Italia", country: "it", groups: [
            ("Sport", [
                "Sky Sport F1", "Sky Sport MotoGP", "Sky Sport Calcio", "Sky Sport Uno", "Sky Sport Arena", "Sky Sport Tennis",
                "Sky Sport NBA", "Sky Sport Max", "Sky Sport 24", "Sky Sport Golf", "Eurosport 1", "Eurosport 2", "DAZN 1", "DAZN 2",
                "Rai Sport HD", "IT | Sky Sport F1 FHD", "Sky Sport F1 4K HDR — Gran Premio d'Italia Multicam con Telecamere Onboard",
            ]),
            ("Intrattenimento", [
                "Sky Uno", "Sky Atlantic", "Sky Serie", "Sky Investigation", "Sky Arte", "Sky Documentaries", "Sky Nature", "TV8",
                "Cielo", "Real Time", "Discovery Channel", "DMAX", "Nove", "Comedy Central",
            ]),
            ("Cinema", [
                "Sky Cinema Uno", "Sky Cinema Due", "Sky Cinema Action", "Sky Cinema Collection", "Sky Cinema Comedy",
                "Sky Cinema Family", "Sky Cinema Romance", "Sky Cinema Suspense", "Sky Cinema Drama", "Rai Movie", "Iris", "Cine34",
            ]),
            ("News", [
                "Sky TG24", "Rai News 24", "TGCOM24", "Euronews", "BBC World News", "CNN International", "Bloomberg TV",
                "Al Jazeera English", "France 24 English", "DW English", "CNBC Europe",
            ]),
            ("Rai", ["Rai 1 HD", "Rai 2 HD", "Rai 3 HD", "Rai 4", "Rai 5", "Rai Premium", "Rai Gulp", "Rai Yoyo", "Rai Storia", "Rai Scuola"]),
            ("Mediaset", ["Canale 5", "Italia 1", "Rete 4", "20 Mediaset", "La5", "Focus", "Top Crime", "Boing", "Cartoonito", "Twentyseven", "Mediaset Extra"]),
            ("Kids", ["Nick Jr", "Nickelodeon", "Cartoon Network", "Boomerang", "DeA Kids", "DeA Junior", "Disney Junior", "Frisbee", "K2"]),
            ("Musica", ["MTV Music", "Radio Italia TV", "RTL 102.5 TV", "Deejay TV", "Radio Kiss Kiss TV", "VH1", "Virgin Radio TV"]),
        ])
    }

    private static func worldTV() -> DebugSeedPlaylist {
        live("World TV", country: nil, groups: [
            ("UK | General", ["BBC One HD", "BBC Two HD", "ITV1 HD", "Channel 4 HD", "Channel 5", "E4", "Dave", "Sky Showcase", "Sky Max"]),
            ("UK | Sport", ["Sky Sports Main Event", "Sky Sports F1", "Sky Sports Premier League", "Sky Sports Football", "TNT Sports 1", "TNT Sports 2", "Eurosport UK"]),
            ("UK | News", ["BBC News", "Sky News", "GB News"]),
            ("France", ["TF1", "France 2", "France 3", "France 5", "Canal+", "Canal+ Sport", "M6", "Arte", "BFM TV", "LCI", "franceinfo", "TV5Monde"]),
            ("Deutschland", ["Das Erste HD", "ZDF HD", "RTL", "ProSieben", "Sat.1", "VOX", "Kabel Eins", "n-tv", "Sport1", "Sky Sport Bundesliga"]),
            ("España", ["La 1", "La 2", "Antena 3", "Cuatro", "Telecinco", "laSexta", "Movistar LaLiga", "DAZN F1", "Teledeporte"]),
            ("日本 Japan", ["NHK総合", "NHK Eテレ", "日本テレビ", "テレビ朝日", "TBSテレビ", "フジテレビ", "NHK World Japan"]),
            ("عربي Arabic", ["الجزيرة", "العربية", "MBC 1", "beIN Sports 1", "beIN Sports 2"]),
            ("Ελλάδα", ["ΕΡΤ1", "ANT1", "Star Channel"]),
            ("Brasil", ["Globo", "SBT", "Record TV", "SporTV", "ESPN Brasil"]),
            ("Music", ["MTV Live HD", "Trace Urban", "Mezzo", "Stingray Classica"]),
        ])
    }

    private static func cinemaClub() -> DebugSeedPlaylist {
        var playlist = DebugSeedPlaylist(name: "Cinema Club")
        let movieGroups = ["Azione | Action", "Commedia | Comedy", "Drama", "Fantascienza | Sci-Fi", "Animation", "Documentari", "4K UHD", "Classics"]
        var id = 1_000
        for (groupIndex, group) in movieGroups.enumerated() {
            for index in 0..<12 {
                let title = movieTitle(groupIndex * 12 + index)
                let year = 1_968 + (groupIndex * 31 + index * 7) % 57
                let name = "\(title) (\(year))"
                id += 1
                playlist.entries.append(.init(name: name, group: group, url: "\(host)/movie/demo/demo/\(id).mp4", logo: posterLogo(name, subtitle: "\(year) · \(group)", index: id)))
            }
        }
        let seriesGroups: [(String, [String])] = [
            ("Serie TV | Drama", ["Harbor Lights", "The Night Desk", "Paper Kings"]),
            ("Series | Comedy", ["Small Town Signals", "Office Plants", "Second Breakfast"]),
            ("Series | Sci-Fi", ["Orbit", "Deep Field", "The Lantern Protocol"]),
            ("Anime", ["Sky Runners", "Moonlit Garden"]),
        ]
        for (group, shows) in seriesGroups {
            for show in shows {
                for season in 1...2 {
                    for episode in 1...5 {
                        id += 1
                        let name = String(format: "%@ S%02dE%02d", show, season, episode)
                        playlist.entries.append(.init(name: name, group: group, url: "\(host)/series/demo/demo/\(id).mkv", logo: posterLogo(show, subtitle: "Season \(season)", index: id)))
                    }
                }
            }
        }
        return playlist
    }

    /// Streams of Tools/Simulator/test-stream.sh, plus one that always fails.
    private static func loopbackTest(baseURL: URL) -> DebugSeedPlaylist {
        let base = base(of: baseURL)
        var playlist = DebugSeedPlaylist(name: "Loopback Test")
        let live: [(String, String)] = [
            ("Test Pattern (HLS)", "\(base)/hls/live.m3u8"),
            ("Test Pattern (MPEG-TS)", "\(base)/live/test-pattern"),
            ("Unreachable Channel", "http://127.0.0.1:9/live/offline"),
        ]
        for (name, url) in live {
            playlist.entries.append(.init(name: name, group: "Test Streams", url: url, tvgID: "FluxoTest.test", logo: DebugArtwork.logo(for: name, style: .filled)))
        }
        let onDemand: [(String, String)] = [
            ("Test Clip (MP4)", "\(base)/movie/clip.mp4"),
            ("Test Clip (MPEG-TS)", "\(base)/movie/clip.ts"),
        ]
        for (name, url) in onDemand {
            playlist.entries.append(.init(name: name, group: "Test On Demand", url: url, logo: DebugArtwork.poster(title: name, subtitle: "Loopback")))
        }
        return playlist
    }

    // MARK: - Large

    /// Logos of the large playlists are short http URLs served by Tools/Simulator/test-stream.sh (240 distinct
    /// images), like real large playlists: inline images would make the files hundreds of megabytes. Without the
    /// test-stream server they fail to load and the cards show their placeholders.
    private static func megaLive(artworkBase: String) -> DebugSeedPlaylist {
        let countries = ["IT", "UK", "FR", "DE", "ES", "PT", "NL", "BE", "CH", "AT", "PL", "GR", "TR", "US", "CA", "BR", "AR", "MX", "IN", "AR-SA"]
        let categories = ["General", "Sport", "News", "Movies", "Kids", "Music", "Documentary", "Entertainment", "Regional", "Religious", "Shopping", "Adult Swim", "Local", "4K", "Radio"]
        var playlist = DebugSeedPlaylist(name: "Mega IPTV")
        var id = 0
        for country in countries {
            for category in categories {
                let group = "\(country) | \(category)"
                for index in 1...100 {
                    id += 1
                    let name = "\(country) | \(category) \(index) \(["HD", "FHD", "SD", "4K"][index % 4])"
                    let logo = id.isMultiple(of: 2) ? "\(artworkBase)/logo/\(id % 240).png" : nil
                    playlist.entries.append(.init(name: name, group: group, url: "\(host)/live/mega/mega/\(id)", tvgID: "\(country)\(category)\(index).\(country.lowercased())", logo: logo))
                }
            }
        }
        return playlist
    }

    private static func megaOnDemand(artworkBase: String) -> DebugSeedPlaylist {
        var playlist = DebugSeedPlaylist(name: "Mega VOD")
        var id = 100_000
        for groupIndex in 0..<24 {
            let group = "VOD | \(["Action", "Comedy", "Drama", "Thriller", "Horror", "Family"][groupIndex % 6]) \(groupIndex / 6 + 1)"
            for index in 0..<500 {
                id += 1
                let name = "\(movieTitle(groupIndex * 500 + index)) (\(1_970 + index % 55))"
                playlist.entries.append(.init(name: name, group: group, url: "\(host)/movie/mega/mega/\(id).mp4", logo: id.isMultiple(of: 3) ? nil : "\(artworkBase)/poster/\(id % 240).png"))
            }
        }
        for groupIndex in 0..<6 {
            let group = "Series | Collection \(groupIndex + 1)"
            for show in 0..<20 {
                for episode in 0..<35 {
                    id += 1
                    let name = String(format: "%@ S%02dE%02d", movieTitle(show * 7 + groupIndex), episode / 10 + 1, episode % 10 + 1)
                    playlist.entries.append(.init(name: name, group: group, url: "\(host)/series/mega/mega/\(id).mkv", logo: "\(artworkBase)/poster/\((show * 6 + groupIndex) % 240).png"))
                }
            }
        }
        return playlist
    }

    // MARK: - Helpers

    /// The URL without a trailing slash.
    private static func base(of url: URL) -> String {
        url.absoluteString.hasSuffix("/") ? String(url.absoluteString.dropLast()) : url.absoluteString
    }

    private static func live(_ name: String, country: String?, groups: [(String, [String])]) -> DebugSeedPlaylist {
        var playlist = DebugSeedPlaylist(name: name)
        var id = DebugArtwork.stableHash(name) % 1_000 * 1_000
        for (group, channels) in groups {
            for channel in channels {
                id += 1
                playlist.entries.append(.init(
                    name: channel,
                    group: group,
                    url: "\(host)/live/demo/demo/\(id)",
                    tvgID: tvgID(for: channel, country: country ?? countryCode(forGroup: group)),
                    logo: liveLogo(channel, index: id)
                ))
            }
        }
        return playlist
    }

    /// Most channels get a logo in one of the styles real playlists use; every 9th has none (placeholder),
    /// and two have logos that cannot load (a broken data URI, an unreachable loopback URL).
    private static func liveLogo(_ name: String, index: Int) -> String? {
        if index % 9 == 0 {
            return nil
        }
        if index % 41 == 0 {
            return "data:image/png;base64,AAAA"
        }
        if index % 43 == 0 {
            return "http://127.0.0.1:9/logo.png"
        }
        let styles = DebugArtwork.LogoStyle.allCases
        return DebugArtwork.logo(for: name, style: styles[index % styles.count])
    }

    private static func posterLogo(_ title: String, subtitle: String, index: Int) -> String? {
        index % 11 == 0 ? nil : DebugArtwork.poster(title: title, subtitle: subtitle)
    }

    /// iptv-org style ids, e.g. "SkySportF1.it".
    private static func tvgID(for name: String, country: String?) -> String? {
        let base = name.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) && $0.isASCII }
        guard !base.isEmpty else {
            return nil
        }
        return String(base) + (country.map { ".\($0)" } ?? "")
    }

    private static func countryCode(forGroup group: String) -> String? {
        let codes = ["UK": "uk", "France": "fr", "Deutschland": "de", "España": "es", "Japan": "jp", "Arabic": "qa", "Ελλάδα": "gr", "Brasil": "br"]
        return codes.first { group.contains($0.key) }?.value
    }

    private static let adjectives = ["Silent", "Crimson", "Last", "Hidden", "Broken", "Golden", "Distant", "Midnight", "Electric", "Frozen", "Wild", "Paper", "Iron", "Velvet", "Hollow", "Bright"]
    private static let nouns = ["Harbor", "Signal", "Empire", "Orbit", "Garden", "Frontier", "Echo", "Horizon", "Tide", "Circuit", "Lantern", "Summit", "River", "Station", "Archive", "Meridian", "Canyon"]

    /// Invented, deterministic titles: "The Silent Harbor", "Crimson Signal", …
    private static func movieTitle(_ index: Int) -> String {
        let adjective = adjectives[index % adjectives.count]
        let noun = nouns[(index / adjectives.count + index) % nouns.count]
        switch index % 3 {
        case 0:
            return "The \(adjective) \(noun)"
        case 1:
            return "\(adjective) \(noun)"
        default:
            return "\(noun) of the \(adjective) \(nouns[(index * 7) % nouns.count])"
        }
    }
}
#endif
