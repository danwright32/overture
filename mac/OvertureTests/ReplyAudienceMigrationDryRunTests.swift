import Testing
import Foundation
import SwiftData

// #2063 migration dry-run, on the JointSendMigrationDryRunTests precedent (#2031, rewritten in #2054).
//
// Two columns onto entities that already hold Dan's real data (`Recipient.replyAudience` and
// `Inquiry.replyAudience`), both optional with a nil default, which is the shape SwiftData's lightweight
// migration handles. Rehearsed against a COPY of the real Release store, never the live file.
//
// It WAS a genuine forward migration when written: the columns did not exist in the live store, so the
// census read nothing going in and the run had to produce them empty. They have since shipped and Dan's
// store now carries real values, so the census takes its other branch (the count going in must equal the
// count coming out) and the rehearsal is now about preserving data rather than creating columns.
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

        let tmpDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("reply-audience-dryrun-\(UUID().uuidString)")
        try fm.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tmpDir) }

        // #1672: through the ONE shared clone, which takes the copy via SQLite's online backup rather
        // than racing three file copies against a live writer. See LiveStoreClone.
        // #3035: and through MigrationRehearsal, which SAYS when it rehearsed nothing. Both of the exits
        // this used to take were silent, so a run against Dan's real store and a run that never opened a
        // file left the same green tick (L98).
        let start = try MigrationRehearsal.begin("the reply-audience columns", liveStore: live, into: tmpDir)
        guard case let .rehearse(copy) = start else {
            if case let .skipped(said) = start { MigrationRehearsal.report(said) }
            if case let .cloneFailed(said) = start { MigrationRehearsal.report(said) }
            return
        }

        // Z_PK is on every CoreData table and never null, so an unreadable answer here means the counting
        // is broken rather than that a column is absent. Those must never be confused: one is a defect in
        // this test, the other is the state the rehearsal is about.
        let probe = StoreColumnCensus.nonNullRows(table: "ZRECIPIENT", column: "Z_PK",
                                                  inSQLiteFileAt: copy.path)
        if case .unreadable(let why) = probe {
            Issue.record(Comment(rawValue: "the clone could not be counted at all (\(why)), so nothing "
                                 + "below measured anything"))
            return
        }

        let before = Self.addedColumns.map {
            StoreColumnCensus.nonNullRows(table: $0.table, column: $0.column, inSQLiteFileAt: copy.path)
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
            let reading = StoreColumnCensus.nonNullRows(table: spec.table, column: spec.column,
                                                        inSQLiteFileAt: copy.path)
            guard case .rows(let after) = reading else {
                let missing = "\(spec.label) could not be counted after the migration: \(reading)"
                Issue.record(Comment(rawValue: missing))
                continue
            }
            // #2930: the two ways `before` can carry no number are told apart here rather than folded
            // together. A column that was ABSENT going in must come out empty, which is the forward
            // migration's whole claim. A column that could not be READ going in says nothing about what
            // the migration did, and asserting the absent-column claim on it would be a pass measuring
            // nothing (L90).
            switch before[i] {
            case .rows(let was):
                let invented = "\(spec.label): \(was) rows carried a value going in and \(after) came out, "
                    + "so the migration wrote values nobody chose"
                #expect(after == was, Comment(rawValue: invented))
            case .unreadable(.columnNotInTable), .unreadable(.tableNotInStore):
                let notEmpty = "\(spec.label): the column did not exist going in, so every row must come out "
                    + "of the migration empty, and \(after) did not"
                #expect(after == 0, Comment(rawValue: notEmpty))
            case .unreadable(let why):
                Issue.record(Comment(rawValue: "\(spec.label) could not be counted BEFORE the migration "
                                     + "(\(why)), so this column measured nothing either side"))
            }
        }

        // Nobody inherits an audience they never had, and nobody loses one they do have.
        //
        // This used to read `r.replyAudience == nil` on every row, which was true only for as long as the
        // feature had never been used. On 2026-08-05 the reply repair pass legitimately filled two rows on
        // Dan's Pumpkin Singalong thread and this went red on working software, which is exactly the shape
        // L68 names: a guard over live data must assert the SIGNATURE of the failure it protects against,
        // never the data's current emptiness, or ordinary use expires it.
        //
        // The signature is a migration that invents, drops or corrupts an audience. So: a row with nothing
        // captured still falls back to the contact alone (the property the whole change rests on), and a
        // row that has one comes out holding real addresses rather than a husk of empty strings.
        for r in recipients {
            let own = [r.email].compactMap { $0 }.filter { !$0.isEmpty }
            if let captured = r.replyAudience {
                #expect(!captured.isEmpty, "a migrated row carries an audience with nothing in it")
                #expect(captured.allSatisfy { !$0.trimmingCharacters(in: .whitespaces).isEmpty },
                        "a migrated audience holds a blank address, so the values did not survive intact")
                #expect(SendGroup.replyAudience(of: r) == captured)
            } else {
                #expect(SendGroup.replyAudience(of: r) == own)
            }
        }

        // Opening the ALREADY-migrated clone a second time must find exactly the same rows.
        let reopened = ModelContext(try ModelContainer(for: AppSchema.schema,
                                                       configurations: [ModelConfiguration(url: copy)]))
        #expect(try reopened.fetch(FetchDescriptor<Prospect>()).count == prospects.count)
        #expect(try reopened.fetch(FetchDescriptor<Recipient>()).count == recipients.count)
    }
}
