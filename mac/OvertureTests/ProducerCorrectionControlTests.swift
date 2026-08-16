import Testing
import Foundation
import SwiftData

// #1719 (milestone 34 Phase 2), the way in. The store and the wiring shipped first and changed nothing
// Dan could see, because nothing could put a key in either set. This is the half that switches it on.
//
// Dan's choice, asked on 2026-07-29: correct it inline, on the show where the wrong verdict is visible,
// with no management sheet. The control is STATEFUL so it doubles as the way back, which is what makes
// a sheet unnecessary: the same menu that applied a correction shows it in force and takes it back.
@MainActor
@Suite("Correcting a producer/house verdict from the row (#1719)")
struct ProducerCorrectionControlTests {

    private func container() throws -> ModelContainer {
        try ModelContainer(for: AppSchema.schema,
                           configurations: [ModelConfiguration(isStoredInMemoryOnly: true)])
    }

    private func prospect(_ ctx: ModelContext, key: String, presenter: String?,
                          venue: String = "Under St Marks") -> Prospect {
        let p = Prospect(naturalKey: key, groupName: "A Show", discipline: "theater",
                         venue: venue, performanceDate: "2026-09-10",
                         sourceListingURL: nil, websiteURL: nil,
                         priorRelationship: "none", production: "self", profile: "strong",
                         coverage: "likely_uncovered", fitScore: 7, tier: "high", fitReason: "r",
                         matchedClientName: nil, possibleMatchSource: nil, possibleMatchName: nil)
        p.presenter = presenter
        ctx.insert(p)
        try? ctx.save()
        return p
    }

    // The row has to KNOW what is in force, or the control cannot show it and cannot offer the way back.
    // Derived in the model from the same overrides the gate reads, never looked up in the view (#863).
    @Test func theRowCarriesTheCorrectionInForce() throws {
        let ctx = ModelContext(try container())
        _ = prospect(ctx, key: "k1", presenter: "FRIGID New York")
        let all = (try? ctx.fetch(FetchDescriptor<Prospect>())) ?? []

        #expect(QueueModel.items(from: all).first?.producerStanding == ProducerOverrideEditing.Standing.none)

        ProducerOverrideEditing.demote("FRIGID New York", into: ctx)
        let demoted = QueueModel.items(from: all,
                                       overrides: ProducerOverrideEditing.overrides(in: ctx)).first
        #expect(demoted?.producerStanding == .demoted)

        ProducerOverrideEditing.promote("FRIGID New York", into: ctx)
        let promoted = QueueModel.items(from: all,
                                        overrides: ProducerOverrideEditing.overrides(in: ctx)).first
        #expect(promoted?.producerStanding == .promoted)
    }

    // A row with no presenter has no organisation to correct, so the control must not be offered. Offering
    // it would either do nothing on click or store a key nothing can ever match, which is the silent kind
    // of wrong this whole issue exists to end.
    @Test func aRowWithNoOrganisationOffersNothingToCorrect() throws {
        let ctx = ModelContext(try container())
        _ = prospect(ctx, key: "k1", presenter: nil)
        let all = (try? ctx.fetch(FetchDescriptor<Prospect>())) ?? []
        #expect(QueueModel.items(from: all).first?.correctableOrganisation == nil)
    }

    @Test func aRowWithAnOrganisationNamesItForTheControl() throws {
        let ctx = ModelContext(try container())
        _ = prospect(ctx, key: "k1", presenter: "FRIGID New York")
        let all = (try? ctx.fetch(FetchDescriptor<Prospect>())) ?? []
        #expect(QueueModel.items(from: all).first?.correctableOrganisation == "FRIGID New York")
    }

