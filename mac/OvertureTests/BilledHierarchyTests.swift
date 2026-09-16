import Testing
import Foundation
import SwiftData

// #3347 and #2258, the two halves of one mistake: the run ranking people against something other than
// how the show BILLS them.
//
// #2258 is a run failing to rank the billed leads at all, so a variety bill's fifteen cast members and
// its producer sat in one flat pool and whoever happened to publish an email reached the card. #3347 is
// the mirror: on one 2026-08-30 show the run emitted TWO people with the identical role string
// "Producer and performer" at `tier: "primary"`, while the page bills both of them under a bare
// `Featuring:` and credits neither as producing anything. The names below are STAND-INS of the same
// shape: the real ones are performers on a real show and this repository is public (L155, L222).
//
// `primary` is defined in `docs/prep-runbook.md` as whoever could actually hire Dan, and it moves a show
// up into what Dan looks at first, so a guessed one is worse than none.
//
// WHY THIS SIGNAL AND NOT THE ONE #3347 PROPOSED. The issue suggests treating an identical role string
// emitted for two people as the tell. Measured across every archived run on this Mac, 2026-09-06: 20 of
// 68 show-answers with two or more contacts share a role string, and 6 have more than one contact at
// `primary` sharing one. At least half of those six are real co-producing pairs, and the listing says so
// ("Directed and produced by Sydney Ciencin and Piper Redford"), so that rule fires on the ordinary case
// and would be switched off within a day (L93).
//
// The signal that discriminates is the one #2258 names, the BILLED HIERARCHY, and it was measured the
// same way: of 108 `primary` contacts across the paired archives, exactly TWO are named on the listing
// only after a cast marker and in no credit clause, and those two are Marlowe Fenn and Rennick Slade.
@MainActor
@Suite("Billed as cast, ranked as a decision maker (#3347, #2258)")
struct BilledHierarchyTests {

    // The measured case, in the page's own SHAPE. The names are stand-ins: the real ones are performers
    // on a real show and this repository is public, and what the rule turns on is where a name sits
    // relative to a cast marker and a credit clause, never who it is (L155, L222).
    private let chillsAndThrills = """
        An Evening of Chills and Thrills. An evening of songs from stage and screen.
        Featuring: Marlowe Fenn Rennick Slade Music Director Corwin T. Hale
        Genre Variety Shows Duration 75 minutes
        """

