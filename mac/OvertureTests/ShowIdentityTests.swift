import Testing
import Foundation
import SwiftData

// #4357 slice I2 (plan v7 Phase 3, step 5, finding B3): a press finds its show by the card's store
// identifier, with the natural key as a witness, through `ShowIdentity`.
//
// WHAT THIS EXISTS TO STOP. Every row action used to find its show as `prospects.first(where: {
// $0.naturalKey == item.id })`. `naturalKey` is unique and reassigned by merges, so after a merge hands a
// deleted show's key to a survivor, a press on the deleted show's card found the SURVIVOR and wrote to it,
// with nothing said (L145, L75, L15). The Reached out list already refused that (#3651); these pin that
// every action now does, through the same rule.
//
// ONE TEST PER REFUSAL, each asserting the sentence Dan is shown AND that nothing was written, because a
// refusal that still wrote is the defect this exists to stop, and one that wrote nothing silently is #1778.
// Each runs through a real action (`saveDraft`, whose write is easy to see), not the resolver alone, so it
// proves the wiring as well as the rule (L3).
@MainActor
@Suite("An action finds its show by identity, and refuses by name (#4357 slice I2)")
struct ShowIdentityTests {

    // HELD by the suite, because a context does not keep its container alive. Measured 2026-10-05: read
    // off a container nothing held, the test host died in every one of these tests.
    private let container: ModelContainer

    init() throws {
        container = try TestModelContainer.inMemory([Prospect.self, Recipient.self])
    }

    private func context() -> ModelContext { container.mainContext }

    private func make(_ ctx: ModelContext, key: String, org: String) -> Prospect {
        let p = Prospect(naturalKey: key, groupName: org, discipline: "music", venue: "Weill Recital Hall",
                         performanceDate: "2082-10-01", sourceListingURL: nil, priorRelationship: "none",
                         production: "presenter", profile: "strong", coverage: "likely_uncovered",
                         fitScore: 5, tier: "mid", fitReason: "r", matchedClientName: nil,
                         possibleMatchSource: nil, possibleMatchName: nil, status: .drafted)
        p.draftSubject = "The subject before the press"
        p.draftBody = "The body before the press"
        ctx.insert(p)
        return p
    }

    private func pressSaveDraft(_ item: QueueItem, among rows: [Prospect], _ ctx: ModelContext)
        -> ActionFeedback {
        let feedback = ActionFeedback()
        ProspectMutations.saveDraft(item, "The subject Dan typed", "The body Dan typed",
                                    prospects: rows, context: ctx, feedback: feedback)
        return feedback
    }

