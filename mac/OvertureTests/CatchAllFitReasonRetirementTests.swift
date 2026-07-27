import Testing
import Foundation
import SwiftData
@testable import Overture

// #1600 (milestone 32 Phase 7.1): retiring the classifier's catch-all fit reason.
//
// "Unclear producer; needs a closer look before pitching." was the final `return` of buildReason's
// if/else chain, so it carried every show that was neither agency-routed nor self-produced: 499 rows on
// the live store, 414 of them untriaged, roughly three quarters of the queue. Dan read it as "Overture
// doesn't know who the producer is", which it never meant. Measured on the same store, of the 419 rows
// then carrying it only 10 genuinely had no name: 233 named the room and 176 had a real producer. A
// line that is accidentally right on some rows and flatly wrong on others, with nothing to tell them
// apart, is worse than one that is consistently wrong.
@MainActor
@Suite("Retiring the catch-all fit reason (#1600)")
struct CatchAllFitReasonRetirementTests {

    // A show that is neither agency-routed nor self-produced falls to the end of the chain and now
    // carries no reason at all. The row already guards on an empty reason, so the line simply collapses:
    // removed, not replaced by a different sentence.
    @Test func aShowWithNoInformativeReasonNowCarriesNone() {
        // A bare title at a room, which is what three quarters of the queue looks like.
        let classification = EventClassifier.classify(
            ExtractedEvent(title: "An Evening of Song", presenter: nil, venue: "A Hall",
                           performanceDate: "2026-09-12", sourceUrl: nil))
        guard classification.production != .selfProduced, classification.production != .agency else {
            Issue.record("expected this fixture to fall through to the catch-all branch")
            return
        }
        #expect(classification.fitReason.isEmpty)
    }

    // The informative branches above it are untouched: this phase removes the empty sentence, it does
    // not stop the classifier explaining itself when it genuinely has something to say.
    @Test func theInformativeReasonsSurvive() {
        let selfProduced = EventClassifier.classify(
            ExtractedEvent(title: "The Dessoff Choirs sing Bach", presenter: "The Dessoff Choirs",
                           venue: "Church of St. Luke and St. Matthew",
                           performanceDate: "2026-09-12", sourceUrl: nil))
        guard selfProduced.production == .selfProduced else {
            Issue.record("expected this fixture to classify as self-produced")
            return
        }
        #expect(!selfProduced.fitReason.isEmpty)
    }

    private func container() throws -> ModelContainer {
        try ModelContainer(for: Schema([Prospect.self, Recipient.self]),
                           configurations: [ModelConfiguration(isStoredInMemoryOnly: true)])
    }

    @discardableResult
    private func makeShow(_ ctx: ModelContext, group: String, reason: String,
                          status: ReviewStatus = .new) -> Prospect {
        let p = Prospect(naturalKey: "k-\(group)", groupName: group, discipline: "music",
                         venue: "A Hall", performanceDate: "2026-09-12", sourceListingURL: nil,
                         websiteURL: nil, priorRelationship: "none", production: "unclear",
                         profile: "unknown", coverage: "unknown", fitScore: 5, tier: "mid",
                         fitReason: reason, matchedClientName: nil, possibleMatchSource: nil,
                         possibleMatchName: nil, status: status)
        ctx.insert(p)
        return p
    }

    // The stored reason is only rewritten when the hash-gated scout re-emits a row, so changing the
    // classifier alone would leave the sentence sitting on an arbitrary, slowly shrinking subset of the
    // queue for weeks. The one-time pass is what actually clears Dan's screen.
    @Test func theMigrationClearsExactlyTheRetiredSentence() throws {
        let ctx = ModelContext(try container())
        let retired = makeShow(ctx, group: "Retired", reason: CatchAllFitReasonMigration.retired)
        let informative = makeShow(ctx, group: "Informative",
                                   reason: "Self-produced music group, a strong-fit target.")
        let blank = makeShow(ctx, group: "Blank", reason: "")

        let changed = CatchAllFitReasonMigration.run(in: ctx)

        #expect(changed == 1)
        #expect(retired.fitReason.isEmpty)
        #expect(informative.fitReason == "Self-produced music group, a strong-fit target.")
        #expect(blank.fitReason.isEmpty)
    }

    // Dan's escalated decision 4 (2026-07-26): all 499 rows, including the 85 already dismissed. The
    // sentence is equally uninformative on a dismissed row, and two kinds of card in the Archive would
    // be an inconsistency nobody remembers the reason for.
    @Test func theMigrationClearsDismissedRowsToo() throws {
        let ctx = ModelContext(try container())
        let dismissed = makeShow(ctx, group: "Dismissed", reason: CatchAllFitReasonMigration.retired,
                                 status: .dismissed)

        #expect(CatchAllFitReasonMigration.run(in: ctx) == 1)
        #expect(dismissed.fitReason.isEmpty)
    }

    @Test func theMigrationIsIdempotent() throws {
        let ctx = ModelContext(try container())
        makeShow(ctx, group: "Retired", reason: CatchAllFitReasonMigration.retired)

        #expect(CatchAllFitReasonMigration.run(in: ctx) == 1)
        #expect(CatchAllFitReasonMigration.run(in: ctx) == 0)
    }

    // Rehearsed against a COPY of the real Release store, never the live file, on the
    // InquiryMigrationDryRunTests pattern: this one edits 499 existing rows, so "it should only touch
    // the rows carrying that string" is a claim worth proving against Dan's actual data before it ships.
    // Skips cleanly on any machine without a live store.
    @Test func theMigrationRehearsesCleanlyAgainstACloneOfTheLiveStore() throws {
        let fm = FileManager.default
        let live = StoreLocation.storeURL(appSupport: StoreLocation.appSupport, isDebugBuild: false)
        guard fm.fileExists(atPath: live.path) else { return }

        let tmpDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("fitreason-dryrun-\(UUID().uuidString)")
        try fm.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tmpDir) }

        let copy = tmpDir.appendingPathComponent("Overture.store")
        for suffix in ["", "-wal", "-shm"] {
            let src = URL(fileURLWithPath: live.path + suffix)
            guard fm.fileExists(atPath: src.path) else { continue }
            try fm.copyItem(at: src, to: URL(fileURLWithPath: copy.path + suffix))
        }

        let container = try ModelContainer(for: AppSchema.schema,
                                           configurations: [ModelConfiguration(url: copy)])
        let ctx = ModelContext(container)
        let before = try ctx.fetch(FetchDescriptor<Prospect>())
        let carrying = before.filter { $0.fitReason == CatchAllFitReasonMigration.retired }.count
        let otherReasons = before.filter {
            $0.fitReason != CatchAllFitReasonMigration.retired && !$0.fitReason.isEmpty
        }.count

        let changed = CatchAllFitReasonMigration.run(in: ctx)
        try ctx.save()

        // copy-inventory:ignore-start  a test diagnostic, not a sentence Overture says on screen
        print("FITREASON DRY RUN: cleared \(changed) of \(before.count) rows")
        // copy-inventory:ignore-end
        #expect(changed == carrying)
        let after = try ctx.fetch(FetchDescriptor<Prospect>())
        // Nothing lost, and no OTHER reason touched: only the retired sentence went.
        #expect(after.count == before.count)
        #expect(after.filter { $0.fitReason == CatchAllFitReasonMigration.retired }.isEmpty)
        #expect(after.filter {
            $0.fitReason != CatchAllFitReasonMigration.retired && !$0.fitReason.isEmpty
        }.count == otherReasons)
    }
}
