import Testing
import Foundation
import SwiftData

// #1824: what the run understood the show to BE, written back so the instruction leaves a checkable trace
// instead of living only in the prompt (L27), and so Dan can see whether a draft was grounded in anything.
//
// The vocabulary is deliberately three reasons, not one absent field. "There was no listing page", "we
// could not read the page" and "the page publishes no description" are three different facts about the
// world, and collapsing them would put the app right back to claiming more than it measured (L11).
@Suite("What this show is (#1824)")
struct ShowSummaryTests {

    // The raw strings cross the language boundary in overture-prep-results.json, so they are pinned here
    // rather than left to the enum's spelling.
    @Test func theAbsenceVocabularyIsTheContractsOwnSpelling() {
        #expect(ShowSummaryAbsence(rawValue: "no_listing_page") == .noListingPage)
        #expect(ShowSummaryAbsence(rawValue: "page_unreadable") == .pageUnreadable)
        #expect(ShowSummaryAbsence(rawValue: "no_description_published") == .noDescriptionPublished)
        // A value a newer run invents is not coerced into one of the three: it reads as no reason given,
        // which shows nothing rather than a claim the app cannot stand behind.
        #expect(ShowSummaryAbsence(rawValue: "something_new") == nil)
    }

    // Each reason says what actually happened, and no two collapse into the same sentence.
    @Test func eachReasonSaysWhatActuallyHappened() {
        let none = ShowSummaryCopy.absenceLine(.noListingPage)
        let unreadable = ShowSummaryCopy.absenceLine(.pageUnreadable)
        let undescribed = ShowSummaryCopy.absenceLine(.noDescriptionPublished)
        #expect(Set([none, unreadable, undescribed].compactMap { $0 }).count == 3)
        #expect(none?.isEmpty == false)
    }

    // No reason given means say nothing. Every draft written before this feature existed is in exactly
    // that state, and a line on all of them would be noise claiming a fact nobody measured.
    @Test func noReasonShowsNothingAtAll() {
        #expect(ShowSummaryCopy.absenceLine(nil) == nil)
    }

    // The summary itself is shown as the run wrote it, with no label in front of it. A "What this show is:"
    // prefix would be the #843 shape: a second line saying what the line beside it already says.
    @Test func aSummaryIsShownAsWritten() {
        #expect(ShowSummaryCopy.line(summary: "A cabaret concert of new songs, with a cast of five",
                                     absence: .pageUnreadable)
                == "A cabaret concert of new songs, with a cast of five")
    }

    // A summary and a reason cannot both be true. If a run sends both, the summary wins: it is the thing
    // that actually carries information, and the reason would contradict it on screen.
    @Test func aSummaryOutranksAContradictoryReason() {
        #expect(ShowSummaryCopy.line(summary: "A staged opera in two acts", absence: .noListingPage)
                == "A staged opera in two acts")
    }

    // An empty or whitespace summary is not a summary. Without this, a run that emitted `""` would blank
    // the line and silently suppress the honest reason beside it.
    @Test func anEmptySummaryFallsBackToTheReason() {
        #expect(ShowSummaryCopy.line(summary: "   ", absence: .noDescriptionPublished)
                == ShowSummaryCopy.absenceLine(.noDescriptionPublished))
        #expect(ShowSummaryCopy.line(summary: nil, absence: nil) == nil)
    }
}

// The contract half: the summary has to be EMITTED by the run, because only the run reads the listing text.
@Suite("The show summary crosses the results contract (#1824)")
struct ShowSummaryContractTests {

    private func fixture(_ name: String) throws -> Data {
        try Data(contentsOf: RepoRoot.url
            .appendingPathComponent("fixtures/prep-results").appendingPathComponent(name))
    }

    @Test func theV8FixtureCarriesBothASummaryAndAnAbsentReason() throws {
        let decoded = try PrepResultsDecoder.decode(try fixture("v8.json"))
        #expect(decoded.version == 8)
        #expect(decoded.results[0].showSummary?.contains("cabaret concert") == true)
        #expect(decoded.results[0].showSummaryAbsentReason == nil)
        #expect(decoded.results[1].showSummary == nil)
        #expect(decoded.results[1].showSummaryAbsentReason == "no_description_published")
    }

    // Additive and optional, so every v7 producer stays valid and no committed fixture changes meaning.
    @Test func aResultWithoutEitherStillDecodes() throws {
        let json = Data("""
        {"version":7,"generatedAt":"2026-07-30T12:00:00Z","results":[{"naturalKey":"k"}]}
        """.utf8)
        let decoded = try PrepResultsDecoder.decode(json)
        #expect(decoded.results.first?.showSummary == nil)
        #expect(decoded.results.first?.showSummaryAbsentReason == nil)
    }

    // The #1594 trap, restated for this bump. `PrepImporter.answeredKeys` decodes with NO version gate and
    // succeeds on a newer file, while `ingestFile` comes through the decoder and throws, and `consumeIfNew`
    // swallows that with `try?`. If the version the runner writes ever outruns supportedVersion, a whole
    // run's drafts are silently dropped. The two must move together.
    @Test func theSupportedVersionKeepsUpWithTheVersionTheContractNowCarries() {
        #expect(PrepResultsDecoder.supportedVersion >= 8)
    }
}

@MainActor
@Suite("Ingesting what the show is (#1824)")
struct ShowSummaryIngestTests {
    private func container() throws -> ModelContainer {
        try ModelContainer(for: Schema([Prospect.self]),
                           configurations: [ModelConfiguration(isStoredInMemoryOnly: true)])
    }

