import Foundation

/// Checks that a Tidy pass kept the speaker's wording. The model may change
/// capitalization and punctuation, drop filler sounds and stutters, and
/// respell a name from the document; any other change means it reworded
/// something, and the output is thrown away.
enum TidyCheck {
    struct Word: Equatable {
        /// The word as written, minus surrounding punctuation.
        let text: String
        /// Lowercased, apostrophes removed: "Let's" and "lets" compare equal.
        let key: String
    }

    /// Words split on whitespace and dashes, so "double check" and
    /// "double-check" compare equal.
    static func words(_ text: String) -> [Word] {
        let separators = CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "-\u{2013}\u{2014}/"))
        return text.components(separatedBy: separators).compactMap { raw in
            let trimmed = raw.trimmingCharacters(in: .punctuationCharacters.union(.symbols))
            let key = trimmed.lowercased().replacingOccurrences(of: "'", with: "").replacingOccurrences(of: "\u{2019}", with: "")
            return key.isEmpty ? nil : Word(text: trimmed, key: key)
        }
    }

    /// Stutters this long or shorter may be dropped: "the the", "I think I think".
    static let maxRepeatLength = 3

    static func isFaithful(input: String, output: String, terms: [String] = []) -> Bool {
        let source = words(input)
        let result = words(output)
        guard !result.isEmpty else { return false }
        let termSet = Set(terms)

        var i = 0
        for word in result {
            while true {
                guard i < source.count else { return false }
                if source[i].key == word.key {
                    i += 1
                    break
                }
                if let joined = joinedRespelling(source, at: i, as: word, terms: termSet) {
                    i += joined
                    break
                }
                if isRespelling(source[i], as: word, terms: termSet) {
                    i += 1
                    break
                }
                guard let skip = droppable(source, at: i) else { return false }
                i += skip
            }
        }
        // Whatever the model left off the end must be droppable too.
        while i < source.count {
            guard let skip = droppable(source, at: i) else { return false }
            i += skip
        }
        return true
    }

    /// How many words at `index` may be dropped: a filler sound, or a run
    /// that repeats the words just before it. Nil when the word must stay.
    static func droppable(_ words: [Word], at index: Int) -> Int? {
        if FillerRemover.fillers.contains(words[index].key) { return 1 }
        for length in 1...maxRepeatLength {
            guard index - length >= 0, index + length <= words.count else { continue }
            if words[(index - length)..<index].map(\.key) == words[index..<(index + length)].map(\.key) {
                return length
            }
        }
        return nil
    }

    /// A name from the document spelled the document's way: "Katie" → "Katy".
    /// Only close spellings count, so the model can't swap in a different word.
    static func isRespelling(_ spoken: Word, as written: Word, terms: Set<String>) -> Bool {
        guard terms.contains(written.text), spoken.key.count >= 3 else { return false }
        let allowed = written.key.count >= 4 ? max(2, written.key.count / 3) : 1
        return editDistance(spoken.key, written.key) <= allowed
    }

    /// Two spoken words written as one name: "birch tree" → "Birchtree".
    static func joinedRespelling(_ words: [Word], at index: Int, as written: Word, terms: Set<String>) -> Int? {
        guard terms.contains(written.text), index + 1 < words.count else { return nil }
        return words[index].key + words[index + 1].key == written.key ? 2 : nil
    }

    static func editDistance(_ a: String, _ b: String) -> Int {
        let a = Array(a), b = Array(b)
        guard !a.isEmpty else { return b.count }
        guard !b.isEmpty else { return a.count }
        var previous = Array(0...b.count)
        for (i, ca) in a.enumerated() {
            var current = [i + 1]
            for (j, cb) in b.enumerated() {
                current.append(min(previous[j + 1] + 1, current[j] + 1, previous[j] + (ca == cb ? 0 : 1)))
            }
            previous = current
        }
        return previous[b.count]
    }
}

