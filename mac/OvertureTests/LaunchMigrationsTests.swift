import Testing
import Foundation
import SwiftData

// #479: applicationDidFinishLaunching ran the thread-down repair and the salutation strip against
// mainContext with no save after them, so a short-lived launch could lose the
// writes and the idempotency guard would just leave a fragile unsaved window every time it re-ran. This
// proves the fix against a real, file-backed store (an in-memory one has nothing to "reopen"): run the
// migrations against one context, WITHOUT the test itself ever calling save, then open a second,
// independent container/context on the same file and confirm the writes already landed.
@Suite("Launch migrations explicit save (#479)")
struct LaunchMigrationsTests {
    private func openContainer(at url: URL) throws -> ModelContainer {
        let schema = Schema([Prospect.self, Recipient.self])
        return try ModelContainer(for: schema,
                                  configurations: [ModelConfiguration(schema: schema,
                                                                      url: url, cloudKitDatabase: .none)])
    }

    private func makeProspect(_ key: String) -> Prospect {
        Prospect(naturalKey: key, groupName: key, discipline: "music", venue: nil,
                 performanceDate: nil, sourceListingURL: nil,
                 priorRelationship: "warm", production: "self", profile: "neutral",
                 coverage: "unknown", fitScore: 3, tier: "longshot", fitReason: "r",
                 matchedClientName: nil, possibleMatchSource: nil, possibleMatchName: nil)
    }

    // #1006: real, disk-backed ModelContainer work runs between an acquire()/release() pair so it
    // never overlaps another suite's, in the whole process.
    @Test func persistsAllThreeLaunchMigrationsWithoutTheCallerEverCallingSave() async throws {
        await RealStoreTestLock.shared.acquire()
        do {
            let fm = FileManager.default
            let scratch = fm.temporaryDirectory
                .appendingPathComponent("overture-launch-migrations-\(UUID().uuidString)", isDirectory: true)
            defer { try? fm.removeItem(at: scratch) }
            try fm.createDirectory(at: scratch, withIntermediateDirectories: true)
            let storeURL = scratch.appendingPathComponent("default.store")

            let container = try openContainer(at: storeURL)
            let context = ModelContext(container)
            let p = makeProspect("k1")
            p.draftBody = "Hi Emma, I photograph performing arts in New York."
            p.setRecipients([Recipient(id: "ann@example.com", email: "ann@example.com", provenance: .act)])
            context.insert(p)
            try context.save()   // seed data, as if it were already durable before this launch

            let succeeded = LaunchMigrations.run(in: context)
            #expect(succeeded)

            // The caller (AppDelegate) never calls save itself. Open a brand new container/context on the
            // SAME file: every migrated write must already be there if LaunchMigrations.run saved for real.
            let reopened = try openContainer(at: storeURL)
            let reContext = ModelContext(reopened)
            let reProspects = try reContext.fetch(FetchDescriptor<Prospect>())
            #expect(reProspects.count == 1)
            let reProspect = try #require(reProspects.first)
            #expect(reProspect.recipients.count == 1)
            #expect(reProspect.recipients.first?.provenance == .act)
            // #2010: the launch no longer rewrites a stored body, so what was saved is what was written.
            #expect(reProspect.draftBody == "Hi Emma, I photograph performing arts in New York.")
            await RealStoreTestLock.shared.release()
        } catch {
            await RealStoreTestLock.shared.release()
            throw error
        }
    }

    // #1590: SameNightTitleVariantMerge working and SameNightTitleVariantMerge being RUN are two separate
    // claims, and only the second one reaches Dan's queue. These two rows are the live FRIGID pair: their
    // folded natural keys still differ (the titles differ by real words, which is why the key fold cannot
    // touch them), so nothing except the new pass can collapse them. Verified through a reopened store,
    // so it also proves the delete was saved rather than left in an unsaved context.
    @Test func launchCollapsesTwoBillingsOfOneNightIntoOneCard() async throws {
        await RealStoreTestLock.shared.acquire()
        do {
            let fm = FileManager.default
            let scratch = fm.temporaryDirectory
                .appendingPathComponent("overture-1590-launch-\(UUID().uuidString)", isDirectory: true)
            defer { try? fm.removeItem(at: scratch) }
            try fm.createDirectory(at: scratch, withIntermediateDirectories: true)
            let storeURL = scratch.appendingPathComponent("default.store")

            let context = ModelContext(try openContainer(at: storeURL))
            for title in ["FRIGID Nightcap", "FRIGID Nightcap: FUTURE TENSE"] {
                let p = makeProspect(title)
                p.groupName = title
                p.performanceDate = "2026-07-31"
                p.venue = "Under St Marks"
                p.naturalKey = Prospect.makeNaturalKey(groupName: title,
                                                       performanceDate: "2026-07-31",
                                                       venue: "Under St Marks")
                context.insert(p)
            }
            try context.save()
            #expect(try context.fetch(FetchDescriptor<Prospect>()).count == 2, "two cards before launch")

            #expect(LaunchMigrations.run(in: context))

            let reContext = ModelContext(try openContainer(at: storeURL))
            let remaining = try reContext.fetch(FetchDescriptor<Prospect>())
            #expect(remaining.count == 1, "one night, one room, one show, one card")
            await RealStoreTestLock.shared.release()
        } catch {
            await RealStoreTestLock.shared.release()
            throw error
        }
    }

