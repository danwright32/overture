import Testing
import Foundation
import SwiftData

// #2657: a check can return a full list of contacts and still have reached nobody who could hire Dan,
// and the card said the same thing either way.
//
// "54 Sings Shuffle Along, Or... A 10th Anniversary Celebration" (54 Below, 2026-08-17), checked
// 2026-08-13, returned 13 contacts. Every one was a co-performer, every one honestly tiered `secondary`.
// The producer and director credited on the listing was never a target (#2554). The card wore the gold
// "Email found" pill and "13 contacts", which is exactly what it shows for a check that reached the
// person whose show it is. Dan read that card, went to the listing himself, and found the producer's
// contact page in seconds.
//
// This is NOT #2641, which catches a run that IGNORES the tier instruction and leaves the field missing.
// This run honoured it perfectly on all 13, and the honesty was invisible: `ContactTier.best(of:)`
// already computed the number and nothing on the card read it back (L46, a value with a writer and no
// reader).
@MainActor
@Suite("A check that reached nobody with authority says so (#2657)")
struct NoAuthorityReachedTests {

    private func container() throws -> ModelContainer {
        try ModelContainer(for: Schema([Prospect.self, Recipient.self]),
                           configurations: [ModelConfiguration(isStoredInMemoryOnly: true)])
    }

    private func show(_ ctx: ModelContext) -> Prospect {
        let p = Prospect(naturalKey: "k", groupName: "54 Sings Shuffle Along", discipline: "theater",
                         venue: "54 Below", performanceDate: "2026-08-17", sourceListingURL: nil, priorRelationship: "none", production: "unknown",
                         profile: "neutral", coverage: "unknown", fitScore: 5, tier: "mid",
                         fitReason: "", matchedClientName: nil, possibleMatchSource: nil,
                         possibleMatchName: nil, status: .new)
        ctx.insert(p)
        return p
    }

    private func contact(_ email: String, _ tier: ContactTier?) -> Recipient {
        let r = Recipient(id: email, email: email, name: "Someone", provenance: .performer)
        r.contactConfidence = .high
        r.contactTier = tier
        return r
    }

    // The case the gate exists for: the runbook emits a full contact for a named performer even when no
    // address was verified, so a contact can carry a tier and no way to write to them.
    private func addresslessContact(_ id: String, _ tier: ContactTier?) -> Recipient {
        let r = Recipient(id: id, email: nil, name: "Someone", provenance: .performer)
        r.contactTier = tier
        return r
    }

    private func item(_ ctx: ModelContext, _ recipients: [Recipient]) -> QueueItem {
        let p = show(ctx)
        p.setRecipients(recipients)
        p.reachabilityResult = .emailFound
        p.reachabilityProbedAt = Date()
        return QueueItem(p)
    }

    // MARK: - The case the issue was filed for

    // Thirteen co-performers and no producer. The card has to say so, in words that tell Dan what he is
    // looking at rather than in a number that reads like thirteen ways in.
    @Test func aListOfPerformersWithNoProducerIsNamedAsSuch() throws {
        let i = item(ModelContext(try container()),
                     [contact("a@example.com", .secondary), contact("b@example.com", .secondary)])
        #expect(i.contactAuthorityGap() == .secondary)
    }

    // The finding that makes the warning worth having: it says nothing at all when the check DID reach
    // the person whose show it is, even alongside a crowd of co-performers. One primary is enough,
    // exactly as one verified address is enough to keep the plain badge in #1628.
    @Test func oneProducerAmongTheCastSilencesIt() throws {
        let i = item(ModelContext(try container()),
                     [contact("cast@example.com", .secondary), contact("producer@example.com", .primary),
                      contact("more@example.com", .secondary)])
        #expect(i.contactAuthorityGap() == nil)
    }

    // A manager or agent is its own answer and its own sentence: it may well get Dan a reply, but nobody
    // who owns the show was reached, so it is not silence and it is not the performers case either.
    @Test func aRepresentativeOnlyIsItsOwnAnswer() throws {
        let i = item(ModelContext(try container()), [contact("agency@example.com", .tertiary)])
        #expect(i.contactAuthorityGap() == .tertiary)
    }

    // MARK: - Absent is not weak

