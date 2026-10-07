import Testing
import Foundation
import SwiftData

// #4338 (A10): a SYNTHETIC store to look at the landing line on, at the real scale: 39 sources and 1,350 shows,
// every name drawn from the A1 synthetic arm's invented vocabulary (`LandingOracleCorpus`), and a landing record
// seeded in each state that lives in records, so the Debug build opened on it (`run-debug.sh --store-folder`) shows
// each through the real survey rather than a stand in. Never a clone of the live store: this is a public repository,
// and the live store's names, presenters, venues and clients must never reach it (L222, L155).
//
// Written by `scripts/make-synthetic-landing-store.sh`, which names the folder and runs the opt-in writer below.
// `SyntheticLandingStoreTests` builds the same store in a sandbox on every run and holds its shape.
@MainActor
enum SyntheticLandingStore {
    static let sourceCount = 39
    static let showCount = 1_350

    // The records seeded, each in one state, by the sequence it carries.
    enum Seeded {
        // An ingest the recovery will finish at idle, from its own kept copy; the copy itself is over a day old,
        // so the sweep also counts it as stuck.
        static let waitingSequence = 101
        // A sweep the recovery stopped trying after `LandingRecovery.attemptCap` attempts.
        static let stoppedSequence = 102
        static let stoppedIdentity = "sweep-synthetic-stopped"
        // A landing record nobody can read.
        static let unreadableSequence = 103
        // Kept results the launch sweep lands.
        static let freshSequence = 104
        // Kept results that had already landed, which the launch sweep removes.
        static let alreadyLandedSequence = 105
    }

    // The invented vocabulary, from the synthetic arm.
    static var titles: [String] {
        var seen = Set<String>()
        return (LandingOracleCorpus.sources.flatMap { $0.events.map(\.title) } + LandingOracleCorpus.stored.map(\.title))
            .filter { seen.insert($0).inserted }
    }

    static var venues: [String] {
        var seen = Set<String>()
        return (LandingOracleCorpus.sources.flatMap { $0.events.compactMap(\.venue) } + LandingOracleCorpus.stored.map(\.venue))
            .filter { seen.insert($0).inserted }
    }

    // The arm's organisations, each placed in up to seven invented districts, which is enough for 39.
    static var organisations: [String] {
        var seen = Set<String>()
        let bases = (LandingOracleCorpus.sources.map(\.org) + LandingOracleCorpus.stored.map(\.presenter))
            .filter { seen.insert($0).inserted }
        let districts = ["", "North ", "South ", "East ", "West ", "Upper ", "Lower "]
        return districts.flatMap { district in bases.map { district + $0 } }
    }

    // Past clients, from the arm's presenters no source in it owns.
    static let clients = ["Saltmarsh Singers", "Kestrel Dance Works", "Hollow Oak Ensemble", "Ember Choir"]

    static func slug(_ text: String) -> String {
        String(text.lowercased().map { $0.isLetter || $0.isNumber ? $0 : "-" })
    }

    static func sourceId(_ index: Int) -> String { "synthetic-\(index)" }

    // How many shows source `index` holds: 1,350 over 39, the first ones a show more.
    static func shows(for index: Int) -> Int {
        showCount / sourceCount + (index < showCount % sourceCount ? 1 : 0)
    }

    struct Written: Equatable {
        var sources = 0
        var shows = 0
        var landingRuns = 0
    }

