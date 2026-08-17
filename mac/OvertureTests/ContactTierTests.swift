import Testing
import Foundation
import SwiftData

// #2622: every found email scored the same, whoever it belonged to.
//
// The mechanism, measured on a live card: a show billed to one performer read "Unverified email found"
// over the only address the check had found, and that address belonged to the performer's musical
// director. An address for the person whose show it is, an address for somebody performing on it, and an
// address for that person's manager are three different findings, and Overture recorded one.
//
// LIVE-STORE-CLAIM verified=2026-08-13 measure="ZPROSPECT.ZFITSCORE over shows at reachabilityResult = email_found"
// Across the 29 shows then at `email_found`, the scores pile up either side of the high-fit line: 11 at
// exactly 4 and 5 at exactly 5. Dan's weights were chosen against that distribution rather than by feel,
// the same way #1648's were, and both directions were chosen deliberately.
@MainActor
@Suite("Who the check found (#2622)")
struct ContactTierTests {

    // MARK: the vocabulary

    @Test func thetiersRankByWhoCanSayYes() {
        #expect(ContactTier.primary.rank > ContactTier.secondary.rank)
        #expect(ContactTier.secondary.rank > ContactTier.tertiary.rank)
        #expect(ContactTier.allCases.count == 3)
    }

    // Open question 5, answered in the type: an unknown tier is nil, never a fourth case, because a
    // contact found before this shipped and one the run declined to judge are the same thing (nobody has
    // said), and both differ from a show no check has looked at, which the row's own result says.
    @Test func anunknownTierIsNilRatherThanAFourthCase() {
        #expect(ContactTier(rawValue: "unknown") == nil)
        #expect(ContactTier(rawValue: "") == nil)
        #expect(ContactTier.best(of: []) == nil)
        #expect(ContactTier.best(of: [nil, nil]) == nil)
    }

    @Test func thebestOfSeveralIsTheHighest() {
        #expect(ContactTier.best(of: [.tertiary, .primary, .secondary]) == .primary)
        #expect(ContactTier.best(of: [.tertiary, .secondary]) == .secondary)
        #expect(ContactTier.best(of: [nil, .tertiary]) == .tertiary)
    }

    // MARK: what it does to the score

    @Test func thetierDecidesWhatAFoundEmailIsWorth() {
        #expect(Ranker.contactRoutePoints(.emailFound, tier: .primary) == 3)
        #expect(Ranker.contactRoutePoints(.emailFound, tier: .secondary) == 2)
        #expect(Ranker.contactRoutePoints(.emailFound, tier: .tertiary) == -1)
    }

    // Open question 4, left honest. Every contact stored before this shipped reads as unknown, and scores
    // exactly what it scored yesterday, rather than being filled by a second definition of the rule.
    @Test func anunknownTierScoresWhatItAlwaysDid() {
        #expect(Ranker.contactRoutePoints(.emailFound, tier: nil) == 2)
        #expect(Ranker.contactRoutePoints(.emailFound) == 2)
    }