    // The rule that stops this lighting up most of the existing store for no reason. A contact found
    // before #2622 shipped carries no tier, and unknown is not the same claim as "somebody without
    // authority". Saying nothing is the honest answer, and it is what `ContactTier.best(of:)` already
    // encodes by returning nil rather than a fourth case.
    @Test func aContactWithNoStoredTierRaisesNothing() throws {
        let i = item(ModelContext(try container()),
                     [contact("older@example.com", nil), contact("older2@example.com", nil)])
        #expect(i.contactAuthorityGap() == nil)
    }

    // And a mixed row answers from what it KNOWS. An untiered contact beside a tiered one cannot be
    // counted as evidence in either direction, so the answer comes from the tiers that exist.
    @Test func anUntieredContactBesideATieredOneDoesNotChangeTheAnswer() throws {
        let ctx = ModelContext(try container())
        let i = item(ctx, [contact("older@example.com", nil), contact("cast@example.com", .secondary)])
        #expect(i.contactAuthorityGap() == .secondary)
    }

    // The two states that already exist must be untouched: no check has run, and a check ran and found
    // nothing. Neither has a contact to judge, so neither may wear this.
    @Test func aShowWithNoContactsSaysNothing() throws {
        let i = item(ModelContext(try container()), [])
        #expect(i.contactAuthorityGap() == nil)
    }

    // The gate, and it is not a detail. The runbook emits a full contact for a named performer even when
    // no address was verified, so a tier can sit on a show whose badge says nobody was found to write to.
    // Printed under that badge this note would be a second negative saying less than the first (L118), and
    // "Only a venue or press address" is already this warning in its own words.
    @Test func itIsSilentUnderEveryBadgeThatIsNotAFind() throws {
        let ctx = ModelContext(try container())

        // A tiered performer with no address at all. The badge here says nobody was found to write to,
        // and this note under it would be a second negative saying less than the first.
        let nothingToWriteTo = item(ctx, [addresslessContact("cast", .secondary)])
        #expect(nothingToWriteTo.reachabilityBadge() == .noEmailFound)
        #expect(nothingToWriteTo.contactAuthorityGap() == nil)

        // The same shape with a form and with a social profile: both are routes the badge already
        // qualifies in its own words, so this adds nothing to either.
        for route in ["https://example.com/contact", "https://instagram.com/someact"] {
            let r = addresslessContact(route, .secondary)
            r.contactFormURL = route
            let i = item(ctx, [r])
            #expect(i.reachabilityBadge() != .emailFound)
            #expect(i.contactAuthorityGap() == nil, "spoke under \(i.reachabilityBadge())")
        }

        // And an address held by a guard, which already reads "Only a venue or press address": this
        // warning in its own words.
        let held = contact("frontdesk@54below.example", .secondary)
        held.looksLikeVenue = true
        let weak = item(ctx, [held])
        #expect(weak.reachabilityBadge() == .weakContactOnly)
        #expect(weak.contactAuthorityGap() == nil)
    }

    // MARK: - The words

    // One badge, two sentences: the #1722 rule this file already follows for the weak-contact and
    // unverified badges. Same wording, same tone, same position, so the card does not get louder; only
    // the explanation says which of the two situations Dan is in.
    @Test func bothAnswersWearTheSameBadgeAndExplainThemselvesDifferently() {
        #expect(ReachabilityCopy.noAuthorityBadge == "Nobody who can hire you")
        let performers = ReachabilityCopy.noAuthorityHelp(tier: .secondary)
        let representatives = ReachabilityCopy.noAuthorityHelp(tier: .tertiary)
        #expect(performers != representatives)
        // Each names WHO was found, since that is the fact that tells Dan what the list is worth.
        #expect(performers.contains("music director"))
        #expect(representatives.contains("agent"))
        // And each ends somewhere Dan can go, rather than naming a fault with no way out (L80).
        #expect(performers.contains("credits"))
        #expect(representatives.contains("credits"))
    }

    // MARK: - It reaches the card

    // The wiring, not just the rule: the value has to survive the snapshot the row actually renders from,
    // which is where #2623's own attribution work had to go too. Without this the rule is correct and the
    // screen never sees it.
    @Test func theTierSurvivesTheSnapshotTheRowRendersFrom() throws {
        let ctx = ModelContext(try container())
        let p = show(ctx)
        p.setRecipients([contact("cast@example.com", .secondary)])
        p.reachabilityResult = .emailFound
        p.reachabilityProbedAt = Date()
        let snapshot = QueueItem(p).contacts.first
        #expect(snapshot?.contactTier == .secondary)
    }
}
