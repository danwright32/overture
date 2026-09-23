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

    // THE STAMP MOVING IS ITS OWN CLAIM, and the test above cannot see it: the INSERT arm stamps every
    // new row, so a fixture that only ever watches the first writer is answered by that line whatever the
    // update arm does. Measured: a mutation removing the update stamp (`if false { existing
    // .presenterSourceKey = incomingKey }`) SURVIVED the suite as first written (L467, L135).
    //
    // This is the direction where the incoming reading WINS, so the field's owner changes, and the second
    // half is what the stamp is FOR: the source whose own reading was displaced must not take the field
    // back on its next ordinary re-read.
    @Test func asourceThatFilledAnEmptyPresenterOwnsItAfterwards() throws {
        let ctx = try context()
        ingest(ctx, presenter: nil, source: "kaufmanmusiccenter-org")
        ingest(ctx, presenter: "Kaufman Music Center", source: "aggregator-example-org")
        #expect(try stored(ctx).presenterSourceKey == "aggregator-example-org",
                "the stamp stayed with the source that read nobody, so that source may erase this name")

        ingest(ctx, presenter: nil, source: "kaufmanmusiccenter-org")
        #expect(try stored(ctx).presenter == "Kaufman Music Center",
                "a source whose reading was displaced emptied the field on its next ordinary re-read")
    }

    // A LOSING READING WRITES NOTHING, and the field that proves it is the PROVENANCE beside the value
    // rather than the value itself. Writing the stored name back would go through `setPresenter(_:from:
    // .scout)`, which stamps `presenterSource`, so a name Dan (or the sweep, or the AI pass) put there
    // would be recorded as the scout's the first time any other source listed the show, and #2453's
    // refusal reads exactly that stamp: the name would then be erasable by the next ordinary re-read
    // that names nobody. The value and the record of who wrote it are one fact (L544).
    @Test func areadingThatLosesDoesNotRestampTheValueItLeftAlone() throws {
        let ctx = try context()
        ingest(ctx, presenter: "Kaufman Music Center", source: "kaufmanmusiccenter-org")

        // Dan corrects the name himself, which is what the stamp is there to protect.
        let row = try stored(ctx)
        row.setPresenter("Kaufman Music Center Presents", from: .dan)
        try ctx.save()

        ingest(ctx, presenter: "Some Other Presenter", source: "aggregator-example-org")

        let after = try stored(ctx)
        #expect(after.presenter == "Kaufman Music Center Presents")
        #expect(after.presenterSource == PresenterSource.dan.rawValue,
                "the losing source restamped the row as the scout's, so an ordinary re-read may now empty it")
        #expect(after.presenterSurvivesAnOrdinaryReRead,
                "which is the consequence that matters: #2453 stopped protecting the name")
    }

    // THE RULE ITSELF, as a pure function, including the case no ingest fixture can reach on a fresh row:
    // a row written before this shipped carries no stamp at all, which reads as nothing recorded, so the
    // incoming value lands and stamps it. That is what makes this shippable without a backfill (L389).
    @Test func arowWithNoStampTakesTheIncomingValueAndRecordsIt() {
        #expect(GenrePrecedence.incomingPresenterStands(stored: "Held", storedKey: nil,
                                                        incoming: "Incoming", incomingKey: "b"))
        #expect(GenrePrecedence.incomingPresenterStands(stored: "Held", storedKey: "   ",
                                                        incoming: nil, incomingKey: "b"),
                "an empty stamp is nothing recorded, so the incoming reading owns the field")
        #expect(GenrePrecedence.incomingPresenterStands(stored: nil, storedKey: "a",
                                                        incoming: "Incoming", incomingKey: "b"))
        #expect(GenrePrecedence.incomingPresenterStands(stored: "  ", storedKey: "a",
                                                        incoming: "Incoming", incomingKey: "b"),
                "a stored value that is only whitespace is nobody, so it must not block a real name")

        // AND THE CASE THAT DECIDES THE SHAPE of this rule: two sources reading the SAME name. A merge
        // returning the winning VALUE cannot separate them, so ownership would go to whoever spoke last.
        #expect(!GenrePrecedence.incomingPresenterStands(stored: "Same Name", storedKey: "a",
                                                         incoming: "Same Name", incomingKey: "b"),
                "a second source reading the same name took ownership of a value it did not put there")
        #expect(GenrePrecedence.incomingPresenterStands(stored: "Held", storedKey: "a",
                                                        incoming: "Other", incomingKey: "a"),
                "a source correcting its own reading owns what it writes")
        #expect(!GenrePrecedence.incomingPresenterStands(stored: "Held", storedKey: "a",
                                                         incoming: "Other", incomingKey: "b"),
                "between two sources that both read a name, the incumbent stands")
    }
}
