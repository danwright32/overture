import Testing
import Foundation
@testable import Overture

// Phase 2.5 (#393): drafts authored before the salutation-free rule embed the greeting inline in the
// first sentence ("Hi Emma, I photograph..."). To make the body reusable per recipient (the app owns
// the greeting at send), a one-shot normalizer strips that leading greeting. It must be CONSERVATIVE:
// strip only when the prefix matches the greeting grammar AND the token looks like a name, otherwise
// leave the copy untouched and flag it for Dan rather than corrupt it.
@Suite("Salutation strip")
struct SalutationStripTests {
    @Test func stripsALeadingHiNameGreeting() {
        let r = SalutationStrip.strip("Hi Emma, I photograph performing arts in New York.")
        #expect(r.body == "I photograph performing arts in New York.")
        #expect(r.didStrip)
        #expect(!r.needsReview)
    }

    @Test func stripsHelloAndBangPunctuation() {
        #expect(SalutationStrip.strip("Hello Maria! I document dance.").body == "I document dance.")
        #expect(SalutationStrip.strip("Hey Sam, the run looks great.").body == "the run looks great.")
    }

    @Test func stripsATwoWordName() {
        let r = SalutationStrip.strip("Hi Anna Pierre, I saw your spring program.")
        #expect(r.body == "I saw your spring program.")
        #expect(r.didStrip)
    }

    @Test func stripsGenericGreetingFillers() {
        #expect(SalutationStrip.strip("Hi there, I photograph performing arts.").body == "I photograph performing arts.")
    }

    @Test func leavesAnAlreadySalutationFreeBodyUntouched() {
        let body = "I photograph performing arts in New York and saw your show."
        let r = SalutationStrip.strip(body)
        #expect(r.body == body)
        #expect(!r.didStrip)
        #expect(!r.needsReview)
    }

    // Idempotent: stripping an already-stripped body is a no-op, so the normalizer is safe to re-run.
    @Test func isIdempotent() {
        let once = SalutationStrip.strip("Hi Emma, I photograph performing arts.").body
        let twice = SalutationStrip.strip(once).body
        #expect(once == twice)
    }

    // A word that merely starts with "Hi"/"Hello" is not a greeting — word boundary required.
    @Test func doesNotStripAWordThatJustStartsWithHi() {
        let body = "Highlights from the season are online."
        #expect(SalutationStrip.strip(body).body == body)
        #expect(!SalutationStrip.strip(body).didStrip)
    }

    // Greeting grammar but the token is not name-like (digits / clearly not a name): leave the copy
    // untouched and flag it for Dan rather than guess.
    @Test func flagsForReviewWhenTheTokenIsNotNameLike() {
        let body = "Hi 2026 season, here is what we offer."
        let r = SalutationStrip.strip(body)
        #expect(r.body == body)
        #expect(!r.didStrip)
        #expect(r.needsReview)
    }
}
