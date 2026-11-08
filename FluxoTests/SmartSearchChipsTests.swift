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

    @Test("A competition keeps its capitals")
    func competitionName() {
        let chips = plan(["serie a", "calcio"]).summaryChips(for: "serie a tonight")
        #expect(chips.first == "Serie A")
    }
}
