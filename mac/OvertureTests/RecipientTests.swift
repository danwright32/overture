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

    // A form-only contact (#368, the Ivalas Quartet case) has no published email, only a contact
    // form. It still becomes a recipient so it shows in the list and can be tracked; its id is the
    // form URL (not an email), so the SAME recipient is kept when Dan fills in an email later.
    @Test func aFormOnlyRecipientHasNoEmailAndAStableFormId() {
        let id = Recipient.makeId(email: nil, formURL: "https://www.ivalasquartet.com/contact")
        let r = Recipient(id: id!, email: nil, provenance: .act,
                          contactFormURL: "https://www.ivalasquartet.com/contact")
        #expect(r.email == nil)
        #expect(r.id == "form:https://www.ivalasquartet.com/contact")
    }

    // The id is the canonicalized email when there is one, the form URL otherwise, and nil when
    // there is neither (nothing to make a recipient from).
    @Test func makeIdPrefersTheCanonicalizedEmailThenTheForm() {
        #expect(Recipient.makeId(email: "Erobinson@Aurora.Example", formURL: "x") == "erobinson@aurora.example")
        #expect(Recipient.makeId(email: nil, formURL: "https://act.example/contact") == "form:https://act.example/contact")
        #expect(Recipient.makeId(email: "", formURL: "https://act.example/contact") == "form:https://act.example/contact")
        #expect(Recipient.makeId(email: nil, formURL: nil) == nil)
    }

    // Per-recipient resolution (#389 derived-outcome model): an additive field capturing the
    // terminal commercial outcomes that aren't inferable from send/reply/bounce state. Phase 5
    // reads it to derive the performance status; here we only pin that it round-trips.
    @Test func resolutionRoundTripsThroughRawString() throws {
        var r = Recipient(id: "a@act.example", email: "a@act.example", provenance: .act)
        #expect(r.resolution == nil)
        r.resolution = .declinedSoft
        #expect(r.resolutionRaw == "declined_soft")
        let back = try JSONDecoder().decode(Recipient.self, from: JSONEncoder().encode(r))
        #expect(back.resolution == .declinedSoft)
    }
}
