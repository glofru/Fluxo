//
//  ToolStubs.swift
//  Fluxo
//
//  What the sources compiled by Tools/LibraryCheck use from files the tool leaves out (the player and the download
//  transport, which need AVFoundation and the engine).
//

import Foundation

enum TrackPreferences {
    static func displayName(forLanguage code: String) -> String {
        code
    }
}

enum EngineMessage {
    static func formatSentence(_ message: String) -> String? {
        nil
    }

    static func localized(_ message: String) -> String {
        message
    }
}

enum DownloadTransport {
    static func isNetworkError(_ error: any Error) -> Bool {
        false
    }
}
