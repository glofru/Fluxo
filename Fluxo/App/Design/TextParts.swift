//
//  TextParts.swift
//  Fluxo
//
//  Created by Gianluca Lofrumento on 2026-11-03.
//

import Foundation

/// Joins pieces of text (a localized word, a group name, a playlist name, …) with the separators of the
/// app's language.
///
/// The pieces often mix scripts: a localized word next to the provider's Latin-script names. For lines that
/// are shown, every piece goes in a first-strong isolate (U+2068 … U+2069), so that a right-to-left reader
/// sees them in order (in Arabic, "بث مباشر · Sport · Freeview" would otherwise show Freeview before Sport).
/// The Arabic separator carries a letter mark, which makes the whole line right-to-left. Spoken text
/// (VoiceOver) needs no isolates, but uses the punctuation of the language (Japanese and Chinese have 、
/// and 。).
enum TextParts {

    /// "Live TV · Sport · Freeview": the parts of a subtitle line. Nil and empty parts are left out.
    static func line(_ parts: [String?]) -> String {
        let parts = parts.compactMap { $0 }.filter { !$0.isEmpty }
        guard parts.count > 1 else {
            return parts.first ?? ""
        }
        return parts.map(isolated).joined(separator: lineSeparator)
    }

    /// "Evening News, BBC One, 20:00–21:30": the parts of a VoiceOver label, read with a short pause between
    /// them. Nil and empty parts are left out.
    static func spoken(_ parts: [String?]) -> String {
        parts.compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: clauseSeparator)
    }

    /// "Sport, News": a list shown inside a line that has separators of its own (such as the · of AVKit's line of
    /// details), joined with the comma of the language. Each part is isolated, as in `line(_:)`. Nil and empty parts
    /// are left out.
    static func list(_ parts: [String?]) -> String {
        let parts = parts.compactMap { $0 }.filter { !$0.isEmpty }
        guard parts.count > 1 else {
            return parts.first ?? ""
        }
        return parts.map(isolated).joined(separator: clauseSeparator)
    }

    /// "On now: Evening News, 40 min left. Next at 21:00: Weather": spoken parts that are each a sentence
    /// without its final full stop. Nil and empty parts are left out.
    static func sentences(_ parts: [String?]) -> String {
        parts.compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: sentenceSeparator)
    }

    /// The text in a first-strong isolate: it keeps its own direction inside a line of the other direction.
    static func isolated(_ text: String) -> String {
        "\u{2068}\(text)\u{2069}"
    }

    private static var lineSeparator: String {
        String(localized: "TextParts.lineSeparator", defaultValue: " · ", comment: "Separator between the parts of a line of text, such as 'Live TV · Sport · My Playlist'. Keep the spaces around it. Arabic: add U+061C ARABIC LETTER MARK so that the line reads right to left.")
    }

    private static var clauseSeparator: String {
        String(localized: "TextParts.clauseSeparator", defaultValue: ", ", comment: "Separator between the parts of a spoken description (VoiceOver), such as 'Evening News, BBC One, 20:00–21:30', and of a short list shown on screen, such as 'Sport, News'. Use the comma of your language, with the spacing it needs.")
    }

    private static var sentenceSeparator: String {
        String(localized: "TextParts.sentenceSeparator", defaultValue: ". ", comment: "VoiceOver: separator between two spoken sentences, such as 'On now: News. Next at 21:00: Weather'. Use the full stop of your language, with the spacing it needs.")
    }
}
