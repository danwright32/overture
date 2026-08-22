import Testing
import Foundation
import SwiftData

// #2895: a named performer could reach `high` off a page that names no show.
//
// Measured on the live store 2026-08-17 (identities redacted, L155): a card credited a named performer as
// "Playwright" at `high`, `named_decision_maker`, provenance `performer`, citing their own portfolio site.
// That page describes them as "an actor and writer", contains the word "playwright" exactly once inside
// the NAME OF A THEATRE in an unrelated regional credit, and never mentions this show, this venue or this
// festival at all. The address IS on the page, so the address-against-page check #2269 proposes would have
// passed it clean.
//
// The claim happened to be true: an independent trade announcement does credit that person as the writer.
// That is the reassuring case and it is why the class survives. What was recorded was a correct conclusion
// with the wrong evidence behind it, on a route that would have recorded an incorrect one identically, and
// the next step after the card is an outbound pitch under Dan's name addressing a stranger by a role
// Overture asserted (L161).
//
// The runbook has always said the rule (`docs/prep-runbook.md`, the STRICT verification block): "For a
// named performer specifically, only use `high` if the source page corroborates that person against THIS
// SPECIFIC performance". Nothing enforced it, which is the same gap #1856 closed for the citation itself
// (L27, a rule that lives only in a prompt is a hope).
//
// PERFORMER ONLY, because the runbook's own rule is performer-only. `ContactConfidenceGuard`'s citation
// rule is applied to every contact for the opposite reason, that the runbook states IT universally, and
// the guard exists to enforce the runbook deterministically rather than to invent a stricter one.
@MainActor
@Suite("A performer's citation has to corroborate the performance (#2895)")
struct PerformerCitationCorroboratesTests {
    private let page = "https://performer.example/about"

    // MARK: the rule

    // THE case. The run said high, named a page, and declared the page does not tie this person to this
    // performance. It may not be stored as verified.
    @Test func aperformerWhoseCitedPageDoesNotCorroborateCannotBeHigh() {
        let stored = ContactConfidenceGuard.confidence(raw: "high", sourceURL: page,
                                                       provenance: "performer",
                                                       performanceCorroborated: false)
        #expect(stored == "low")
    }

