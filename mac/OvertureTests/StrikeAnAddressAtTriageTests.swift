import Testing
import Foundation
import SwiftData

// #2392: Dan strikes an address he does not want to contact, BEFORE the prep run pays to research and
// draft to it.
//
// His words on the live build 2026-08-09, looking at a triage card reading "10 found, 4 reachable" over
// four addresses, three of them personal gmail accounts that look nothing like whoever books the show:
// "I should be able to remove emails that I don't want to contact before prepping." He could see it at a
// glance and there was nothing on the card he could do about it.
//
// The test this suite exists for is `aStruckAddressIsNotBroughtBackByTheNextPrepRun`. Removing a still
// pending recipient HARD DELETES it, and PrepImporter matches an incoming contact to a pending recipient
// or creates one, so a deleted row is indistinguishable from one never found and the very next run puts
// the address straight back. Striking it before the run is the whole point, so the removal has to be
// recorded as a REFUSAL the importer reads, never as an absence.
@MainActor
@Suite("Striking an address before the prep run (#2392)")
struct StrikeAnAddressAtTriageTests {

    private func context() throws -> ModelContext {
        ModelContext(try ModelContainer(for: AppSchema.schema,
                                        configurations: [ModelConfiguration(isStoredInMemoryOnly: true)]))
    }

    @discardableResult
    private func show(_ ctx: ModelContext, presenter: String? = "Feinstein's/54 Below",
                      emails: [String] = ["devin@devinmarlowe.example"]) -> Prospect {
        let key = Prospect.makeNaturalKey(groupName: "Devin Marlowe",
                                          performanceDate: "2026-10-03", venue: "54 Below")
        let p = Prospect(naturalKey: key, groupName: "Devin Marlowe", discipline: "music",
                         venue: "54 Below", performanceDate: "2026-10-03",
                         sourceListingURL: nil, priorRelationship: "none",
                         production: "self", profile: "strong", coverage: "likely_uncovered",
                         fitScore: 20, tier: "high", fitReason: "r", matchedClientName: nil,
                         possibleMatchSource: nil, possibleMatchName: nil, status: .queued)
        p.presenter = presenter
        ctx.insert(p)
        for e in emails {
            p.addRecipient(Recipient(id: ReplyDetection.email(from: e), email: e, name: nil,
                                     provenance: .act))
        }
        try? ctx.save()
        return p
    }

    private func results(_ key: String, emails: [String]) -> PrepResults {
        PrepResults(version: 9, generatedAt: "2026-08-09T00:00:00Z",
                    results: [PrepResult(naturalKey: key,
                                         contacts: emails.map {
                                             PrepContact(name: nil, role: nil, email: $0,
                                                         method: "generic_inbox", confidence: "low",
                                                         provenance: "act")
                                         },
                                         draft: nil)])
    }

    // MARK: - THE test

    // A refusal survives the run it was made to forestall. Before this, the strike deleted a pending row
    // and the next import created it again, so the removal silently undid itself.
    @Test func aStruckAddressIsNotBroughtBackByTheNextPrepRun() throws {
        let ctx = try context()
        let p = show(ctx, emails: ["devin@devinmarlowe.example", "devinsbrother@example.com"])

        ContactRefusal.refuse(email: "devinsbrother@example.com", scope: .show(p.naturalKey), in: ctx)
        p.removeOrSuppressRecipient(id: ReplyDetection.email(from: "devinsbrother@example.com"))
        try ctx.save()

        _ = PrepImporter.ingest(results(p.naturalKey,
                                        emails: ["devin@devinmarlowe.example", "devinsbrother@example.com"]),
                                into: ctx)

        #expect(p.recipients.compactMap(\.email).sorted() == ["devin@devinmarlowe.example"])
    }

    // The refusal is about the ADDRESS, however it is spelled on the way in. A run that reports it with
    // different case, or wrapped in a display name, is reporting the same person.
    @Test func aRefusalHoldsHoweverTheAddressIsSpelled() throws {
        let ctx = try context()
        let p = show(ctx, emails: ["devin@devinmarlowe.example"])

        ContactRefusal.refuse(email: "DevinsBrother@Example.com ", scope: .show(p.naturalKey), in: ctx)

        _ = PrepImporter.ingest(results(p.naturalKey, emails: ["devinsbrother@example.com"]), into: ctx)

        #expect(p.recipients.compactMap(\.email).sorted() == ["devin@devinmarlowe.example"])
    }

