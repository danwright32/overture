import Testing
import Foundation
import SwiftData

// #1866: `ContactConfidenceGuard` (#1856) rewrites a contact's confidence from `high` down to `low` when
// the find names no page it was read off. Until this issue the rewrite left no trace, so the stored row
// simply said `low` and was indistinguishable from a run that judged the address weak all by itself.
//
// Two different things produced one badge. "Unverified email found" meant either "the check looked and was
// not sure" or "the check WAS sure and Overture overruled it", and those ask different things of Dan: the
// first is a weak find to treat carefully, the second is a citation the run failed to record about an
// address that may be perfectly good.
//
// The three sibling guards on a contact (`looksLikeVenue`, `looksLikePressContact`,
// `looksLikeDuplicateContact`) each store the fact they fired AND carry a `...Dismissed` companion Dan can
// set, because he can look at an address and judge it. This one stored nothing, so it could not be seen
// and could not be overruled. It now has the same two fields, written by the same importer, re-derived on
// every ingest rather than latched.
//
// Measured on the live store 2026-07-31, before the guard shipped: 33 recipients were `high` WITH a source
// page and 2 were `high` without one, so this describes two rows rather than repainting the queue.
@MainActor
@Suite("A contact held down to unverified says so (#1866)")
struct ConfidenceHeldDownIsRecordedTests {

    private func container() throws -> ModelContainer {
        try ModelContainer(for: Schema([Prospect.self, Recipient.self]),
                           configurations: [ModelConfiguration(isStoredInMemoryOnly: true)])
    }

