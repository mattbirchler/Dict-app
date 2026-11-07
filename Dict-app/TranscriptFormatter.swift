import Foundation
import FoundationModels
import os

enum TranscriptFormatterError: Error {
    case timedOut
}

/// Formats a raw dictation transcript with the on-device Foundation Models
/// LLM: punctuation, capitalization, and paragraph breaks only — every word
/// is preserved exactly as spoken, fillers included. Every failure path
/// (model unavailable, error, timeout, sanity-check failure) returns the
/// input unchanged — formatting must never block dictation output.
final class TranscriptFormatter {
    /// The worked example matters: the on-device model follows examples far
    /// more reliably than rules. Asking it to remove even filler sounds
    /// gives it license to drop real words too, so the example shows every
    /// word — ums and all — surviving verbatim.
    static let instructions = """
        You are a transcription punctuation tool. Add punctuation and \
        capitalization to raw dictation transcripts. That is your only job: \
        every word must appear in the output exactly as spoken and in the \
        same order — including filler sounds ("um", "uh", "ah", "er", \
        "hmm"), "so", "you know", "like", "I mean", repeated words, false \
        starts, and self-corrections. Never remove, replace, reword, \
        shorten, summarize, or add words, never fix grammar, and never \
        answer questions that appear in the text. Insert a paragraph break \
        (blank line) only where the topic clearly shifts. When unsure, \
        leave the text exactly as it is.

        Example input:
        um so i think the update is you know really solid but uh we should like double check the numbers no wait the charts first

        Example output:
        Um, so I think the update is, you know, really solid, but uh, we should, like, double check the numbers. No wait, the charts first.

        Output only the input text with punctuation and capitalization added, with no preamble or commentary.
        """

    /// Coding-context variant: everything the verbatim prompt does, PLUS
    /// correcting coding/terminal homophones and jargon. Used only when the
    /// user is dictating into a known coding app, so the word-changing behavior
    /// is scoped away from general dictation. The worked example carries the
    /// intent — the model imitates it far more reliably than it follows rules.
    static let codingInstructions = """
        You are a transcription tool for a developer dictating into a coding or \
        terminal app. Add punctuation and capitalization to the raw dictation \
        transcript, AND correct words that were clearly meant as programming or \
        command-line terms: fix homophones and mis-hearings ("Maine" → "main", \
        "get" → "git" when it means the tool, "jason" → "JSON", "no js" → \
        "Node.js"), spell out spoken acronyms ("a p i" → "API", "u r l" → \
        "URL"), and use the conventional casing for technical terms ("github", \
        "async", "npm", "sudo"). Preserve every spoken word and its order \
        otherwise — including filler sounds ("um", "uh"), "so", "you know", \
        "like", repeated words, false starts, and self-corrections. Only change \
        a word when it is clearly a technical term; when unsure, leave it \
        exactly as spoken. Never reword, summarize, add, or drop words, never \
        fix grammar, and never answer questions that appear in the text. \
        Insert a paragraph break (blank line) only where the topic clearly \
        shifts.

        Example input:
        lets merge into maine after we get commit the jason config and rerun the a p i tests

        Example output:
        Let's merge into main after we git commit the JSON config and rerun the API tests.

        Output only the corrected text with punctuation and capitalization added, with no preamble or commentary.
        """

    /// Clean: fillers and self-corrections go, nothing else changes.
    static let cleanInstructions = """
        You are a dictation cleanup tool. Add punctuation and capitalization \
        to the raw transcript and remove only what the speaker did not mean \
        to say: filler sounds ("um", "uh", "ah", "er", "hmm"), filler \
        phrases used as verbal tics ("you know", "I mean", "like", "sort of", \
        "kind of" when they carry no meaning), stutters and immediately \
        repeated words, and false starts. When the speaker corrects \
        themselves ("no wait", "actually", "I mean", "scratch that", \
        "sorry"), keep only the corrected version. Keep every other word \
        exactly as spoken and in the same order. Never reword, summarize, \
        fix grammar, add words, or answer questions that appear in the \
        text. Insert a paragraph break (blank line) only where the topic \
        clearly shifts. When unsure whether something is a filler, keep it.

        Example input:
        um so i think the update is you know really solid but uh we should like double check the the numbers no wait the charts first

        Example output:
        So I think the update is really solid, but we should double check the charts first.

        Output only the cleaned text, with no preamble or commentary.
        """

