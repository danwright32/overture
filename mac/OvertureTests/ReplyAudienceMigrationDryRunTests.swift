import Testing
import Foundation
import SwiftData

// #2063 migration dry-run, on the JointSendMigrationDryRunTests precedent (#2031, rewritten in #2054).
//
// Two columns onto entities that already hold Dan's real data (`Recipient.replyAudience` and
// `Inquiry.replyAudience`), both optional with a nil default, which is the shape SwiftData's lightweight
// migration handles. Rehearsed against a COPY of the real Release store, never the live file.
//
// Unlike the joint-send rehearsal this one is a GENUINE forward migration at the time of writing: the
// columns do not exist in the live store yet, so the census below reads nothing going in and the run has
// to produce them empty. That is the branch #2054 built and could no longer exercise itself, because its
// own columns had already shipped.
@MainActor
@Suite("Reply-audience columns migration dry-run against a clone of the live store")
struct ReplyAudienceMigrationDryRunTests {
    private var releaseStoreURL: URL {
        StoreLocation.storeURL(appSupport: StoreLocation.appSupport, isDebugBuild: false)
    }

    private static let addedColumns: [(table: String, column: String, label: String)] = [
        ("ZRECIPIENT", "ZREPLYAUDIENCE", "Recipient.replyAudience"),
        ("ZINQUIRY", "ZREPLYAUDIENCE", "Inquiry.replyAudience"),
    ]

    @Test func addingTheReplyAudienceColumnsPreservesACloneOfTheLiveStore() throws {
        let fm = FileManager.default
        let live = releaseStoreURL
        guard fm.fileExists(atPath: live.path) else { return }   // no live store here: nothing to rehearse

        let tmpDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("reply-audience-dryrun-\(UUID().uuidString)")
        try fm.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tmpDir) }

        // Clone the store and its WAL/SHM sidecars, or the copy is a snapshot missing the newest writes.
        let copy = tmpDir.appendingPathComponent("Overture.store")
        for suffix in ["", "-wal", "-shm"] {
            let src = URL(fileURLWithPath: live.path + suffix)
            guard fm.fileExists(atPath: src.path) else { continue }
            try fm.copyItem(at: src, to: URL(fileURLWithPath: copy.path + suffix))
        }

        // Z_PK is on every CoreData table and never null, so a nil here means the counting is broken rather
        // than that a column is absent. Those must never be confused: one is a defect in this test, the
        // other is the state the rehearsal is about.
        #expect(StoreColumnCensus.nonNullCount(table: "ZRECIPIENT", column: "Z_PK",
                                               inSQLiteFileAt: copy.path) != nil,
                "the clone could not be counted at all, so nothing below measured anything")

        let before = Self.addedColumns.map {
            StoreColumnCensus.nonNullCount(table: $0.table, column: $0.column, inSQLiteFileAt: copy.path)
        }

        let container = try ModelContainer(for: AppSchema.schema,
                                           configurations: [ModelConfiguration(url: copy)])
        let ctx = ModelContext(container)
        let prospects = try ctx.fetch(FetchDescriptor<Prospect>())
        let recipients = try ctx.fetch(FetchDescriptor<Recipient>())

        // A store that migrated still has Dan's rows in it. Zero is the signature of the quiet failure: a
        // brand-new empty store opened beside the real data.
        #expect(!prospects.isEmpty, "the migrated clone holds no shows, which is a fresh store, not a migrated one")
        #expect(!recipients.isEmpty)
        #expect(recipients.contains { $0.email?.isEmpty == false })

        for (i, spec) in Self.addedColumns.enumerated() {
            let after = StoreColumnCensus.nonNullCount(table: spec.table, column: spec.column,
                                                       inSQLiteFileAt: copy.path)
            guard let after else {
                let missing = "\(spec.label) could not be counted after the migration, so the column the "
                    + "migration is supposed to add is not there"
                Issue.record(Comment(rawValue: missing))
                continue
            }
            if let was = before[i] {
                let invented = "\(spec.label): \(was) rows carried a value going in and \(after) came out, "
                    + "so the migration wrote values nobody chose"
                #expect(after == was, Comment(rawValue: invented))
            } else {
                let notEmpty = "\(spec.label): the column did not exist going in, so every row must come out "
                    + "of the migration empty, and \(after) did not"
                #expect(after == 0, Comment(rawValue: notEmpty))
            }
        }

        // Nobody inherits an audience they never had: with nothing captured, a reply reaches the contact
        // alone, which is the fallback the whole change rests on.
        for r in recipients {
            #expect(r.replyAudience == nil)
            #expect(SendGroup.replyAudience(of: r) == [r.email].compactMap { $0 }.filter { !$0.isEmpty })
        }

        // Opening the ALREADY-migrated clone a second time must find exactly the same rows.
        let reopened = ModelContext(try ModelContainer(for: AppSchema.schema,
                                                       configurations: [ModelConfiguration(url: copy)]))
        #expect(try reopened.fetch(FetchDescriptor<Prospect>()).count == prospects.count)
        #expect(try reopened.fetch(FetchDescriptor<Recipient>()).count == recipients.count)
    }
}