    @Test func aperformerWhoseCitedPageDoesCorroborateStaysHigh() {
        #expect(ContactConfidenceGuard.confidence(raw: "high", sourceURL: page,
                                                  provenance: "performer",
                                                  performanceCorroborated: true) == "high")
    }

    // Dan's call, 2026-08-21: silence reads as "nobody has said", exactly as #2912 chose for
    // `nameMatchOnly`. Nothing already in his queue moves, and the check works on the runs that declare it.
    // The cost is that it stays dormant until runs do, which `PerformerCorroborationAdoption` measures
    // rather than leaving to be discovered (L128).
    @Test func arunThatSaidNothingChangesNothing() {
        #expect(ContactConfidenceGuard.confidence(raw: "high", sourceURL: page,
                                                  provenance: "performer",
                                                  performanceCorroborated: nil) == "high")
    }

    // Not a performer, so not this rule. A presenter or an act cited against its own page is a different
    // claim: the organisation IS the target, where a named individual appears on many bills.
    @Test func anonPerformerIsNotJudgedByThisRule() {
        for provenance: String? in ["act", "presenter", nil] {
            #expect(ContactConfidenceGuard.confidence(raw: "high", sourceURL: page,
                                                      provenance: provenance,
                                                      performanceCorroborated: false) == "high",
                    "provenance \(provenance ?? "nil") is not what the runbook's rule is about")
        }
    }

    // It never UPGRADES. A run's own `low` is its judgement and this has no business improving it.
    @Test func itneverUpgrades() {
        for raw in ["low", "medium"] {
            #expect(ContactConfidenceGuard.confidence(raw: raw, sourceURL: page, provenance: "performer",
                                                      performanceCorroborated: true) == raw)
        }
        #expect(ContactConfidenceGuard.confidence(raw: nil, sourceURL: page, provenance: "performer",
                                                  performanceCorroborated: true) == nil)
    }

    // The older rules are untouched and still fire, so this one is not carrying them and they are not
    // carrying it.
    @Test func theolderRulesStillHold() {
        // #1856: high with no page cited is still low, corroborated or not.
        #expect(ContactConfidenceGuard.confidence(raw: "high", sourceURL: nil, provenance: "performer",
                                                  performanceCorroborated: true) == "low")
        // #2912: a declared name match is still low, whatever page it cites.
        #expect(ContactConfidenceGuard.confidence(raw: "high", sourceURL: page, nameMatchOnly: true,
                                                  provenance: "performer",
                                                  performanceCorroborated: true) == "low")
    }

    // MARK: which rule fired

    // #1866 recorded that the guard MOVED the answer, because "unverified" alone could not tell Dan
    // whether the check was unsure or whether Overture overruled a sure one. There are two ways to be
    // overruled now, they ask different things of him, and one sentence cannot honestly cover both
    // (L11). So the record says WHICH.
    @Test func theholdDownSaysWhichRuleFired() {
        #expect(ContactConfidenceGuard.holdDown(raw: "high", sourceURL: nil) == .namedNoPage)
        #expect(ContactConfidenceGuard.holdDown(raw: "high", sourceURL: page, provenance: "performer",
                                                performanceCorroborated: false) == .pageDoesNotCorroborate)
        #expect(ContactConfidenceGuard.holdDown(raw: "high", sourceURL: page, provenance: "performer",
                                                performanceCorroborated: true) == nil)
        #expect(ContactConfidenceGuard.holdDown(raw: "low", sourceURL: nil) == nil)
    }

    // A declared name match is deliberately NOT a hold-down, unchanged from #2912: the card says that in
    // its own words, from its own field, and folding it in here would give one record two meanings.
    @Test func adeclaredNameMatchIsStillNotAheldDown() {
        #expect(ContactConfidenceGuard.holdDown(raw: "high", sourceURL: page, nameMatchOnly: true) == nil)
    }

    // Every reason the record can hold has a sentence of its own, and no two are the same words. A
    // vocabulary whose entries share one message is a distinction that is real in the code and collapses
    // on screen (#843).
    @Test func everyReasonHasItsOwnSentence() {
        let sentences = ContactConfidenceGuard.HoldDown.allCases
            .map { ReachabilityCopy.confidenceHeldDownHelp($0) }
        #expect(Set(sentences).count == ContactConfidenceGuard.HoldDown.allCases.count)
        for sentence in sentences { #expect(sentence.isEmpty == false) }
    }

    // A row stored BEFORE this shipped carries no reason, and there was exactly one reason then, so the
    // fallback is a fact about the code that wrote those rows rather than a guess about them (L90).
    @Test func arowWithNoRecordedReasonReadsAsTheOnlyReasonThatExistedThen() {
        let noReason: ContactConfidenceGuard.HoldDown? = nil
        #expect(ReachabilityCopy.confidenceHeldDownHelp(noReason)
                == ReachabilityCopy.confidenceHeldDownHelp(.namedNoPage))
    }

    // MARK: through the real ingest, to the card

    private func container() throws -> ModelContainer {
        try ModelContainer(for: Schema([Prospect.self, Recipient.self]),
                           configurations: [ModelConfiguration(isStoredInMemoryOnly: true)])
    }

    private func keptProspect(_ ctx: ModelContext, group: String, venue: String) -> String {
        let key = Prospect.makeNaturalKey(groupName: group, performanceDate: "2026-11-14", venue: venue)
        let p = Prospect(naturalKey: key, groupName: group, discipline: "theatre", venue: venue,
                         performanceDate: "2026-11-14", sourceListingURL: nil, websiteURL: nil,
                         priorRelationship: "none", production: "self", profile: "strong",
                         coverage: "likely_uncovered", fitScore: 7, tier: "high", fitReason: "r",
                         matchedClientName: nil, possibleMatchSource: nil, possibleMatchName: nil,
                         status: .queued)
        ctx.insert(p)
        try? ctx.save()
        return key
    }

    private func prospect(_ ctx: ModelContext, key: String) throws -> Prospect? {
        try ctx.fetch(FetchDescriptor<Prospect>(predicate: #Predicate { $0.naturalKey == key })).first
    }

    private func performer(_ email: String, corroborated: Bool?) -> PrepContact {
        PrepContact(name: "Robin Vale", role: "Playwright", email: email,
                    method: "named_decision_maker", confidence: "high", formUrl: nil,
                    provenance: "performer", sourceUrl: "https://robinvale.example/about",
                    performanceCorroborated: corroborated)
    }

    // The whole chain, through the real importer: what the run emitted, what got stored, what the card
    // reads. A rule proved only on the pure function is a rule nothing feeds (L3).
    @Test func adeclaredNonCorroborationReachesTheStoredRow() throws {
        let ctx = ModelContext(try container())
        let key = keptProspect(ctx, group: "Robin Vale", venue: "East Village Playhouse")
        _ = PrepImporter.ingest(PrepResults(version: 6, generatedAt: "now", results: [
            PrepResult(naturalKey: key, contacts: [performer("robin@robinvale.example", corroborated: false)])
        ]), into: ctx)

        let r = try #require(try prospect(ctx, key: key)?.recipients.first)
        #expect(r.contactConfidence != .high, "the run said high off a page that establishes nobody")
        #expect(r.heldDownToUnverified)
        #expect(r.heldDownReason == .pageDoesNotCorroborate)
    }

    @Test func acorroboratedPerformerIsStoredVerified() throws {
        let ctx = ModelContext(try container())
        let key = keptProspect(ctx, group: "Robin Vale", venue: "East Village Playhouse")
        _ = PrepImporter.ingest(PrepResults(version: 6, generatedAt: "now", results: [
            PrepResult(naturalKey: key, contacts: [performer("robin@robinvale.example", corroborated: true)])
        ]), into: ctx)

        let r = try #require(try prospect(ctx, key: key)?.recipients.first)
        #expect(r.contactConfidence == .high)
        #expect(r.heldDownToUnverified == false)
        #expect(r.heldDownReason == nil)
    }

    // The card's sentence. Same badge, same tone, same position: only the hover differs, which is the
    // #1722 rule #1866 already follows.
    @Test func thecardSaysWhichRuleHeldTheRowDown() throws {
        let ctx = ModelContext(try container())
        let key = keptProspect(ctx, group: "Robin Vale", venue: "East Village Playhouse")
        _ = PrepImporter.ingest(PrepResults(version: 6, generatedAt: "now", results: [
            PrepResult(naturalKey: key, contacts: [performer("robin@robinvale.example", corroborated: false)])
        ]), into: ctx)

        let item = QueueItem(try #require(try prospect(ctx, key: key)))
        #expect(item.onlyUnverifiedEmailsFound)
        #expect(item.unverifiedBecauseAGuardHeldItDown)
        #expect(item.heldDownReasonForTheWholeRow == .pageDoesNotCorroborate)
        #expect(ReachabilityCopy.unverifiedEmailFoundHelp(heldDown: true,
                                                          reason: item.heldDownReasonForTheWholeRow)
                == ReachabilityCopy.citationDoesNotCorroborateHelp)
    }

    // A row holding BOTH kinds keeps the general sentence. This badge speaks for the whole card, so naming
    // one reason over a mixed row would be a true statement about half of what Dan is looking at, which is
    // exactly how the previous wording came to say "this one" about a list (#1866).
    @Test func amixedRowKeepsTheGeneralSentence() throws {
        let ctx = ModelContext(try container())
        let key = keptProspect(ctx, group: "Robin Vale", venue: "East Village Playhouse")
        _ = PrepImporter.ingest(PrepResults(version: 6, generatedAt: "now", results: [
            PrepResult(naturalKey: key, contacts: [
                performer("robin@robinvale.example", corroborated: false),
                PrepContact(name: "Roan Petrie", role: nil, email: "sam@ensemble.example",
                            method: "named_decision_maker", confidence: "high", formUrl: nil,
                            provenance: "act", sourceUrl: nil),
            ])
        ]), into: ctx)

        let item = QueueItem(try #require(try prospect(ctx, key: key)))
        #expect(item.unverifiedBecauseAGuardHeldItDown, "both are held down, so the badge still speaks")
        #expect(item.heldDownReasonForTheWholeRow == nil, "two reasons, so neither may speak for the row")
        #expect(ReachabilityCopy.unverifiedEmailFoundHelp(heldDown: true, reason: nil)
                == ReachabilityCopy.confidenceHeldDownHelp)
    }

    // A row of ONLY the older kind is unchanged, which is what says this did not repaint the queue.
    @Test func arowHeldDownForNamingNoPageIsUnchanged() throws {
        let ctx = ModelContext(try container())
        let key = keptProspect(ctx, group: "Robin Vale", venue: "East Village Playhouse")
        _ = PrepImporter.ingest(PrepResults(version: 6, generatedAt: "now", results: [
            PrepResult(naturalKey: key, contacts: [
                PrepContact(name: "Roan Petrie", role: nil, email: "sam@ensemble.example",
                            method: "named_decision_maker", confidence: "high", formUrl: nil,
                            provenance: "act", sourceUrl: nil),
            ])
        ]), into: ctx)

        let item = QueueItem(try #require(try prospect(ctx, key: key)))
        #expect(item.heldDownReasonForTheWholeRow == .namedNoPage)
        #expect(ReachabilityCopy.unverifiedEmailFoundHelp(heldDown: true,
                                                          reason: item.heldDownReasonForTheWholeRow)
                == ReachabilityCopy.confidenceHeldDownHelp)
    }

    // A later run that DOES corroborate clears it, because the record is re-derived on every ingest and
    // never latched. Without that a row could carry a stale accusation for ever (#1866's own rule).
    @Test func alaterCorroboratingRunClearsIt() throws {
        let ctx = ModelContext(try container())
        let key = keptProspect(ctx, group: "Robin Vale", venue: "East Village Playhouse")
        _ = PrepImporter.ingest(PrepResults(version: 6, generatedAt: "now", results: [
            PrepResult(naturalKey: key, contacts: [performer("robin@robinvale.example", corroborated: false)])
        ]), into: ctx)
        _ = PrepImporter.ingest(PrepResults(version: 6, generatedAt: "later", results: [
            PrepResult(naturalKey: key, contacts: [performer("robin@robinvale.example", corroborated: true)])
        ]), into: ctx)

        let r = try #require(try prospect(ctx, key: key)?.recipients.first)
        #expect(r.heldDownToUnverified == false)
        #expect(r.heldDownReasonRaw == nil)
        #expect(r.contactConfidence == .high)
    }
}
