//
//  EpisodeParserCases.swift
//  FluxoTests
//
//  The names `EpisodeParser` is checked against: real-world styles of IPTV providers, scene releases and localized
//  playlists, plus movies and live channels that must not be read as episodes. Shared by the unit tests
//  (EpisodeParserTests) and Tools/SeriesCheck, which compiles this file with the app's sources.
//

import Foundation

struct ParserCase {
    let name: String
    var group: String = ""
    /// The entry is already known to be a series (URL or category): weak markers count.
    var weak: Bool = true
    /// nil: not an episode.
    let expected: Expected?

    struct Expected {
        let title: String
        let season: Int?
        let episode: Int
        var episodeTitle: String?
        var year: Int?
        var strong: Bool = true
    }
}

private func ep(_ title: String, _ season: Int?, _ episode: Int, _ episodeTitle: String? = nil, year: Int? = nil, strong: Bool = true) -> ParserCase.Expected {
    ParserCase.Expected(title: title, season: season, episode: episode, episodeTitle: episodeTitle, year: year, strong: strong)
}

let parserCases: [ParserCase] = [
    // SxxEyy and its spellings.
    ParserCase(name: "Breaking Bad S01E01", expected: ep("Breaking Bad", 1, 1)),
    ParserCase(name: "Breaking Bad S01 E01", expected: ep("Breaking Bad", 1, 1)),
    ParserCase(name: "Breaking Bad s1e1", expected: ep("Breaking Bad", 1, 1)),
    ParserCase(name: "Breaking Bad S1 E10", expected: ep("Breaking Bad", 1, 10)),
    ParserCase(name: "Breaking Bad S01.E02", expected: ep("Breaking Bad", 1, 2)),
    ParserCase(name: "Breaking Bad S01-E03", expected: ep("Breaking Bad", 1, 3)),
    ParserCase(name: "Breaking Bad S01_E04", expected: ep("Breaking Bad", 1, 4)),
    ParserCase(name: "Breaking Bad S01 - E05", expected: ep("Breaking Bad", 1, 5)),
    ParserCase(name: "Breaking Bad S01xE06", expected: ep("Breaking Bad", 1, 6)),
    ParserCase(name: "Breaking Bad S01 Ep. 07", expected: ep("Breaking Bad", 1, 7)),
    ParserCase(name: "Breaking Bad S01 Ep07", expected: ep("Breaking Bad", 1, 7)),
    ParserCase(name: "Breaking Bad S02 Episode 3", expected: ep("Breaking Bad", 2, 3)),
    ParserCase(name: "Breaking Bad - S05E14 - Ozymandias", expected: ep("Breaking Bad", 5, 14, "Ozymandias")),
    ParserCase(name: "Breaking Bad S05E16: Felina", expected: ep("Breaking Bad", 5, 16, "Felina")),
    ParserCase(name: "Friends S01E16E17", expected: ep("Friends", 1, 16)),
    ParserCase(name: "Friends S01E16-E17 The One with Two Parts", expected: ep("Friends", 1, 16, "The One with Two Parts")),
    ParserCase(name: "The Simpsons S35E01 (2023)", expected: ep("The Simpsons", 35, 1)),
    ParserCase(name: "Doctor Who S00E01 Christmas Special", expected: ep("Doctor Who", 0, 1, "Christmas Special")),
    ParserCase(name: "Bluey S01 E01 (example)", expected: ep("Bluey", 1, 1, "example")),
    ParserCase(name: "Bluey S01 E02 (The Magic Xylophone)", expected: ep("Bluey", 1, 2, "The Magic Xylophone")),
    // NxNN.
    ParserCase(name: "Stranger Things 4x05 Chapter Five", expected: ep("Stranger Things", 4, 5, "Chapter Five")),
    ParserCase(name: "Lupin 1x03", expected: ep("Lupin", 1, 3)),
    ParserCase(name: "Lupin - 01x04 - Chapitre 4", expected: ep("Lupin", 1, 4, "Chapitre 4")),
    ParserCase(name: "Lupin 2×01", expected: ep("Lupin", 2, 1)),
    // Words, in several languages.
    ParserCase(name: "Doctor Who Season 1 Episode 1", expected: ep("Doctor Who", 1, 1)),
    ParserCase(name: "Doctor Who: Season 2, Episode 4 - The Girl in the Fireplace", expected: ep("Doctor Who", 2, 4, "The Girl in the Fireplace")),
    ParserCase(name: "Doctor Who Season 3 Ep 5", expected: ep("Doctor Who", 3, 5)),
    ParserCase(name: "Doctor Who Season 3 E06", expected: ep("Doctor Who", 3, 6)),
    ParserCase(name: "Sherlock Series 2 Episode 3", expected: ep("Sherlock", 2, 3)),
    ParserCase(name: "Harbor Lights 2 Season 1 Episode 4", expected: ep("Harbor Lights 2", 1, 4)),
    ParserCase(name: "Harbor Lights 2 1x04", expected: ep("Harbor Lights 2", 1, 4)),
    ParserCase(name: "Harbor Lights 2 Stagione 1 Episodio 4", expected: ep("Harbor Lights 2", 1, 4)),
    ParserCase(name: "Il commissario Montalbano Stagione 1 Episodio 2", expected: ep("Il commissario Montalbano", 1, 2)),
    ParserCase(name: "Mare fuori - Stagione 3 - Episodio 5", expected: ep("Mare fuori", 3, 5)),
    ParserCase(name: "Dark Staffel 1 Folge 2", expected: ep("Dark", 1, 2)),
    ParserCase(name: "Babylon Berlin 2. Staffel, Folge 3", expected: ep("Babylon Berlin", 2, 3)),
    ParserCase(name: "La Casa de Papel Temporada 1 Episodio 3", expected: ep("La Casa de Papel", 1, 3)),
    ParserCase(name: "La Casa de Papel Temporada 2 Capítulo 4", expected: ep("La Casa de Papel", 2, 4)),
    ParserCase(name: "La Casa de Papel T01E05", expected: ep("La Casa de Papel", 1, 5)),
    ParserCase(name: "Élite T3 E2", expected: ep("Élite", 3, 2)),
    ParserCase(name: "Les Revenants Saison 1 Épisode 1", expected: ep("Les Revenants", 1, 1)),
    ParserCase(name: "Dix pour cent - Saison 2 - Épisode 6", expected: ep("Dix pour cent", 2, 6)),
    ParserCase(name: "De Luizenmoeder Seizoen 1 Aflevering 2", expected: ep("De Luizenmoeder", 1, 2)),
    ParserCase(name: "Ojciec Mateusz Sezon 1 Odcinek 5", expected: ep("Ojciec Mateusz", 1, 5)),
    ParserCase(name: "Kuruluş Osman Sezon 1 Bölüm 5", expected: ep("Kuruluş Osman", 1, 5)),
    ParserCase(name: "Шерлок 1 сезон 2 серия", expected: ep("Шерлок", 1, 2)),
    ParserCase(name: "Шерлок Сезон 2 Серия 3", expected: ep("Шерлок", 2, 3)),
    ParserCase(name: "Bron/Broen Säsong 1 Avsnitt 2", expected: ep("Bron/Broen", 1, 2)),
    // Episode only (weak): accepted for series entries, never for movies.
    ParserCase(name: "Naruto Shippuden Episode 245", expected: ep("Naruto Shippuden", nil, 245, strong: false)),
    ParserCase(name: "One Piece Ep. 1071", expected: ep("One Piece", nil, 1071, strong: false)),
    ParserCase(name: "One Piece EP 1072", expected: ep("One Piece", nil, 1072, strong: false)),
    ParserCase(name: "One Piece E1073", expected: ep("One Piece", nil, 1073, strong: false)),
    ParserCase(name: "Tatort Folge 1234", expected: ep("Tatort", nil, 1234, strong: false)),
    ParserCase(name: "Un posto al sole Puntata 6000", expected: ep("Un posto al sole", nil, 6000, strong: false)),
    ParserCase(name: "Un posto al sole Episodio 12", expected: ep("Un posto al sole", nil, 12, strong: false)),
    ParserCase(name: "Kurtlar Vadisi 12. Bölüm", expected: ep("Kurtlar Vadisi", nil, 12, strong: false)),
    ParserCase(name: "Star Wars: Episode 4 - A New Hope", weak: false, expected: nil),
    // Prefixes, tags and years.
    ParserCase(name: "IT: Gomorra S01E01", expected: ep("Gomorra", 1, 1)),
    ParserCase(name: "IT: Gomorra - La serie S02 E03 [MULTI] FHD", expected: ep("Gomorra - La serie", 2, 3)),
    ParserCase(name: "|EN| Breaking Bad S01 E01", expected: ep("Breaking Bad", 1, 1)),
    ParserCase(name: "[4K] The Mandalorian S02E01", expected: ep("The Mandalorian", 2, 1)),
    ParserCase(name: "EN - The Crown S04E01 4K", expected: ep("The Crown", 4, 1)),
    ParserCase(name: "4K-IT: The Bear S01E02 HDR", expected: ep("The Bear", 1, 2)),
    ParserCase(name: "NF: Wednesday S01E01 MULTI-SUB", expected: ep("Wednesday", 1, 1)),
    ParserCase(name: "The Last of Us S01E01 FHD [SUB ITA]", expected: ep("The Last of Us", 1, 1)),
    ParserCase(name: "The Last of Us S01E02 HD ITA", expected: ep("The Last of Us", 1, 2)),
    ParserCase(name: "Doctor Who (2005) S01E01 Rose", expected: ep("Doctor Who", 1, 1, "Rose", year: 2005)),
    ParserCase(name: "Doctor Who (1963) S01E01", expected: ep("Doctor Who", 1, 1, year: 1963)),
    ParserCase(name: "The Office (US) S02E01", expected: ep("The Office (US)", 2, 1)),
    ParserCase(name: "1923 S01E01", expected: ep("1923", 1, 1)),
    ParserCase(name: "Yellowstone 1923 S01E02", expected: ep("Yellowstone 1923", 1, 2)),
    ParserCase(name: "9-1-1 S05E01", expected: ep("9-1-1", 5, 1)),
    ParserCase(name: "24 S08E24", expected: ep("24", 8, 24)),
    ParserCase(name: "The 4400 S01E01", expected: ep("The 4400", 1, 1)),
    ParserCase(name: "CSI: Miami S01E01", expected: ep("CSI: Miami", 1, 1)),
    ParserCase(name: "NCIS: Los Angeles S03E04", expected: ep("NCIS: Los Angeles", 3, 4)),
    ParserCase(name: "S.W.A.T. S01E01", expected: ep("S.W.A.T", 1, 1)),
    ParserCase(name: "Love, Death & Robots S01E01", expected: ep("Love, Death & Robots", 1, 1)),
    // Split episodes: both halves are episode 1.
    ParserCase(name: "SpongeBob SquarePants S01E01a Help Wanted", expected: ep("SpongeBob SquarePants", 1, 1, "Help Wanted")),
    ParserCase(name: "SpongeBob SquarePants S01E01b Reef Blower", expected: ep("SpongeBob SquarePants", 1, 1, "Reef Blower")),
    // A year after the marker is the episode's (when it aired), not the series': it is dropped and does not
    // become part of the series key. Only a year before the marker tells two series apart ("Doctor Who (2005)").
    ParserCase(name: "The Boys S04E01 (2024)", expected: ep("The Boys", 4, 1)),
    ParserCase(name: "The Boys (2019) S04E02", expected: ep("The Boys", 4, 2, year: 2019)),
    ParserCase(name: "Mr. Robot S01E01 eps1.0_hellofriend.mov", expected: ep("Mr. Robot", 1, 1, "eps1.0_hellofriend.mov")),
    // Scene releases.
    ParserCase(name: "Breaking.Bad.S01E01.720p.HDTV.x264", expected: ep("Breaking Bad", 1, 1)),
    ParserCase(name: "The_Expanse_S03E05_1080p_WEB-DL", expected: ep("The Expanse", 3, 5)),
    // The category names the series.
    ParserCase(name: "S01 E01 - Pilot", group: "Series | Breaking Bad", expected: ep("Breaking Bad", 1, 1, "Pilot")),
    ParserCase(name: "Episode 3", group: "Anime: Naruto", expected: ep("Naruto", nil, 3, strong: false)),
    ParserCase(name: "S01E01", group: "Series", expected: nil),
    ParserCase(name: "S01E01", group: "", expected: nil),
    // Not episodes.
    ParserCase(name: "Rocky 4", expected: nil),
    ParserCase(name: "Apollo 13", expected: nil),
    ParserCase(name: "Se7en", expected: nil),
    ParserCase(name: "WALL-E", expected: nil),
    ParserCase(name: "Fast X (2023)", expected: nil),
    ParserCase(name: "1917", expected: nil),
    ParserCase(name: "2001: A Space Odyssey", expected: nil),
    ParserCase(name: "Ocean's 11 1080p", expected: nil),
    ParserCase(name: "Movie 1920x1080", expected: nil),
    ParserCase(name: "Trainspotting T2", expected: nil),
    ParserCase(name: "Mission: Impossible 7 (2023) 4K", expected: nil),
    ParserCase(name: "The Expanse Season 3", expected: nil),
    ParserCase(name: "The Expanse S03", expected: nil),
    ParserCase(name: "Sky Sport F1 HD", expected: nil),
    ParserCase(name: "E4 HD", weak: false, expected: nil),
    ParserCase(name: "Star Wars Episode 4", weak: false, expected: nil),
    ParserCase(name: "Captain America", expected: nil),
    ParserCase(name: "Rai 1 HD", expected: nil),
]
