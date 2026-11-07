//
//  ClassifierCases.swift
//  FeaturedCheck
//
//  Names the adult-content classifier (`MatureContent`) must recognize, and names it must leave alone: category
//  names and titles as IPTV providers write them, in many languages and scripts.
//

import Foundation

enum ClassifierCases {

    /// Category names that are adult content.
    static let adultGroups: [String] = [
        "XXX", "XXX | Adult", "|XXX| Brazzers", "VOD | XXX", "XXX 24/7", "XXXHD", "xxx", "ＸＸＸ", "Adult", "ADULTS",
        "Adults Only", "For Adults", "Adult Movies", "VOD - Adult", "IT | Adulti", "Film per adulti", "Para Adultos",
        "Películas para adultos", "Cine Adulto", "Adulte", "Films pour adultes", "FR | Adultes", "Erwachsene",
        "Filme für Erwachsene", "Erotik", "DE | Erotik", "Erotic Movies", "Érotique", "Eróticos", "Erotica", "18+",
        "+18", "Movies 18+", "Canali (+18)", "18 +", "21+ Only", "Hentai", "Porn", "PORNO HD", "Pornstars",
        "Порно", "Для взрослых", "Эротика", "Ενηλίκων", "Ερωτικά", "للكبار فقط", "قنوات اباحية", "Yetişkin",
        "Yetişkinler +18", "Dla dorosłych", "Erotyka", "Volwassenen", "Erotiek", "Voksne", "Vuxen", "Aikuisille",
        "Felnőtt", "Pro dospělé", "Erotika", "למבוגרים", "アダルト", "ｱﾀﾞﾙﾄ", "成人频道", "成人頻道", "色情", "18禁",
        "성인방송", "19금", "หนังผู้ใหญ่", "Sex", "IT | Sex", "Sexy TV", "Sexo", "SEX MOVIES", "NSFW", "MILF",
        "Luci rosse", "Phim người lớn", "Playboy", "Playboy TV", "Hustler HD", "Penthouse Gold", "Private TV",
        "Brazzers TV Europe", "Dorcel TV", "Babestation", "Redlight HD", "Blue Hustler", "Vivid Red", "X-Rated", "R18",
        "OnlyFans",
    ]

    /// Titles of channels, movies and series that are adult content, with their kind.
    static let adultTitles: [(String, ChannelContentKind)] = [
        ("Hot XXX Night", .movie), ("XXX Gold", .live), ("XXX", .live), ("Brazzers Exxtra", .live), ("Dorcel XXX", .live),
        ("Playboy TV HD", .live), ("Penthouse Passion", .live), ("Hustler TV", .live), ("Private Spice", .live),
        ("Erotic Night Stories", .movie), ("Porn Stars Live", .live), ("Pornhub Premium", .movie), ("Babestation 24", .live),
        ("Redlight", .live), ("Hentai Collection S01E01", .series), ("Late Movie (18+)", .movie), ("+18 Night", .live),
        ("Эротика HD", .live), ("Ερωτικά", .live), ("アダルトチャンネル", .live), ("成人影片 1", .movie), ("Phim người lớn 2024", .movie),
    ]