    // A refusal on ONE show says nothing about any other. It is the narrower of the two scopes on
    // purpose, and a show-level fact read at the organisation level would silently strike people it is
    // not true of (L83).
    @Test func aShowRefusalDoesNotReachAnotherShow() throws {
        let ctx = try context()
        let p = show(ctx, emails: ["devin@devinmarlowe.example"])
        let other = Prospect(naturalKey: "other|2026-11-01|54-below", groupName: "Someone Else",
                             discipline: "music", venue: "54 Below", performanceDate: "2026-11-01",
                             sourceListingURL: nil, priorRelationship: "none",
                             production: "self", profile: "strong", coverage: "likely_uncovered",
                             fitScore: 20, tier: "high", fitReason: "r", matchedClientName: nil,
                             possibleMatchSource: nil, possibleMatchName: nil, status: .queued)
        ctx.insert(other)
        try ctx.save()

        ContactRefusal.refuse(email: "devinsbrother@example.com", scope: .show(p.naturalKey), in: ctx)

        _ = PrepImporter.ingest(results(other.naturalKey, emails: ["devinsbrother@example.com"]), into: ctx)

        #expect(other.recipients.compactMap(\.email) == ["devinsbrother@example.com"])
    }

    // MARK: - The reversal

    // Dan's rule for removal at review (#2155) is that it is immediate with no undo, "just like it would
    // in a real email client. if they want to add it back they can". Triage follows the same rule, which
    // means adding the address back has to actually reverse it rather than leaving a refusal standing
    // behind a contact that is on the card.
    // A show with no contacts of its own, so the incoming address is genuinely APPENDED rather than
    // read as a correction to a pending act contact already there (which is what the importer's
    // `matchPending` does, and would hide what this test is measuring).
    @Test func addingTheAddressBackReversesTheStrike() throws {
        let ctx = try context()
        let p = show(ctx, emails: [])

        ContactRefusal.refuse(email: "devinsbrother@example.com", scope: .show(p.naturalKey), in: ctx)
        _ = PrepImporter.ingest(results(p.naturalKey, emails: ["devinsbrother@example.com"]), into: ctx)
        // The strike holds first, so the second half below is measuring the reversal and not simply an
        // importer that would have taken the address either way.
        #expect(p.recipients.isEmpty)

        ContactRefusal.allow(email: "devinsbrother@example.com", showKey: p.naturalKey,
                             orgKey: OrgKey.stored(for: p.presenter ?? ""), in: ctx)
        _ = PrepImporter.ingest(results(p.naturalKey, emails: ["devinsbrother@example.com"]), into: ctx)

        #expect(p.recipients.compactMap(\.email) == ["devinsbrother@example.com"])
    }