    // The store and its handoff folder, written into `folder` (laid out as `StoreLocation.paths(inStoreFolder:)`
    // says the Debug build reads it). The folder must hold no store yet: this never writes over one.
    @discardableResult
    static func write(into folder: URL, now: Date) throws -> Written {
        let paths = StoreLocation.paths(inStoreFolder: folder)
        guard !FileManager.default.fileExists(atPath: paths.store.path) else {
            throw Refused(description: "\(paths.store.path) already holds a store, and this never writes over one")
        }
        try FileManager.default.createDirectory(at: paths.handoff, withIntermediateDirectories: true)
        let container = try FileStores.container(for: AppSchema.schema,
                                           configurations: [ModelConfiguration(schema: AppSchema.schema,
                                                                               url: paths.store,
                                                                               cloudKitDatabase: .none)])
        let context = ModelContext(container)
        context.autosaveEnabled = false
        var written = Written()
        let orgs = organisations
        let titles = titles
        let venues = venues
        var keys = Set<String>()
        for index in 0..<sourceCount {
            let org = orgs[index]
            let source = WatchedSource(sourceId: sourceId(index), orgName: org,
                                       listingsURL: "https://\(slug(org)).example/events", kind: .html, addedAt: now)
            source.successfulCheckCount = WatchedSource.warmupRuns
            source.baselineFeedCount = shows(for: index)
            source.venueLocation = "New York, NY"
            context.insert(source)
            written.sources += 1
            let venue = venues[index % venues.count]
            for k in 0..<shows(for: index) {
                let title = titles[(index * 5 + k) % titles.count]
                var day = 7 + (k * 4 + index) % 150
                var date = ScoutTestClock.day(day, after: now)
                var key = Prospect.makeNaturalKey(groupName: title, performanceDate: date, venue: venue)
                while !keys.insert(key).inserted {
                    day += 1
                    date = ScoutTestClock.day(day, after: now)
                    key = Prospect.makeNaturalKey(groupName: title, performanceDate: date, venue: venue)
                }
                let fit = 1 + (index * 3 + k) % 10
                let warm = k % 17 == 0
                let show = Prospect(naturalKey: key, groupName: title,
                                    discipline: ["music", "choral", "theater", "dance"][(index + k) % 4],
                                    venue: venue, performanceDate: date,
                                    sourceListingURL: "https://\(slug(org)).example/\(slug(title))",
                                    priorRelationship: warm ? "warm" : "none", production: "self", profile: "strong",
                                    coverage: "likely_uncovered", fitScore: fit,
                                    tier: fit >= 8 ? "high" : fit >= 5 ? "mid" : "longshot",
                                    fitReason: "invented", matchedClientName: warm ? clients[k % clients.count] : nil,
                                    possibleMatchSource: nil, possibleMatchName: nil, ingestedAt: now, runSourceURLs: [])
                show.presenter = org
                show.sourceIds = [source.sourceId]
                context.insert(show)
                written.shows += 1
            }
        }
        try context.save()
        written.landingRuns = try seedLandingRecords(handoff: paths.handoff, now: now, into: context)
        return written
    }

    // The landing records, one per state that lives in records, plus a fortnight of finished landings with their
    // entry flush counts, so `scripts/landing-flush-rate.sh` has a rate to read.
    static func seedLandingRecords(handoff: URL, now: Date, into context: ModelContext) throws -> Int {
        let journals = LandingJournals(directory: handoff.appendingPathComponent(LandingJournals.folderName,
                                                                                isDirectory: true),
                                       readFailures: HandoffReadFailures())
        let pending = PendingScoutIngests(directory: handoff.appendingPathComponent(PendingScoutIngests.folderName,
                                                                                   isDirectory: true),
                                          readFailures: HandoffReadFailures())
        let twoDaysAgo = now.addingTimeInterval(-2 * 86_400)
        var runs: [LandingRun] = []

        // Waiting to be finished at idle, and stuck as a kept copy.
        let waitingData = try results(for: [0, 1, 2], suffix: "waiting", now: now)
        let waitingCopy = try pending.record(waitingData, sequence: Seeded.waitingSequence, now: twoDaysAgo)
        try journals.start(LandingJournal(runIdentity: waitingCopy.contentHash, sequence: Seeded.waitingSequence,
                                          entryPoint: .scoutExtractIngest,
                                          sources: [0, 1, 2].map { .init(sourceId: sourceId($0), pageHash: nil) },
                                          now: twoDaysAgo, resultsCopy: waitingCopy.contentHash))
        let waitingRun = LandingRun(runIdentity: waitingCopy.contentHash, landedAt: nil, sequence: Seeded.waitingSequence,
                                    entryPoint: .scoutExtractIngest, startedAt: twoDaysAgo)
        waitingRun.attemptCount = 1
        runs.append(waitingRun)

        // Stopped retrying.
        let dayAgo = now.addingTimeInterval(-86_400)
        try journals.start(LandingJournal(runIdentity: Seeded.stoppedIdentity, sequence: Seeded.stoppedSequence,
                                          entryPoint: .runScoutLanding,
                                          sources: [3, 4, 5, 6].map { .init(sourceId: sourceId($0), pageHash: nil) },
                                          now: dayAgo))
        let stoppedRun = LandingRun(runIdentity: Seeded.stoppedIdentity, landedAt: nil, sequence: Seeded.stoppedSequence,
                                    entryPoint: .runScoutLanding, startedAt: dayAgo)
        stoppedRun.attemptCount = LandingRecovery.attemptCap
        runs.append(stoppedRun)

        // Unreadable, set aside as the journal reader sets one aside.
        try FileManager.default.createDirectory(at: journals.directory, withIntermediateDirectories: true)
        try Data("not a landing record".utf8).write(to: journals.directory.appendingPathComponent(
            LandingJournals.fileName(sequence: Seeded.unreadableSequence, runIdentity: "sweep-synthetic-unreadable")
                + LandingJournals.quarantineSuffix))

        // Kept results the launch sweep lands.
        try pending.record(try results(for: [7, 8], suffix: "fresh", now: now), sequence: Seeded.freshSequence,
                           now: now.addingTimeInterval(-600))

        // Kept results that had already landed.
        let alreadyData = try results(for: [9], suffix: "already", now: now)
        let alreadyCopy = try pending.record(alreadyData, sequence: Seeded.alreadyLandedSequence,
                                             now: now.addingTimeInterval(-3_600))
        runs.append(LandingRun(runIdentity: alreadyCopy.contentHash, landedAt: now.addingTimeInterval(-3 * 3_600),
                               sequence: Seeded.alreadyLandedSequence, entryPoint: .scoutExtractIngest,
                               startedAt: now.addingTimeInterval(-3 * 3_600)))

        // A fortnight of finished landings: their entry flushes, and one the recovery finished late.
        let flushes = [0, 0, 1, 0, 2, 0, 0, 1, 0, 0, 0, 1, 0, 0]
        for (day, saved) in flushes.enumerated() {
            let started = now.addingTimeInterval(-TimeInterval(day + 1) * 86_400)
            let run = LandingRun(runIdentity: "synthetic-landed-\(day)", landedAt: started.addingTimeInterval(9),
                                 sequence: 10 + day, entryPoint: day % 2 == 0 ? LandingSingleFlight.EntryPoint.runScoutLanding : .scoutExtractIngest,
                                 startedAt: started)
            run.entryFlushSaves = saved
            if day == 3 {
                run.attemptCount = 1
                run.recoveredAt = started.addingTimeInterval(3 * 3_600)
            }
            runs.append(run)
        }
        for run in runs { context.insert(run) }
        try context.save()
        return runs.count
    }