    // #1744: LocationBackfill working and LocationBackfill being RUN are two separate claims, and only
    // the second one reaches the 341 blank rows sitting in Dan's queue. Two rows here, both live shapes:
    // a Carnegie room the shared table knows, and a Carnegie tour date at a hall it does not, placed by
    // the title convention. Verified through a reopened store, so it also proves the fill was saved.
    @Test func launchPlacesTheShowsAlreadyInTheStore() async throws {
        await RealStoreTestLock.shared.acquire()
        do {
            let fm = FileManager.default
            let scratch = fm.temporaryDirectory
                .appendingPathComponent("overture-1744-launch-\(UUID().uuidString)", isDirectory: true)
            defer { try? fm.removeItem(at: scratch) }
            try fm.createDirectory(at: scratch, withIntermediateDirectories: true)
            let storeURL = scratch.appendingPathComponent("default.store")

            let context = ModelContext(try openContainer(at: storeURL))
            let known = makeProspect("Songmaking 2026")
            known.groupName = "Songmaking 2026"
            known.venue = "Weill Recital Hall"
            known.performanceDate = "2099-05-05"     // #864 must not retire these before we read them
            context.insert(known)
            let touring = makeProspect("NYO2 in Santo Domingo, Dominican Republic")
            touring.groupName = "NYO2 in Santo Domingo, Dominican Republic"
            touring.venue = "Teatro Nacional Eduardo Brito"
            touring.performanceDate = "2099-05-06"
            context.insert(touring)
            try context.save()
            #expect(known.location == nil, "blank before launch, as the live rows were")

            #expect(LaunchMigrations.run(in: context))

            let reContext = ModelContext(try openContainer(at: storeURL))
            let byName = Dictionary(uniqueKeysWithValues:
                try reContext.fetch(FetchDescriptor<Prospect>()).map { ($0.groupName, $0.location) })
            #expect(byName["Songmaking 2026"] == "New York, NY")
            #expect(byName["NYO2 in Santo Domingo, Dominican Republic"]
                    == "Santo Domingo, Dominican Republic")
            await RealStoreTestLock.shared.release()
        } catch {
            await RealStoreTestLock.shared.release()
            throw error
        }
    }

    // #1693: the recheck working and the recheck being RUN are two separate claims, and only the second
    // one reaches the 18 cards actually carrying the wrong flag. This is the live shape: a Carnegie Hall
    // show flagged against a Madison Square Park act, in a store where no such record exists any more.
    //
    // The clients and history come in through LaunchMigrations' seam rather than off disk, because the
    // recheck reads two files no test process has: a test run resolves its own handoff directory, which
    // holds no Downbeat export, so against the real loader this pass no-ops and the test proves nothing.
    // The first version of this test did exactly that, and said so only when the call was deleted from
    // LaunchMigrations and the suite stayed green.
    @Test func launchClearsAPossibleMatchTheMatcherNoLongerMakes() async throws {
        await RealStoreTestLock.shared.acquire()
        do {
            let fm = FileManager.default
            let scratch = fm.temporaryDirectory
                .appendingPathComponent("overture-1693-launch-\(UUID().uuidString)", isDirectory: true)
            defer { try? fm.removeItem(at: scratch) }
            try fm.createDirectory(at: scratch, withIntermediateDirectories: true)
            let storeURL = scratch.appendingPathComponent("default.store")

            let context = ModelContext(try openContainer(at: storeURL))
            let p = makeProspect("nyo2")
            p.groupName = "NYO2"
            p.presenter = "Carnegie Hall Presents"
            p.venue = "Stern Auditorium / Perelman Stage"
            p.performanceDate = "2026-07-30"
            p.priorRelationship = "none"
            p.possibleMatchSource = "history"
            p.possibleMatchName = "Carnegie Hall Citywide: Ivalas Quartet"
            context.insert(p)
            try context.save()

            // The record the flag names no longer exists anywhere Dan's history can produce it. What DOES
            // exist is the Madison Square Park dismissal it came from, kept here so the pass is judged
            // against the real thing rather than an empty history that would clear any flag at all.
            let history = [HistoryRecord(groupName: "Carnegie Hall Citywide: Ivalas Quartet",
                                         status: "declined")]
            #expect(LaunchMigrations.run(in: context,
                                         possibleMatchInputs: { _ in
                                             PossibleMatchRecheck.Inputs(clients: [], history: history)
                                         }))

            let reContext = ModelContext(try openContainer(at: storeURL))
            let reloaded = try #require(try reContext.fetch(FetchDescriptor<Prospect>()).first)
            #expect(reloaded.possibleMatchName == nil)
            #expect(reloaded.possibleMatchSource == nil)
            await RealStoreTestLock.shared.release()
        } catch {
            await RealStoreTestLock.shared.release()
            throw error
        }
    }

    // #1784: OrgKeyRealignmentMigration working and OrgKeyRealignmentMigration being RUN are two separate
    // claims, and only the second one reaches an answer sitting in Dan's ledger. Its own suite proves the
    // rules; this proves the launch calls it and that the rewritten key was SAVED, which is the whole
    // point of the pass (an answer nobody can look up is an answer paid for twice).
    @Test func launchMovesALedgerAnswerOntoTheKeyTheSharedFoldComputes() async throws {
        await RealStoreTestLock.shared.acquire()
        do {
            let fm = FileManager.default
            let scratch = fm.temporaryDirectory
                .appendingPathComponent("overture-1784-launch-\(UUID().uuidString)", isDirectory: true)
            defer { try? fm.removeItem(at: scratch) }
            try fm.createDirectory(at: scratch, withIntermediateDirectories: true)
            let storeURL = scratch.appendingPathComponent("default.store")

            let schema = Schema([Prospect.self, Recipient.self, OrgReachabilityAnswer.self])
            func open() throws -> ModelContext {
                ModelContext(try ModelContainer(for: schema,
                                                configurations: [ModelConfiguration(schema: schema,
                                                                                    url: storeURL,
                                                                                    cloudKitDatabase: .none)]))
            }

            let presenter = "The Golden Hour Series (curated with Jalopy Theatre, and others)"
            let context = try open()
            context.insert(OrgReachabilityAnswer(orgKey: "presenter:" + presenter.lowercased(),
                                                 result: .emailFound,
                                                 probedAt: Date(timeIntervalSince1970: 1_800_000_000),
                                                 sourceNaturalKey: "k|2026-09-12|jalopy theatre",
                                                 sourceGroupName: "A night of songs",
                                                 presenterName: presenter,
                                                 foundEmails: ["hello@example.org"]))
            try context.save()

            #expect(LaunchMigrations.run(in: context))

            let reContext = try open()
            let reloaded = try #require(try reContext.fetch(FetchDescriptor<OrgReachabilityAnswer>()).first)
            #expect(reloaded.orgKey == OrgKey.stored(for: "The Golden Hour Series"))
            await RealStoreTestLock.shared.release()
        } catch {
            await RealStoreTestLock.shared.release()
            throw error
        }
    }

    // #3453: WIRED, not merely built. `DeadRunWriteOffRepair` is a pass nothing else calls, so if the
    // line in `LaunchMigrations` were dropped the repair's own suite would stay entirely green while
    // the repair never ran on Dan's Mac (L3). Proven by deleting that line and watching this go red.
    @Test func launchRepairsAShowADeadRunWroteOff() async throws {
        await RealStoreTestLock.shared.acquire()
        do {
            let fm = FileManager.default
            let scratch = fm.temporaryDirectory
                .appendingPathComponent("overture-3453-launch-\(UUID().uuidString)", isDirectory: true)
            defer { try? fm.removeItem(at: scratch) }
            try fm.createDirectory(at: scratch, withIntermediateDirectories: true)
            let storeURL = scratch.appendingPathComponent("default.store")
            let handoff = scratch.appendingPathComponent("handoff", isDirectory: true)

            let schema = Schema([Prospect.self, Recipient.self, OrgReachabilityAnswer.self])
            let context = ModelContext(try ModelContainer(
                for: schema,
                configurations: [ModelConfiguration(schema: schema, url: storeURL,
                                                    cloudKitDatabase: .none)]))
            let p = makeProspect("dead-run|2027-04-18|rowan hall")
            context.insert(p)
            p.reachabilityResult = .noEmailFound
            p.reachabilityProbedAt = Date(timeIntervalSince1970: 1_756_580_000)
            try context.save()

            let folder = RunSlot.check.archivesDirectory(in: handoff)
                .appendingPathComponent("20260830-205244", isDirectory: true)
            try fm.createDirectory(at: folder, withIntermediateDirectories: true)
            try Data(#"{"version":13,"generatedAt":"2026-08-30T20:52:44Z","items":[]}"#.utf8)
                .write(to: folder.appendingPathComponent(RunSlot.check.queueFileName))
            try Data(#"""
            {"version":11,"generatedAt":"2026-08-30T20:52:44Z",
             "results":[{"naturalKey":"dead-run|2027-04-18|rowan hall","contacts":[]}],
             "runCost":{"recorded":false,"streams":10,"streamsRecorded":9}}
            """#.utf8).write(to: folder.appendingPathComponent(RunSlot.check.resultsFileName))

            #expect(LaunchMigrations.run(
                in: context,
                defaults: UserDefaults(suiteName: "launch-3453-\(UUID().uuidString)")!,
                handoffDirectory: handoff))

            #expect(p.reachabilityResult == nil)
            #expect(p.reachabilityProbedAt == nil)
            #expect(p.reachabilityUnansweredAt == Date(timeIntervalSince1970: 1_756_580_000))
            await RealStoreTestLock.shared.release()
        } catch {
            await RealStoreTestLock.shared.release()
            throw error
        }
    }
}
