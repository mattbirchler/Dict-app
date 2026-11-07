import Testing
@testable import Dict_app

struct SmartSpacingTests {
    @Test func addsSpaceAfterWordOrSentenceEnd() {
        #expect(SmartSpacing.needsLeadingSpace(preceding: "o", text: "Then we ship."))
        #expect(SmartSpacing.needsLeadingSpace(preceding: ".", text: "Then we ship."))
        #expect(SmartSpacing.needsLeadingSpace(preceding: ",", text: "then we ship."))
    }

    @Test func noSpaceAtStartOrAfterWhitespace() {
        #expect(!SmartSpacing.needsLeadingSpace(preceding: nil, text: "Hello."))
        #expect(!SmartSpacing.needsLeadingSpace(preceding: " ", text: "Hello."))
        #expect(!SmartSpacing.needsLeadingSpace(preceding: "\n", text: "Hello."))
        #expect(!SmartSpacing.needsLeadingSpace(preceding: "\t", text: "Hello."))
    }

    @Test func noSpaceAfterOpeningBracketsAndQuotes() {
        for opener: Character in ["(", "[", "\"", "\u{201C}", "/", "@"] {
            #expect(!SmartSpacing.needsLeadingSpace(preceding: opener, text: "hello"))
        }
    }

    @Test func noSpaceBeforeClosingPunctuation() {
        #expect(!SmartSpacing.needsLeadingSpace(preceding: "d", text: ", and then"))
        #expect(!SmartSpacing.needsLeadingSpace(preceding: "d", text: "."))
    }

    @Test func noSpaceForEmptyText() {
        #expect(!SmartSpacing.needsLeadingSpace(preceding: "d", text: ""))
    }

    @Test func skipsZeroWidthSpaceOnAnEmptyObsidianLine() {
        // What Obsidian reports before the cursor on some empty lines.
        let preceding = SmartSpacing.lastVisibleCharacter(in: "fun!\n\u{200B}")
        #expect(preceding == "\n")
        #expect(!SmartSpacing.needsLeadingSpace(preceding: preceding, text: "Hello"))
    }

    @Test func onlyInvisibleCharactersCountAsStartOfField() {
        #expect(SmartSpacing.lastVisibleCharacter(in: "\u{200B}\u{FEFF}") == nil)
    }

    @Test func stillSpacesAfterAWordFollowedByAZeroWidthSpace() {
        #expect(SmartSpacing.lastVisibleCharacter(in: "word\u{200B}") == "d")
    }
}
