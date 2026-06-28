import Testing
import Foundation
@testable import Overture

// One party emailed for a performance. Multiple per performance, each with its own send state and
// engagement. The behaviors that matter to the rest of the system: who is "silent" (the only ones
// that get follow-ups), the provenance/send-state mapping, and a clean Codable round-trip (it is
// stored as a JSON blob on Prospect).
@Suite("Recipient")
struct RecipientTests {
    private func sent(replied: Bool = false, bounced: Bool = false) -> Recipient {
        var r = Recipient(id: "a@act.example", email: "a@act.example", provenance: .act)
        r.sendState = .sent
        r.replied = replied
        r.bounced = bounced
        return r
    }

    @Test func aSentUnansweredRecipientIsSilent() {
        #expect(sent().isSilent)
    }

    @Test func aPendingRecipientIsNotSilent() {
        let r = Recipient(id: "a@act.example", email: "a@act.example", provenance: .act)
        #expect(r.sendState == .pending)
        #expect(!r.isSilent)
    }

    @Test func aRepliedRecipientIsNotSilent() {
        #expect(!sent(replied: true).isSilent)
    }

    @Test func aBouncedRecipientIsNotSilent() {
        #expect(!sent(bounced: true).isSilent)
    }

    @Test func firstNameUsesTheSharedSalutationHelper() {
        var r = Recipient(id: "x", email: "x@act.example", provenance: .act)
        r.name = "Anna Pierre"
        #expect(r.firstName == "Anna")
    }

    @Test func provenanceAndSendStateRoundTripThroughRawStrings() {
        var r = Recipient(id: "p@present.example", email: "p@present.example", provenance: .presenter)
        r.sendState = .suppressed
        #expect(r.provenance == .presenter)
        #expect(r.provenanceRaw == "presenter")
        #expect(r.sendState == .suppressed)
        #expect(r.sendStateRaw == "suppressed")
    }

    @Test func codableRoundTripPreservesState() throws {
        var r = Recipient(id: "a@act.example", email: "a@act.example", provenance: .manual)
        r.name = "Virgile Roche"
        r.sendState = .sent
        r.replied = true
        r.gmailThreadId = "t1"
        let data = try JSONEncoder().encode(r)
        let back = try JSONDecoder().decode(Recipient.self, from: data)
        #expect(back == r)
    }
}
