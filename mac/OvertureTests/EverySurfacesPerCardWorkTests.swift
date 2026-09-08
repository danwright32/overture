import Testing
import Foundation
import SwiftData

// #3499: #2048 pinned the per-card work for the QUEUE, through `QueueRenderPass`. The two other surfaces
// that build `QueueItem`s call `QueueModel.items` directly and go through no pass, so neither had its
// per-card work pinned by anything.
//
// That matters because Archive is where the cost was actually measured: on the running app, 2026-09-02
// (#3437), `ArchiveView.items` weighed 65% of the main thread while typing, with `QueueItem.init` at 33%.
// The surface with the most measured per-card cost was the one no counter judged.
//
// WHAT THIS CAN AND CANNOT DO. `WorkTally` is a task local and `QueueModel.items` is shared, so the
// counters already fire on those paths; what was missing is something binding a tally around each
// surface's derivation and holding the result to a number. A SwiftUI body cannot be evaluated in a unit
// test, so each derivation is asked here the way the view asks it, and `EverySurfaceIsCountedGuardTests`
// below checks that list against the source rather than against memory (L96, L263).
//
// A SURFACE NOT COVERED REPORTS UNMEASURED, never zero, which is #3499's own requirement and the reason
// the coverage half is a separate suite: a surface silently contributing nothing and a surface with no
// per-card work look identical from a number (L98, L90).
@MainActor
@Suite("Every surface that builds cards has its per-card work pinned (#3499)")
struct EverySurfacesPerCardWorkTests {

    // The same corpus shape the queue's own counter is pinned against, so the three surfaces' figures can
    // be read side by side. Shared through the one type that records the live shape (#3516).
    private static let corpusSize = 1142

    private func container() throws -> ModelContainer {
        try ModelContainer(
            for: Schema([Prospect.self, Recipient.self, Inquiry.self, OrgReachabilityAnswer.self,
                         WatchedSource.self]),
            configurations: [ModelConfiguration(isStoredInMemoryOnly: true)])
    }

    private func seed(_ ctx: ModelContext) -> [Prospect] {
        let dates = LiveDateClustering.dates(forRows: Self.corpusSize)
        var rows: [Prospect] = []
        for n in 0..<Self.corpusSize {
            let p = Prospect(naturalKey: "row-\(n)", groupName: "Ensemble \(n % 90)", discipline: "music",
                             venue: "Venue \(n % 169) Hall", performanceDate: dates[n],
                             sourceListingURL: nil, priorRelationship: "none",
                             production: n % 3 == 0 ? "self" : "presenter", profile: "strong",
                             coverage: "likely_uncovered", fitScore: 4 + (n % 5), tier: "mid",
                             fitReason: "r", matchedClientName: nil, possibleMatchSource: nil,
                             possibleMatchName: nil,
                             status: n % 3 == 0 ? .drafted : .new)
            p.presenter = "Ensemble \(n % 90) Presents"
            p.location = "New York, NY"
            ctx.insert(p)
            rows.append(p)
        }
        try? ctx.save()
        return rows
    }

    // ARCHIVE, asked the way `ArchiveView.items` asks it: no corpus argument, so the whole-store
    // judgments the queue makes are absent here, which is itself worth having pinned.
    static func archiveDerivation(_ rows: [Prospect]) -> [QueueItem] {
        QueueModel.items(from: rows, answers: [], overrides: .none, sources: [], refusals: .none)
    }

    // THE ROOT VIEW, asked the way `RootView.allItems` asks it: a bare map, with no answers, no corpus and
    // no overrides at all.
    static func rootViewDerivation(_ rows: [Prospect]) -> [QueueItem] {
        rows.map(QueueItem.init)
    }

    @Test("Archive builds one card per row and one send group per card")
    func archiveIsPinned() throws {
        let ctx = ModelContext(try container())
        let rows = seed(ctx)

        let work = QueueRenderPass.WorkTally.measure { _ = Self.archiveDerivation(rows) }

        #expect(work.queueItems == Self.corpusSize)
        #expect(work.sendGroupBuilds == Self.corpusSize)
        // No row in this corpus carries a body, so nothing reaches DraftCheck. Pinned rather than left
        // out, because zero is only meaningful beside the assertion that says why it is zero (L90).
        #expect(work.draftLintRuns == 0)
        #expect(rows.allSatisfy { ($0.draftBody ?? "").isEmpty },
                "a row carries a body, so the lint figure above is not the zero it claims to be")
    }

    @Test("the root view builds one card per row and one send group per card")
    func rootViewIsPinned() throws {
        let ctx = ModelContext(try container())
        let rows = seed(ctx)

        let work = QueueRenderPass.WorkTally.measure { _ = Self.rootViewDerivation(rows) }

        #expect(work.queueItems == Self.corpusSize)
        #expect(work.sendGroupBuilds == Self.corpusSize)
        #expect(work.draftLintRuns == 0)
    }

    // The two surfaces cost the SAME per card, which is the finding worth pinning rather than the two
    // numbers separately: `QueueItem.init` is where the per-card work lives, so passing fewer arguments
    // to `QueueModel.items` buys nothing at all. A change that made one of them cheaper without the other
    // would be a real difference and is what this catches.
    @Test("no surface builds a card more cheaply than another")
    func everySurfacePaysTheSamePerCard() throws {
        let ctx = ModelContext(try container())
        let rows = seed(ctx)

        let archive = QueueRenderPass.WorkTally.measure { _ = Self.archiveDerivation(rows) }
        let root = QueueRenderPass.WorkTally.measure { _ = Self.rootViewDerivation(rows) }

        #expect(archive.queueItems == root.queueItems)
        #expect(archive.sendGroupBuilds == root.sendGroupBuilds)
        #expect(archive.queueItems > 0, "neither derivation built a card, so this compared two zeroes")
    }
}