extension FillerRemover {
    /// Drops filler sounds and stutters from text that already has
    /// punctuation, keeping it tidy: "Um, so I think" becomes "So I think",
    /// and "I think, uh, the" becomes "I think the".
    static func cleanPunctuated(_ text: String) -> String {
        var tokens = tokenize(text)
        var kept: [(leading: String, token: String)] = []
        var index = 0
        while index < tokens.count {
            let (leading, token) = tokens[index]
            let bare = token.trimmingCharacters(in: .punctuationCharacters).lowercased()
            let isFiller = fillers.contains(bare)
            let isStutter = !bare.isEmpty
                && (kept.last.map { $0.token.trimmingCharacters(in: .punctuationCharacters).lowercased() == bare } ?? false)
                && (kept.last?.token.last?.isLetter ?? false)
            guard isFiller || isStutter else {
                kept.append((leading, token))
                index += 1
                continue
            }

            let trailing = String(token.reversed().prefix { !$0.isLetter }.reversed())
            let sentenceEnd = trailing.first { ".?!".contains($0) }
            if let sentenceEnd, var last = kept.popLast() {
                if last.token.last == "," { last.token.removeLast() }
                if last.token.last?.isLetter == true || last.token.last?.isNumber == true {
                    last.token.append(sentenceEnd)
                }
                kept.append(last)
            } else if isFiller, trailing.hasPrefix(","), var last = kept.popLast() {
                // "I think, um, the" → "I think the"
                if last.token.last == "," { last.token.removeLast() }
                kept.append(last)
            }

            if index + 1 < tokens.count {
                // The next word takes this one's place, including a
                // paragraph break and a sentence-starting capital.
                if !tokens[index + 1].leading.contains("\n") {
                    tokens[index + 1].leading = leading
                }
                if isFiller, token.first?.isUppercase == true {
                    tokens[index + 1].token = capitalizedFirst(tokens[index + 1].token)
                }
            }
            index += 1
        }
        guard !kept.isEmpty else { return text }
        var result = kept.map { $0.leading + $0.token }.joined()
        while result.first?.isWhitespace == true { result.removeFirst() }
        return result
    }

    /// Words with the whitespace before each, so paragraph breaks survive.
    private static func tokenize(_ text: String) -> [(leading: String, token: String)] {
        var tokens: [(leading: String, token: String)] = []
        var leading = ""
        var token = ""
        for character in text {
            if character.isWhitespace {
                if !token.isEmpty {
                    tokens.append((leading, token))
                    leading = ""
                    token = ""
                }
                leading.append(character)
            } else {
                token.append(character)
            }
        }
        if !token.isEmpty { tokens.append((leading, token)) }
        return tokens
    }

    private static func capitalizedFirst(_ token: String) -> String {
        guard let index = token.firstIndex(where: { $0.isLetter }) else { return token }
        return token.replacingCharacters(in: index...index, with: token[index].uppercased())
    }
}

/// The on-device model ends most Tidy passes with a question mark, even
/// after a plain statement ("I think we're in good shape?"). A "?" the
/// speech engine didn't write survives only when its sentence reads like a
/// question: a clause opens with a question word or auxiliary ("what",
/// "did you", "but can we"), or it ends with a tag like "right".
enum QuestionMarkGuard {
    static let openers: Set<String> = [
        "who", "whom", "whose", "what", "when", "where", "why", "how", "which",
        "is", "are", "am", "was", "were", "do", "does", "did", "can", "could",
        "will", "would", "should", "shall", "may", "might", "must", "have", "has", "had",
        "isnt", "arent", "wasnt", "werent", "dont", "doesnt", "didnt", "cant", "couldnt",
        "wont", "wouldnt", "shouldnt", "havent", "hasnt", "hadnt", "any", "anyone", "anybody",
        "whats", "whos", "wheres", "hows", "whys",
    ]

    /// Words after which a new clause starts, so "but did you" counts.
    static let clauseJoiners: Set<String> = [
        "and", "but", "so", "or", "then", "also", "well", "okay", "ok", "yeah", "now", "oh",
    ]

    static let tags: Set<String> = ["right", "correct", "huh", "eh", "ok", "okay", "yeah", "no"]

    static func apply(_ output: String, input: String) -> String {
        let spokenQuestions = Set(input.split(separator: "?", omittingEmptySubsequences: false)
            .dropLast()
            .compactMap { TidyCheck.words(String($0)).last?.key })

        var result = ""
        var sentence = ""
        for character in output {
            if character == "?" {
                let words = TidyCheck.words(sentence)
                let keep = words.last.map { spokenQuestions.contains($0.key) } ?? true
                    || readsAsQuestion(sentence)
                result += sentence + (keep ? "?" : ".")
                sentence = ""
            } else if ".!\n".contains(character) {
                result += sentence + String(character)
                sentence = ""
            } else {
                sentence.append(character)
            }
        }
        return result + sentence
    }

    static func readsAsQuestion(_ sentence: String) -> Bool {
        let raw = sentence.split(whereSeparator: \.isWhitespace)
        var clauseStart = true
        for (index, token) in raw.enumerated() {
            guard let word = TidyCheck.words(String(token)).first?.key else { continue }
            if clauseStart, openers.contains(word) { return true }
            if index == raw.count - 1, index > 0, tags.contains(word),
               raw[index - 1].last == "," { return true }
            clauseStart = token.last.map { ",;:".contains($0) } ?? false || clauseJoiners.contains(word)
        }
        return false
    }
}
