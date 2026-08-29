import Testing
import Foundation
import SwiftData

// #1665 and #1640: the app's FIRST subtractive schema change, rehearsed against a clone of the live store
// before it ships.
//
// Every migration this app has made has been additive: a new entity, at most a defaulted column. There is
// no `MigrationPlan` and no `VersionedSchema` anywhere, and the only safety net is the launch-time backup.
// SwiftData's lightweight migration is expected to handle an attribute deletion, but this store has never
// been asked to, and it holds every prospect, contact and outreach record Dan has (L7: rehearse every
// destructive migration against a copy of the real store, never only fresh data).
//
// WHY THIS CANNOT BE THE ADDITIVE REHEARSAL WITH THE SIGN FLIPPED. `InquiryMigrationDryRunTests` and
// `OrgAnswerMigrationDryRunTests` build a container from the OLD model list and one from the NEW, and
// compare. Once a property is deleted from the model there is no old list to build: the type does not have
// it any more, and the only place the column still exists is the file. So the before-reading is taken from
// the file itself, through `StoreColumns`.
//
// AND THAT IS WHAT MAKES IT A REHEARSAL RATHER THAN A FORMALITY. Opening a clone under the new schema and
// finding the rows intact proves nothing if the clone never carried the columns being dropped: an empty
// result and a successful subtraction leave the same green tick (L98). So it asserts the columns ARE on
// the clone first, and that they hold nothing, and only then drops them.
//
// The emptiness assertion is the one that would stop this shipping. `classificationConfidence` and
// `confidenceReviewedByDan` were retired by #1533 and read and written by nothing since;
// `websiteURL`'s only writer is the literal `nil` in `ProspectAssembler`, measured 2026-08-27. If any of
// the three turns out to hold a value on Dan's real rows, dropping it destroys data and this says so
// rather than migrating and reporting a clean row count (L5).
@MainActor
@Suite("Dropping the retired columns, rehearsed on a clone of the live store (#1665)")
struct RetiredColumnsDryRunTests {

    // CoreData's own column names for the three properties, which is what is on disk. It prefixes an
    // attribute with Z and upper-cases it.
    // ONE column is dropped, and which one was decided by this rehearsal rather than by the issue.
    //
    // #1665 proposed dropping `classificationConfidence` and `confidenceReviewedByDan`, describing them as
    // "read and written by nothing". Not read, true. But run against a clone of the live store on
    // 2026-08-27 this found 505 of 1018 prospects marked `uncertain` by the retired classifier, and TWO
    // marked reviewed by Dan himself. That is content, not two empty columns, and dropping it is a
    // deletion of records rather than a tidy-up (L5). Dan's call, in session that day: drop `websiteURL`
    // only, and leave the confidence pair until the reporting work in milestone #16 has decided whether
    // the old classifier's reading is worth anything as history.
    //
    // Each column carries the DEFAULT its Swift property declares, because that is what the emptiness
    // question has to be asked against: a Swift property with a default is written to every row whether
    // anybody set it or not, so "is it null" reported all 1018 rows as data about to be destroyed when the
    // truth was 1018 copies of a value nothing ever wrote. `websiteURL` is an optional with no default, so
    // for it any non-null really is somebody's data, and there is none.
    private static let droppedColumns: [(column: String, declaredDefault: String?)] = [
        ("ZWEBSITEURL", nil),
    ]

    // And the pair that must SURVIVE, so a later change cannot quietly take them with it. They hold real
    // values and their removal is a decision nobody has made.
    private static let keptColumns = ["ZCLASSIFICATIONCONFIDENCE", "ZCONFIDENCEREVIEWEDBYDAN"]
    private static let prospectTable = "ZPROSPECT"

    private var releaseStoreURL: URL {
        StoreLocation.storeURL(appSupport: StoreLocation.appSupport, isDebugBuild: false)
    }