    /// Names that are not adult content, though they look close to it.
    static let ordinaryNames: [(String, ChannelContentKind?)] = [
        // Places and words that contain the letters of an adult term.
        ("Essex", nil), ("BBC Essex", .live), ("Sussex", nil), ("BBC Sussex", .live), ("Middlesex", nil), ("Wessex FM", .live),
        ("Sextant", nil), ("Sexton", nil), ("Sextet", nil), ("Pornic", nil), ("Scunthorpe United", nil), ("Adulting", .series),
        ("Adultery (2018)", .movie), ("Hornets", nil), ("Pixxx Studio", nil), ("Exxon Valdez", .movie),
        // "Adult" in ordinary names.
        ("Adult Swim", nil), ("IT | Adult Swim 1 HD", .live), ("US | Adult Swim", nil), ("Adult Contemporary", nil),
        ("Adult Hits 80s", .live), ("Adult Standards", nil), ("Adult Education", nil), ("Adult Learning Channel", .live),
        ("Adult Animation", nil), ("Adult Ed", nil), ("Young Adult", nil), ("New Adult Fiction", nil), ("Adultos Mayores", nil),
        ("Adulto joven", nil),
        // Titles with "sex" are not adult content; only categories named just "Sex" are.
        ("Sex Education S01E01", .series), ("Sex and the City", .series), ("Sex/Life", .series),
        ("The Sex Lives of College Girls", .series), ("Sex Education", .movie),
        // XXX as a film title and as a Roman numeral, and in a name.
        ("xXx (2002)", .movie), ("xXx: Return of Xander Cage (2017)", .movie), ("xXx: State of the Union", .movie),
        ("Super Bowl XXX", .movie), ("WrestleMania XXX", .live), ("XXXTentacion Hits", .live),
        // Names of adult networks that are also ordinary titles.
        ("The Hustler (1961)", .movie), ("Hustlers (2019)", .movie), ("The Penthouse: War in Life", .series),
        ("Penthouse (2013)", .movie), ("Private Benjamin", .movie), ("Playboy of the Western World", .movie),
        ("Venus", .movie), ("Spice World", .movie), ("From Dusk Till Dawn", .movie), ("Red Light District", .movie),
        // Numbers next to a plus: timeshift channels, brands, ages.
        ("Canal+ Sport", .live), ("Canal+ 18", .live), ("Sky Sport+", .live), ("Rai 1 +1", .live), ("Channel 4 +1", .live),
        ("E4 +1", .live), ("ITV +24", .live), ("Kanal 18", .live), ("Fox 21", .live), ("Apollo 18 (2011)", .movie),
        ("21 Jump Street", .movie), ("Kids 18 Months+", nil), ("Studio 118+", .live), ("Tele 2+1", .live),
        // Ordinary channels and categories.
        ("Sky Cinema Uno", .live), ("Rai 1 HD", .live), ("NHK総合", .live), ("الجزيرة", .live), ("ΕΡΤ1", .live),
        ("Kids", nil), ("Cartoon Network", .live), ("Boomerang", .live), ("Movies", nil), ("Commedia | Comedy", nil),
        ("UK | Sport", nil), ("4K UHD", nil), ("Documentari", nil), ("Anime", nil), ("Hot Shots! (1991)", .movie),
        ("Hot Kitchen", .live), ("XXL Movies", nil), ("X Factor", .series), ("Malcolm X (1992)", .movie),
        ("Love Actually (2003)", .movie), ("Erin Brockovich (2000)", .movie), ("Vivid Colors of Nature", .movie),
        ("Private Practice", .series), ("Blue Planet II", .series), ("Красная Площадь", nil), ("Детское", nil),
        ("Взрослая жизнь", .series), ("成人式 2024", .movie), ("聖人の物語", .movie),
    ]

    /// Titles and the keys `FeaturedTitle` must give them: the same title in other qualities and languages, and
    /// the films of a franchise.
    static let sameTitle: [(String, String)] = [
        ("Avatar (2009) [ITA]", "Avatar 4K"), ("Avatar (2009)", "AVATAR - MULTI SUB"), ("IT: Inception (2010) FHD", "Inception"),
        ("The Matrix [Extended] (1999)", "Matrix"), ("Sky Sport F1 HD", "IT | Sky Sport F1 FHD"), ("Dune: Part Two (2024)", "Dune Part Two DV HDR"),
    ]
    static let sameFranchise: [(String, String)] = [
        ("Toy Story (1995)", "Toy Story 3 (2010)"), ("Harry Potter and the Philosopher's Stone", "Harry Potter and the Chamber of Secrets"),
        ("Fast & Furious 7", "Fast & Furious 9 [ITA]"), ("Mission: Impossible - Fallout", "Mission Impossible: Dead Reckoning"),
        ("Rocky II", "Rocky III"), ("John Wick: Chapter 2", "John Wick: Chapter 4"), ("Star Wars: Episode IV", "Star Wars: Episode V"),
    ]
    static let sameLiveFamily: [(String, String)] = [
        ("Sky Sport F1", "Sky Sport MotoGP"), ("Rai 1 HD", "Rai 2"), ("France 2", "France 3"), ("BBC One", "BBC Two"), ("Canal+", "Canal+ Sport"),
    ]
    static let differentTitles: [(String, String)] = [
        ("The Dark Knight", "The Dark Tower"), ("Love Actually", "Love Story"), ("The Man Who Knew Too Much", "The Man Who Wasn't There"),
        ("It (2017)", "Us (2019)"), ("Night at the Museum", "Night of the Living Dead"), ("Alien", "Avatar"),
    ]
    static let differentLiveFamilies: [(String, String)] = [
        ("Sky Sport F1", "Sky Cinema Uno"), ("Das Erste", "ZDF"), ("BBC One", "ITV1"),
    ]
}
