//
//  StoreHistory.swift
//  Fluxo
//
//  SwiftData records every insert and delete in the stores' persistent history and never removes it: a guide refresh
//  of 260,000 programmes leaves about 35 MB of it, twice a day. Fluxo reads no history (iCloud sync has its own
//  records), and SwiftData only reads what other contexts of the same process saved meanwhile. So once the library is
//  open, the history of earlier launches goes (`pruneEarlierLaunches`, off the main thread: about 150 ms on a Mac
//  after a guide of 260,000 programmes), and after each playlist import and guide refresh what is older than an hour.
//

import Foundation
import os
import SwiftData

enum StoreHistory {

    private static let logger = Logger(subsystem: "dev.watermelon.Fluxo", category: "LibraryStore")

    /// The age `prune(in:olderThan:)` keeps while the app runs.
    static let keptAge: TimeInterval = 3_600

    /// Deletes the history older than `age` in every store of the container.
    static func prune(in container: ModelContainer, olderThan age: TimeInterval) {
        prune(in: container, before: Date.now.addingTimeInterval(-age))
    }

    /// Deletes the history written before this launch opened the library: none of it can be read any more. Off the
    /// main thread, while the app starts; what this launch writes from `openedAt` on is untouched.
    static func pruneEarlierLaunches(in container: ModelContainer, openedAt: Date) {
        Task.detached(priority: .utility) {
            prune(in: container, before: openedAt)
        }
    }

    static func prune(in container: ModelContainer, before cutoff: Date) {
        let context = ModelContext(container)
        do {
            try delete(before: cutoff, in: context)
        } catch {
            logger.error("Could not prune the store history: \(error.localizedDescription, privacy: .public)")
        }
    }

    static func delete(before cutoff: Date, in context: ModelContext) throws {
        try context.deleteHistory(HistoryDescriptor<DefaultHistoryTransaction>(predicate: #Predicate { $0.timestamp < cutoff }))
    }
}
