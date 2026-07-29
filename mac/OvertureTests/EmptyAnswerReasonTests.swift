import Testing
import Foundation
import SwiftData
@testable import Overture

// #1722 (milestone 34 Phase 1): a check that found the venue's own address and correctly refused it used
// to report "No email found", which claims the search came up empty when it came up with something and
// rejected it. LESSONS L11: a message may claim only what its check actually measured.
//
// Deliberately NOT a new ProbeResult case and NOT a new Badge state. The result stays `.noEmailFound` and
// the badge stays `.noEmailFound`, so the fit score (#1648 Ranker.contactRoutePoints), ContactScoreAdjustment,
// the organisation ledger, ContactFormResultMigration, the stored-string migration and the pill tone are
// all untouched. Only the SENTENCE varies, which is the whole of what was wrong.
@Suite("Why an answer was empty (#1722)")
struct EmptyAnswerReasonTests {

    // The contract's vocabulary. These raw strings cross the language boundary in
    // overture-prep-results.json, so they are pinned here rather than left to the enum's spelling.
    @Test func theReasonVocabularyIsTheContractsOwnSpelling() {
        #expect(Reachability.EmptyReason(rawValue: "only_venue_contact") == .onlyVenueContact)
        #expect(Reachability.EmptyReason(rawValue: "only_press_contact") == .onlyPressContact)
        #expect(Reachability.EmptyReason(rawValue: "nothing_published") == .nothingPublished)
        // An unknown value is not silently coerced into one of the three: it reads as no reason given,
        // which degrades to today's sentence rather than inventing a claim.
        #expect(Reachability.EmptyReason(rawValue: "something_new") == nil)
    }

    // Dan's call 2026-07-29: the VISIBLE sentence changes, not just the hover text. A tooltip fix would
    // leave the false claim on screen, which is the thing the issue is about.
    @Test func theBadgeSaysWhatWasActuallyMeasured() {
        #expect(ReachabilityCopy.emptyAnswerBadge(.onlyVenueContact) == "Only the venue's address")
        #expect(ReachabilityCopy.emptyAnswerBadge(.onlyPressContact) == "Only a press address")
    }

    // Nothing published at all IS "no email found", so that case keeps today's wording exactly. A new
    // sentence there would be the #843 shape: a second way of saying what the first already said.
    @Test func nothingPublishedKeepsTodaysWording() {
        #expect(ReachabilityCopy.emptyAnswerBadge(.nothingPublished) == ReachabilityCopy.noEmailFoundBadge)
        #expect(ReachabilityCopy.emptyAnswerHelp(.nothingPublished) == ReachabilityCopy.noEmailFoundHelp)
    }

    // The honest degradation. A runbook is a prompt (L27), so the field WILL sometimes be missing. With no
    // reason in hand the app knows only that nothing usable came back, and today's sentence says exactly
    // that, so a missing reason must fall back to it rather than guess at a cause.
    @Test func noReasonFallsBackToTodaysSentence() {
        #expect(ReachabilityCopy.emptyAnswerBadge(nil) == ReachabilityCopy.noEmailFoundBadge)
        #expect(ReachabilityCopy.emptyAnswerHelp(nil) == ReachabilityCopy.noEmailFoundHelp)
    }

    // Each reason's help says what that check actually did, and the two refusal cases must not collapse
    // into the same sentence (L11: distinct causes get distinct messages).
    @Test func eachReasonExplainsItselfDistinctly() {
        let venue = ReachabilityCopy.emptyAnswerHelp(.onlyVenueContact)
        let press = ReachabilityCopy.emptyAnswerHelp(.onlyPressContact)
        #expect(venue != press)
        #expect(venue != ReachabilityCopy.noEmailFoundHelp)
        #expect(press != ReachabilityCopy.noEmailFoundHelp)
        // Both must say an address WAS found, since that is the correction being made.
        #expect(venue.lowercased().contains("found"))
        #expect(press.lowercased().contains("found"))
    }
}

