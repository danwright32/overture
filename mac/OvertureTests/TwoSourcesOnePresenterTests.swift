import Testing
import Foundation
import SwiftData

// #1954: a show found by two sources kept whichever presenter was written last.
//
// #1663 and #1949 gave the genre and the producer axes a precedence rule. The presenter those axes are
// DERIVED from kept none, so the field that decides the producer verdict, the genre word and the target
// of the paid contact hunt could flip run to run while everything computed from it held steady.
//
// PREMISE RE-CHECKED before this was built. The issue's original claim, an unconditional
// `existing.presenter = p.presenter`, is gone: #2453 replaced it with a provenance stamp that refuses an
// ERASURE by an ordinary scout re-read but lets a named value win. That guard answers a DIFFERENT
// question (may the scout empty what a sweep, the AI pass or Dan put there) and leaves this one open:
// may a different SOURCE take a field the first one filled. Until now it could.
//
// THE SHAPE IS THE ONE ALREADY IN THE FILE, `GenrePrecedence`, rather than a second vocabulary for the
// same question (L263): a source may always correct its own reading, and between two different sources a
// value that was read is never displaced by one that was not, with the incumbent standing when both read
// something.
@MainActor
@Suite("Two sources, one presenter (#1954)")
struct TwoSourcesOnePresenterTests {

    private static let venue = "Merkin Hall"
    private static let night = "2026-10-06"
    private static let title = "Orli Shaham, piano"

    private func context() throws -> ModelContext {
        ModelContext(try ModelContainer(for: Schema([Prospect.self, Recipient.self, DayOff.self]),
                                        configurations: [ModelConfiguration(isStoredInMemoryOnly: true)]))
    }

    @discardableResult
    private func ingest(_ ctx: ModelContext, presenter: String?, source: String,
                        title: String = title) -> ScoutService.Outcome {
        let e = ExtractedEvent(title: title, presenter: presenter ?? "", venue: Self.venue,
                               performanceDate: Self.night,
                               sourceUrl: "https://\(source)/listing")
        let outcome = ScoutService.apply(events: [e], clients: [], history: [], blocked: .empty,
                                         today: "2026-09-21", sourceIds: [source], into: ctx)
        try? ctx.save()
        return outcome
    }

    private func stored(_ ctx: ModelContext) throws -> Prospect {
        try #require(try ctx.fetch(FetchDescriptor<Prospect>()).first)
    }

    // THE CLAIM. A second source that names a DIFFERENT presenter does not take the field.
    @Test func asecondSourceDoesNotTakeAPresenterTheFirstOneFilled() throws {
        let ctx = try context()
        ingest(ctx, presenter: "Kaufman Music Center", source: "kaufmanmusiccenter-org")
        ingest(ctx, presenter: "Some Other Presenter", source: "aggregator-example-org")

        let row = try stored(ctx)
        #expect(row.presenter == "Kaufman Music Center",
                "the second source overwrote a presenter the first one read, which is last writer wins")
    }

    // AND IT NEVER SILENTLY ERASES ONE. A second source that names nobody is the commonest shape of this
    // collision and the one that costs the most: the producer axes are derived from this field.
    @Test func asecondSourceThatNamesNobodyDoesNotEmptyTheField() throws {
        let ctx = try context()
        ingest(ctx, presenter: "Kaufman Music Center", source: "kaufmanmusiccenter-org")
        ingest(ctx, presenter: nil, source: "aggregator-example-org")

        #expect(try stored(ctx).presenter == "Kaufman Music Center")
    }

    // A SOURCE MAY ALWAYS CORRECT ITSELF, which is every ordinary re-read and is what keeps #2453's
    // blank rule and #1766's drained room working exactly as they did.
    @Test func asourceCorrectingItsOwnReadingStillWins() throws {
        let ctx = try context()
        ingest(ctx, presenter: "Kaufman Music Center", source: "kaufmanmusiccenter-org")
        ingest(ctx, presenter: "Kaufman Music Center Presents", source: "kaufmanmusiccenter-org")

        #expect(try stored(ctx).presenter == "Kaufman Music Center Presents",
                "a source that cannot correct its own reading pins a stale name forever (#1795)")
    }

    // AND A SECOND SOURCE FILLS AN EMPTY FIELD, which is the direction that adds information. A
    // presenter that was read is never displaced by one that was not; the reverse is exactly what a
    // second source is for.
    @Test func asecondSourceFillsAPresenterNobodyHadRead() throws {
        let ctx = try context()
        ingest(ctx, presenter: nil, source: "kaufmanmusiccenter-org")
        ingest(ctx, presenter: "Kaufman Music Center", source: "aggregator-example-org")

        #expect(try stored(ctx).presenter == "Kaufman Music Center")
    }

    // THE STAMP, which is what makes all of the above decidable on the NEXT run too. It records whoever
    // is responsible for the value standing, never merely the last run to touch the row.
    @Test func theStampNamesWhoeverSPresenterIsStanding() throws {
        let ctx = try context()
        ingest(ctx, presenter: "Kaufman Music Center", source: "kaufmanmusiccenter-org")
        #expect(try stored(ctx).presenterSourceKey == "kaufmanmusiccenter-org")

        ingest(ctx, presenter: "Some Other Presenter", source: "aggregator-example-org")
        #expect(try stored(ctx).presenterSourceKey == "kaufmanmusiccenter-org",
                "the stamp moved to a source whose reading was refused, so the next run would let it win")
    }

    // THE RULE ITSELF, as a pure function, including the case no ingest fixture can reach on a fresh row:
    // a row written before this shipped carries no stamp at all, which reads as nothing recorded, so the
    // incoming value lands and stamps it. That is what makes this shippable without a backfill (L389).
    @Test func arowWithNoStampTakesTheIncomingValueAndRecordsIt() {
        #expect(GenrePrecedence.mergedPresenter(stored: "Held", storedKey: nil,
                                                incoming: "Incoming", incomingKey: "b") == "Incoming")
        #expect(GenrePrecedence.mergedPresenter(stored: "Held", storedKey: "   ",
                                                incoming: nil, incomingKey: "b") == nil,
                "an empty stamp is nothing recorded, so the incoming reading owns the field")
        #expect(GenrePrecedence.mergedPresenter(stored: nil, storedKey: "a",
                                                incoming: "Incoming", incomingKey: "b") == "Incoming")
        #expect(GenrePrecedence.mergedPresenter(stored: "  ", storedKey: "a",
                                                incoming: "Incoming", incomingKey: "b") == "Incoming",
                "a stored value that is only whitespace is nobody, so it must not block a real name")
    }
}