    // Refusing twice is one refusal. A strike Dan repeats (or a second surface writing the same fact)
    // must not leave two rows behind that one `allow` cannot clear.
    @Test func refusingTwiceStillClearsInOneGo() throws {
        let ctx = try context()
        let p = show(ctx)

        ContactRefusal.refuse(email: "x@example.com", scope: .show(p.naturalKey), in: ctx)
        ContactRefusal.refuse(email: "x@example.com", scope: .show(p.naturalKey), in: ctx)
        ContactRefusal.allow(email: "x@example.com", showKey: p.naturalKey, orgKey: nil, in: ctx)

        #expect(ContactRefusal.ledger(in: ctx)
            .isRefused(email: "x@example.com", showKey: p.naturalKey, orgKey: nil) == false)
    }

    // MARK: - The organisation scope

    // An INHERITED address has no Recipient on this show at all: it is printed from the organisation
    // ledger, so there is no row to delete and the fact belongs at the organisation (Dan's call,
    // 2026-08-09). Striking it must therefore reach every show that inherits it, not just this card.
    @Test func anOrganisationRefusalReachesEveryShowThatInheritsIt() throws {
        let ctx = try context()
        let orgKey = try #require(OrgKey.stored(for: "Feinstein's/54 Below"))

        ContactRefusal.refuse(email: "boxoffice@54below.com", scope: .organisation(orgKey), in: ctx)
        let ledger = ContactRefusal.ledger(in: ctx)

        #expect(ledger.isRefused(email: "boxoffice@54below.com", showKey: "any-show", orgKey: orgKey))
        #expect(ledger.isRefused(email: "boxoffice@54below.com", showKey: "some-other-show", orgKey: orgKey))
        // And says nothing about a different organisation.
        #expect(!ledger.isRefused(email: "boxoffice@54below.com", showKey: "any-show",
                                  orgKey: OrgKey.stored(for: "Joe's Pub")))
    }

    // The addresses a card PRINTS come from the ledger too, so a struck one has to leave the card. An
    // inherited answer whose every address has been struck stops being an answer at all: a badge saying
    // an email was found, over nothing, is the mismatch L16 exists to prevent.
    @Test func aStruckInheritedAddressLeavesTheCard() throws {
        let ctx = try context()
        let orgKey = try #require(OrgKey.stored(for: "Feinstein's/54 Below"))
        ContactRefusal.refuse(email: "boxoffice@54below.com", scope: .organisation(orgKey), in: ctx)

        let answers = [OrgAnswerLedger.Answer(orgKey: orgKey, result: .emailFound,
                                              probedAt: Date(timeIntervalSince1970: 1_000_000),
                                              presenterName: "Feinstein's/54 Below",
                                              emails: ["boxoffice@54below.com", "booking@54below.com"])]
        let allowed = ContactRefusal.ledger(in: ctx).allowedAnswers(answers)

        #expect(allowed.first?.emails == ["booking@54below.com"])

        let noneLeft = ContactRefusal.ledger(in: ctx).allowedAnswers(
            [OrgAnswerLedger.Answer(orgKey: orgKey, result: .emailFound,
                                    probedAt: Date(timeIntervalSince1970: 1_000_000),
                                    presenterName: "Feinstein's/54 Below",
                                    emails: ["boxoffice@54below.com"])])
        #expect(noneLeft.first?.emails.isEmpty == true)
    }

    // MARK: - The card

    // What the card prints, and what the count above it promises, come from one rule. "10 found, 4
    // reachable" over a list of three is exactly the promise L16 exists to keep.
    @Test func theCountMovesWithTheList() throws {
        let ctx = try context()
        let p = show(ctx, emails: ["a@act.com", "b@act.com", "c@act.com"])

        var item = QueueItem(p)
        #expect(item.contactCountLabel == "3 contacts")
        #expect(item.displayedContactEmails.count == 3)

        p.removeOrSuppressRecipient(id: ReplyDetection.email(from: "b@act.com"))
        ContactRefusal.refuse(email: "b@act.com", scope: .show(p.naturalKey), in: ctx)
        try ctx.save()

        item = QueueItem(p)
        #expect(item.displayedContactEmails.sorted() == ["a@act.com", "c@act.com"])
        #expect(item.contactCountLabel == "2 contacts")
    }

    // Each printed address carries whether there is a Recipient behind it, because the two are removed by
    // different routes: one has a row to take out, the other is owned by the organisation ledger. The
    // card cannot work that out for itself from a list of strings.
    @Test func eachPrintedAddressSaysWhetherItHasARowBehindIt() throws {
        let ctx = try context()
        let p = show(ctx, emails: ["a@act.com"])

        let own = QueueItem(p).displayedContactAddresses
        #expect(own.map(\.email) == ["a@act.com"])
        #expect(own.first?.recipientId == ReplyDetection.email(from: "a@act.com"))

        var inheritedItem = QueueItem(p)
        inheritedItem.contacts = []
        inheritedItem.inheritedReachability = OrgAnswerLedger.Inherited(
            result: .emailFound, probedAt: Date(timeIntervalSince1970: 1_000_000),
            organisation: "Feinstein's/54 Below", emails: ["boxoffice@54below.com"])

        let inherited = inheritedItem.displayedContactAddresses
        #expect(inherited.map(\.email) == ["boxoffice@54below.com"])
        #expect(inherited.first?.recipientId == nil)
        // The emails list stays the strings it always was, derived from the same rule rather than
        // restated, so the two can never disagree about which addresses a card shows.
        #expect(inheritedItem.displayedContactEmails == inherited.map(\.email))
    }

    // MARK: - The run

    // The removal is meant to stop the run PAYING to research and draft to the address, not merely to
    // drop what it brings home. The queue is the only thing the run reads, so the refusals ride on it.
    @Test func theWorkListTellsTheRunWhichAddressesToLeaveAlone() throws {
        let ctx = try context()
        let p = show(ctx, presenter: "Feinstein's/54 Below", emails: ["devin@devinmarlowe.example"])
        let orgKey = try #require(OrgKey.stored(for: "Feinstein's/54 Below"))

        ContactRefusal.refuse(email: "devinsbrother@example.com", scope: .show(p.naturalKey), in: ctx)
        ContactRefusal.refuse(email: "boxoffice@54below.com", scope: .organisation(orgKey), in: ctx)

        let queue = PrepQueueService.buildQueue(from: ctx, generatedAt: "2026-08-09T00:00:00Z",
                                                today: "2026-08-09",
                                                venueHistory: VenueShootHistory(shoots: [], bookings: [], today: "2026-08-09"))

        let item = try #require(queue.items.first { $0.naturalKey == p.naturalKey })
        #expect(item.refusedEmails?.sorted() == ["boxoffice@54below.com", "devinsbrother@example.com"])
    }

    // Absent, not empty, on the overwhelming majority of shows: a field present on every item would tell
    // the run to reason about a list that is almost always nothing, and the runbook is told the two mean
    // different things.
    @Test func aShowWithNoStrikesCarriesNoListAtAll() throws {
        let ctx = try context()
        let p = show(ctx)

        let queue = PrepQueueService.buildQueue(from: ctx, generatedAt: "2026-08-09T00:00:00Z",
                                                today: "2026-08-09",
                                                venueHistory: VenueShootHistory(shoots: [], bookings: [], today: "2026-08-09"))

        #expect(try #require(queue.items.first { $0.naturalKey == p.naturalKey }).refusedEmails == nil)
    }
}