// The contract half. The reason has to be EMITTED by the run, because the runbook disqualifies a venue
// address and therefore never sends one, so the app has nothing to infer a reason from.
@Suite("The empty-answer reason crosses the results contract (#1722)")
struct EmptyAnswerReasonContractTests {

    @Test func aResultCarriesTheReasonWhenTheRunGivesOne() throws {
        let json = """
        {"version":7,"generatedAt":"2026-07-29T12:00:00Z","results":[
          {"naturalKey":"k","emptyReason":"only_venue_contact"}
        ]}
        """.data(using: .utf8)!
        let decoded = try PrepResultsDecoder.decode(json)
        #expect(decoded.results.first?.emptyReason == "only_venue_contact")
        #expect(decoded.results.first?.contacts == nil)
    }

    // Additive and optional, so every v6 producer stays valid and no existing fixture changes meaning.
    @Test func aResultWithoutOneStillDecodes() throws {
        let json = """
        {"version":6,"generatedAt":"2026-07-29T12:00:00Z","results":[{"naturalKey":"k"}]}
        """.data(using: .utf8)!
        let decoded = try PrepResultsDecoder.decode(json)
        #expect(decoded.results.first?.emptyReason == nil)
    }

    // THE TRAP this test exists for. `PrepImporter.answeredKeys` decodes with NO version gate and
    // succeeds on a v7 file, while `ingestFile` goes through PrepResultsDecoder and throws, and
    // `consumeIfNew` swallows that with `try?`. If the version the runner writes ever outruns
    // supportedVersion, markProbed stamps every show with the no-email floor, nothing upgrades it, and the
    // badge locks them out of a re-check for ~90 days. That is the #1594 shape. The two must move together.
    @Test func theSupportedVersionKeepsUpWithTheVersionTheContractNowCarries() {
        #expect(PrepResultsDecoder.supportedVersion >= 7)
    }
}

@MainActor
@Suite("Ingesting an empty answer (#1722)")
struct EmptyAnswerReasonIngestTests {
    private func container() throws -> ModelContainer {
        try ModelContainer(for: Schema([Prospect.self]),
                           configurations: [ModelConfiguration(isStoredInMemoryOnly: true)])
    }

    private func newProspect(_ ctx: ModelContext) -> String {
        let key = Prospect.makeNaturalKey(groupName: "Aurora Strings", performanceDate: "2026-09-12",
                                          venue: "Weill Recital Hall")
        let p = Prospect(naturalKey: key, groupName: "Aurora Strings", discipline: "music",
                         venue: "Weill Recital Hall", performanceDate: "2026-09-12",
                         sourceListingURL: nil, websiteURL: nil, priorRelationship: "none",
                         production: "self", profile: "strong", coverage: "likely_uncovered",
                         fitScore: 6, tier: "mid", fitReason: "r", matchedClientName: nil,
                         possibleMatchSource: nil, possibleMatchName: nil, status: .new)
        ctx.insert(p)
        try? ctx.save()
        return key
    }

