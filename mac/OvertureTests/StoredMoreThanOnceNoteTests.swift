import Testing
import Foundation
import SwiftData

// #3282: Overture can hold two rows for one show and no surface anywhere says so. The false
// cancellation warning in #3278 was only the symptom that happened to be visible, and #3921 fixed
// that symptom without making the underlying fact visible anywhere.
//
// Measured through `ShowLink` on the live store 2026-09-19: 19 groups over the whole store, 6 of them
// on the queue, joining 12 rows Dan is looking at as 12 separate cards.
//
// This is the card saying so, in the place he already meets the show, rather than a report on a screen
// nothing links to (L546). `linkedEngagementNote` beside it is the precedent: EngagementLink finds the
// same production at other venues and the card carries one line about it.
@Suite("A card says when the same show is stored more than once (#3282)")
struct StoredMoreThanOnceNoteTests {

    private func item(_ others: [String]) -> QueueItem {
        var item = QueueItem(id: "k", groupName: "A Show", discipline: "music", venue: "A Room",
                             performanceDate: "2026-10-02", sourceListingURL: nil,
                             priorRelationship: "none", production: "unknown", profile: "neutral",
                             coverage: "unknown", fitScore: 3, tier: "longshot", fitReason: "r",
                             matchedClientName: nil, possibleMatchSource: nil,
                             possibleMatchName: nil, status: .new)
        item.sameShowKeys = others
        return item
    }

    @Test func saysNothingWhenTheShowIsStoredOnce() {
        #expect(QueueModel.storedMoreThanOnceNote(item([])) == nil)
    }

    // The commonest real case by far: every one of the six groups on the queue today holds exactly two
    // rows, so "stored twice" is the sentence Dan will actually read. It counts ROWS rather than the
    // OTHERS, so the number in the sentence is the number of copies, which is what the reader expects
    // a count after "stored" to mean.
    @Test func saysStoredTwiceForTheCommonestCase() {
        #expect(QueueModel.storedMoreThanOnceNote(item(["other"]))
                == "This show is stored twice.")
    }

    @Test func countsEveryRowHoldingTheShowWhenThereAreSeveral() {
        #expect(QueueModel.storedMoreThanOnceNote(item(["a", "b", "c"]))
                == "This show is stored 4 times.")
    }

    // MARK: the wiring, because a sentence no card can reach says nothing

    private func memoryContext() throws -> ModelContext {
        let schema = Schema([Prospect.self, Recipient.self])
        return ModelContext(try ModelContainer(for: schema,
                            configurations: [ModelConfiguration(schema: schema,
                                                                isStoredInMemoryOnly: true)]))
    }

    @discardableResult
    private func row(_ ctx: ModelContext, key: String, title: String, venue: String,
                     opens: String, runEnd: String? = nil, nights: [String]? = nil) -> Prospect {
        let p = Prospect(naturalKey: key, groupName: title, discipline: "theater", venue: venue,
                         performanceDate: opens, sourceListingURL: nil, priorRelationship: "none",
                         production: "unknown", profile: "unknown", coverage: "unknown", fitScore: 3,
                         tier: "medium", fitReason: "", matchedClientName: nil,
                         possibleMatchSource: nil, possibleMatchName: nil,
                         runEndDate: runEnd, partOfRelatedRun: runEnd != nil,
                         runSourceURLs: [], runNights: nights ?? [opens])
        ctx.insert(p)
        return p
    }

    @Test func theCardCarriesTheOtherRowsHoldingThisShow() throws {
        let ctx = try memoryContext()
        row(ctx, key: "single", title: "We Are Happy To Serve You", venue: "The Players Theatre",
            opens: "2026-12-20")
        row(ctx, key: "run", title: "We Are Happy To Serve You", venue: "The Players Theatre",
            opens: "2026-12-03", runEnd: "2026-12-20",
            nights: ["2026-12-03", "2026-12-20"])
        let all = try ctx.fetch(FetchDescriptor<Prospect>())

        var data = QueueModel.scope(from: all)
        let row = try #require(data.rows.first { $0.id == "single" })
        #expect(data.cards.card(for: row).sameShowKeys == ["run"])
    }

    // The negative half. Two rows at one venue under one title on nights that do not overlap are the
    // Tuudr shape and are NOT one show, so neither card may accuse the store of holding a duplicate.
    @Test func aCardSaysNothingWhenTheOtherRowIsADifferentShow() throws {
        let ctx = try memoryContext()
        row(ctx, key: "oct11", title: "Tuudr Piano Competition Gala", venue: "Weill Recital Hall",
            opens: "2026-10-11")
        row(ctx, key: "oct31", title: "Tuudr Piano Competition Gala", venue: "Weill Recital Hall",
            opens: "2026-10-31")
        let all = try ctx.fetch(FetchDescriptor<Prospect>())

        var data = QueueModel.scope(from: all)
        let row = try #require(data.rows.first { $0.id == "oct11" })
        #expect(data.cards.card(for: row).sameShowKeys.isEmpty)
    }

    // Judged over the WHOLE corpus, not the caller's rows: a second row for this show may itself be
    // dismissed or outside the queue's window, and a duplicate the caller's scope happens to exclude is
    // still a duplicate. The same reason `contradictedCancellations` beside it is built that way.
    @Test func aDuplicateOutsideTheCallersRowsIsStillCounted() throws {
        let ctx = try memoryContext()
        let shown = row(ctx, key: "shown", title: "Space Quest", venue: "The Players Theatre",
                        opens: "2027-02-04", runEnd: "2027-02-07",
                        nights: ["2027-02-04", "2027-02-07"])
        row(ctx, key: "hidden", title: "Space Quest", venue: "The Players Theatre",
            opens: "2027-01-07", runEnd: "2027-02-07",
            nights: ["2027-01-07", "2027-02-07"])
        let all = try ctx.fetch(FetchDescriptor<Prospect>())

        var data = QueueModel.scope(from: [shown], corpus: all)
        let row = try #require(data.rows.first { $0.id == "shown" })
        #expect(data.cards.card(for: row).sameShowKeys == ["hidden"])
    }
}
