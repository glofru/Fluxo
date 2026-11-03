//
//  CandidateRegistry.swift
//  Fluxo
//

import os

/// The numbered candidates of one model request.
///
/// The prompt lists candidates by number, the model answers with numbers, and tools the model calls append
/// new candidates (with the next numbers) while it generates. Numbers that are not in the registry are ignored,
/// so the model can never suggest something that is not in the library.
final class CandidateRegistry<Candidate: Sendable>: Sendable {

    private struct State {
        var candidates: [Candidate] = []
        var toolCalls = 0
    }

    private let state = OSAllocatedUnfairLock(initialState: State())
    /// Tool calls allowed per request: each one adds latency, and two are plenty to fill a gap in the list.
    let maximumToolCalls: Int

    init(_ candidates: [Candidate], maximumToolCalls: Int = 2) {
        self.maximumToolCalls = maximumToolCalls
        state.withLock { $0.candidates = candidates }
    }

    var count: Int {
        state.withLock { $0.candidates.count }
    }

    var all: [Candidate] {
        state.withLock { $0.candidates }
    }

    /// The candidate listed as `number` (1-based).
    func candidate(number: Int) -> Candidate? {
        state.withLock { state in
            state.candidates.indices.contains(number - 1) ? state.candidates[number - 1] : nil
        }
    }

    /// Adds candidates and returns their numbers.
    func append(_ new: [Candidate]) -> [Int] {
        state.withLock { state in
            let first = state.candidates.count + 1
            state.candidates.append(contentsOf: new)
            return Array(first..<(first + new.count))
        }
    }

    /// Counts a tool call; false once the budget is spent.
    func beginToolCall() -> Bool {
        state.withLock { state in
            guard state.toolCalls < maximumToolCalls else {
                return false
            }
            state.toolCalls += 1
            return true
        }
    }
}
