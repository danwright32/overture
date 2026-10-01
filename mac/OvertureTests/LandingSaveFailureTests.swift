import Testing
import Foundation
import Darwin
import SwiftData

// #4334 (A5): which save refusals are confined to one source's rows, decided ONCE (L35, L527), and the two
// source scans that keep the revert sound.
//
// THE REPRODUCTION (L82, L681). Every real refusal a save can be made to throw on this SDK, each reached
// for real and classified. Measured by #4327 step 0.8 on 2026-09-29 and again here: a duplicate natural key
// does not refuse at all (`Prospect.naturalKey` is `.unique`, which upserts); a SQLite trigger that aborts a
// write ends the PROCESS ("Unable to recover from optimistic locking failure") before any catch runs, so it
// is A6's idle recovery's to catch, not this; and the two below refuse every save the container makes,
// whatever rows it carries. None is confined to one source's rows, so none is SOURCE level, and every
// failure stops the landing. A refusal found later that IS confined is added to `LandingSaveFailure` with
// its reproduction beside it here.
@MainActor
@Suite("Which save refusals stop a scout landing, and what the landing path may never do (#4334)", .serialized)
final class LandingSaveFailureTests {
    private let sandboxes = TemporarySandboxes()

    private func seededStore(_ name: String) throws -> URL {
        let dir = try sandboxes.make(named: "refusal-\(name)")
        let url = dir.appendingPathComponent("Overture.store")
        let c = try FileStores.container(for: AppSchema.schema,
                                         configurations: [ModelConfiguration(schema: AppSchema.schema, url: url)])
        let ctx = ModelContext(c)
        ctx.insert(WatchedSource(sourceId: "seed", orgName: "Org seed", listingsURL: "https://seed.example/", kind: .html))
        try ctx.save()
        return url
    }

    private func failedSave(on ctx: ModelContext) -> Error? {
        ctx.insert(WatchedSource(sourceId: "new", orgName: "Org new", listingsURL: "https://new.example/", kind: .html))
        do {
            try ctx.save()
            return nil
        } catch {
            return error
        }
    }