    // #1763: a presenter spelled EXACTLY like a room can never be promoted. ProducerGate.isVenueBrand
    // tests equality before it ever reads `overrides.promoted`, and ProducerGateTests pins that as
    // deliberate, so the control offered on those rows applies a correction the gate then ignores.
    // Measured on the live store 2026-07-29: 15 organisations, 312 rows, and all 15 stay refused after
    // being promoted. That is a control that reads as applied while changing nothing, the #1679 shape.
    // So it must not be offered at all: the row says nothing rather than something untrue.
    @Test func aPresenterSpelledExactlyLikeItsRoomOffersNoCorrection() throws {
        let ctx = ModelContext(try container())
        _ = prospect(ctx, key: "k1", presenter: "The Green Room 42", venue: "The Green Room 42")
        let all = (try? ctx.fetch(FetchDescriptor<Prospect>())) ?? []
        #expect(QueueModel.items(from: all).first?.correctableOrganisation == nil)
    }

    // The other arm must keep its control: promotion genuinely relaxes containment, so an organisation
    // caught only by name overlap IS correctable and losing its control would be the opposite defect.
    // Carnegie Hall Presents is this shape on the live store (28 rows), and the Metropolitan Opera at the
    // Metropolitan Opera House is the case promotion was written for.
    @Test func aPresenterCaughtOnlyByNameOverlapKeepsItsCorrection() throws {
        let ctx = ModelContext(try container())
        _ = prospect(ctx, key: "k1", presenter: "Carnegie Hall Presents", venue: "Carnegie Hall")
        _ = prospect(ctx, key: "k2", presenter: "Carnegie Hall Presents", venue: "Zankel Hall")
        let all = (try? ctx.fetch(FetchDescriptor<Prospect>())) ?? []
        let item = QueueModel.items(from: all).first { $0.correctableOrganisation != nil }
        #expect(item?.correctableOrganisation == "Carnegie Hall Presents")
    }

    // And a correction ALREADY in force keeps its way back, even on a room name. Clearing a promotion
    // that never worked is still a real state change, and stranding Dan with a standing correction he
    // cannot take back is how #1679 happened. The store holds none of these today, so this is the guard
    // that stops the narrowing from creating a one-way door later.
    @Test func aRoomNameWithACorrectionInForceKeepsTheWayBack() throws {
        let ctx = ModelContext(try container())
        _ = prospect(ctx, key: "k1", presenter: "The Green Room 42", venue: "The Green Room 42")
        ProducerOverrideEditing.promote("The Green Room 42", into: ctx)
        let all = (try? ctx.fetch(FetchDescriptor<Prospect>())) ?? []
        let item = QueueModel.items(from: all,
                                    overrides: ProducerOverrideEditing.overrides(in: ctx)).first
        #expect(item?.correctableOrganisation == "The Green Room 42")
        #expect(item?.producerStanding == .promoted)
    }

    // The mutation, end to end from the row's own item: it stores the correction the gate will read.
    @Test func correctingFromTheRowStoresWhatTheGateReads() throws {
        let ctx = ModelContext(try container())
        _ = prospect(ctx, key: "k1", presenter: "FRIGID New York")
        let item = QueueModel.items(from: (try? ctx.fetch(FetchDescriptor<Prospect>())) ?? []).first!
        let feedback = ActionFeedback()

        ProspectMutations.correctProducer(item, to: .demoted, context: ctx, feedback: feedback)
        #expect(ProducerOverrideEditing.overrides(in: ctx).demoted == ["frigid new york"])

        // The way back, through the same call. This is what lets the inline control be the only surface.
        ProspectMutations.correctProducer(item, to: ProducerOverrideEditing.Standing.none,
                                          context: ctx, feedback: feedback)
        #expect(ProducerOverrideEditing.overrides(in: ctx).demoted.isEmpty)
        #expect(ProducerOverrideEditing.overrides(in: ctx).promoted.isEmpty)
    }

