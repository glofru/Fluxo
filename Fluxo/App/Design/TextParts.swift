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
///
/// A line that wraps never starts with a separator: the space before each one (the app's ·, and those inside the
/// provider's names, as in "Serie TV | Drama") is a no-break space, so the separator stays at the end of the line
/// before (`keepingSeparatorsAttached(_:)`).
enum TextParts {

    /// "Live TV · Sport · Freeview": the parts of a subtitle line. Nil and empty parts are left out.
    static func line(_ parts: [String?]) -> String {
        let parts = parts.compactMap { $0 }.filter { !$0.isEmpty }
        guard parts.count > 1 else {
            return parts.first.map(keepingSeparatorsAttached) ?? ""
        }
        return parts.map { isolated(keepingSeparatorsAttached($0)) }.joined(separator: attachedToPrevious(lineSeparator))
    }

    /// The pieces of `line(_:)` shown one by one (`PartsLine` at the accessibility text sizes): each part with the
    /// separator at its end ("2021 ·", "2 seasons ·", "10 episodes"), the last one without. Each part is isolated as in
    /// `line(_:)`, and the space before the separator is a no-break space. The no-break spaces inside a part (from
    /// `keepingWordsTogether(_:)`) become spaces: the piece moves to the next line whole, and one wider than the whole
    /// line then wraps between its words rather than inside one. Nil and empty parts are left out.
    static func flowPieces(_ parts: [String?]) -> [String] {
        let parts = parts.compactMap { $0 }.filter { !$0.isEmpty }
        guard parts.count > 1 else {
            return parts.map(keepingSeparatorsAttached)
        }
        var separator = attachedToPrevious(lineSeparator)
        while separator.last?.isWhitespace == true {
            separator.removeLast()
        }
        return parts.enumerated().map { index, part in
            let piece = isolated(keepingSeparatorsAttached(part.replacing("\u{00A0}", with: " ")))
            return index < parts.count - 1 ? piece + separator : piece
        }
    }

    /// `text` with the space before each separator between words (" | ", " · ", " - ", " – ", " / "…) made a
    /// no-break space, so that text wrapping there leaves the separator at the end of a line ("Serie TV |" then
    /// "Drama") instead of starting the next one with it ("| Drama"). Cheap when there is nothing to change.
    static func keepingSeparatorsAttached(_ text: String) -> String {
        guard text.unicodeScalars.contains(where: { separatorScalars.contains($0) }) else {
            return text
        }
        var scalars = Array(text.unicodeScalars)
        var changed = false
        for index in scalars.indices.dropFirst().dropLast() where separatorScalars.contains(scalars[index]) {
            if scalars[index - 1] == " " && scalars[index + 1] == " " {
                scalars[index - 1] = noBreakSpace
                changed = true
            }
        }
        guard changed else {
            return text
        }
        var result = String.UnicodeScalarView()
        result.append(contentsOf: scalars)
        return String(result)
    }

    /// `text` with its spaces made no-break spaces, so that a short phrase ("10 episodes", "2 seasons") is never
    /// split over two lines.
    static func keepingWordsTogether(_ text: String) -> String {
        text.replacing(" ", with: "\u{00A0}")
    }

    /// Separators that providers and the app put between words, with a space on both sides.
    private static let separatorScalars: Set<Unicode.Scalar> = [
        "|", "\u{00A6}", "\u{00B7}", "\u{2022}", "\u{2027}", "\u{30FB}", "-", "\u{2013}", "\u{2014}", "/", "\\", ">", "\u{00BB}", "\u{203A}", "\u{2192}",
    ]

    private static let noBreakSpace: Unicode.Scalar = "\u{00A0}"

    /// A separator whose leading space is a no-break space (" · " becomes "\u{00A0}· "), so that it ends the line
    /// before when the text wraps there.
    private static func attachedToPrevious(_ separator: String) -> String {
        guard separator.unicodeScalars.first == " " else {
            return separator
        }
        var scalars = separator.unicodeScalars
        scalars.replaceSubrange(scalars.startIndex...scalars.startIndex, with: [noBreakSpace])
        return String(scalars)
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

    /// A translated text made a file name the user sees (in the Files save panel, the share sheet): without the "/"
    /// and ":" a path component cannot hold (a "/" makes a folder; Finder shows a ":" as "/"), the characters that
    /// aren't printed, and the spaces and dots at its ends (a leading dot hides the file). `fallback` when nothing is
    /// left.
    static func fileName(_ text: String, fallback: String) -> String {
        let cleaned = String(String.UnicodeScalarView(text.unicodeScalars.map { scalar in
            scalar == "/" || scalar == ":" || scalar.properties.generalCategory == .control ? "-" : scalar
        }))
        let trimmed = cleaned.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: ".")))
        return trimmed.isEmpty ? fallback : trimmed
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