    private func newProspect(_ ctx: ModelContext) -> String {
        let key = Prospect.makeNaturalKey(groupName: "Alex Example", performanceDate: "2026-09-12",
                                          venue: "The Example Room")
        let p = Prospect(naturalKey: key, groupName: "Alex Example", discipline: "other",
                         venue: "The Example Room", performanceDate: "2026-09-12",
                         sourceListingURL: "https://tickets.example/a", websiteURL: nil,
                         priorRelationship: "none", production: "self", profile: "strong",
                         coverage: "likely_uncovered", fitScore: 6, tier: "mid", fitReason: "r",
                         matchedClientName: nil, possibleMatchSource: nil, possibleMatchName: nil,
                         status: .queued)
        ctx.insert(p)
        try? ctx.save()
        return key
    }

    private func prospect(_ ctx: ModelContext, _ key: String) throws -> Prospect? {
        try ctx.fetch(FetchDescriptor<Prospect>(predicate: #Predicate { $0.naturalKey == key })).first
    }

    @Test func theSummaryTheRunWroteIsStored() throws {
        let ctx = ModelContext(try container())
        let key = newProspect(ctx)

        _ = PrepImporter.ingest(PrepResults(version: 8, generatedAt: "now", results: [
            PrepResult(naturalKey: key, showSummary: "A cabaret concert of new songs, cast of five")
        ]), into: ctx, now: Date(timeIntervalSince1970: 1_780_000_000))

        #expect(try prospect(ctx, key)?.showSummary == "A cabaret concert of new songs, cast of five")
        #expect(try prospect(ctx, key)?.showSummaryAbsence == nil)
    }

    @Test func anHonestAbsenceIsStoredToo() throws {
        let ctx = ModelContext(try container())
        let key = newProspect(ctx)

        _ = PrepImporter.ingest(PrepResults(version: 8, generatedAt: "now", results: [
            PrepResult(naturalKey: key, showSummaryAbsentReason: "page_unreadable")
        ]), into: ctx, now: Date(timeIntervalSince1970: 1_780_000_000))

        #expect(try prospect(ctx, key)?.showSummary == nil)
        #expect(try prospect(ctx, key)?.showSummaryAbsence == .pageUnreadable)
    }

    // A later run that DID read the page must not leave the old "could not read it" line behind, or the
    // card contradicts the draft beside it (L14: every action updates every surface showing what it changed).
    @Test func aLaterRunThatReadsThePageClearsTheOldReason() throws {
        let ctx = ModelContext(try container())
        let key = newProspect(ctx)
        let now = Date(timeIntervalSince1970: 1_780_000_000)

        _ = PrepImporter.ingest(PrepResults(version: 8, generatedAt: "now", results: [
            PrepResult(naturalKey: key, showSummaryAbsentReason: "page_unreadable")
        ]), into: ctx, now: now)
        _ = PrepImporter.ingest(PrepResults(version: 8, generatedAt: "now", results: [
            PrepResult(naturalKey: key, showSummary: "A staged opera in two acts")
        ]), into: ctx, now: now.addingTimeInterval(60))

        #expect(try prospect(ctx, key)?.showSummary == "A staged opera in two acts")
        #expect(try prospect(ctx, key)?.showSummaryAbsence == nil)
    }

    // The runbook is a prompt (L27), so a run WILL sometimes send neither field. That is not evidence the
    // page became unreadable, so what is already recorded stands rather than being wiped by a silent gap.
    @Test func aRunThatSaysNothingLeavesWhatIsAlreadyKnown() throws {
        let ctx = ModelContext(try container())
        let key = newProspect(ctx)
        let now = Date(timeIntervalSince1970: 1_780_000_000)

        _ = PrepImporter.ingest(PrepResults(version: 8, generatedAt: "now", results: [
            PrepResult(naturalKey: key, showSummary: "A cabaret concert of new songs")
        ]), into: ctx, now: now)
        _ = PrepImporter.ingest(PrepResults(version: 8, generatedAt: "now", results: [
            PrepResult(naturalKey: key)
        ]), into: ctx, now: now.addingTimeInterval(60))

        #expect(try prospect(ctx, key)?.showSummary == "A cabaret concert of new songs")
    }

    // An unrecognised reason from a newer run must not be stored as a claim the app cannot explain.
    @Test func anUnknownReasonIsNotStored() throws {
        let ctx = ModelContext(try container())
        let key = newProspect(ctx)

        _ = PrepImporter.ingest(PrepResults(version: 8, generatedAt: "now", results: [
            PrepResult(naturalKey: key, showSummaryAbsentReason: "invented_by_a_newer_run")
        ]), into: ctx, now: Date(timeIntervalSince1970: 1_780_000_000))

        #expect(try prospect(ctx, key)?.showSummaryAbsence == nil)
    }
}

// A guard and its wiring are two claims (#887). Everything above can be right while nothing ever reaches
// the screen, which is how a written-only field ends up looking alive while its purpose never happens (L46).
@Suite("What this show is reaches the card (#1824)")
struct ShowSummaryWiringTests {
    @Test func theRowDrawsTheShowSummaryLine() {
        let row = SourceGuardHelper.source("Overture/UI/ProspectRowView.swift")
        #expect(row.contains("ShowSummaryCopy.line("))
    }

    @Test func theQueueModelCarriesItToTheRow() {
        let model = SourceGuardHelper.source("Overture/UI/QueueView+Model.swift")
        #expect(model.contains("showSummary"))
    }

    // Only the runbook can produce either field, so a runbook that stops asking silently empties the line
    // with every test above still green.
    @Test func theRunbookStillAsksTheRunWhatTheShowIs() {
        let runbook = SourceGuardHelper.source("../docs/prep-runbook.md")
        #expect(runbook.contains("showSummary"))
        #expect(runbook.contains("showSummaryAbsentReason"))
        #expect(runbook.contains("no_description_published"))
    }
}
