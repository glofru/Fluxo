//
//  SerialTaskQueue.swift
//  Fluxo
//
//  Runs async steps one after the other, in the order they were asked for, each one only once the previous one
//  finished, suspensions included. `CloudKitSyncTransport` runs the life of its `CKSyncEngine` on one (start, stop,
//  replace, Delete iCloud Data), so a new engine is never created while the previous one is still cancelling.
//  Compiled by `Tools/SyncCheck` too.
//

import Foundation

@MainActor
final class SerialTaskQueue {

    private var last: Task<Void, Never>?
    /// Steps asked for and not finished yet.
    private(set) var pendingCount = 0

    init() {}

    /// Runs `step` after the steps asked for before it; await the task's value for its result.
    @discardableResult
    func enqueue<Value: Sendable>(_ step: @escaping @MainActor () async -> Value) -> Task<Value, Never> {
        let previous = last
        pendingCount += 1
        let task = Task { @MainActor in
            await previous?.value
            let value = await step()
            self.pendingCount -= 1
            return value
        }
        last = Task { @MainActor in
            _ = await task.value
        }
        return task
    }

    /// Waits until every step asked for so far, and any asked for meanwhile, finished.
    func settled() async {
        while let current = last {
            await current.value
            if last == current {
                return
            }
        }
    }
}
