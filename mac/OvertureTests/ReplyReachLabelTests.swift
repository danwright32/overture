import Testing
import Foundation

// #2063: the reply card has to say who the reply reaches, because that is now a fact about the incoming
// message rather than something Dan can infer from the contact whose card he is looking at. What he
// approves must include WHO it goes to (L64).
//
// It says so ONLY when the reply reaches somebody besides that contact. On the ordinary one-to-one reply
// the line would restate the card it sits on, which is the duplicate-copy shape #843 exists to stop.
@MainActor
@Suite("What the reply card says about who the reply reaches")
struct ReplyReachLabelTests {
    // MARK: - The shared list joiner (#2063 consolidation)

    @Test func oneNameIsJustThatName() {
        #expect(Plural.list(["Ann"]) == "Ann")
    }

    @Test func twoNamesAreJoinedByAnd() {
        #expect(Plural.list(["Ann", "Ben"]) == "Ann and Ben")
    }

    @Test func threeOrMoreTakeCommasAndAFinalAnd() {
        #expect(Plural.list(["Ann", "Ben", "Cara"]) == "Ann, Ben and Cara")
    }

    @Test func nothingListsAsNothing() {
        #expect(Plural.list([]) == "")
    }

    // MARK: - The line itself

    @Test func aReplyReachingOnlyThisContactSaysNothingExtra() {
        #expect(QueueModel.replyAlsoReachesLabel([]) == nil)
    }

    @Test func aReplyReachingOthersNamesThem() {
        #expect(QueueModel.replyAlsoReachesLabel(["ben@org.example"])
                == "Also goes to ben@org.example")
        #expect(QueueModel.replyAlsoReachesLabel(["ben@org.example", "cara@org.example"])
                == "Also goes to ben@org.example and cara@org.example")
    }

    // MARK: - Who "the others" are

    // Through the REAL snapshot construction, so this covers the wiring too: a card can only name the
    // others if the audience actually reaches it from the stored contact (L3).
    private func snapshot(email: String, audience: [String]?) -> RecipientSnapshot {
        let r = Recipient(id: "ann@org.example", email: email, name: "Ann", provenance: .presenter)
        r.replyAudience = audience
        return RecipientSnapshot(r)
    }

    @Test func theContactWhoseCardItIsIsNotOneOfTheOthers() {
        let s = snapshot(email: "ann@org.example", audience: ["ann@org.example", "ben@org.example"])

        #expect(s.replyAlsoReaches == ["ben@org.example"])
    }

    @Test func aReplyToThisContactAloneLeavesNoOthers() {
        let s = snapshot(email: "ann@org.example", audience: ["ann@org.example"])

        #expect(s.replyAlsoReaches.isEmpty)
    }

    // With nothing captured the reply goes to this contact alone, so there is nobody else to name and the
    // card stays quiet rather than announcing a fallback.
    @Test func nothingCapturedLeavesNoOthersToName() {
        let s = snapshot(email: "ann@org.example", audience: nil)

        #expect(s.replyAlsoReaches.isEmpty)
    }

    // A stored address differing only in case is the same person, not a second reader.
    @Test func aDifferentlyCasedAddressIsTheSamePerson() {
        let s = snapshot(email: "Ann@Org.Example", audience: ["ann@org.example", "ben@org.example"])

        #expect(s.replyAlsoReaches == ["ben@org.example"])
    }
}