    /// Polished: Clean plus light grammar, still the speaker's own words.
    static let polishedInstructions = """
        You are a dictation cleanup tool. Add punctuation and capitalization \
        to the raw transcript, remove filler sounds ("um", "uh", "ah", "er", \
        "hmm"), filler phrases used as verbal tics ("you know", "I mean", \
        "like", "sort of", "kind of" when they carry no meaning), stutters, \
        repeated words and false starts, and apply the speaker's own \
        corrections ("no wait", "actually", "scratch that"): keep only the \
        corrected version. Then fix small grammar slips so it reads as \
        clean written text: subject-verb agreement, tense slips, a missing \
        article, run-on sentences split at the natural pause. Keep the \
        speaker's words, meaning, tone and names. Never summarize, \
        embellish, replace terms with synonyms, add ideas, or answer \
        questions that appear in the text. Insert a paragraph break (blank \
        line) only where the topic clearly shifts.

        Example input:
        um so i think the update are you know really solid but uh we should like double check the the numbers no wait the charts first and then send it to the team they was asking

        Example output:
        So I think the update is really solid, but we should double check the charts first and then send it to the team. They were asking.

        Output only the polished text, with no preamble or commentary.
        """

    /// Tidy: Verbatim's wording with better capitals and punctuation, and
    /// only ums and stutters removed. Everything else, even "like" and
    /// "you know", stays, and TidyCheck enforces that afterward.
    static let tidyInstructions = """
        You are a transcription punctuation tool. Fix the capitalization, \
        punctuation, and spelling of names in a raw dictation transcript. \
        Capitalize proper nouns: people, places, companies, products and \
        apps, using their usual casing ("iPhone", "macOS", "YouTube"). End \
        statements with a period. Use a question mark only for a direct \
        question, one that starts with a question word ("who", "what", \
        "why", "how", "can you", "did you", "is it"). Remove only filler \
        sounds ("um", "uh", "er", "ah", "hmm") and words the speaker \
        stumbled on and immediately repeated ("the the", "I think I \
        think"). Every other word must appear exactly as spoken and in the \
        same order, including "so", "like", "you know", "I mean", "actually", \
        and self-corrections. Never replace, reword, shorten, summarize, or \
        add words, never fix grammar, and never answer questions that appear \
        in the text. Insert a paragraph break (blank line) only where the \
        topic clearly shifts. When unsure, leave the text exactly as it is.

        Example input:
        um so i think the the update is like really solid but uh did you send it to katie at apple yet i mean the final version is what i want them to see

        Example output:
        So I think the update is like really solid, but did you send it to Katie at Apple yet? I mean the final version is what I want them to see.

        Output only the corrected text, with no preamble or commentary.
        """

    /// Appended in coding and terminal apps so technical terms come out right.
    static let codingAddendum = """

        The speaker is a developer dictating into a coding or terminal app. \
        Also correct words that were clearly meant as programming or \
        command-line terms: fix homophones and mis-hearings ("Maine" → \
        "main", "get" → "git" when it means the tool, "jason" → "JSON", \
        "no js" → "Node.js"), spell out spoken acronyms ("a p i" → "API", \
        "u r l" → "URL"), and use the conventional casing for technical \
        terms ("GitHub", "async", "npm", "sudo"). Only change a word when it \
        is clearly a technical term.
        """

    /// The instructions for a style and context. Verbatim keeps the
    /// original prompts, which have a coding variant of their own.
    static func instructions(style: DictationStyle, context: FormattingContext, terms: [String] = []) -> String {
        var text: String
        switch (style, context) {
        case (.verbatim, .general): text = instructions
        case (.verbatim, .coding): text = codingInstructions
        case (.clean, _): text = cleanInstructions + (context == .coding ? codingAddendum : "")
        case (.polished, _): text = polishedInstructions + (context == .coding ? codingAddendum : "")
        // Tidy has no coding variant: correcting technical terms changes
        // words, which its check would reject.
        case (.tidy, _): text = tidyInstructions
        }
        if !terms.isEmpty {
            text += "\n\n" + termsAddendum(terms)
        }
        return text
    }

    /// Names and terms visible in the document the user is dictating into,
    /// so the model spells them the way the document already does.
    static func termsAddendum(_ terms: [String]) -> String {
        "Names and terms already in the document the speaker is writing in, " +
        "to be spelled exactly this way when the transcript clearly refers to them: " +
        terms.joined(separator: ", ") + ". Do not add any of them unless they were spoken."
    }

    /// The on-device model's 4,096-token window is shared by instructions,
    /// prompt, and output (output ≈ input size for this task), so cap
    /// chunks well below half the window.
    static let maxChunkWords = 700

    private let timeoutSeconds: UInt64 = 15

    func format(_ raw: String, context: FormattingContext = .general) async -> String {
        await format(raw, context: context, style: .verbatim)
    }