    private func keptProspect(_ ctx: ModelContext, group: String, date: String, venue: String) -> String {
        let key = Prospect.makeNaturalKey(groupName: group, performanceDate: date, venue: venue)
        let p = Prospect(naturalKey: key, groupName: group, discipline: "music", venue: venue,
                         performanceDate: date, sourceListingURL: nil, websiteURL: nil,
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

    // MARK: the guard can be asked whether it acted

    // The fact the row has to record is not "the answer is low", which the stored confidence already says.
    // It is "this answer is not the one the run gave", which nothing could ask before.
    @Test func theGuardSaysWhenItActuallyChangedTheAnswer() {
        #expect(ContactConfidenceGuard.heldDown(raw: "high", sourceURL: nil))
        #expect(ContactConfidenceGuard.heldDown(raw: "high", sourceURL: "   "))
        #expect(!ContactConfidenceGuard.heldDown(raw: "high", sourceURL: "https://act.example/contact"))
    }

    // It never claims to have acted on an answer it left alone, which is what keeps the new sentence off
    // every ordinarily weak find (the common case: 10 of 29 stored contacts were `low` on 2026-07-27).
    @Test func theGuardClaimsNothingAboutAnAnswerItLeftAlone() {
        #expect(!ContactConfidenceGuard.heldDown(raw: "low", sourceURL: nil))
        #expect(!ContactConfidenceGuard.heldDown(raw: "medium", sourceURL: nil))
        #expect(!ContactConfidenceGuard.heldDown(raw: nil, sourceURL: nil))
        #expect(!ContactConfidenceGuard.heldDown(raw: "low", sourceURL: "https://act.example/contact"))
    }

    // MARK: the importer writes it

    @Test func anIngestRecordsThatAConfidentFindWasHeldDown() throws {
        let ctx = ModelContext(try container())
        let key = keptProspect(ctx, group: "Mind Games", date: "2026-09-18", venue: "SoHo Playhouse")
        _ = PrepImporter.ingest(PrepResults(version: 6, generatedAt: "now", results: [
            PrepResult(naturalKey: key, contacts: [
                PrepContact(name: "Jake Berg", role: nil, email: "jake@jakebergmagic.example",
                            method: "named_decision_maker", confidence: "high", formUrl: nil,
                            provenance: "act", sourceUrl: nil)
            ])
        ]), into: ctx)

        let r = try prospect(ctx, key: key)?.recipients.first
        #expect(r?.contactConfidenceRaw == "low")
        #expect(r?.heldDownToUnverified == true)
        #expect(r?.isHeldDownToUnverified == true)
    }

    // The other half, and the one that stops the new sentence appearing on every weak contact: a find the
    // run itself called weak was never held down by anything.
    @Test func anOrdinarilyWeakFindIsNotRecordedAsHeldDown() throws {
        let ctx = ModelContext(try container())
        let key = keptProspect(ctx, group: "Copeland", date: "2026-09-19", venue: "Jalopy Theatre")
        _ = PrepImporter.ingest(PrepResults(version: 6, generatedAt: "now", results: [
            PrepResult(naturalKey: key, contacts: [
                PrepContact(name: nil, role: nil, email: "info@jalopy.example",
                            method: "generic_inbox", confidence: "medium", formUrl: nil,
                            provenance: "act", sourceUrl: nil)
            ])
        ]), into: ctx)

        let r = try prospect(ctx, key: key)?.recipients.first
        #expect(r?.contactConfidenceRaw == "medium")
        #expect(r?.heldDownToUnverified == false)
    }

    @Test func aCitedFindIsNotRecordedAsHeldDown() throws {
        let ctx = ModelContext(try container())
        let key = keptProspect(ctx, group: "Anna Pierre", date: "2026-09-20", venue: "Weill Recital Hall")
        _ = PrepImporter.ingest(PrepResults(version: 6, generatedAt: "now", results: [
            PrepResult(naturalKey: key, contacts: [
                PrepContact(name: "Anna Pierre", role: nil, email: "anna@annapierre.example",
                            method: "named_decision_maker", confidence: "high", formUrl: nil,
                            provenance: "act", sourceUrl: "https://annapierre.example/contact")
            ])
        ]), into: ctx)

        let r = try prospect(ctx, key: key)?.recipients.first
        #expect(r?.contactConfidenceRaw == "high")
        #expect(r?.heldDownToUnverified == false)
    }

    // Re-derived on every ingest, never a one-way latch, exactly like the three guesses beside it: a later
    // run that finally names the page clears the record along with the downgrade it explains.
    @Test func aLaterRunThatNamesThePageClearsTheRecord() throws {
        let ctx = ModelContext(try container())
        let key = keptProspect(ctx, group: "Mind Games", date: "2026-09-18", venue: "SoHo Playhouse")
        let uncited = PrepContact(name: "Jake Berg", role: nil, email: "jake@jakebergmagic.example",
                                  method: "named_decision_maker", confidence: "high", formUrl: nil,
                                  provenance: "act", sourceUrl: nil)
        _ = PrepImporter.ingest(PrepResults(version: 6, generatedAt: "now",
                                            results: [PrepResult(naturalKey: key, contacts: [uncited])]), into: ctx)
        #expect(try prospect(ctx, key: key)?.recipients.first?.heldDownToUnverified == true)

        _ = PrepImporter.ingest(PrepResults(version: 6, generatedAt: "later", results: [
            PrepResult(naturalKey: key, contacts: [
                PrepContact(name: "Jake Berg", role: nil, email: "jake@jakebergmagic.example",
                            method: "named_decision_maker", confidence: "high", formUrl: nil,
                            provenance: "act", sourceUrl: "https://jakebergmagic.example/booking")
            ])
        ]), into: ctx)

        let r = try prospect(ctx, key: key)?.recipients.first
        #expect(r?.contactConfidenceRaw == "high")
        #expect(r?.heldDownToUnverified == false)
    }

    // A re-run over a contact that STILL cites nothing keeps saying so, which is the case the live store
    // holds: the run does not know Overture downgraded it, so it reports `high` again every time.
    @Test func aReRunOfTheSameUncitedFindStillRecordsIt() throws {
        let ctx = ModelContext(try container())
        let key = keptProspect(ctx, group: "Mind Games", date: "2026-09-18", venue: "SoHo Playhouse")
        let uncited = PrepContact(name: "Jake Berg", role: nil, email: "jake@jakebergmagic.example",
                                  method: "named_decision_maker", confidence: "high", formUrl: nil,
                                  provenance: "act", sourceUrl: nil)
        for stamp in ["now", "later"] {
            _ = PrepImporter.ingest(PrepResults(version: 6, generatedAt: stamp,
                                                results: [PrepResult(naturalKey: key, contacts: [uncited])]), into: ctx)
        }

        let r = try prospect(ctx, key: key)?.recipients.first
        #expect(r?.contactConfidenceRaw == "low")
        #expect(r?.heldDownToUnverified == true)
    }

    // MARK: Dan can overrule it

    // The whole reason the three siblings carry a dismissal: he can look at an address and judge it. Once
    // he says the address really is theirs, the row stops calling it unverified.
    @Test func overrulingTheHoldMakesTheAddressReadVerifiedAgain() throws {
        let ctx = ModelContext(try container())
        let key = keptProspect(ctx, group: "Mind Games", date: "2026-09-18", venue: "SoHo Playhouse")
        _ = PrepImporter.ingest(PrepResults(version: 6, generatedAt: "now", results: [
            PrepResult(naturalKey: key, contacts: [
                PrepContact(name: "Jake Berg", role: nil, email: "jake@jakebergmagic.example",
                            method: "named_decision_maker", confidence: "high", formUrl: nil,
                            provenance: "act", sourceUrl: nil)
            ])
        ]), into: ctx)
        let p = try #require(try prospect(ctx, key: key))
        #expect(QueueItem(p).onlyUnverifiedEmailsFound)

        let feedback = ActionFeedback()
        ProspectMutations.dismissConfidenceHeldDown(QueueItem(p), "jake@jakebergmagic.example",
                                                    prospects: [p], context: ctx, feedback: feedback)

        #expect(p.recipients.first?.heldDownToUnverifiedDismissed == true)
        #expect(p.recipients.first?.isHeldDownToUnverified == false)
        #expect(!QueueItem(p).onlyUnverifiedEmailsFound)
        #expect(QueueItem(p).unverifiedContactEmails.isEmpty)
    }

    // Overruling this guard says nothing about any OTHER contact's find. A show can carry two performers
    // and only one of them be a held-down claim (#366).
    @Test func overrulingOneContactLeavesTheOtherAlone() throws {
        let ctx = ModelContext(try container())
        let key = keptProspect(ctx, group: "Two Performers", date: "2026-09-21", venue: "The Owl")
        _ = PrepImporter.ingest(PrepResults(version: 6, generatedAt: "now", results: [
            PrepResult(naturalKey: key, contacts: [
                PrepContact(name: "Jake Berg", role: nil, email: "jake@jakebergmagic.example",
                            method: "named_decision_maker", confidence: "high", formUrl: nil,
                            provenance: "act", sourceUrl: nil),
                PrepContact(name: "Room Desk", role: nil, email: "info@theowl.example",
                            method: "generic_inbox", confidence: "medium", formUrl: nil,
                            provenance: "presenter", sourceUrl: nil)
            ])
        ]), into: ctx)
        let p = try #require(try prospect(ctx, key: key))

        let feedback = ActionFeedback()
        ProspectMutations.dismissConfidenceHeldDown(QueueItem(p), "jake@jakebergmagic.example",
                                                    prospects: [p], context: ctx, feedback: feedback)

        let item = QueueItem(p)
        #expect(item.unverifiedContactEmails == ["info@theowl.example"])
        // One verified contact is enough to write to, so the badge goes back to its plain wording (#1628).
        #expect(!item.onlyUnverifiedEmailsFound)
    }

    // The dismissal is Dan's judgement about THIS address, so a genuinely different address gets it asked
    // again: the reset-on-real-change convention the venue and duplicate guesses already use.
    @Test func aCorrectedAddressReAsksTheOverrule() throws {
        let ctx = ModelContext(try container())
        let key = keptProspect(ctx, group: "Mind Games", date: "2026-09-18", venue: "SoHo Playhouse")
        _ = PrepImporter.ingest(PrepResults(version: 6, generatedAt: "now", results: [
            PrepResult(naturalKey: key, contacts: [
                PrepContact(name: "Jake Berg", role: nil, email: "jake@jakebergmagic.example",
                            method: "named_decision_maker", confidence: "high", formUrl: nil,
                            provenance: "act", sourceUrl: nil)
            ])
        ]), into: ctx)
        let p = try #require(try prospect(ctx, key: key))
        p.recipients.first?.heldDownToUnverifiedDismissed = true
        try ctx.save()

        _ = PrepImporter.ingest(PrepResults(version: 6, generatedAt: "later", results: [
            PrepResult(naturalKey: key, contacts: [
                PrepContact(name: "Jake Berg", role: nil, email: "booking@mindgamesshow.example",
                            method: "named_decision_maker", confidence: "high", formUrl: nil,
                            provenance: "act", sourceUrl: nil)
            ])
        ]), into: ctx)

        let r = try prospect(ctx, key: key)?.recipients.first
        #expect(r?.email == "booking@mindgamesshow.example")
        #expect(r?.heldDownToUnverifiedDismissed == false)
        #expect(r?.isHeldDownToUnverified == true)
    }

    // MARK: the badge's hover says which of the two it is

    @Test func theCardCarriesWhetherAGuardIsWhatMadeItUnverified() throws {
        let ctx = ModelContext(try container())
        let heldKey = keptProspect(ctx, group: "Mind Games", date: "2026-09-18", venue: "SoHo Playhouse")
        let weakKey = keptProspect(ctx, group: "Copeland", date: "2026-09-19", venue: "Jalopy Theatre")
        _ = PrepImporter.ingest(PrepResults(version: 6, generatedAt: "now", results: [
            PrepResult(naturalKey: heldKey, contacts: [
                PrepContact(name: "Jake Berg", role: nil, email: "jake@jakebergmagic.example",
                            method: "named_decision_maker", confidence: "high", formUrl: nil,
                            provenance: "act", sourceUrl: nil)
            ]),
            PrepResult(naturalKey: weakKey, contacts: [
                PrepContact(name: nil, role: nil, email: "info@jalopy.example",
                            method: "generic_inbox", confidence: "medium", formUrl: nil,
                            provenance: "act", sourceUrl: nil)
            ])
        ]), into: ctx)

        let held = QueueItem(try #require(try prospect(ctx, key: heldKey)))
        let weak = QueueItem(try #require(try prospect(ctx, key: weakKey)))
        #expect(held.onlyUnverifiedEmailsFound)
        #expect(weak.onlyUnverifiedEmailsFound)
        // Same badge, and the hover is the only thing that differs, which is what the issue asked for.
        #expect(held.unverifiedBecauseAGuardHeldItDown)
        #expect(!weak.unverifiedBecauseAGuardHeldItDown)
    }

    // A show whose addresses are all verified makes no claim about a guard at all, so the hover can never
    // reach the held-down sentence from a plain "Email found" badge.
    @Test func aVerifiedShowMakesNoClaimAboutAGuard() throws {
        let ctx = ModelContext(try container())
        let key = keptProspect(ctx, group: "Anna Pierre", date: "2026-09-20", venue: "Weill Recital Hall")
        _ = PrepImporter.ingest(PrepResults(version: 6, generatedAt: "now", results: [
            PrepResult(naturalKey: key, contacts: [
                PrepContact(name: "Anna Pierre", role: nil, email: "anna@annapierre.example",
                            method: "named_decision_maker", confidence: "high", formUrl: nil,
                            provenance: "act", sourceUrl: "https://annapierre.example/contact")
            ])
        ]), into: ctx)

        let item = QueueItem(try #require(try prospect(ctx, key: key)))
        #expect(!item.onlyUnverifiedEmailsFound)
        #expect(!item.unverifiedBecauseAGuardHeldItDown)
    }

    // The badge speaks for the WHOLE row (#1628 retired the per-address caveat), so a row that mixes a
    // held-down find with an ordinarily weak one keeps the general sentence. The held-down wording would
    // otherwise be a true statement about half of what Dan is looking at, which is exactly the "this one"
    // defect the general sentence was rewritten to remove.
    @Test func aMixedRowKeepsTheSentenceThatIsTrueOfEveryAddressOnIt() throws {
        let ctx = ModelContext(try container())
        let key = keptProspect(ctx, group: "Mixed Bill", date: "2026-09-22", venue: "The Owl")
        _ = PrepImporter.ingest(PrepResults(version: 6, generatedAt: "now", results: [
            PrepResult(naturalKey: key, contacts: [
                PrepContact(name: "Jake Berg", role: nil, email: "jake@jakebergmagic.example",
                            method: "named_decision_maker", confidence: "high", formUrl: nil,
                            provenance: "act", sourceUrl: nil),
                PrepContact(name: "Nina Ross", role: nil, email: "nina@ninaross.example",
                            method: "inferred", confidence: "low", formUrl: nil,
                            provenance: "performer", sourceUrl: nil)
            ])
        ]), into: ctx)

        let item = QueueItem(try #require(try prospect(ctx, key: key)))
        #expect(item.onlyUnverifiedEmailsFound)
        #expect(!item.unverifiedBecauseAGuardHeldItDown)
    }

    @Test func theTwoExplanationsAreNotTheSameSentence() {
        let held = ReachabilityCopy.unverifiedEmailFoundHelp(heldDown: true)
        let weak = ReachabilityCopy.unverifiedEmailFoundHelp(heldDown: false)
        #expect(held != weak)
        #expect(weak == ReachabilityCopy.unverifiedEmailFoundHelp)
        // The held-down sentence has a job the other cannot do: it names something Dan can act on, so it
        // has to carry where to act. Naming a problem and offering no route is the other half of this
        // defect (L80), and it is the whole reason the fact is recorded at all.
        #expect(held.contains("review panel"))
    }

    // The wiring, not just the wording: the row has to ASK which of the two it is, or the second sentence
    // exists and is never shown (L3, built is not wired).
    @Test func theRowAsksWhichOfTheTwoProducedTheBadge() throws {
        let source = SourceGuardHelper.source("Overture/UI/ProspectRowView.swift")
        #expect(source.contains("unverifiedBecauseAGuardHeldItDown"),
                "the badge's hover must choose its sentence from whether a guard held the find down")
    }

    // MARK: the overrule is reachable

    // The three siblings are dismissible from the draft review panel, through one shared warning row. This
    // one joins them there rather than inventing a fourth place to answer a guard.
    @Test func theOverruleIsOfferedWhereTheOtherThreeAre() throws {
        let source = SourceGuardHelper.source("Overture/UI/DraftReviewView.swift")
        #expect(source.contains("onDismissConfidenceHeldDown"),
                "a guard nobody can answer is the defect this issue is about")
        // Scoped to the panel's own body, because declaring the row is not showing it: the first version
        // of this guard matched the `confidenceHeldDownWarnings` DECLARATION and passed happily with the
        // row removed from everything that renders (L3, built is not wired).
        let body = try #require(SourceGuardHelper.propertyBody("var body: some View {", in: source),
                                "DraftReviewView's body could not be read, so this guard measured nothing")
        for row in ["venueMatchWarnings", "pressContactWarnings", "duplicateContactWarnings",
                    "confidenceHeldDownWarnings"] {
            #expect(body.contains(row), "the review panel must render \(row) with the guards beside it")
        }
    }

    // MARK: the merge keeps Dan's answer

    // #2009's rule, applied to the new pair: a guard's opinion is re-derived on the next ingest, but Dan's
    // answer about a person is his work and must survive whichever duplicate row he gave it on.
    @Test func aDuplicateMergeKeepsTheOverruleWhicheverRowCarriedIt() throws {
        let source = SourceGuardHelper.source("Overture/Domain/DuplicateContactMerge.swift")
        #expect(source.contains("heldDownToUnverifiedDismissed"),
                "Dan's overrule must survive a merge, like the three dismissals beside it")
    }
}
