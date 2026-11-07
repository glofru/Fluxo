//
//  LicenseText.swift
//  Fluxo
//
//  Lays out a plain-text license for a phone, a Mac window or a TV. License files are written for a fixed-width
//  terminal: each line ends at about 72 or 80 columns. Shown as they are, they wrap twice on a narrow screen and stay
//  a narrow column at large text sizes. `paragraphs` joins the lines a fixed-width editor wrapped, and keeps the line
//  breaks the author made: titles, copyright and address blocks, list items, file lists and separator lines. The words
//  are unchanged.
//

import Foundation

enum LicenseText {

    /// The paragraphs of a plain-text license. Inside a paragraph, a "\n" is a line break of the original text.
    static func paragraphs(_ text: String) -> [String] {
        var lines = text.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\t", with: "        ")
            .components(separatedBy: "\n")
            .map { String($0.reversed().drop { $0 == " " }.reversed()) }
        lines = removingCommentMarkers(lines)
        let width = wrapWidth(lines)

        // The paragraphs: runs of lines between blank lines.
        var blocks: [[String]] = [[]]
        for line in lines {
            if line.trimmingCharacters(in: .whitespaces).isEmpty {
                blocks.append([])
            } else {
                blocks[blocks.count - 1].append(line)
            }
        }
        return blocks.filter { !$0.isEmpty }.map { block in
            // A block whose lines all stop well before the width was laid out by hand (a title, a copyright and
            // address block): every line stays.
            let byHand = block.count > 1 && block.allSatisfy { $0.count <= width - 6 }
            // Nested list items keep their indentation, relative to the paragraph's.
            let margin = block.map(indentation).min() ?? 0
            var paragraph = block[0].trimmingCharacters(in: .whitespaces)
            for (line, next) in zip(block, block.dropFirst()) {
                let trimmed = next.trimmingCharacters(in: .whitespaces)
                let joins = continues(line, with: trimmed) || (!byHand && wasWrapped(line, before: trimmed, width: width))
                if joins {
                    paragraph += " "
                } else {
                    paragraph += "\n"
                    if startsItem(trimmed) {
                        paragraph += String(repeating: " ", count: min(indentation(next) - margin, 8))
                    }
                }
                paragraph += trimmed
            }
            return paragraph
        }
    }

    /// Whether the line break after `line` was made by a fixed-width editor (the next word didn't fit on the line),
    /// rather than by the author.
    private static func wasWrapped(_ line: String, before next: String, width: Int) -> Bool {
        guard width > 0, !isRule(line), !isRule(next), !startsItem(next) else {
            return false
        }
        let nextWord = next.prefix { $0 != " " }.count
        // The editor breaks the line when the next word would pass the width (an estimate: a little tolerance).
        return line.count + 1 + nextWord > width - 2
    }

    /// Whether `next` goes on with the sentence of `line`: it starts with a lowercase word (not an address), or
    /// `line` ends with a word that can't end a sentence ("or", "the"). Then it is not a title, a name or a new item.
    private static func continues(_ line: String, with next: String) -> Bool {
        guard !isRule(line), !startsItem(next), !line.hasSuffix(":") else {
            return false
        }
        if let first = next.first, first.isLetter, first.isLowercase, !next.hasPrefix("http"), !next.hasPrefix("www.") {
            return true
        }
        let lastWord = line.split(separator: " ").last.map(String.init) ?? ""
        return joiningWords.contains(lastWord)
    }

    private static let joiningWords: Set<String> = [
        "a", "an", "and", "any", "as", "at", "be", "by", "for", "from", "in", "is", "of", "on", "or", "that", "the",
        "to", "under", "with",
    ]

    /// The width the text was wrapped at: what most of its long lines reach. (Not the longest line: a URL or a
    /// separator can be longer than the rest.)
    private static func wrapWidth(_ lines: [String]) -> Int {
        let lengths = lines.map(\.count).filter { $0 > 0 }
        guard let longest = lengths.max() else {
            return 0
        }
        let long = lengths.filter { $0 * 2 >= longest }.sorted()
        return long[long.count * 3 / 4]
    }

    private static func indentation(_ line: String) -> Int {
        line.prefix { $0 == " " }.count
    }

    /// A separator line ("-----", "=====").
    private static func isRule(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        return trimmed.count >= 3 && trimmed.allSatisfy { "-=_*#~".contains($0) }
    }

    /// The start of a list item, a section number, a file name or an address: "* ", "- ", "1. ", "1.2. ", "(a) ",
    /// "a) ", "./", "Files:", "Copyright", "https://".
    private static func startsItem(_ line: String) -> Bool {
        if line.hasPrefix("* ") || line.hasPrefix("- ") || line.hasPrefix("• ") || line.hasPrefix("./")
            || line.hasPrefix("Files:") || line.hasPrefix("Copyright") || line.hasPrefix("(c)") || line.hasPrefix("(C)")
            || line.hasPrefix("http://") || line.hasPrefix("https://") || line.hasPrefix("www.") {
            return true
        }
        let token = line.prefix { $0 != " " }
        guard token.count <= 8, token.count < line.count else {
            return false
        }
        // "1.", "1.2.", "12)", "(a)", "a)", "(iv)"
        let core = token.trimmingCharacters(in: CharacterSet(charactersIn: "()."))
        let closes = token.hasSuffix(".") || token.hasSuffix(")")
        if closes, !core.isEmpty, core.allSatisfy({ $0.isNumber || $0 == "." }) {
            return true
        }
        if token.hasSuffix(")"), core.count <= 4, core.allSatisfy({ $0.isLetter && $0.isLowercase }) {
            return true
        }
        return false
    }

    /// Texts copied from a source file have each line commented ("// Copyright …"): the markers go.
    private static func removingCommentMarkers(_ lines: [String]) -> [String] {
        let text = lines.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        guard !text.isEmpty, text.allSatisfy({ $0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }) else {
            return lines
        }
        return lines.map { line in
            var trimmed = Substring(line.trimmingCharacters(in: .whitespaces))
            if trimmed.hasPrefix("//") {
                trimmed = trimmed.dropFirst(2)
                if trimmed.hasPrefix(" ") {
                    trimmed = trimmed.dropFirst()
                }
            }
            return String(trimmed)
        }
    }
}