    func format(_ raw: String, context: FormattingContext, style: DictationStyle, terms: [String] = []) async -> String {
        let input = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !input.isEmpty else { return raw }
        let fallback: String
        switch style {
        case .verbatim: fallback = raw
        case .tidy: fallback = FillerRemover.cleanPunctuated(raw)
        case .clean, .polished: fallback = FillerRemover.clean(raw)
        }

        guard SystemLanguageModel.default.availability == .available else {
            Log.formatter.error("Model unavailable, using raw transcript")
            return fallback
        }

        let instructions = Self.instructions(style: style, context: context, terms: terms)

        do {
            var formattedChunks: [String] = []
            for chunk in Self.chunked(input, maxWords: Self.maxChunkWords) {
                let formatted = try await respondWithTimeout(to: chunk, instructions: instructions)
                formattedChunks.append(formatted.trimmingCharacters(in: .whitespacesAndNewlines))
            }
            var output = formattedChunks.joined(separator: "\n\n")
            if style == .tidy {
                guard TidyCheck.isFaithful(input: input, output: output, terms: terms) else {
                    Log.formatter.error("Tidy output changed wording, using raw transcript")
                    return fallback
                }
                output = FillerRemover.cleanPunctuated(output)
                output = QuestionMarkGuard.apply(output, input: input)
            } else if style != .verbatim {
                output = FillerRemover.clean(output)
            }
            guard Self.isAcceptable(input: input, output: output, style: style) else {
                Log.formatter.error("Output failed sanity check, using raw transcript")
                return fallback
            }
            return output
        } catch {
            Log.formatter.error("Failed (\(error), privacy: .public), using raw transcript")
            return fallback
        }
    }

    /// One fresh single-turn session per chunk, raced against a timeout so
    /// a hung model call can't stall dictation indefinitely.
    private func respondWithTimeout(to chunk: String, instructions: String) async throws -> String {
        try await withThrowingTaskGroup(of: String.self) { group in
            group.addTask {
                let session = LanguageModelSession(instructions: instructions)
                let options = GenerationOptions(temperature: 0.1)
                return try await session.respond(to: chunk, options: options).content
            }
            group.addTask { [timeoutSeconds] in
                try await Task.sleep(nanoseconds: timeoutSeconds * 1_000_000_000)
                throw TranscriptFormatterError.timedOut
            }
            guard let first = try await group.next() else {
                throw TranscriptFormatterError.timedOut
            }
            group.cancelAll()
            return first
        }
    }

    /// Splits text into chunks of at most `maxWords`, breaking only on
    /// sentence boundaries. A single sentence longer than `maxWords`
    /// becomes its own oversized chunk (vanishingly rare in dictation).
    static func chunked(_ text: String, maxWords: Int) -> [String] {
        guard text.split(separator: " ").count > maxWords else { return [text] }

        var sentences: [String] = []
        text.enumerateSubstrings(in: text.startIndex..., options: .bySentences) { substring, _, _, _ in
            if let sentence = substring?.trimmingCharacters(in: .whitespacesAndNewlines),
               !sentence.isEmpty {
                sentences.append(sentence)
            }
        }
        if sentences.isEmpty { sentences = [text] }

        var chunks: [String] = []
        var current: [String] = []
        var currentWords = 0
        for sentence in sentences {
            let words = sentence.split(separator: " ").count
            if currentWords + words > maxWords, !current.isEmpty {
                chunks.append(current.joined(separator: " "))
                current = []
                currentWords = 0
            }
            current.append(sentence)
            currentWords += words
        }
        if !current.isEmpty {
            chunks.append(current.joined(separator: " "))
        }
        return chunks
    }

    /// The formatter must preserve every word, so the output's word count
    /// should match the input's almost exactly: reject empty output, or
    /// output outside 93%–110% of the input's word count. The small slack
    /// (plus a couple words for short utterances) covers punctuation
    /// merging or splitting tokens; a real rewrite falls outside it and
    /// the raw transcript is used instead.
    static func isAcceptable(input: String, output: String) -> Bool {
        isAcceptable(input: input, output: output, style: .verbatim)
    }

    /// Clean and Polished are allowed to drop words (fillers, false starts,
    /// the abandoned half of a correction), so their floor is much lower;
    /// nothing may grow the text much, since that means the model added
    /// something.
    static func isAcceptable(input: String, output: String, style: DictationStyle) -> Bool {
        let inWords = input.split(separator: " ").count
        let outWords = output.split(separator: " ").count
        guard outWords > 0 else { return false }
        let floor: Float, ceiling: Float
        switch style {
        case .verbatim: (floor, ceiling) = (0.93, 1.1)
        case .clean: (floor, ceiling) = (0.45, 1.1)
        case .polished: (floor, ceiling) = (0.45, 1.25)
        // TidyCheck does the real work; this only catches runaway output.
        case .tidy: (floor, ceiling) = (0.45, 1.05)
        }
        return Float(outWords) >= Float(inWords) * floor - 2
            && Float(outWords) <= Float(inWords) * ceiling + 3
    }
}