    // THE ORDINARY CASE FIRST: every refusal below means something only if the same press on a live,
    // unmoved card is written (L159).
    @Test func aPressOnALiveCardIsWritten() throws {
        let ctx = context()
        let show = make(ctx, key: "show-1", org: "Ensemble Alpha")
        try ctx.save()

        let feedback = pressSaveDraft(QueueItem(show), among: [show], ctx)

        #expect(show.draftSubject == "The subject Dan typed",
                "a press on a live card did not write, so every refusal below proves nothing")
        #expect(feedback.tone != .warning, "a press that was written was answered with a refusal")
    }

    // 1. GONE, and specifically the B3 shape: the card's show was merged away and a DIFFERENT show adopted
    // its key. The old lookup found the survivor by key and wrote to it.
    @Test func aCardWhoseKeyAnotherShowAdoptedIsRefusedAndTheSurvivorIsNotWritten() throws {
        let ctx = context()
        let pressed = make(ctx, key: "show-1", org: "The one Dan pressed")
        let survivor = make(ctx, key: "show-2", org: "A different show entirely")
        try ctx.save()
        let card = QueueItem(pressed)

        // The merge: the loser goes, then the survivor adopts its key.
        ctx.delete(pressed)
        try ctx.save()
        survivor.naturalKey = "show-1"
        try ctx.save()

        let feedback = pressSaveDraft(card, among: [survivor], ctx)

        #expect(survivor.draftSubject == "The subject before the press",
                Comment(rawValue: "the press on a merged-away show's card wrote to the survivor that adopted "
                        + "its key. A key-only lookup finds exactly one row with nothing to report, so the "
                        + "change lands on a show Dan did not press (B3, L145, L75)."))
        #expect(!ctx.hasChanges, "the refused press left an unsaved change behind")
        #expect(feedback.message == ShowIdentity.Refusal.gone.sentence(org: card.groupName))
        #expect(feedback.tone == .warning)
    }

    // 2. RE-KEYED IN PLACE: the same row, its own key moved underneath it (a night drop does this).
    @Test func aCardWhoseShowWasRekeyedIsRefusedAsMovedAndNothingIsWritten() throws {
        let ctx = context()
        let show = make(ctx, key: "show-1", org: "Ensemble Alpha")
        try ctx.save()
        let card = QueueItem(show)

        show.naturalKey = "show-1-night-2"
        try ctx.save()

        let feedback = pressSaveDraft(card, among: [show], ctx)

        #expect(show.draftSubject == "The subject before the press",
                "a press on a card whose show has since moved wrote to it anyway")
        #expect(!ctx.hasChanges, "the refused press left an unsaved change behind")
        #expect(feedback.message == ShowIdentity.Refusal.reKeyed.sentence(org: card.groupName))
        #expect(feedback.tone == .warning)
    }

    // 3. DRAWN BEFORE ITS FIRST SAVE. The identifier a row carries before its first save is replaced AT that
    // save, so a card drawn in between names nothing afterwards. Refused by name rather than found by key.
    @Test func aCardDrawnBeforeItsShowsFirstSaveIsRefusedAndNothingIsWritten() throws {
        let ctx = context()
        let show = make(ctx, key: "show-1", org: "Ensemble Alpha")
        let card = QueueItem(show)
        // The positive control in the same fixture: before the save, the very same card resolves (L159).
        #expect(ShowIdentity(card)?.resolve(in: [show]).show === show,
                Comment(rawValue: "an unsaved row's card did not resolve even before the save, so the "
                        + "refusal below is not about the save at all"))
        try ctx.save()
        #expect(card.showID != show.persistentModelID,
                "the identifier did not change on the first save, so this fixture no longer reaches the case")

        let feedback = pressSaveDraft(card, among: [show], ctx)

        #expect(show.draftSubject == "The subject before the press",
                "a card drawn before its show's first save was resolved onto a row anyway")
        #expect(!ctx.hasChanges, "the refused press left an unsaved change behind")
        #expect(feedback.message == ShowIdentity.Refusal.drawnBeforeItsFirstSave.sentence(org: card.groupName))
        #expect(feedback.tone == .warning)
    }

    // 4. A CARD NAMING NO STORED SHOW, which only a hand-built card can be. Its key matches a live row, so
    // the old lookup wrote to that row; it now resolves to nothing, and says so.
    @Test func aCardWithNoIdentityIsRefusedEvenWhereItsKeyMatchesALiveShow() throws {
        let ctx = context()
        let show = make(ctx, key: "show-1", org: "Ensemble Alpha")
        try ctx.save()
        let handBuilt = QueueItem(id: "show-1", groupName: "Ensemble Alpha", discipline: "music",
                                  venue: "Weill Recital Hall", performanceDate: "2082-10-01",
                                  sourceListingURL: nil, priorRelationship: "none", production: "presenter",
                                  profile: "strong", coverage: "likely_uncovered", fitScore: 5, tier: "mid",
                                  fitReason: "r", matchedClientName: nil, possibleMatchSource: nil,
                                  possibleMatchName: nil, status: .drafted)

        let feedback = pressSaveDraft(handBuilt, among: [show], ctx)

        #expect(show.draftSubject == "The subject before the press",
                "a card naming no stored show was resolved by its key onto a live row")
        #expect(feedback.message == ShowIdentity.Refusal.gone.sentence(org: handBuilt.groupName))
    }

    // The key-only callers (a reply, a nudge, a confirmed send) hold no card. A key no row holds is refused
    // with the show's own gone sentence, which names no organisation because they do not know it.
    @Test func aKeyNoShowHoldsIsRefusedAsGone() throws {
        let ctx = context()
        let show = make(ctx, key: "show-1", org: "Ensemble Alpha")
        try ctx.save()
        let feedback = ActionFeedback()

        let missing = ProspectMutations.model(forKey: "no-such-show", org: nil, in: [show], feedback: feedback)
        let found = ProspectMutations.model(forKey: "show-1", org: nil, in: [show], feedback: ActionFeedback())

        #expect(missing == nil)
        #expect(feedback.message == ShowIdentity.Refusal.gone.sentence(org: nil))
        #expect(found === show, "a key a live show holds did not resolve, so the refusal above proves nothing")
    }

    // The refusals must not share a sentence, with an organisation named or without one (L11, L260).
    @Test func eachRefusalSaysSomethingDifferent() {
        for org in ["Ensemble Alpha", nil] as [String?] {
            let said = ShowIdentity.Refusal.allCases.map { $0.sentence(org: org) }
            #expect(Set(said).count == said.count,
                    Comment(rawValue: "two refusals say the same thing: \(said)"))
            for sentence in said {
                #expect(!sentence.isEmpty, "a refusal with no wording cannot be acted on")
            }
        }
    }
}

