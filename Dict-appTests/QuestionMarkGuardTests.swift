import Testing
@testable import Dict_app

struct QuestionMarkGuardTests {
    @Test func demotesStatementTheModelTurnedIntoAQuestion() {
        let input = "So the meeting went well. We talked about the budget and I think we're in good shape."
        let output = "So the meeting went well. We talked about the budget and I think we're in good shape?"
        #expect(QuestionMarkGuard.apply(output, input: input) == input)
    }

    @Test func demotesLongStatementWithEmbeddedQuestionWord() {
        let output = "I don't know how you can replicate this, but yeah, I kind of expect it to happen most of the time?"
        #expect(QuestionMarkGuard.apply(output, input: "") ==
            "I don't know how you can replicate this, but yeah, I kind of expect it to happen most of the time.")
    }

    @Test func keepsDirectQuestions() {
        for question in [
            "What do you think about the new layout?",
            "Can you take a look at recent merges?",
            "So I think it's solid, but did you send it to Katie yet?",
            "Okay, so where are we on this?",
            "That's the plan, right?",
        ] {
            #expect(QuestionMarkGuard.apply(question, input: "") == question)
        }
    }

    @Test func keepsQuestionMarksTheSpeechEngineWrote() {
        let input = "You're coming tomorrow? Great."
        #expect(QuestionMarkGuard.apply("You're coming tomorrow? Great.", input: input) == input)
    }

    @Test func onlyTouchesTheSentencesThatNeedIt() {
        let output = "Did you ship it? I love that about it?\n\nWhy?"
        #expect(QuestionMarkGuard.apply(output, input: "") == "Did you ship it? I love that about it.\n\nWhy?")
    }
}
