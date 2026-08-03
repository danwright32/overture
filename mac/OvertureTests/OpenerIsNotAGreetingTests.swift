import Testing
import Foundation

// #2013. Overture exports the opening sentence of recent drafts so the AI drafter can vary its own
// openers rather than repeating a shape. The extraction assumed the stored body carries no greeting,
// which was true when the app owned the greeting at send and nothing else could put one there.
//
// LIVE-STORE-CLAIM verified=2026-08-03 measure="exported openers that are really a greeting glued to the first sentence, out of all exported openers"
// It is not true now. Measured on the live `overture-recent-openers.json`: 3 of the 8 openers the drafter
// currently reads begin "Hello, I photograph performing arts here in New York and saw...". The drafter is
// being told to avoid a shape whose distinguishing feature is a greeting, and two of those three are the
// same real opener that only fail to collapse because their greetings sit in front of them.
//
// Four of the nine stored drafts open this way, and the AI drafter wrote them, so this is not about hand
// typed text.
@Suite("An exported opener is never just a greeting (#2013)")
struct OpenerIsNotAGreetingTests {

    // The live case, verbatim from the file the drafter reads.
    @Test func agreetingIsNotPartOfTheOpener() {
        let body = "Hello, I photograph performing arts here in New York and saw Avery Wilson is playing. "
            + "I shoot unobtrusive documentary coverage."

        #expect(RecentOpenersBuilder.opener(from: body)
                == "I photograph performing arts here in New York and saw Avery Wilson is playing.")
    }

    // Every greeting the app can meet, including the ones its retired strip could not see: a bare
    // "Hello," with no name, and "Dear", which that pattern did not know about at all.
    @Test func everygreetingShapeIsDropped() {
        #expect(RecentOpenersBuilder.opener(from: "Hi Sarah, Great to see the festival back.")
                == "Great to see the festival back.")
        #expect(RecentOpenersBuilder.opener(from: "Dear Sarah, Great to see the festival back.")
                == "Great to see the festival back.")
        #expect(RecentOpenersBuilder.opener(from: "Hello,\n\nI photograph performing arts.")
                == "I photograph performing arts.")
    }

    // An ordinary opener is untouched, or the fix costs more than it saves.
    @Test func anordinaryOpenerIsUnchanged() {
        #expect(RecentOpenersBuilder.opener(from: "I photograph performing arts in New York. And more.")
                == "I photograph performing arts in New York.")
        #expect(RecentOpenersBuilder.opener(from: "I've photographed at Carnegie Hall for ten years.")
                == "I've photographed at Carnegie Hall for ten years.")
    }

    // A sentence that merely starts with a greeting WORD is not a greeting, and stripping it would
    // silently delete the real opener.
    @Test func asentenceThatOnlyStartsWithAGreetingWordIsKept() {
        #expect(RecentOpenersBuilder.opener(from: "Highlights from the season are attached.")
                == "Highlights from the season are attached.")
        #expect(RecentOpenersBuilder.opener(from: "Hello Dolly opens at the Palace in March.")
                == "Hello Dolly opens at the Palace in March.")
    }

    // A body that is ONLY a greeting has no opener to teach anything, so it contributes none rather than
    // an empty string that would occupy a slot and dedupe against every other empty one.
    @Test func abodyThatIsOnlyAGreetingYieldsNoOpener() {
        #expect(RecentOpenersBuilder.opener(from: "Hi Sarah,").isEmpty)
        #expect(RecentOpenersBuilder.opener(from: "Hello,").isEmpty)
    }

    // The detector and the stripper must agree about what a leading greeting IS, or the draft screen
    // will point at one the export has already removed, and the two will drift the first time either
    // pattern is touched.
    @Test func thedetectorAndTheStripperAgree() {
        let greeted = ["Hi Sarah, Great to see you.", "Hello, I photograph performing arts.",
                       "Dear Sarah, Great to see you."]
        let plain = ["I photograph performing arts.", "Highlights from the season are attached.",
                     "Hello Dolly opens at the Palace in March."]

        for body in greeted {
            #expect(DraftOpeningNotice.bodyRepeatsAGreeting(body),
                    "the draft screen must point at this: \(body)")
            #expect(!DraftOpeningNotice.bodyRepeatsAGreeting(RecentOpenersBuilder.opener(from: body)),
                    "and the export must have already removed it: \(body)")
        }
        for body in plain {
            #expect(!DraftOpeningNotice.bodyRepeatsAGreeting(body))
        }
    }
}