    @Test func somebodyBilledOnlyUnderFeaturingIsNotCredited() {
        #expect(BilledHierarchy.billedAsCastOnly(name: "Marlowe Fenn",
                                                 inListingText: chillsAndThrills))
        #expect(BilledHierarchy.billedAsCastOnly(name: "Rennick Slade",
                                                 inListingText: chillsAndThrills))
    }

    // The other side of the same page, and the reason this cannot be a rule about the marker alone: the
    // page separates who is IN CHARGE from the cast, and the run is meant to read that separation. Here
    // the producer is credited before the cast marker.
    @Test func somebodyCreditedAboveTheCastListIsNotCastOnly() {
        let page = """
            Produced by Odalie Prentiss, with music direction by Nadim Ashcroft.
            Featuring: Tamsin Croy, Ilo Bekker, Marguerite Vane, Pell Dorrance, Sable Quist.
            """
        #expect(!BilledHierarchy.billedAsCastOnly(name: "Odalie Prentiss", inListingText: page))
        #expect(BilledHierarchy.billedAsCastOnly(name: "Pell Dorrance", inListingText: page))
    }

    // A credit that names somebody AFTER the cast marker still credits them, and this is the case that
    // makes the rule about the credit rather than about position. Measured on the live corpus: 54 Below
    // pages routinely run the credits below the cast.
    @Test func aCreditAfterTheCastListStillCounts() {
        let page = """
            An evening of new songs.
            Featuring: Ada Fenwick, Ruben Oyelaran, Mira Vance.
            Produced and directed by Mira Vance.
            """
        #expect(!BilledHierarchy.billedAsCastOnly(name: "Mira Vance", inListingText: page))
        #expect(BilledHierarchy.billedAsCastOnly(name: "Ada Fenwick", inListingText: page))
    }

    // Every way the question is UNANSWERABLE comes back false, which is the fail-safe direction and the
    // one that decides whether this can ever be trusted as a hold-down. Reading any of these as "billed
    // as cast" would overrule a tier on the strength of a page nobody read (L98, L11, L93).
    @Test func anythingItCannotJudgeIsNotAnAccusation() {
        // No listing at all: most items carry one, but a show whose page did not render carries none.
        #expect(!BilledHierarchy.billedAsCastOnly(name: "Marlowe Fenn", inListingText: nil))
        #expect(!BilledHierarchy.billedAsCastOnly(name: "Marlowe Fenn", inListingText: ""))
        // No name to look for.
        #expect(!BilledHierarchy.billedAsCastOnly(name: nil, inListingText: chillsAndThrills))
        #expect(!BilledHierarchy.billedAsCastOnly(name: "  ", inListingText: chillsAndThrills))
        // A page that draws no hierarchy at all is #2258's fourth case, where nothing changes.
        #expect(!BilledHierarchy.billedAsCastOnly(
            name: "Marlowe Fenn",
            inListingText: "An evening with Marlowe Fenn and friends at the piano."))
        // A person the page does not name: the run found them somewhere else, so the listing says
        // nothing about how they are billed.
        #expect(!BilledHierarchy.billedAsCastOnly(name: "Nobody Here",
                                                  inListingText: chillsAndThrills))
    }

    // A name appearing BOTH above and below the marker is credited, not cast only. Judged over EVERY
    // occurrence rather than the first, because a page that credits somebody and then lists them in the
    // cast is the ordinary shape for a self-producing performer, which is the single most valuable
    // contact Overture can find.
    @Test func aSelfProducingPerformerIsNotCastOnly() {
        let page = """
            Produced by Marlowe Fenn.
            Featuring: Marlowe Fenn, Rennick Slade.
            """
        #expect(!BilledHierarchy.billedAsCastOnly(name: "Marlowe Fenn", inListingText: page))
        #expect(BilledHierarchy.billedAsCastOnly(name: "Rennick Slade", inListingText: page))
    }

    // MARK: - #2625: an address with nobody behind it

    // A tier is an answer to "who could hire Dan", and a bare shared inbox with no person attached is
    // genuinely unanswerable on it. Measured across every archived run, 2026-09-06: 22 of 447 contacts
    // carry no name, and THIRTEEN of those 22 carry `primary`, every one a `generic_inbox`. So the
    // strongest available claim was being made about the weakest available finding, on 13 real shows.
    //
    // Dan's call, 2026-09-06, shown that measurement and that it moves those shows down his queue: no
    // tier at all, which is what `ContactTier` already means by nil (nobody has said who this is) and is
    // exactly true here. Not a fourth case and not a default (L113).
    @Test func aTierOnAnAddressWithNoNameIsNotAnAnswer() {
        #expect(BilledHierarchy.tierIsAnswerable(name: "Odalie Prentiss"))
        #expect(!BilledHierarchy.tierIsAnswerable(name: nil))
        #expect(!BilledHierarchy.tierIsAnswerable(name: ""))
        #expect(!BilledHierarchy.tierIsAnswerable(name: "   "))
    }

    // MARK: - Wired, not merely built (L3)

    private func context() throws -> ModelContext {
        ModelContext(try ModelContainer(for: AppSchema.schema,
                                        configurations: [ModelConfiguration(isStoredInMemoryOnly: true)]))
    }

    @discardableResult
    private func show(_ ctx: ModelContext) -> Prospect {
        let key = Prospect.makeNaturalKey(groupName: "An Evening of Chills and Thrills",
                                          performanceDate: "2027-09-07", venue: "The Green Room 42")
        let p = Prospect(naturalKey: key, groupName: "An Evening of Chills and Thrills",
                         discipline: "music", venue: "The Green Room 42",
                         performanceDate: "2027-09-07", sourceListingURL: nil, priorRelationship: "none",
                         production: "self", profile: "strong", coverage: "likely_uncovered",
                         fitScore: 6, tier: "mid", fitReason: "r", matchedClientName: nil,
                         possibleMatchSource: nil, possibleMatchName: nil, status: .queued)
        ctx.insert(p)
        try? ctx.save()
        return p
    }

    private func results(_ key: String) -> PrepResults {
        PrepResults(version: 11, generatedAt: "2027-09-01T00:00:00Z",
                    results: [PrepResult(naturalKey: key, contacts: [
                        PrepContact(name: "Marlowe Fenn", role: "Producer and performer",
                                    tier: "primary", email: "marlowe@marlowefenn.example",
                                    method: "named_decision_maker", confidence: "medium",
                                    provenance: "performer"),
                    ])])
    }

    // The rank the page does not support never reaches the row. Proven by deleting the call in
    // `PrepImporter.supportedTier` and watching this go red: the rule is pure and its own tests would
    // stay entirely green while nothing in the app ever asked it.
    @Test func aPrimaryTheListingContradictsDoesNotReachTheRow() throws {
        let ctx = try context()
        let p = show(ctx)
        let listing = ShowListing(status: ShowListing.read, url: "https://example.org/chills",
                                  text: chillsAndThrills)

        PrepImporter.ingest(results(p.naturalKey), into: ctx, isProbe: true,
                            listings: [p.naturalKey: listing])

        let contact = try #require(p.recipients.first)
        #expect(contact.name == "Marlowe Fenn")
        #expect(contact.contactTierRaw == nil,
                Comment(rawValue: "the page bills her only under Featuring and credits nobody, so the "
                        + "primary rank was carried across from somewhere other than this show"))
    }

    // #2625: and a tier about nobody never reaches the row either, on a show whose page says nothing
    // at all. Wired, not merely built: the predicate is pure and its own tests would stay green
    // while nothing in the app asked it (L3).
    @Test func aTierAboutNobodyDoesNotReachTheRow() throws {
        let ctx = try context()
        let p = show(ctx)
        var nameless = PrepContact()
        nameless.tier = "primary"
        nameless.method = "generic_inbox"
        nameless.confidence = "medium"
        nameless.provenance = "presenter"
        nameless.email = "info@marlowefenn.example"
        PrepImporter.ingest(
            PrepResults(version: 11, generatedAt: "2027-09-01T00:00:00Z",
                        results: [PrepResult(naturalKey: p.naturalKey, contacts: [nameless])]),
            into: ctx, isProbe: true)
        let contact = try #require(p.recipients.first)
        #expect(contact.name == nil)
        #expect(contact.contactTierRaw == nil, Comment(rawValue:
            "a shared inbox with nobody behind it was ranked as somebody who could hire Dan, and "
            + "that rank lifts the show up the queue"))
    }

    // With NO page handed over, the run's judgement stands untouched. This is the half that decides
    // whether the guard is safe to ship: a caller with no work-list must never overrule a run on the
    // strength of a page it never read (L98).
    @Test func aRunWithNoPageToJudgeAgainstKeepsItsOwnTier() throws {
        let ctx = try context()
        let p = show(ctx)
        PrepImporter.ingest(results(p.naturalKey), into: ctx, isProbe: true)
        #expect(try #require(p.recipients.first).contactTierRaw == "primary")
    }

    // A credit for SOMEBODY ELSE that this name merely follows is not a credit for this name. The
    // separator here is a sentence end rather than a cast marker, which is the case a rule that only
    // looked for the marker would miss: without it the second name reads as credited by the sentence
    // above it, and a cast member keeps a `primary` rank on the strength of somebody else's credit.
    // Found by mutation: deleting the sentence-end check left every other test green, because they all
    // happened to have a cast marker in the gap as well (L178).
    @Test func aCreditForSomebodyElseDoesNotReachTheNameThatFollowsIt() {
        let page = """
            Featuring: Tamsin Croy, Ilo Bekker.
            Produced by Odalie Prentiss. Ilo Bekker also arranges.
            """
        #expect(!BilledHierarchy.billedAsCastOnly(name: "Odalie Prentiss", inListingText: page))
        #expect(BilledHierarchy.billedAsCastOnly(name: "Ilo Bekker", inListingText: page))
    }

    // A truncated page cannot support this any more than it can support a finished negative (#2698): the
    // credit is often the last block on a listing, which is exactly what a cut removes, so a name that
    // appears only in the cast on a page that was cut says nothing about whether it was also credited.
    @Test func aTruncatedPageIsNeverEnoughToOverruleATier() {
        #expect(!BilledHierarchy.billedAsCastOnly(name: "Marlowe Fenn",
                                                  inListingText: chillsAndThrills, truncated: true))
    }
}
