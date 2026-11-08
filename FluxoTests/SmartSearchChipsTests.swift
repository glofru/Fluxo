//
//  SmartSearchChipsTests.swift
//  FluxoTests
//
//  The chips of Smart Results: the viewer's own words, not the synonyms and translations the plan searches as well.
//

import Foundation
import Testing
@testable import Fluxo

@Suite("Smart Search chips")
struct SmartSearchChipsTests {

    private func plan(_ keywords: [String], time: SmartSearchPlan.Time = .any) -> SmartSearchPlan {
        var plan = SmartSearchPlan()
        plan.keywords = keywords
        plan.time = time
        return plan
    }

    @Test("An English query shows its own words, not the translations searched with them")
    func translationsStayOut() {
        let chips = plan(["sports", "football", "calcio"], time: .tonight).summaryChips(for: "sports tonight")
        #expect(chips == ["Sports", String(localized: "Tonight")])
    }

    @Test("An Italian query shows its own words, not the English ones")
    func englishStaysOutOfItalian() {
        let chips = plan(["sport", "sports", "football"]).summaryChips(for: "sport stasera")
        #expect(chips == ["Sport"])
    }

    @Test("A query said in other words shows the first keyword")
    func firstKeywordStandsForTheRest() {
        let chips = plan(["comedy", "sitcom"]).summaryChips(for: "something to laugh at")
        #expect(chips == ["Comedy"])
    }

    @Test("A Japanese query, written without spaces, shows its own words, not the English ones")
    func japaneseQueryWithoutSpaces() {
        let chips = plan(["soccer", "サッカー", "football"], time: .tonight).summaryChips(for: "今夜のサッカー")
        #expect(chips == ["サッカー", String(localized: "Tonight")])
    }

    @Test("A Chinese query, written without spaces, shows its own words")
    func chineseQueryWithoutSpaces() {
        let chips = plan(["news", "新闻"]).summaryChips(for: "今晚的新闻")
        #expect(chips == ["新闻"])
    }

    @Test("In a script with spaces, a part of a word is not one of the viewer's words")
    func partOfALatinWordIsNotAWord() {
        let chips = plan(["sports", "sport"]).summaryChips(for: "sports")
        #expect(chips == ["Sports"])
    }

    @Test("A competition keeps its capitals")
    func competitionName() {
        let chips = plan(["serie a", "calcio"]).summaryChips(for: "serie a tonight")
        #expect(chips.first == "Serie A")
    }
}