// The coverage half, kept separate because it answers a different question: not "what does this surface
// cost" but "is there a surface nobody is measuring".
@Suite("Every card-building surface is covered by a counter (#3499)")
struct EverySurfaceIsCountedGuardTests {

    // A file that builds `QueueItem`s, and where its per-card work is pinned. DERIVED below rather than
    // trusted: the walk finds the files, and this says what is done about each (L96).
    struct Covered: Equatable, Sendable {
        let file: String
        let by: String
    }

    static let covered: [Covered] = [
        Covered(file: "QueueRenderPass.swift",
                by: "QueueRenderPassWorkUnitCostTests, which measures the pass itself. This is where the "
                  + "queue's own derivation moved in #1913, and it is the reason the guard is derived "
                  + "from the source: #3499 named QueueView.swift and RootView.swift by line number, and "
                  + "the queue's card build had already left the file it named."),
        Covered(file: "QueueView.swift",
                by: "QueueRenderPassWorkUnitCostTests for the render path. Its remaining "
                  + "QueueModel.items call is the `items` property, read only by action handlers "
                  + "(a scroll jump, a Prep confirm, a send confirm), which run on a press rather than "
                  + "during a render and pay the same per card as the pass does."),
        Covered(file: "ArchiveView.swift", by: "EverySurfacesPerCardWorkTests.archiveIsPinned"),
        Covered(file: "RootView.swift", by: "EverySurfacesPerCardWorkTests.rootViewIsPinned"),
    ]

    // Every app file that turns prospects into cards, whichever of the two spellings it uses.
    static func cardBuildingFiles(_ files: [AppSourceWalk.File]) -> [String] {
        files.filter { file in
            let code = SourceGuardHelper.normalizedCode(file.text)
            // #3653: `scope(from:` joins the list rather than replacing `items(from:`. The render pass
            // takes the arm that builds the cheap rows beside the cards; ArchiveView and QueueView's own
            // action-path property still take the cards-only forwarder. A walk that knew only the new
            // spelling would stop seeing two of the four surfaces it exists to enumerate (L96, L247).
            return code.contains("QueueModel.items(from:") || code.contains("QueueModel.scope(from:")
                || code.contains("map(QueueItem.init)")
        }
        .map(\.name).sorted()
    }

    @Test("no surface builds cards without something pinning what that costs")
    func everyCardBuildingSurfaceIsPinned() {
        let files = AppSourceWalk.files(under: RepoRoot.url.appendingPathComponent("mac/Overture"))
        let building = Self.cardBuildingFiles(files)

        // UNMEASURED, and it is its own outcome: a walk that read nothing and an app that builds no cards
        // leave the same empty list, and the emptiest possible failure must not read as the cleanest
        // possible pass (L98, L11).
        #expect(!building.isEmpty,
                """
                No file in the app was seen building QueueItems at all. That is a broken reader, not an \
                app without a queue: with nothing found, every assertion below passes over every surface \
                it exists to check (#3499).
                """)

        let uncovered = building.filter { name in !Self.covered.contains(where: { $0.file == name }) }
        #expect(uncovered.isEmpty,
                """
                \(uncovered.joined(separator: ", ")) build QueueItems and nothing pins what that costs \
                per card. #2048's counters fire on those paths already; what is missing is a test that \
                binds a tally around the derivation and holds the result to a number, so a change that \
                adds per-card work there moves no number (#3499, L63).
                """)

        // And the other way, so an entry naming a surface that has stopped building cards goes red rather
        // than sitting here reading as coverage (L346).
        for entry in Self.covered {
            #expect(building.contains(entry.file),
                    "\(entry.file) is recorded as a card-building surface and no longer builds any")
        }
    }
}
