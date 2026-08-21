import Testing
import Foundation
import SwiftData

// #2031 migration dry-run, on the InquiryMigrationDryRunTests precedent (#1435).
//
// This one differs from every rehearsal before it: those added a new INDEPENDENT entity, which SwiftData
// can add without touching a single existing row. This adds THREE COLUMNS to entities that already hold
// Dan's real data (`Recipient.sendGroupId`, `Prospect.jointOpeningOverride`, `Prospect.sendsTogetherOverride`),
// so the migration reaches the tables that matter. All three are optional with a nil default, which is the
// shape SwiftData's lightweight migration handles, and this rehearses it against a COPY of the real Release
// store (never the live file).
//
// The failure it exists to catch is the loud one and the quiet one at once: a container that refuses to
// open, and a container that opens onto a silently FRESH store while the real rows sit unreachable in the
// file. Counting is what tells those apart.
//
// #2054 rewrote how the third failure is asked about: a migration handing every existing row a value nobody
// chose. That used to be written as "no show carries a send mode", which stopped being true the first night
// Dan used the feature (1 of 730 shows, measured 2026-08-03) and could not tell his own choice apart from
// the fabricated default it existed to catch, so it failed every local run (L68).
//
// What it asks instead is whether OPENING the store CHANGES how many rows carry a value. That needs a count
// taken before SwiftData touches the file, which is what `StoreColumnCensus` is for, and it holds whichever
// state the clone is in:
//
//   - Column absent (a store from before these columns shipped, the real forward migration): every row must
//     come out of the migration empty, which is the original claim, asked exactly where it still means
//     something.
//   - Column present (any store Dan has used since): the number of rows carrying a value must be exactly
//     what it was going in. A fabricated default reaches all 730 at once, so it still goes red instantly,
//     while Dan choosing a mode passes through untouched.
//
// The "reads as together when unset" default is NOT asserted here any more. It belongs to the model, not to
// Dan's data, and TogetherOrSeparatelySwitchTests.thecardShowsWhichWayTheEmailWillGo pins it where no live
// row can ever falsify it (the old line here passed only because the one mode Dan had picked happened to be
// "together", and would have gone red the first time he picked "separately").
//
// Gated on the live store existing, so it skips cleanly on CI and on any machine without one.
@MainActor
@Suite("Joint-send columns migration dry-run against a clone of the live store")
struct JointSendMigrationDryRunTests {
    private var releaseStoreURL: URL {
        StoreLocation.storeURL(appSupport: StoreLocation.appSupport, isDebugBuild: false)
    }

    // The three columns the migration adds, by their stored names.
    private static let addedColumns: [(table: String, column: String, label: String)] = [
        ("ZRECIPIENT", "ZSENDGROUPID", "Recipient.sendGroupId"),
        ("ZPROSPECT", "ZJOINTOPENINGOVERRIDE", "Prospect.jointOpeningOverride"),
        ("ZPROSPECT", "ZSENDSTOGETHEROVERRIDE", "Prospect.sendsTogetherOverride"),
    ]

    @Test func addingTheJointSendColumnsPreservesACloneOfTheLiveStore() throws {
        let fm = FileManager.default
        let live = releaseStoreURL
        guard fm.fileExists(atPath: live.path) else { return }   // no live store here: nothing to rehearse

        let tmpDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("joint-dryrun-\(UUID().uuidString)")
        try fm.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tmpDir) }

        // #1672: through the ONE shared clone, which takes the copy via SQLite's online backup rather
        // than racing three file copies against a live writer. See LiveStoreClone.
        guard let copy = try LiveStoreClone.makeClone(in: tmpDir) else { return }

        // Prove the census can read this clone at all before anything below is read as a measurement.
        // Z_PK is on every CoreData table and is never null, so an unreadable answer here means the
        // counting is broken, not that a column is missing, and the two must never be confused: one is a
        // defect in this test, the other is the state the rehearsal exists to handle.
        let probe = StoreColumnCensus.nonNullRows(table: "ZPROSPECT", column: "Z_PK",
                                                  inSQLiteFileAt: copy.path)
        if case .unreadable(let why) = probe {
            Issue.record(Comment(rawValue: "the clone could not be counted at all (\(why)), so nothing "
                                 + "below measured anything"))
            return
        }

        // Taken before SwiftData opens the file, so it describes the store going IN to the migration.
        let before = Self.addedColumns.map {
            StoreColumnCensus.nonNullRows(table: $0.table, column: $0.column, inSQLiteFileAt: copy.path)
        }

        let container = try ModelContainer(for: AppSchema.schema,
                                           configurations: [ModelConfiguration(url: copy)])
        let ctx = ModelContext(container)
        let prospects = try ctx.fetch(FetchDescriptor<Prospect>())
        let recipients = try ctx.fetch(FetchDescriptor<Recipient>())

        // A store that migrated is a store that still has Dan's rows in it. Zero is the signature of the
        // quiet failure: a brand-new empty store opened beside the real data.
        #expect(!prospects.isEmpty, "the migrated clone holds no shows, which is a fresh store, not a migrated one")
        #expect(!recipients.isEmpty)
        // The rows are intact, not merely present.
        #expect(recipients.contains { $0.email?.isEmpty == false })

        // The migration invented nothing. Counted the same way on both sides, so a difference is a real
        // change in the data rather than a difference in how it was measured.
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

        // Tie the raw count to what the app actually reads, so a column counted here but mapped to a
        // different attribute cannot pass as agreement.
        #expect(StoreColumnCensus.nonNullRows(table: "ZPROSPECT", column: "ZSENDSTOGETHEROVERRIDE",
                                              inSQLiteFileAt: copy.path)
                == .rows(prospects.filter { $0.sendsTogetherOverride != nil }.count))

        // Opening the ALREADY-migrated clone a second time must find exactly the same rows. A migration
        // that loses rows on a later launch is the version of this failure nobody would connect to this
        // change.
        let reopened = ModelContext(try ModelContainer(for: AppSchema.schema,
                                                       configurations: [ModelConfiguration(url: copy)]))
        #expect(try reopened.fetch(FetchDescriptor<Prospect>()).count == prospects.count)
        #expect(try reopened.fetch(FetchDescriptor<Recipient>()).count == recipients.count)
    }
}
