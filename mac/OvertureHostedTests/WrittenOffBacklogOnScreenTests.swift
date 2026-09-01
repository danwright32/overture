import Testing
import Foundation
import SwiftUI
import ViewInspector
@testable import Overture

// Milestone 61 Phase 0.3: the shows a paid check wrote off that turned out to hold a route, ON SCREEN.
//
// Separate from `WrittenOffBacklogTests`, which proves the report is computed correctly. A correct
// report that never reaches the screen is the #2204 shape (L3: built is not wired), and this section's
// whole job is to be the reader that makes the contradiction marker something other than dead data.
//
// Every branch is rendered, not just the populated one (#1547): a section whose explaining sentence
// lives only in the has-rows branch reads as broken in the state Dan is actually in most of the time,
// which here is the empty one, since the marker is written once and by nothing else ever.
@MainActor
@Suite("Shows written off that could be reached, on screen (#3356 Phase 0.3)")
struct WrittenOffBacklogOnScreenTests {

    private func lines(_ report: WrittenOffBacklog.Report) -> [String] {
        let view = WrittenOffBacklogBody(report: report)
        return ((try? view.inspect().findAll(ViewType.Text.self)) ?? [])
            .compactMap { try? $0.string() }
            .filter { !$0.isEmpty }
    }

    private func row(_ name: String, venue: String?, at: Date = Date()) -> WrittenOffBacklog.Row {
        WrittenOffBacklog.Row(naturalKey: "key-\(name)", groupName: name, venue: venue, markedAt: at)
    }

    // The state Dan is in on any Mac where the repair found nothing, which is most of them. The heading
    // must not stand over silence.
    @Test func theEmptyStateExplainsItselfUnderItsHeading() {
        let drawn = lines(WrittenOffBacklog.Report(rows: []))
        #expect(drawn == [WrittenOffBacklogCopy.title, WrittenOffBacklogCopy.nothingContradicted])
    }

    @Test func aWrittenOffShowIsNamedOnScreenWithItsRoom() {
        let drawn = lines(WrittenOffBacklog.Report(rows: [row("Kestrel Quartet", venue: "Rowan Hall")]))
        #expect(drawn == [WrittenOffBacklogCopy.title,
                          WrittenOffBacklogCopy.summary(count: 1),
                          "Kestrel Quartet",
                          "Rowan Hall"])
    }

    // A row with no room recorded still draws its show rather than an empty slot beside the name.
    @Test func aShowWithNoRoomStillDrawsItsName() {
        let drawn = lines(WrittenOffBacklog.Report(rows: [row("Kestrel Quartet", venue: nil)]))
        #expect(drawn == [WrittenOffBacklogCopy.title,
                          WrittenOffBacklogCopy.summary(count: 1),
                          "Kestrel Quartet"])
    }

    // The plural sentence is a different string from the singular one, and only one of them can be
    // wrong at a time, so both are rendered rather than only the branch that happens to be commonest.
    @Test func severalShowsUseThePluralSentence() {
        let drawn = lines(WrittenOffBacklog.Report(rows: [
            row("Kestrel Quartet", venue: "Rowan Hall", at: Date(timeIntervalSince1970: 1_800_000_000)),
            row("Marlow Ensemble", venue: "Rowan Hall", at: Date(timeIntervalSince1970: 1_700_000_000)),
        ]))
        #expect(drawn.contains(WrittenOffBacklogCopy.summary(count: 2)))
        #expect(!drawn.contains(WrittenOffBacklogCopy.summary(count: 1)))
        // Newest first, the order the report promises, proven where Dan actually reads it.
        #expect(drawn.firstIndex(of: "Kestrel Quartet")! < drawn.firstIndex(of: "Marlow Ensemble")!)
    }
}