    // The tier says nothing about a show with no address: those verdicts are about whether an address
    // exists at all, and a tier cannot change that.
    @Test func thetierNeverMovesAShowWithNoAddress() {
        for route: ContactRoute in [.noEmailFound, .contactFormOnly, .socialOnly, .weakContactOnly, .unchecked] {
            for tier: ContactTier? in [nil, .primary, .secondary, .tertiary] {
                #expect(Ranker.contactRoutePoints(route, tier: tier) == Ranker.contactRoutePoints(route),
                        "\(route) moved on a \(String(describing: tier)) tier")
            }
        }
    }

    // MARK: which contact speaks for the show

    private func context() throws -> ModelContext {
        ModelContext(try ModelContainer(for: AppSchema.schema,
                                        configurations: [ModelConfiguration(isStoredInMemoryOnly: true)]))
    }

    private func show(_ ctx: ModelContext) -> Prospect {
        let p = Prospect(naturalKey: "k", groupName: "Music by Matthew Meade", discipline: "music",
                         venue: "The Green Room 42", performanceDate: "2026-10-03", sourceListingURL: nil,
                         websiteURL: nil, priorRelationship: "none", production: "self",
                         profile: "strong", coverage: "likely_uncovered", fitScore: 4, tier: "longshot",
                         fitReason: "r", matchedClientName: nil, possibleMatchSource: nil,
                         possibleMatchName: nil, status: .queued)
        ctx.insert(p)
        return p
    }

    @discardableResult
    private func contact(_ p: Prospect, _ id: String, tier: ContactTier?, email: String? = nil,
                         sendable: Bool = true) -> Recipient {
        let r = Recipient(id: id, email: email ?? "\(id)@example.test", name: id, provenance: .act)
        r.contactTier = tier
        if !sendable { r.looksLikeVenue = true }
        p.addRecipient(r)
        return r
    }

    // Dan's decision: the highest tier among the show's SENDABLE contacts.
    @Test func theshowSpeaksWithItsBestSendableContact() throws {
        let ctx = try context()
        let p = show(ctx)
        contact(p, "cast", tier: .secondary)
        contact(p, "producer", tier: .primary)
        try? ctx.save()

        #expect(p.contactTierFromRecipients == .primary)
    }

    // The first case the rule exists for: a PRIMARY contact with no address cannot lift the show. The
    // runbook emits a full contact for a named performer even when no email was verified, and Dan's
    // standing rule is that it is not a high fit if he cannot email anybody, so a person he has
    // identified and cannot write to must not score as if he could.
    @Test func aprimaryContactWithNoAddressCannotLiftTheShow() throws {
        let ctx = try context()
        let p = show(ctx)
        contact(p, "cast", tier: .secondary)
        let unreachable = contact(p, "producer", tier: .primary)
        unreachable.email = nil
        try? ctx.save()

        #expect(p.contactTierFromRecipients == .secondary)
    }

    // The second: an address a guard is holding does not set the tier either, for the same reason it does
    // not make the show emailFound.
    @Test func anaddressHeldByAGuardDoesNotSetTheTier() throws {
        let ctx = try context()
        let p = show(ctx)
        contact(p, "cast", tier: .secondary)
        contact(p, "frontdesk", tier: .primary, sendable: false)
        try? ctx.save()

        #expect(p.contactTierFromRecipients == .secondary)
        // And the badge agrees, because both read the same sendable test.
        #expect(p.reachabilityResultFromRecipients == .emailFound)
    }

    // The worked examples from the live store: a show whose five contacts are four performers and a music
    // director scores SECONDARY, and one whose only route is a manager scores TERTIARY.
    @Test func theworkedExamplesFromTheStore() throws {
        let ctx = try context()
        let performers = show(ctx)
        for i in 1...4 { contact(performers, "performer\(i)", tier: .secondary) }
        contact(performers, "md", tier: .secondary)
        try? ctx.save()
        #expect(performers.contactTierFromRecipients == .secondary)

        let viaManager = show(ctx)
        contact(viaManager, "manager", tier: .tertiary)
        try? ctx.save()
        #expect(viaManager.contactTierFromRecipients == .tertiary)
    }

    // An answer that has aged out stops lifting the show, at the same moment its route falls back to
    // unchecked, so the card and the score cannot disagree about whether an answer is current.
    @Test func astaleAnswerCarriesNoTier() throws {
        let ctx = try context()
        let p = show(ctx)
        contact(p, "producer", tier: .primary)
        p.reachabilityProbedAt = Date(timeIntervalSince1970: 1_700_000_000)
        try? ctx.save()

        let longAfter = Date(timeIntervalSince1970: 1_700_000_000 + Reachability.probeFreshness + 1)
        #expect(p.contactTierForScoring(now: longAfter) == nil)
        #expect(p.contactRouteForScoring(now: longAfter) == .unchecked)
    }
}

// #2622: the tier is WRITTEN by the run and READ by the score. Both halves, because a tier the importer
// never stores is a field with no writer, and one the score never reads is a field with no reader (L46).
@MainActor
@Suite("The tier is written by the run and read by the score (#2622)")
struct ContactTierWiringTests {

    private func context() throws -> ModelContext {
        ModelContext(try ModelContainer(for: AppSchema.schema,
                                        configurations: [ModelConfiguration(isStoredInMemoryOnly: true)]))
    }

    private func show(_ ctx: ModelContext, score: Int = 4) -> Prospect {
        let p = Prospect(naturalKey: "k", groupName: "Retreat to Broadway", discipline: "music",
                         venue: "Don't Tell Mama", performanceDate: "2026-10-03", sourceListingURL: nil,
                         websiteURL: nil, priorRelationship: "none", production: "self",
                         profile: "strong", coverage: "likely_uncovered", fitScore: score,
                         tier: "longshot", fitReason: "r", matchedClientName: nil,
                         possibleMatchSource: nil, possibleMatchName: nil, status: .queued)
        ctx.insert(p)
        try? ctx.save()
        return p
    }

    private func results(_ key: String, tier: String?) -> PrepResults {
        PrepResults(version: 9, generatedAt: "2026-08-13T00:00:00Z",
                    results: [PrepResult(naturalKey: key,
                                         contacts: [PrepContact(name: "Brian F. B. Reavey",
                                                                role: "Director and Founder",
                                                                tier: tier,
                                                                email: "brian@example.test",
                                                                method: "named_decision_maker",
                                                                confidence: "medium", provenance: "act")],
                                         draft: nil)])
    }

