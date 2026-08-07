import Testing
import Foundation
import SwiftData

// #2259 defect 4: a card said "No email found" about a run that had found two people.
//
// The Summer Lovin' run (2026-08-07) emitted two contacts, Isabella Borte and Ani Chong, each with
// `method: "form_or_dm"`, no email and no form URL. The importer discards a contact carrying neither,
// so the prospect ended with zero recipients. `emptyReason` (#1722) exists precisely so "No email
// found" never stands in for "we refused what we found" or "we never looked", but it was only written
// when `contacts` was ABSENT. Here contacts were present and every one was unusable, so the honest
// failure machinery never engaged and the reason was lost through a door #1722 did not cover.
//
// The truth on that card is closer to "two people found, neither publishes an address". That is a
// different finding from every reason already defined, and Dan does a different thing with each:
//
//   nothingPublished  a finished search he can give up on
//   noOneIdentified   the run never worked out WHO, so his own knowledge of the room beats it
//   onlySocialProfile a doorway was found and not opened, so a re-check is likely to succeed
//   namedButNoRoute   WHO is known and HOW is not, so a hand search has a name to start from
@MainActor
@Suite("A run that named people and no way to reach them says so (#2259)")
struct NamedButNoRouteTests {

    private func container() throws -> ModelContainer {
        try ModelContainer(for: Schema([Prospect.self, Recipient.self]),
                           configurations: [ModelConfiguration(isStoredInMemoryOnly: true)])
    }

    private func show(_ ctx: ModelContext) -> Prospect {
        let p = Prospect(naturalKey: "summer lovin|2026-08-11|the green room 42",
                         groupName: "Summer Lovin'", discipline: "theater",
                         venue: "The Green Room 42", performanceDate: "2026-08-11",
                         sourceListingURL: nil, websiteURL: nil, priorRelationship: "none",
                         production: "unknown", profile: "neutral", coverage: "unknown",
                         fitScore: 4, tier: "mid", fitReason: "r", matchedClientName: nil,
                         possibleMatchSource: nil, possibleMatchName: nil)
        ctx.insert(p)
        return p
    }

    // The live shape, verbatim from the run's own results file.
    private var theTwoUnreachablePeople: [PrepContact] {
        [PrepContact(name: "Isabella Borte", role: "Director/Producer", email: nil,
                     method: "form_or_dm", confidence: "low", formUrl: nil, provenance: "performer"),
         PrepContact(name: "Ani Chong", role: "Music Director", email: nil,
                     method: "form_or_dm", confidence: "low", formUrl: nil, provenance: "performer")]
    }

    @Test func namingPeopleWithNoWayToReachThemIsItsOwnReason() {
        #expect(Reachability.emptyReason(afterIngesting: theTwoUnreachablePeople, usableRecipients: 0)
                == .namedButNoRoute)
    }

    // A run that found a real address has nothing to explain, so no reason is written over it.
    @Test func aRunThatLandedAContactWritesNoReason() {
        let found = [PrepContact(name: "ICB Productions", role: "Producer",
                                 email: "icbproductionsnyc@gmail.com", method: "named_decision_maker",
                                 confidence: "high", formUrl: nil, provenance: "presenter")]
        #expect(Reachability.emptyReason(afterIngesting: found, usableRecipients: 1) == nil)
    }

    // The social case keeps its own reason rather than being swallowed by the new one: a doorway found
    // and not opened is where a re-check is most likely to succeed, and collapsing the two would hide
    // that (#2265's whole argument).
    @Test func aSocialProfileKeepsItsOwnReason() {
        let social = [PrepContact(name: "ICB Productions", role: "Producer", email: nil,
                                  method: "form_or_dm", confidence: "low",
                                  formUrl: "https://www.instagram.com/icbproductionsnyc",
                                  provenance: "presenter")]
        #expect(Reachability.emptyReason(afterIngesting: social, usableRecipients: 0) == .onlySocialProfile)
    }

    // A contact carrying a REAL contact form is reachable, so it is not this case at all: the importer
    // keeps it and Dan can pitch through the form.
    @Test func aRealContactFormIsNotAnAbsentRoute() {
        let form = [PrepContact(name: "ICB Productions", role: "Producer", email: nil,
                                method: "form_or_dm", confidence: "medium",
                                formUrl: "https://icbproductions.example/contact",
                                provenance: "presenter")]
        #expect(Reachability.emptyReason(afterIngesting: form, usableRecipients: 1) == nil)
    }

    // Nothing emitted at all is a different door, the one #1722 already covered, and it must keep
    // deferring to whatever the run itself reported rather than being overwritten here.
    @Test func anEmptyBatchIsNotThisCase() {
        #expect(Reachability.emptyReason(afterIngesting: [], usableRecipients: 0) == nil)
    }

    // MARK: - Through the importer, which is what actually reaches the card

    // The guard #2259 asks for: a prospect that ends a run with zero usable recipients always carries a
    // reason, so a bare "No email found" can never again stand for something the run did know.
    @Test func neitherOfThoseTwoPeopleCanBecomeARecipient() throws {
        let ctx = ModelContext(try container())
        let p = show(ctx)
        // The importer keys a recipient on an address or a form URL, so a contact carrying neither
        // cannot become one. Proving that here is what makes the count above zero for a real run
        // rather than by assumption.
        for contact in theTwoUnreachablePeople {
            #expect(Recipient.makeId(email: contact.email, formURL: contact.formUrl) == nil)
        }
        #expect(p.recipients.isEmpty)
        #expect(Reachability.emptyReason(afterIngesting: theTwoUnreachablePeople,
                                         usableRecipients: p.recipients.count) == .namedButNoRoute)
    }

    // MARK: - What Dan reads

    @Test func theCardSaysWhoWasFoundRatherThanThatNothingWas() {
        let line = ReachabilityCopy.emptyAnswerBadge(.namedButNoRoute)
        #expect(line.isEmpty == false)
        #expect(line != ReachabilityCopy.emptyAnswerBadge(.nothingPublished))
        #expect(line != ReachabilityCopy.emptyAnswerBadge(.noOneIdentified))
        #expect(line != ReachabilityCopy.emptyAnswerBadge(.onlySocialProfile))
        // And the hover text says what to DO with the names, rather than repeating them.
        #expect(ReachabilityCopy.emptyAnswerHelp(.namedButNoRoute)
                != ReachabilityCopy.emptyAnswerHelp(.nothingPublished))
    }
}
