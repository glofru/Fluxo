//
//  AppInstanceLock.swift
//  Fluxo
//
//  Tells whether this process is the only running instance of the app that uses this container.
//

import Darwin
import Foundation

enum AppInstanceLock {
    /// True when this process holds the instance lock. The lock is taken on first use and held
    /// until the process exits (the kernel releases it, also after a crash).
    ///
    /// Startup cleanup (leftover HLS segments, interrupted recordings) only runs when it is true:
    /// another instance sharing the same container (e.g. a second copy launched from Xcode) may
    /// still be writing those files.
    static let isPrimaryInstance: Bool = {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("fluxo-instance.lock")
        let descriptor = open(url.path, O_CREAT | O_RDWR | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else {
            // Without a lock file the cleanup cannot be proven safe.
            return false
        }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            close(descriptor)
            return false
        }
        // The descriptor stays open on purpose: closing it would release the lock.
        return true
    }()
}
