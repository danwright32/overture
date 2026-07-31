import Testing
import Foundation
@testable import Overture

// #1906: an exclamation mark in the CLOSING line only.
//
// Dan's call, 2026-07-31, after editing a real draft to end "I look forward to hearing from you!"
// and being told the app flags it. The rule against exclamation marks was written for performative
// enthusiasm mid-email, and it was catching his own sign-off, which is the one place he uses one
// deliberately. The mark is allowed in the last sentence and nowhere else.
@Suite("Draft check: closing exclamation")
struct DraftCheckClosingExclamationTests {

    private func flags(_ body: String) -> Bool {
        DraftCheck.findings(in: body).contains(.performativeEnthusiasm)
    }

    // Dan's own sign-off, verbatim from the draft he edited and kept.
    @Test func aclosingSignOffMayCarryAnExclamationMark() {
        #expect(!flags("I'm Dan Wright, a documentary photographer here in NYC. I shoot without flash. I look forward to hearing from you!"))
    }

    // The mark is allowed because it is the CLOSING line, not because the phrase is special.
    @Test func adifferentClosingLineMayAlsoCarryOne() {
        #expect(!flags("I photograph performing arts here in NYC. Hope to hear from you soon!"))
    }

    // Everywhere else it still fires. This is what the rule was written for.
    @Test func anExclamationMarkEarlierInTheEmailStillFlags() {
        #expect(flags("What a show this looks like! I'm Dan Wright, a documentary photographer here in NYC. I look forward to hearing from you."))
    }

    @Test func anExclamationInTheMiddleFlagsEvenWithACleanClose() {
        #expect(flags("I'm Dan Wright. Your August run sounds wonderful! I look forward to hearing from you."))
    }

    // Only ONE closing sentence is exempt: a body that ends in a run of them is back to
    // performative, which is the thing the rule exists to catch.
    @Test func twoExclamationMarksStillFlagEvenAtTheEnd() {
        #expect(flags("I'm Dan Wright, a photographer here in NYC. Thanks so much! I look forward to hearing from you!"))
    }

    // The exemption is about punctuation, never about the words. A performative PHRASE is still
    // caught wherever it sits, including in the closing line.
    @Test func aperformativeWordInTheClosingLineStillFlags() {
        #expect(flags("I'm Dan Wright, a photographer here in NYC. I'd be thrilled to hear from you!"))
    }

    // The exemption is for a SIGN-OFF, which means there has to be an email in front of it. A body
    // that is nothing but an exclamation is the performative shape the rule exists for, and it
    // would otherwise read as its own closing line and walk straight through. Two pre-existing
    // tests caught exactly this in the first version of the check.
    @Test func abodyThatIsNothingButAnExclamationStillFlags() {
        #expect(flags("Come see the show!"))
        #expect(flags("Looking forward to it!"))
    }

    // A body with no exclamation mark at all is unaffected.
    @Test func aplainCloseIsUntouched() {
        #expect(!flags("I'm Dan Wright, a documentary photographer here in NYC. I look forward to hearing from you."))
    }
}