    // A results file for the named sources, two invented shows each, never ones the store already holds.
    static func results(for indexes: [Int], suffix: String, now: Date) throws -> Data {
        let orgs = organisations
        let venues = venues
        let file = ScoutExtractResults(
            version: 1, generatedAt: ISO8601DateFormatter().string(from: now),
            results: indexes.map { index in
                ScoutExtractResult(
                    sourceId: sourceId(index), verdict: .upcomingListings,
                    events: (0..<2).map { k in
                        LandingOracleCorpus.event(
                            "\(titles[(index + k) % titles.count]) (\(suffix) \(k + 1))", orgs[index],
                            venues[index % venues.count],
                            ScoutTestClock.day(20 + k, after: now),
                            "https://\(slug(orgs[index])).example/\(suffix)-\(k + 1)")
                    },
                    note: nil)
            })
        return try JSONEncoder().encode(file)
    }

    struct Refused: Error, CustomStringConvertible {
        let description: String
    }
}

// The shape, every run, in a sandbox: the scale the issue names, the vocabulary only the synthetic arm's, and each
// seeded record read back through the app's own readers in the state it was seeded for.
@MainActor
@Suite("The synthetic landing store holds the real scale and every recorded state (#4338)")
final class SyntheticLandingStoreTests {
    private let sandboxes = TemporarySandboxes()
    private let now = Date(timeIntervalSince1970: 1_791_000_000)