    // Dan's walk of the Debug build, 2026-07-29, on a menu that offered both directions at once: "these
    // are mutually exclusive? What is it currently being treated as?" The answer was nowhere on screen.
    // "No correction in force" is not "no verdict": the gate has always already decided. So the menu must
    // STATE the verdict, and it must name who reached it, because a verdict Dan set is his to revisit and
    // one Overture reached is a rule doing its job.
    @Test func theMenuStatesTheVerdictAndWhoDecidedIt() {
        #expect(QueueModel.producerVerdictLine(ProducerOverrideEditing.Standing.none, treatedAsVenue: false)
                == "Overture decided: the presenter")
        #expect(QueueModel.producerVerdictLine(ProducerOverrideEditing.Standing.none, treatedAsVenue: true)
                == "Overture decided: the venue")
        #expect(QueueModel.producerVerdictLine(.demoted, treatedAsVenue: true) == "You set this: the venue")
        #expect(QueueModel.producerVerdictLine(.promoted, treatedAsVenue: false)
                == "You set this: the presenter")
    }

    // The offered action must always CHANGE the verdict. Offering "treat as the presenter" to a row already
    // treated as the presenter is a click that does nothing, which is how the first version of this menu
    // managed to ask Dan to pick a state it was already in.
    @Test func theOfferedActionIsAlwaysTheOppositeOfTheCurrentVerdict() {
        let treatedAsPresenter = QueueModel.producerCorrectionLabel(
            ProducerOverrideEditing.Standing.none, organisation: "Irvine School of Music",
            treatedAsVenue: false)
        #expect(treatedAsPresenter == "Treat Irvine School of Music as the venue instead")

        let treatedAsVenue = QueueModel.producerCorrectionLabel(
            ProducerOverrideEditing.Standing.none, organisation: "FRIGID New York", treatedAsVenue: true)
        #expect(treatedAsVenue == "Treat FRIGID New York as the presenter instead")
    }

    // With a correction standing, the only action is the way back, in both directions. There is no second
    // entry offering the opposite correction: that would put a state beside its own reversal as equals,
    // which is the shape Dan flagged.
    @Test(arguments: [ProducerOverrideEditing.Standing.demoted, .promoted])
    func aStandingCorrectionOffersOnlyTheWayBack(_ standing: ProducerOverrideEditing.Standing) {
        #expect(QueueModel.producerCorrectionLabel(standing, organisation: "FRIGID New York",
                                                   treatedAsVenue: standing == .demoted)
                == "Go back to deciding FRIGID New York automatically")
    }

    // The verdict the menu states has to be the one the ROW is actually using, or the menu describes a
    // classification the card is not applying. Read off the same corpus verdict, never recomputed.
    @Test func theStatedVerdictFollowsTheRowsRealClassification() throws {
        let ctx = ModelContext(try container())
        _ = prospect(ctx, key: "k1", presenter: "FRIGID New York")
        let all = (try? ctx.fetch(FetchDescriptor<Prospect>())) ?? []

        #expect(QueueModel.items(from: all, corpus: all).first?.treatedAsVenue == false)

        ProducerOverrideEditing.demote("FRIGID New York", into: ctx)
        #expect(QueueModel.items(from: all, corpus: all,
                                 overrides: ProducerOverrideEditing.overrides(in: ctx))
            .first?.treatedAsVenue == true)
    }

    // The control is wired into the row Dan actually triages in, not merely defined. A rule and its wiring
    // are two claims, and the view cannot be built by a running test.
    @Test func theRowAndFactoryReallyOfferTheControl() {
        let row = SourceGuardHelper.source("Overture/UI/ProspectRowView.swift")
        let factory = SourceGuardHelper.source("Overture/UI/ProspectRowFactory.swift")
        // #2726: the CALL, not the name. `onCorrectProducer` without a paren is satisfied by the row's
        // own property declaration (`var onCorrectProducer: (...) -> Void = { _ in }`), which is present
        // whether anything calls it or not, so the guard said "wired in" and asked "does this word exist"
        // (L135).
        #expect(row.contains("onCorrectProducer("))
        #expect(row.contains("QueueModel.producerCorrectionLabel"))
        #expect(factory.contains("ProspectMutations.correctProducer"))
    }

    // #1823, Dan reading the card for Alex Syiek at The Green Room 42: the card carried
    // "Couldn't tell who's putting this on: the listing named only the room." directly under the line
    // naming Alex Syiek, which is two adjacent lines saying opposite things about one show (#843).
    //
    // Dropped rather than narrowed, on Dan's call (2026-08-01). The line existed to send him looking for
    // a company the listing had not named. #1861 removed that errand: a show naming no organiser now has
    // every performer on its bill pursued by name, so the flag no longer changes anything he or the
    // system does, and a mark that changes nothing is noise on 169 cards.
    //
    // Deliberately keyed on the row shape that used to produce the line, so this stays a real claim about
    // the card rather than a test of a deleted symbol.
    @Test func aRowWhosePresenterWasDiscardedAddsNoNoteToTheCard() throws {
        let ctx = ModelContext(try container())
        let p = prospect(ctx, key: "k1", presenter: nil)
        p.presenterWasTheRoom = true
        try? ctx.save()
        let all = (try? ctx.fetch(FetchDescriptor<Prospect>())) ?? []
        let item = try #require(QueueModel.items(from: all).first)
        // The row still records WHY the name went; it simply no longer says so on the card.
        #expect(item.presenterWasTheRoom)
        #expect(item.presenterLine == nil)

        // And the sentence is not merely unreachable from this row, it is gone from the app's whole
        // vocabulary: no surface can say it about any row. Read from the generated copy inventory, which
        // is built from the real source, so a line left rendering somewhere else would still be caught.
        let inventory = try CopyInventory.build()
        #expect(inventory.filesScanned > 50, "the inventory really scanned the app")
        #expect(!inventory.sentences.contains { $0.contains("who's putting this on") })
    }

    // #1731, Dan's verdict on the Presenters sheet (2026-07-30): "this sheet is confusing. I'm not sure
    // what to do with it." The question the sheet was built to answer ("why is no presenter named here?")
    // is one he asks while looking at a CARD, and answering it on a separate screen he has to know exists
    // means the answer never reaches the question. So the card says it.
    //
    // Only where the BUILDING VERDICT is what hid the name. Measured 2026-07-29: of 351 rows whose
    // presenter is judged the building, 296 would have their name hidden anyway because the presenter
    // field simply repeats the venue, where nothing is being judged and there is nothing to explain. The
    // verdict uniquely hides 55, and those are the only ones with something to say.
    @Test func aCardSaysWhenTheBuildingVerdictIsWhyNoPresenterIsNamed() throws {
        let ctx = ModelContext(try container())
        // Jalopy Theatre presenting in a park: the name differs from the venue, so only the gate's verdict
        // hides it. Two rows, because the gate needs to see Jalopy as a venue elsewhere to judge it one.
        _ = prospect(ctx, key: "k1", presenter: "Jalopy Theatre", venue: "Greeley Square")
        _ = prospect(ctx, key: "k2", presenter: "A Visiting Act", venue: "Jalopy Theatre")
        let all = (try? ctx.fetch(FetchDescriptor<Prospect>())) ?? []
        let item = QueueModel.items(from: all).first { $0.venue == "Greeley Square" }
        #expect(item?.presenterLine == nil)
        #expect(item?.readAsTheBuildingNote != nil)
    }

    // A presenter that merely REPEATS its own venue explains itself: the venue is printed right below, so
    // a line saying the name was hidden would be telling Dan something he can already see.
    @Test func aPresenterThatSimplyRepeatsItsVenueSaysNothingExtra() throws {
        let ctx = ModelContext(try container())
        _ = prospect(ctx, key: "k1", presenter: "The Joyce Theater", venue: "The Joyce Theater")
        let all = (try? ctx.fetch(FetchDescriptor<Prospect>())) ?? []
        #expect(QueueModel.items(from: all).first?.readAsTheBuildingNote == nil)
    }

    // And a card that DOES name its presenter says nothing, or it would carry two lines disagreeing.
    @Test func aCardThatNamesItsPresenterSaysNothingAboutBuildings() throws {
        let ctx = ModelContext(try container())
        _ = prospect(ctx, key: "k1", presenter: "Young Concert Artists", venue: "Merkin Hall")
        let all = (try? ctx.fetch(FetchDescriptor<Prospect>())) ?? []
        let item = QueueModel.items(from: all).first
        #expect(item?.presenterLine == "Young Concert Artists")
        #expect(item?.readAsTheBuildingNote == nil)
    }
}
