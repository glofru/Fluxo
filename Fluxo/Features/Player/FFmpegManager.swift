//
//  FFmpegManager.swift
//  Fluxo
//
//  Created by Gianluca Lofrumento on 2025-07-06.
//

import Foundation

class FFmpegManager {
    private(set) var isProcessing = false
    private var currentSession: FFmpegSession?

    func executeCommand(_ command: String, completion: @escaping (Bool, String?) -> Void) {
        guard !isProcessing else {
            completion(false, "Another operation is already running")
            return
        }

        isProcessing = true

        let completeCallback: FFmpegSessionCompleteCallback = { [weak self] session in
            DispatchQueue.main.async {
                self?.isProcessing = false
                self?.currentSession = nil

                let returnCode = session?.getReturnCode()
                let success = returnCode?.isValueSuccess() ?? false
                let errorMessage = success ? nil : "FFmpeg execution failed with return code: \(returnCode?.getValue() ?? -1)"

                completion(success, errorMessage)
            }
        }

        currentSession = FFmpegKit.executeAsync(
            command,
            withCompleteCallback: completeCallback,
        )
    }

    // Stop the current FFmpeg operation
    func stopExecution() {
        guard let session = currentSession, isProcessing else {
            print("No active session to cancel")
            return
        }

        print("Cancelling FFmpeg session...")
        session.cancel()

        self.isProcessing = false
        self.currentSession = nil
    }
}