    @Test func therunsJudgementIsStored() throws {
        let ctx = try context()
        let p = show(ctx)

        _ = PrepImporter.ingest(results(p.naturalKey, tier: "primary"), into: ctx)

        #expect(p.recipients.first?.contactTier == .primary)
        #expect(p.contactTierFromRecipients == .primary)
    }

    // A run that says nothing leaves the contact unjudged rather than guessing, and a value this build
    // does not know reads the same way instead of putting an unexplainable tier on the row.
    @Test func arunThatSaysNothingLeavesItUnjudged() throws {
        let ctx = try context()
        let p = show(ctx)

        _ = PrepImporter.ingest(results(p.naturalKey, tier: nil), into: ctx)
        #expect(p.recipients.first?.contactTier == nil)

        _ = PrepImporter.ingest(results(p.naturalKey, tier: "headliner"), into: ctx)
        #expect(p.recipients.first?.contactTier == nil)
    }

    // A later run's judgement replaces an earlier one; a later run that is silent leaves it standing, so a
    // re-check that only corrects an address cannot erase who the contact was judged to be.
    @Test func alaterRunCorrectsTheJudgementAndSilenceDoesNot() throws {
        let ctx = try context()
        let p = show(ctx)

        _ = PrepImporter.ingest(results(p.naturalKey, tier: "secondary"), into: ctx)
        _ = PrepImporter.ingest(results(p.naturalKey, tier: "primary"), into: ctx)
        #expect(p.recipients.first?.contactTier == .primary)

        _ = PrepImporter.ingest(results(p.naturalKey, tier: nil), into: ctx)
        #expect(p.recipients.first?.contactTier == .primary)
    }

    // THE reader: the show's stored score moves when the check finds somebody who can say yes. This is one
    // of the four shows the measurement says should be promoted into high fit.
    @Test func findingSomebodyWhoCanSayYesLiftsTheStoredScore() throws {
        let ctx = try context()
        let p = show(ctx)
        _ = PrepImporter.ingest(results(p.naturalKey, tier: "primary"), into: ctx)
        p.reachabilityProbedAt = Date()
        p.reachabilityResult = p.reachabilityResultFromRecipients

        // Measured as the DIFFERENCE the tier makes to the same row, not against the seeded score: the
        // settle is a full re-score from the row's own classification, so "before plus three" would be
        // asserting arithmetic on a number this deliberately never does arithmetic on.
        let asPrimary = ClassificationOverride.rescored(p, now: Date()).score
        p.recipients.first?.contactTier = nil
        let asUnknown = ClassificationOverride.rescored(p, now: Date()).score
        #expect(asPrimary == asUnknown + 1, "finding somebody who can say yes is worth one point")
        p.recipients.first?.contactTier = .primary

        #expect(ContactScoreAdjustment.settle(p, now: Date()))

        #expect(p.fitScore == asPrimary)
        #expect(p.contactTierAtScore == "primary")
    }

    // The case the settle would otherwise miss entirely: a re-check that returns the same ROUTE and a
    // different person. Without the tier in the comparison the row keeps yesterday's score forever while
    // the card shows today's contact.
    @Test func asecondCheckThatFindsABetterContactRescoresTheRow() throws {
        let ctx = try context()
        let p = show(ctx)
        _ = PrepImporter.ingest(results(p.naturalKey, tier: "tertiary"), into: ctx)
        p.reachabilityProbedAt = Date()
        p.reachabilityResult = p.reachabilityResultFromRecipients
        _ = ContactScoreAdjustment.settle(p, now: Date())
        let afterTheManager = p.fitScore

        _ = PrepImporter.ingest(results(p.naturalKey, tier: "primary"), into: ctx)
        p.reachabilityResult = p.reachabilityResultFromRecipients

        #expect(ContactScoreAdjustment.settle(p, now: Date()), "the route did not move, so nothing rescored")
        #expect(p.fitScore == afterTheManager + 4)   // -1 becomes +3
    }

    // Failure path: settling twice must not move the score twice. It is a RE-SCORE from the row, never
    // arithmetic on the stored number, and the tier must not break that.
    @Test func settlingTwiceChangesNothingTheSecondTime() throws {
        let ctx = try context()
        let p = show(ctx)
        _ = PrepImporter.ingest(results(p.naturalKey, tier: "primary"), into: ctx)
        p.reachabilityProbedAt = Date()
        p.reachabilityResult = p.reachabilityResultFromRecipients

        _ = ContactScoreAdjustment.settle(p, now: Date())
        let settled = p.fitScore

        #expect(!ContactScoreAdjustment.settle(p, now: Date()))
        #expect(p.fitScore == settled)
    }
}
