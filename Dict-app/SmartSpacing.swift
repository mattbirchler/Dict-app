import Foundation

/// Decides whether a dictation needs a separating space in front of it, from
/// the character just before the cursor. Pure so it's testable without a
/// focused text field.
enum SmartSpacing {
    /// Characters after which new text attaches directly: opening brackets
    /// and quotes, and path/handle prefixes.
    private static let attachingCharacters: Set<Character> = [
        "(", "[", "{", "<", "\"", "'", "\u{201C}", "\u{2018}", "/", "@", "#", "-", "\u{2014}",
    ]

    /// Characters that attach to whatever comes before them, so a dictation
    /// starting with one never gets a leading space.
    private static let closingCharacters: Set<Character> = [
        ".", ",", ";", ":", "!", "?", ")", "]", "}", "\u{201D}", "\u{2019}", "%",
    ]

    /// Characters with no width that editors scatter through their text.
    /// Obsidian (CodeMirror) puts a zero-width space on empty lines, and
    /// Swift doesn't count it as whitespace, so it looked like a word.
    private static let invisibleCharacters: Set<Character> = [
        "\u{200B}", "\u{200C}", "\u{200D}", "\u{2060}", "\u{FEFF}", "\u{FFFC}",
    ]

    /// The last character of `text` that isn't invisible, or nil when
    /// there is none (the cursor is effectively at the start of the field).
    static func lastVisibleCharacter(in text: String) -> Character? {
        text.last { !invisibleCharacters.contains($0) }
    }

    /// - Parameter preceding: the character before the cursor, or nil when
    ///   the cursor is at the start of the field or the app doesn't expose it.
    static func needsLeadingSpace(preceding: Character?, text: String) -> Bool {
        guard let preceding, let first = text.first else { return false }
        if preceding.isWhitespace || attachingCharacters.contains(preceding) { return false }
        if first.isWhitespace || closingCharacters.contains(first) { return false }
        return true
    }
}