// The identifier the resolver reads is WRITTEN by the build, from the fact each card and row is made from
// (L46: a field only ever read is a field nobody fills). Asserted through the entry points the app uses,
// never the memberwise initialiser.
@MainActor
@Suite("Every card and row carries its show's identity (#4357 slice I2)")
struct CardsCarryTheirShowsIdentityTests {

    // Held for the reason `ShowIdentityTests` holds its own.
    private let container: ModelContainer

    init() throws {
        container = try TestModelContainer.inMemory([Prospect.self, Recipient.self])
    }

    private func savedShow() throws -> (Prospect, ModelContext) {
        let ctx = container.mainContext
        let p = Prospect(naturalKey: "show-1", groupName: "Ensemble Alpha", discipline: "music",
                         venue: "Weill Recital Hall", performanceDate: "2082-10-01", sourceListingURL: nil,
                         priorRelationship: "none", production: "presenter", profile: "strong",
                         coverage: "likely_uncovered", fitScore: 5, tier: "mid", fitReason: "r",
                         matchedClientName: nil, possibleMatchSource: nil, possibleMatchName: nil,
                         status: .drafted)
        ctx.insert(p)
        try ctx.save()
        return (p, ctx)
    }

    @Test func aCardFromAShowCarriesItsIdentifier() throws {
        let (p, _) = try savedShow()
        #expect(QueueItem(p).showID == p.persistentModelID)
    }

    // The value the engine will hold builds the same card, by the same body (#4357 slice G2).
    @Test func aCardFromTheShowsFactsCarriesTheSameIdentifier() throws {
        let (p, _) = try savedShow()
        let facts = RowFacts.extract(p)
        let card = QueueItem(facts, sendGroups: SendGroup.Groups(of: facts, among: facts.factContacts,
                                                                 today: "2082-09-01"),
                             among: facts.factContacts)
        #expect(card.showID == p.persistentModelID)
    }

    @Test func aRowFromAShowCarriesItsIdentifier() throws {
        let (p, _) = try savedShow()
        #expect(QueueScopeRow(p, facts: RecipientFacts.of(p)).showID == p.persistentModelID)
    }

    // The splice: a departing card becomes a row again, and the row must keep the identity it came with.
    @Test func aRowSplicedFromACardKeepsItsIdentifier() throws {
        let (p, _) = try savedShow()
        #expect(QueueScopeRow(QueueItem(p)).showID == p.persistentModelID)
    }
}