    @Test func droppingThemPreservesEveryRowInACloneOfTheLiveStore() throws {
        let fm = FileManager.default
        let tmpDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("retired-columns-dryrun-\(UUID().uuidString)")
        try fm.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tmpDir) }

        // #1672/#3035: through the ONE shared clone, which takes the copy via SQLite's online backup
        // rather than racing file copies against a live writer, and which SAYS when it rehearsed nothing.
        let start = try MigrationRehearsal.begin("the retired classification and website columns",
                                                 liveStore: releaseStoreURL, into: tmpDir)
        guard case let .rehearse(copy) = start else {
            if case let .skipped(said) = start { MigrationRehearsal.report(said) }
            if case let .cloneFailed(said) = start { MigrationRehearsal.report(said) }
            return
        }

        // 1. The clone really carries what is about to be dropped. Without this the whole rehearsal
        //    passes on a store that never had these columns, which is the emptiest possible result
        //    reading as the strongest possible proof (L98).
        guard let onDisk = StoreColumns.columns(ofTable: Self.prospectTable, in: copy) else {
            Issue.record(Comment(rawValue: "the clone's \(Self.prospectTable) columns could not be read, "
                                 + "so nothing below measured anything"))
            return
        }
        for (column, _) in Self.droppedColumns {
            #expect(onDisk.contains(column),
                    Comment(rawValue: "\(column) is not on the clone, so this run rehearsed dropping a "
                            + "column that was already gone"))
        }

        // 2. And they hold NOTHING. This is the assertion that would stop the change shipping: a column
        //    with values in it is data, and dropping it destroys data (L5).
        for (column, declaredDefault) in Self.droppedColumns {
            let holding = StoreColumns.rowsHoldingSomethingOtherThan(declaredDefault, inColumn: column,
                                                                     ofTable: Self.prospectTable,
                                                                     in: copy)
            guard let holding else {
                Issue.record(Comment(rawValue: "\(column) could not be counted on the clone, which is "
                                     + "not the same as it being empty"))
                continue
            }
            // The distribution, not just the count: a number says a migration would destroy something,
            // and this says WHAT, which is the difference between a finding somebody has to go and
            // investigate and one they can act on.
            let spread = StoreColumns.valueCounts(inColumn: column, ofTable: Self.prospectTable, in: copy)
            #expect(holding == 0,
                    Comment(rawValue: "\(holding) row(s) hold something other than the default in "
                            + "\(column). Dropping it would destroy that data, which is what this "
                            + "rehearsal exists to catch before it happens. What is in there: "
                            + (spread?.joined(separator: ", ") ?? "could not be read")))
        }

        // 2b. And the pair Dan chose to keep is still declared, so a later change cannot drop them by
        //     accident on the back of this one. They hold 505 `uncertain` readings and two of his own
        //     review marks, and taking them is a decision nobody has made.
        for column in Self.keptColumns {
            #expect(onDisk.contains(column),
                    Comment(rawValue: "\(column) is gone from the clone. It was deliberately kept "
                            + "(#1665, Dan's call 2026-08-27) because it holds real values."))
        }

        // 3. What must survive, read from the file rather than through the model, for the same reason the
        //    before-reading is.
        guard let prospectsBefore = StoreColumns.rowCount(ofTable: Self.prospectTable, in: copy),
              let recipientsBefore = StoreColumns.rowCount(ofTable: "ZRECIPIENT", in: copy) else {
            Issue.record("the clone's row counts could not be read, so nothing below measured anything")
            return
        }
        #expect(prospectsBefore > 0, "the clone holds no prospects, so this rehearsed nothing")

        // 4. The subtraction itself: the same clone, opened under the schema that no longer declares them.
        let container = try ModelContainer(for: AppSchema.schema,
                                           configurations: [ModelConfiguration(url: copy)])
        let ctx = ModelContext(container)
        let prospects = try ctx.fetch(FetchDescriptor<Prospect>())
        #expect(prospects.count == prospectsBefore)
        #expect(try ctx.fetch(FetchDescriptor<Recipient>()).count == recipientsBefore)

        // 5. A spot check of Dan-owned text, because a row count survives a migration that emptied every
        //    field in it.
        #expect(prospects.contains { !$0.groupName.isEmpty },
                "every prospect came back with an empty name, so the rows survived and their contents did not")

        // 6. And the migrated store can take a WRITE, which is the thing a schema mismatch actually
        //    breaks: a container that opens and then refuses to save is the failure this would ship.
        let probe = Prospect(naturalKey: "retired-columns-dryrun-probe", groupName: "Dry run probe",
                             discipline: "music", venue: "Nowhere", performanceDate: "2099-01-01",
                             sourceListingURL: nil, priorRelationship: "none",
                             production: "self", profile: "strong", coverage: "likely_uncovered",
                             fitScore: 1, tier: "low", fitReason: "dry run", matchedClientName: nil,
                             possibleMatchSource: nil, possibleMatchName: nil)
        ctx.insert(probe)
        #expect(throws: Never.self) { try ctx.save() }
    }
}
