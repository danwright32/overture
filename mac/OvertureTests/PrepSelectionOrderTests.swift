import Testing
import Foundation
import SwiftData

// #3375 and #3378: what order the "Which kept shows to prep?" sheet lists shows in.
//
// Dan, 2026-08-30: "this list should be in chronological order". It was in no order at all. `toPrep` is
// a `@Query` with no sort descriptor, so the array is whatever SwiftData returns, and the sheet renders
// it as handed. That is not merely untidy: an undeclared order is UNSTABLE, so the same sheet can
// present the same shows differently twice and nothing would notice (L343).
//
// The order lives here rather than in the view, so it is testable without rendering anything and cannot
// drift from what the sheet draws.
@MainActor
@Suite("The prep selection sheet is ordered (#3375)")
struct PrepSelectionOrderTests {
    private func container() throws -> ModelContainer {
        try ModelContainer(for: AppSchema.schema,
                           configurations: ModelConfiguration(isStoredInMemoryOnly: true))
    }

    @discardableResult
    private func show(_ ctx: ModelContext, _ group: String, on day: String?, at venue: String) -> Prospect {
        let p = Prospect(naturalKey: "\(group)|\(day ?? "none")|\(venue)", groupName: group,
                         discipline: "music", venue: venue, performanceDate: day,
                         sourceListingURL: nil, priorRelationship: "none", production: "self",
                         profile: "strong", coverage: "likely_uncovered", fitScore: 5, tier: "mid",
                         fitReason: "r", matchedClientName: nil, possibleMatchSource: nil,
                         possibleMatchName: nil)
        ctx.insert(p)
        return p
    }

    // Dan's own list, in the order his screenshot showed it, asserted to come back chronological.
    @Test func theShowsComeBackSoonestFirst() throws {
        let ctx = ModelContext(try container())
        for (name, day) in [("Let Down Your Hair", "2026-09-16"), ("Eddie Olmo II", "2026-09-14"),
                            ("Adriane Lenox", "2026-09-11"), ("MOONRISE", "2026-09-19"),
                            ("New York Percussion Series", "2026-09-08"),
                            ("Kyle Ramar Freeman", "2026-09-21"), ("Kait Hickey", "2026-09-14")] {
            show(ctx, name, on: day, at: "A Hall")
        }
        let ordered = PrepQueueBuilder.prepSelectionOrder(prospects: try ctx.fetch(FetchDescriptor<Prospect>()))
        #expect(ordered.map(\.performanceDate) == ["2026-09-08", "2026-09-11", "2026-09-14",
                                                    "2026-09-14", "2026-09-16", "2026-09-19",
                                                    "2026-09-21"])
    }

    // A declared second key, so a reopening cannot reshuffle the two shows on Sep 14. Without it the
    // order is stable only by luck of what the store returned, which is the same defect one level down.
    @Test func showsOnOneDayAreOrderedByVenueThenGroup() throws {
        let ctx = ModelContext(try container())
        show(ctx, "Zeta Choir", on: "2026-09-14", at: "Weill")
        show(ctx, "Alpha Choir", on: "2026-09-14", at: "Weill")
        show(ctx, "Mid Choir", on: "2026-09-14", at: "Ades")
        let ordered = PrepQueueBuilder.prepSelectionOrder(prospects: try ctx.fetch(FetchDescriptor<Prospect>()))
        #expect(ordered.map(\.groupName) == ["Mid Choir", "Alpha Choir", "Zeta Choir"])
    }

    // A show with no date has a DECLARED place rather than falling wherever the store puts it. Last,
    // because the list is read soonest first and a show with no date answers no part of that question.
    @Test func anUndatedShowIsLastRatherThanWhereverItLands() throws {
        let ctx = ModelContext(try container())
        show(ctx, "No Date", on: nil, at: "A Hall")
        show(ctx, "Later", on: "2026-09-21", at: "A Hall")
        show(ctx, "Sooner", on: "2026-09-08", at: "A Hall")
        let ordered = PrepQueueBuilder.prepSelectionOrder(prospects: try ctx.fetch(FetchDescriptor<Prospect>()))
        #expect(ordered.map(\.groupName) == ["Sooner", "Later", "No Date"])
    }

    // Two undated shows still have an order between them, for the same reason two shows on one day do.
    @Test func twoUndatedShowsAreStillOrderedAgainstEachOther() throws {
        let ctx = ModelContext(try container())
        show(ctx, "Zeta", on: nil, at: "Weill")
        show(ctx, "Alpha", on: nil, at: "Weill")
        let ordered = PrepQueueBuilder.prepSelectionOrder(prospects: try ctx.fetch(FetchDescriptor<Prospect>()))
        #expect(ordered.map(\.groupName) == ["Alpha", "Zeta"])
    }

    // The order must be the SAME for any input order, which is what "declared" means. Given the
    // reverse, it comes back identical.
    @Test func theOrderDoesNotDependOnTheOrderItWasHanded() throws {
        let ctx = ModelContext(try container())
        for (name, day) in [("A", "2026-09-16"), ("B", "2026-09-14"), ("C", "2026-09-11")] {
            show(ctx, name, on: day, at: "A Hall")
        }
        let all = try ctx.fetch(FetchDescriptor<Prospect>())
        let forwards = PrepQueueBuilder.prepSelectionOrder(prospects: all).map(\.naturalKey)
        let backwards = PrepQueueBuilder.prepSelectionOrder(prospects: all.reversed()).map(\.naturalKey)
        #expect(forwards == backwards)
    }

    // #3378: the guard that keeps this the only one.
    //
    // The enumeration that issue asked for, run 2026-09-04 over `mac/Overture/`: 43 `@Query`
    // declarations, 7 with a sort descriptor. Zero of the unsorted ones are rendered DIRECTLY by a
    // `ForEach`, so the obvious rule would have been one that could never fire (L557). 26 hand an
    // unsorted result on as an argument, but 25 of those go to something that AGGREGATES it (a count, a
    // tally, a report, a ledger) where order is meaningless, so a rule there would fire on the ordinary
    // case and be switched off within a day (L93).
    //
    // What discriminates is the exact shape #3375 had: a View whose init MAPS an array parameter into a
    // stored list that a `ForEach` renders. Exactly one file in the tree does that, and it is this one.
    @Test func noViewMapsAnInitParameterIntoARenderedListWithoutOrderingIt() throws {
        var offenders: [String] = []
        var scanned = 0
        for file in AppSourceWalk.appFiles() {
            let src = file.text
            guard src.contains(": View {") else { continue }
            scanned += 1
            for line in src.components(separatedBy: "\n") where line.contains(".map {") {
                let assigned = line.contains("self.rows =") || line.contains("self.items =")
                    || line.contains("self.entries =")
                guard assigned else { continue }
                guard src.contains("ForEach(rows") || src.contains("ForEach(items")
                    || src.contains("ForEach(entries") else { continue }
                if !src.contains("Order(prospects:") && !src.contains("sorted") {
                    offenders.append("\(file.name): \(line.trimmingCharacters(in: .whitespaces))")
                }
            }
        }
        // UNMEASURED is its own outcome: a scan that read no view files and a tree with no offenders
        // leave the same empty result (L98).
        #expect(scanned > 20, "the scan read only \(scanned) view files, so it measured nothing")
        #expect(offenders.isEmpty, "\(offenders)")
    }
}