    @Test func anImmutableStoreRefusesEverySaveAndIsStoreLevel() throws {
        let store = FailurePathRevertProbeTests.RefusingStore(url: try seededStore("immutable"))
        defer { store.release() }
        let ctx = try store.openRefusing()
        let error = try #require(failedSave(on: ctx), "an immutable store accepted a save, so nothing here refused")
        let ns = error as NSError
        print("#4334 reproduction, immutable store: \(ns.domain) \(ns.code)")
        #expect(LandingSaveFailure.classify(error) == .store, Comment(rawValue:
            "an immutable store's refusal (\(ns.domain) \(ns.code)) was classified as one source's"))
    }

    @Test func aReadOnlyStoreFileRefusesEverySaveAndIsStoreLevel() throws {
        let url = try seededStore("read-only")
        let paths = ["", "-wal", "-shm"].map { url.path + $0 }
        for p in paths { _ = chmod(p, 0o444) }
        defer { for p in paths { _ = chmod(p, 0o644) } }
        let c = try FileStores.container(for: AppSchema.schema,
                                         configurations: [ModelConfiguration(schema: AppSchema.schema, url: url)])
        c.mainContext.autosaveEnabled = false
        let error = try #require(failedSave(on: c.mainContext), "a read only store file accepted a save")
        let ns = error as NSError
        print("#4334 reproduction, read only store file: \(ns.domain) \(ns.code)")
        #expect(LandingSaveFailure.classify(error) == .store)
    }

    // Measured (L82): what a revert can and cannot give back. A field written back to the value it already
    // had still reads as CHANGED, and `processPendingChanges` does not clear it; only a save does (or
    // `rollback()`, which is banned). An insert deleted before any save leaves nothing behind. So a put back
    // landing leaves rows that differ from the store in nothing, but `hasChanges` stays true until the next
    // save, which then writes the same values again; the next landing's entry flush is that save.
    @Test func aFieldWrittenBackStillReadsAsChanged() throws {
        let c = try TestModelContainer.inMemory(AppSchema.models)
        let ctx = c.mainContext
        ctx.autosaveEnabled = false
        let s = WatchedSource(sourceId: "x", orgName: "Org x", listingsURL: "https://x.example/", kind: .html)
        ctx.insert(s)
        try ctx.save()
        s.notes = "changed"
        s.notes = nil
        ctx.processPendingChanges()
        #expect(ctx.hasChanges && ctx.changedModelsArray.count == 1,
                "a field written back now reads as unchanged, so a revert can promise a clean context")
        let p = Prospect(naturalKey: "k", groupName: "G", discipline: "music", venue: "V",
                         performanceDate: "2099-01-01", sourceListingURL: nil, priorRelationship: "none",
                         production: "self", profile: "strong", coverage: "likely_uncovered", fitScore: 5,
                         tier: "mid", fitReason: "r", matchedClientName: nil, possibleMatchSource: nil,
                         possibleMatchName: nil)
        ctx.insert(p)
        ctx.delete(p)
        ctx.processPendingChanges()
        #expect(ctx.insertedModelsArray.isEmpty && ctx.deletedModelsArray.isEmpty,
                "an insert deleted before any save left something behind")
    }

    // Unclassified goes to stop, because stopping cannot corrupt data and continuing might.
    @Test func anErrorNobodyClassifiedIsStoreLevel() {
        struct NeverSeen: Error {}
        #expect(LandingSaveFailure.classify(NeverSeen()) == .store)
        #expect(LandingSaveFailure.classify(NSError(domain: NSCocoaErrorDomain, code: 1570)) == .store)
    }

    // MARK: - The scans

    // `rollback()` restores nothing a held instance already read, so a landing's working set, and every
    // view holding a row, would go on reading values the store no longer has (#4327's overruled dissent).
    // Banned on every context in the app. An exemption names the file and carries its reason.
    static let rollbackExemptions: [String: String] = [:]

    static func rollbackCalls(in files: [AppSourceWalk.File]) -> [String] {
        files.flatMap { file -> [String] in
            guard rollbackExemptions[file.name] == nil else { return [] }
            return SwiftSource.scannableLines(in: file.text)
                .filter { $0.code.contains("rollback(") }
                .map { "\(file.name):\($0.line)" }
        }
    }

    @Test func nothingInTheAppRollsAContextBack() {
        let found = Self.rollbackCalls(in: AppSourceWalk.appFiles())
        #expect(found.isEmpty, Comment(rawValue:
            "rollback() restores nothing a held row already read, so it is banned; use the failure path revert "
            + "(LandingRevert) instead: \(found)"))
    }

    // Comment 2 on #4334: the revert cannot bring back a committed row the failed turn deleted, so the
    // landing path must never delete one. These files are what a landing runs; the one delete allowed is
    // the revert's own, of rows the failed turn inserted and no save ever carried.
    static let landingPathFiles: Set<String> = [
        "ScoutService.swift", "ScoutExtractIngest.swift", "ScoutLandingStore.swift", "FeedReconcile.swift",
        "SourceWrites.swift", "SourceSchedule.swift", "ScoutExtractLanding.swift", "LandingRevert.swift",
    ]
    static let deleteExemptions: [String: String] = [
        "LandingRevert.swift": "deletes only the failed turn's pending inserts, which no save carried",
    ]

    static func deletes(in files: [AppSourceWalk.File]) -> [String] {
        files.filter { landingPathFiles.contains($0.name) && deleteExemptions[$0.name] == nil }.flatMap { file in
            SwiftSource.scannableLines(in: file.text)
                .filter { $0.code.contains(".delete(") }
                .map { "\(file.name):\($0.line)" }
        }
    }

    @Test func theLandingPathDeletesNoSavedRow() {
        let files = AppSourceWalk.appFiles()
        let present = Set(files.map(\.name)).intersection(Self.landingPathFiles)
        #expect(present == Self.landingPathFiles, Comment(rawValue:
            "a landing path file was renamed or moved, so the scan no longer reads it: "
            + "\(Self.landingPathFiles.subtracting(present).sorted())"))
        let found = Self.deletes(in: files)
        #expect(found.isEmpty, Comment(rawValue:
            "the landing path gained a delete, which the failure path revert cannot undo: \(found)"))
    }
}