    @Test func itHoldsThirtyNineSourcesAndThirteenHundredFiftyShowsInTheRecordedStates() throws {
        let folder = try sandboxes.make(named: "synthetic-landing-store")
        let written = try SyntheticLandingStore.write(into: folder, now: now)
        #expect(written == .init(sources: 39, shows: 1_350, landingRuns: 17))

        let paths = StoreLocation.paths(inStoreFolder: folder)
        let container = try FileStores.container(for: AppSchema.schema,
                                           configurations: [ModelConfiguration(schema: AppSchema.schema, url: paths.store,
                                                                               cloudKitDatabase: .none)])
        let context = ModelContext(container)
        #expect(try context.fetchCount(FetchDescriptor<WatchedSource>()) == 39)
        #expect(try context.fetchCount(FetchDescriptor<Prospect>()) == 1_350)

        let journals = LandingJournals(directory: paths.handoff.appendingPathComponent(LandingJournals.folderName),
                                       readFailures: HandoffReadFailures())
        let pending = PendingScoutIngests(directory: paths.handoff.appendingPathComponent(PendingScoutIngests.folderName),
                                          readFailures: HandoffReadFailures())
        let survey = try LandingRecovery.surveyAll(journals: journals, pending: pending, in: context)
        let findings = Dictionary(uniqueKeysWithValues: survey.interrupted.map { ($0.journal.sequence, $0.finding) })
        #expect(findings[SyntheticLandingStore.Seeded.waitingSequence] == .replay)
        #expect(findings[SyntheticLandingStore.Seeded.stoppedSequence] == .stoppedRetrying(attempts: LandingRecovery.attemptCap))
        #expect(survey.unreadable.count == 1 && survey.unreadable.allSatisfy { $0.hasSuffix(LandingJournals.quarantineSuffix) })
        let standing = LandingOutcome.standing(interrupted: survey.interrupted, unreadable: survey.unreadable,
                                               editsStuck: nil)
        #expect(standing.map(\.look) == [.stalled, .failed, .alive], Comment(rawValue: "\(standing)"))
        // Three kept copies: the waiting landing's, the fresh one the launch sweep lands, the one already landed.
        #expect(try pending.list().count == 3)
        let alreadyLanded = try #require(try Self.alreadyLandedHash(pending))
        #expect(try LandingRun.landedAt(alreadyLanded, in: context) != nil)
    }

    // Every name in the store comes from the synthetic arm, so nothing real can be in it.
    @Test func everyNameComesFromTheSyntheticArm() throws {
        let folder = try sandboxes.make(named: "synthetic-landing-names")
        try SyntheticLandingStore.write(into: folder, now: now)
        let context = ModelContext(try FileStores.container(
            for: AppSchema.schema,
            configurations: [ModelConfiguration(schema: AppSchema.schema,
                                                url: StoreLocation.paths(inStoreFolder: folder).store,
                                                cloudKitDatabase: .none)]))
        let titles = Set(SyntheticLandingStore.titles)
        let venues = Set(SyntheticLandingStore.venues)
        let orgs = Set(SyntheticLandingStore.organisations)
        let shows = try context.fetch(FetchDescriptor<Prospect>())
        #expect(shows.allSatisfy { titles.contains($0.groupName) && venues.contains($0.venue ?? "") })
        #expect(shows.allSatisfy { orgs.contains($0.presenter ?? "") })
        #expect(shows.compactMap(\.matchedClientName).allSatisfy(SyntheticLandingStore.clients.contains))
        #expect(shows.allSatisfy { ($0.sourceListingURL ?? "").contains(".example/") })
    }

    @Test func itNeverWritesOverAStore() throws {
        let folder = try sandboxes.make(named: "synthetic-landing-twice")
        try SyntheticLandingStore.write(into: folder, now: now)
        #expect(throws: SyntheticLandingStore.Refused.self) { try SyntheticLandingStore.write(into: folder, now: now) }
    }

    private static func alreadyLandedHash(_ pending: PendingScoutIngests) throws -> String? {
        try pending.list().compactMap { listed -> PendingScoutIngests.Entry? in
            guard case .entry(let entry) = listed else { return nil }
            return entry
        }.first { $0.sequence == SyntheticLandingStore.Seeded.alreadyLandedSequence }?.contentHash
    }
}

// The writer `scripts/make-synthetic-landing-store.sh` runs. Opt in and SKIPPED everywhere by default: it writes
// only into the folder the script names, refused by the same rule the Debug build refuses a store folder by.
@MainActor
@Suite("Synthetic landing store, written into a named folder (#4338, opt-in)")
struct SyntheticLandingStoreWriter {
    nonisolated static var folder: String? { ProcessInfo.processInfo.environment["OVERTURE_SYNTHETIC_STORE_OUT"] }

    @Test(.enabled(if: SyntheticLandingStoreWriter.folder != nil))
    func writeTheStore() throws {
        let raw = try #require(Self.folder)
        let answer = StoreLocation.debugStoreFolder(arguments: ["Overture", StoreLocation.storeFolderArgument, raw],
                                                    isDebugBuild: true, appSupport: StoreLocation.appSupport)
        guard case .folder(let folder) = answer else {
            Issue.record(Comment(rawValue: "refused the folder: \(answer)"))
            return
        }
        let written = try SyntheticLandingStore.write(into: folder, now: Date())
        try "sources \(written.sources)\nshows \(written.shows)\nlanding records \(written.landingRuns)\n"
            .write(to: folder.appendingPathComponent("synthetic-store-report.txt"), atomically: true, encoding: .utf8)
    }
}