    private func prospect(_ ctx: ModelContext, _ key: String) throws -> Prospect? {
        try ctx.fetch(FetchDescriptor<Prospect>(predicate: #Predicate { $0.naturalKey == key })).first
    }

    // The case in the issue: a run that answered, found only the room's own address, and refused it.
    @Test func aRefusedVenueAddressIsRecordedAsTheReason() throws {
        let ctx = ModelContext(try container())
        let key = newProspect(ctx)
        let now = Date(timeIntervalSince1970: 1_780_000_000)

        _ = PrepImporter.ingest(PrepResults(version: 7, generatedAt: "now", results: [
            PrepResult(naturalKey: key, emptyReason: "only_venue_contact")
        ]), into: ctx, now: now, isProbe: true)

        let p = try prospect(ctx, key)
        #expect(p?.reachabilityEmptyReason == .onlyVenueContact)
        #expect(p?.reachabilityProbedAt == now)
        // The result itself is unchanged: this is a sentence, not a new verdict.
        #expect(p?.reachabilityResult == nil || p?.reachabilityResult == .noEmailFound)
    }

    // A later run that DOES find a contact must not leave the old sentence behind, or the card says
    // "only the venue's address" over an address Dan can write to (L14: every action updates every
    // surface showing what it changed).
    @Test func findingAContactLaterClearsTheReason() throws {
        let ctx = ModelContext(try container())
        let key = newProspect(ctx)
        let now = Date(timeIntervalSince1970: 1_780_000_000)

        _ = PrepImporter.ingest(PrepResults(version: 7, generatedAt: "now", results: [
            PrepResult(naturalKey: key, emptyReason: "only_venue_contact")
        ]), into: ctx, now: now, isProbe: true)
        #expect(try prospect(ctx, key)?.reachabilityEmptyReason == .onlyVenueContact)

        _ = PrepImporter.ingest(PrepResults(version: 7, generatedAt: "now", results: [
            PrepResult(naturalKey: key,
                       contacts: [PrepContact(name: "Jane Doe", role: "Manager", email: "jane@aurora.example",
                                              method: "named_decision_maker", confidence: "high",
                                              formUrl: nil, provenance: "act")])
        ]), into: ctx, now: now.addingTimeInterval(60), isProbe: true)

        #expect(try prospect(ctx, key)?.reachabilityEmptyReason == nil)
    }

    // Dan typing a contact by hand is the strongest possible evidence there IS somebody to email, so a
    // stale refusal sentence must not survive it. Mirrors the #1596 Phase 3 reasoning one branch above.
    @Test func aContactDanAddedHimselfClearsTheReason() throws {
        let ctx = ModelContext(try container())
        let key = newProspect(ctx)
        let now = Date(timeIntervalSince1970: 1_780_000_000)

        _ = PrepImporter.ingest(PrepResults(version: 7, generatedAt: "now", results: [
            PrepResult(naturalKey: key, emptyReason: "only_venue_contact")
        ]), into: ctx, now: now, isProbe: true)

        let p = try prospect(ctx, key)
        p?.recipientsEditedByDan = true
        try? ctx.save()

        _ = PrepImporter.ingest(PrepResults(version: 7, generatedAt: "now", results: [
            PrepResult(naturalKey: key, emptyReason: "only_venue_contact")
        ]), into: ctx, now: now.addingTimeInterval(60), isProbe: true)

        #expect(try prospect(ctx, key)?.reachabilityEmptyReason == nil)
    }

    // An unrecognised reason from a newer producer must not be stored as a claim the app cannot explain.
    @Test func anUnknownReasonIsNotStored() throws {
        let ctx = ModelContext(try container())
        let key = newProspect(ctx)

        _ = PrepImporter.ingest(PrepResults(version: 7, generatedAt: "now", results: [
            PrepResult(naturalKey: key, emptyReason: "invented_by_a_newer_run")
        ]), into: ctx, now: Date(timeIntervalSince1970: 1_780_000_000), isProbe: true)

        #expect(try prospect(ctx, key)?.reachabilityEmptyReason == nil)
    }
}

// A guard and its wiring are two claims (#887). Every sentence above can be right while the card still
// draws the old one.
@Suite("The card draws the reason-aware sentence (#1722)")
struct EmptyAnswerReasonWiringTests {
    @Test func theRowAsksForTheReasonAwareCopy() {
        let row = SourceGuardHelper.source("Overture/UI/ProspectRowView.swift")
        #expect(row.contains("ReachabilityCopy.emptyAnswerBadge("))
        #expect(row.contains("ReachabilityCopy.emptyAnswerHelp("))
    }

    // The runbook is the only thing that can produce a reason, so a runbook that stops asking for one
    // silently returns every card to the old sentence with every test above still green.
    @Test func theRunbookStillAsksTheRunToSayWhyAnAnswerWasEmpty() {
        let runbook = SourceGuardHelper.source("../docs/prep-runbook.md")
        #expect(runbook.contains("emptyReason"))
        #expect(runbook.contains("only_venue_contact"))
    }
}
