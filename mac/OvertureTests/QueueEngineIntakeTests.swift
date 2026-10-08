import Foundation
import SwiftData
import Testing

// #4358 (slice E1a): the queue engine's core, tested. One file on purpose: every new file adds four to six
// entries to the generated project file, and those entries, not the code, are what pushed this branch's review
// diff past what the lessons review can read. The gate, the clock and the change-kind matrix (slice E1b) are
// in `QueueEnginePassTests.swift` and build on what is declared here.
//
// What every test here builds on: a seeded store holding every table the engine keeps, a schedule the test
// runs turn by turn, a clock it moves by hand, a derivation that only counts, and the Mirror walk that finds
// every structure the engine keys by identity. Every name and address is invented (L155, L222) and every date
// is pinned (L130). The store is seeded (L339), so a failure names a seed that reproduces it.
//
// Every assertion about the engine's facts is made against a fresh read of the store through a context of its
// own, never against the engine's own records (L70).

/// A store holding shows with contacts, inquiries, and rows in every small table, built from a seed.
@MainActor
final class EngineStore {
    nonisolated static let baseNow = Date(timeIntervalSince1970: 1_800_014_400)   // 2027-01-15, Eastern

    let container: ModelContainer
    let seed: UInt64
    private var rng: SeededGenerator
    private var made = 0

    var context: ModelContext { container.mainContext }

    init(shows: Int, inquiries: Int = 5, smallRows: Int = 3, seed: UInt64) throws {
        self.seed = seed
        rng = SeededGenerator(seed: seed)
        container = try TestModelContainer.inMemory(AppSchema.models)
        for _ in 0..<shows { addShow() }
        for _ in 0..<inquiries { addInquiry() }
        for _ in 0..<smallRows { addSmallTableRows() }
        try context.save()
    }

    func int(_ range: ClosedRange<Int>) -> Int { range.lowerBound + Int(rng.next() % UInt64(range.count)) }

    func day(_ offset: Int) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "America/New_York")
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: Self.baseNow.addingTimeInterval(Double(offset) * 86_400))
    }

    private func next() -> Int {
        made += 1
        return made
    }

    /// A show with up to three contacts, inserted and not saved.
    @discardableResult
    func addShow(contacts: Int? = nil) -> Prospect {
        let n = next()
        let titles = ["Lantern", "Glass Lantern", "Harbor Lights", "Cedar Strings", "Juniper Choral"]
        let venues = ["Harbor Hall", "Quarry Hall", "Willow Barn", "Willow Barn Stage"]
        let show = Prospect(naturalKey: String(format: "show-%05d", n), groupName: titles[int(0...4)],
                            discipline: "music", venue: venues[int(0...3)], performanceDate: day(int(-10...90)),
                            sourceListingURL: nil, priorRelationship: "none", production: "presenter",
                            profile: "strong", coverage: "likely_uncovered", fitScore: int(1...9), tier: "mid",
                            fitReason: "r", matchedClientName: nil, possibleMatchSource: nil, possibleMatchName: nil,
                            status: [.new, .queued, .drafted, .contacted][int(0...3)], ingestedAt: Self.baseNow)
        show.presenter = ["Lark & Finch Players", "Quarry Arts", nil][int(0...2)]
        context.insert(show)
        let count = contacts ?? int(0...3)
        show.setRecipients((0..<count).map { c in
            let id = String(format: "show%05d-c%d@example.org", n, c)
            return Recipient(id: id, email: id, provenance: .act)
        })
        return show
    }

    @discardableResult
    func addInquiry() -> Inquiry {
        let n = next()
        let inquiry = Inquiry(source: .contactForm, inquirerName: "Inquirer \(n)", inquirerEmail: "inq\(n)@example.org",
                              eventName: "Gala \(n)", performanceDate: day(int(1...60)), venue: "Willow Barn",
                              createdAt: Self.baseNow)
        context.insert(inquiry)
        return inquiry
    }

    /// One row in each of the seven small tables, inserted and not saved.
    func addSmallTableRows() {
        let n = next()
        context.insert(OrgReachabilityAnswer(orgKey: "org-\(n)", result: .emailFound, probedAt: Self.baseNow,
                                             sourceNaturalKey: "show-\(n)", sourceGroupName: "Group \(n)",
                                             presenterName: "Presenter \(n)", foundEmails: ["box\(n)@example.org"]))
        context.insert(WatchedSource(sourceId: "src-\(n)", orgName: "Org \(n)",
                                     listingsURL: "https://org\(n).example.org/e", kind: .html, addedAt: Self.baseNow))
        context.insert(RefusedContactAddress(id: "refusal-\(n)", scopeRaw: "show", scopeId: "show-\(n)",
                                             handleKey: "struck\(n)@example.org", refusedAt: Self.baseNow))
        context.insert(PromotedProducer(orgKey: "promoted-\(n)", addedAt: Self.baseNow))
        context.insert(DemotedHouse(orgKey: "demoted-\(n)", addedAt: Self.baseNow))
        context.insert(ExcludedTown(town: "excluded-\(n)", addedAt: Self.baseNow))
        context.insert(AllowedSeedTown(town: "allowed-\(n)", addedAt: Self.baseNow))
    }

    func shows() throws -> [Prospect] { Prospect.inKeyOrder(try context.fetch(FetchDescriptor<Prospect>())) }

    /// What a fresh read of the SAVED store holds, through a context of its own.
    func freshFacts() throws -> FactStore { try FactStore.extractAll(from: ModelContext(container)) }
}

/// A schedule the test runs by hand, so "one turn per change" is something it can count.
@MainActor
final class EngineTurns {
    private(set) var queued: [@MainActor () -> Void] = []

    var schedule: QueueEngineSchedule {
        { [weak self] work in self?.queued.append(work) }
    }

    /// Runs every queued turn, and any those queue, and says how many ran.
    @discardableResult
    func run() -> Int {
        var ran = 0
        while !queued.isEmpty {
            let work = queued.removeFirst()
            work()
            ran += 1
        }
        return ran
    }

    /// Runs the first queued turn only, and says whether there was one: a launch test steps the fill a batch
    /// at a time with it.
    @discardableResult
    func runOne() -> Bool {
        guard !queued.isEmpty else { return false }
        queued.removeFirst()()
        return true
    }
}

/// A clock the test moves by hand, whose sleeps end only when it has moved far enough (L524).
final class EngineTestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var instant: Date
    private var sleepers: [Int: (until: Date, resume: CheckedContinuation<Void, Error>)] = [:]
    private var nextSleeper = 0

    init(_ start: Date = EngineStore.baseNow) {
        instant = start
    }

    var now: Date { lock.withLock { instant } }

    var waiting: Int { lock.withLock { sleepers.count } }

    var clock: QueueEngineClock {
        QueueEngineClock(now: { [self] in now }, sleep: { [self] interval in try await nap(interval) })
    }

    func advance(by seconds: TimeInterval) {
        let due: [CheckedContinuation<Void, Error>] = lock.withLock {
            instant = instant.addingTimeInterval(seconds)
            let ready = sleepers.filter { $0.value.until <= instant }
            for key in ready.keys { sleepers.removeValue(forKey: key) }
            return ready.values.map { $0.resume }
        }
        for resume in due { resume.resume() }
    }

    private func nap(_ interval: TimeInterval) async throws {
        let key = lock.withLock {
            nextSleeper += 1
            return nextSleeper
        }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (resume: CheckedContinuation<Void, Error>) in
                // A sleep that is already due (no time left) ends at once: only `advance` wakes sleepers, so one
                // registered after its instant passed would otherwise wait for ever.
                enum Outcome { case cancelled, due, sleeping }
                let outcome: Outcome = lock.withLock {
                    if Task.isCancelled { return .cancelled }
                    if interval <= 0 { return .due }
                    sleepers[key] = (instant.addingTimeInterval(interval), resume)
                    return .sleeping
                }
                switch outcome {
                case .cancelled: resume.resume(throwing: CancellationError())
                case .due: resume.resume()
                case .sleeping: break
                }
            }
        } onCancel: {
            let resume = lock.withLock { sleepers.removeValue(forKey: key)?.resume }
            resume?.resume(throwing: CancellationError())
        }
    }
}

/// Derivations a test hands the engine. None is a queue term: each answers only what the test asks about.
enum EngineDerivations {
    /// How many rows of each kind the facts hold, and the minute when asked.
    struct Counts: Equatable {
        var shows = 0
        var contacts = 0
        var inquiries = 0
        var smallRows = 0
        var minute = 0
    }

    static func counts(nextChange: Date? = nil, readsTheMinute: Bool = false,
                       builtCardKeys: Set<String> = []) -> QueueEngineDerivation<Counts> {
        QueueEngineDerivation(
            derive: { input in
                let f = input.facts
                return Counts(shows: f.shows.count, contacts: f.shows.values.reduce(0) { $0 + $1.factContacts.count },
                              inquiries: f.inquiries.count,
                              smallRows: f.orgAnswers.count + f.watchedSources.count + f.refusedAddresses.count
                                  + f.promotedProducers.count + f.demotedHouses.count + f.excludedTowns.count
                                  + f.allowedSeedTowns.count,
                              minute: readsTheMinute ? Int(input.now.timeIntervalSince1970 / 60) : 0)
            },
            differingFields: { a, b in
                var out: [String] = []
                if a.shows != b.shows { out.append("shows") }
                if a.contacts != b.contacts { out.append("contacts") }
                if a.inquiries != b.inquiries { out.append("inquiries") }
                if a.smallRows != b.smallRows { out.append("smallRows") }
                if a.minute != b.minute { out.append("minute") }
                return out
            },
            nextChange: { _ in nextChange },
            builtCardKeys: { _ in builtCardKeys })
    }
}

/// The engine every test builds unless it asks for another derivation.
typealias CountsEngine = QueueEngine<EngineDerivations.Counts>

extension QueueEngineVerifierCounts {
    /// Every verification that ended, whatever it found. ONE sum for every suite that waits on a verdict, so a new
    /// outcome is added in one place: three hand-written copies of it each left out
    /// `cardMismatches` when #4358 slice E4b added it, so a verification ending in one read as still running.
    var ended: Int {
        matches + factMismatches + outputMismatches + cardMismatches + superseded + cancelled
            + unmeasured.values.reduce(0, +)
    }
}

/// Engines built the way every test builds them: the store's main context, a private save counter, the hand
/// run schedule, the hand moved clock, and notification centres of the test's own, never the app's.
@MainActor
enum EngineHarness {
    static func engine<Value>(_ store: EngineStore, _ derivation: QueueEngineDerivation<Value>,
                              turns: EngineTurns, clock: EngineTestClock = EngineTestClock(),
                              events: QueueEngineSystemEvents = QueueEngineSystemEvents(workspace: NotificationCenter(),
                                                                                        system: NotificationCenter()),
                              saves: StoreSaveCount = StoreSaveCount(),
                              refused: @escaping @MainActor (Int, Int) -> Void = { published, incoming in
                                  Issue.record("a generation \(incoming) was refused over \(published)")
                              },
                              // The verifier runs only when asked here: these suites count the clock's sleepers,
                              // and `QueueEngineVerifierTests` drives its own triggers.
                              verifier: QueueEngineVerifierSetup = QueueEngineVerifierSetup(triggers: .byHand),
                              // The launch's reads run in a turn here: these suites start the engine and run its
                              // turns, and `QueueEngineLaunchTests` drives the launch thread itself.
                              launch: QueueEngineLaunchSetup = QueueEngineLaunchSetup(reads: .inTurn),
                              // #4358 slice E4b: the signal inputs every pass is handed. These suites' subject is not
                              // the pass, so the same value every time, asked for by name (`noSignals`).
                              contextInputs: @escaping @MainActor () -> QueueEngineContextInputs = { EngineHarness.noSignals },
                              landing: QueueEngineLandingSetup = QueueEngineLandingSetup())
        -> QueueEngine<Value> {
        QueueEngine(context: store.context, derivation: derivation, saves: saves, clock: clock.clock, events: events,
                    schedule: turns.schedule, refused: refused, verifier: verifier, launch: launch,
                    contextInputs: contextInputs, landing: landing)
    }

    /// No client, Gmail not connected, nothing running: a fixed answer for every input that arrives by a signal.
    nonisolated static let noSignals = QueueEngineContextInputs(clients: .none)

    /// A counting engine, started, with the start's turns run.
    static func started(_ store: EngineStore, _ turns: EngineTurns,
                        saves: StoreSaveCount = StoreSaveCount()) -> CountsEngine {
        let engine = engine(store, EngineDerivations.counts(), turns: turns, saves: saves)
        engine.start()
        turns.run()
        return engine
    }
}

/// Every structure a queue engine keys by identity, found by walking its stored properties with Mirror.
///
/// Independent of `QueueEngine.identityKeyedState` on purpose (L70): the registry is what the resolve step
/// applies, and this is what the engine actually holds, so the two can be compared.
enum EngineIdentityWalk {
    struct Leaf {
        let path: String
        let value: Any
    }

    /// A dictionary, set or array whose key or element is a `PersistentIdentifier` or a `String`.
    static func isIdentityKeyed(_ value: Any) -> Bool {
        let type = String(describing: Swift.type(of: value))
        return type.range(of: #"^(?:Optional<)?(?:Dictionary|Set|Array)<(?:PersistentIdentifier|String)\b"#,
                          options: .regularExpression) != nil
    }

    /// The leaves under `subject`, by path, and every path the walk visited. Walks into the engine's own types
    /// only (a name holding `QueueEngine` or `FactStore`).
    static func walk(_ subject: Any) -> (leaves: [Leaf], paths: Set<String>) {
        var leaves: [Leaf] = []
        var paths: Set<String> = []
        func walk(_ value: Any, _ path: String, depth: Int) {
            guard depth < 6 else { return }
            for child in Mirror(reflecting: value).children {
                guard var label = child.label else { continue }
                if label.hasPrefix("$") || label.hasPrefix("_$") { continue }
                if label.hasPrefix("_") { label.removeFirst() }
                let here = path.isEmpty ? label : path + "." + label
                paths.insert(here)
                if isIdentityKeyed(child.value) {
                    leaves.append(Leaf(path: here, value: child.value))
                    continue
                }
                let type = String(reflecting: Swift.type(of: child.value))
                if type.contains("QueueEngine") || type.contains("FactStore") {
                    walk(unwrapped(child.value), here, depth: depth + 1)
                }
            }
        }
        walk(subject, "", depth: 0)
        return (leaves, paths)
    }

    /// Every identifier a leaf holds: a dictionary's keys and values, a set's or array's elements.
    static func identities(in leaf: Any) -> Set<PersistentIdentifier> { contents(of: leaf).ids }

    /// Every identifier and every string (a natural key) a leaf holds.
    static func contents(of leaf: Any) -> (ids: Set<PersistentIdentifier>, strings: Set<String>) {
        var ids: Set<PersistentIdentifier> = []
        var strings: Set<String> = []
        for child in Mirror(reflecting: unwrapped(leaf)).children {
            let entry = Mirror(reflecting: child.value)
            let items = entry.displayStyle == .tuple ? entry.children.map(\.value) : [child.value]
            for item in items {
                if let id = item as? PersistentIdentifier { ids.insert(id) }
                if let string = item as? String { strings.insert(string) }
            }
        }
        return (ids, strings)
    }

    private static func unwrapped(_ value: Any) -> Any {
        let mirror = Mirror(reflecting: value)
        guard mirror.displayStyle == .optional, let some = mirror.children.first else { return value }
        return some.value
    }
}

// MARK: - The values

// Each record is held to the store's own schema, and the FactStore's tables to the models the pass reads.
//
// Each record carries every stored property of its model, by the same finder `RowFactsSchemaCoverageTests`
// holds `RowFacts` with, so a property added to one of these models is a red test until somebody carries it
// (L40). And the `FactStore` keeps one table per model `AppSchemaInputClass` says the pass reads, spelled as
// its own members, so a model classified as a queue input with nowhere to keep it, or a table nothing feeds,
// is a red test rather than a row the engine silently never holds (L96).
@Suite("The queue engine's records carry every stored property (#4358)")
@MainActor
struct QueueEngineRecordsCoverTheSchemaTests {

    /// One live row of every model the records copy, saved.
    static func liveRecords() throws -> [(entity: String, labels: Set<String>)] {
        let container = try TestModelContainer.inMemory(AppSchema.models)
        let context = container.mainContext
        let inquiry = Inquiry(source: .contactForm, inquirerName: "Ada", inquirerEmail: nil, eventName: "Gala",
                              createdAt: EngineStore.baseNow)
        let answer = OrgReachabilityAnswer(orgKey: "o", result: .emailFound, probedAt: EngineStore.baseNow,
                                           sourceNaturalKey: "k", sourceGroupName: "g", presenterName: "p",
                                           foundEmails: [])
        let source = WatchedSource(sourceId: "s", orgName: "Org", kind: .html, addedAt: EngineStore.baseNow)
        let refusal = RefusedContactAddress(id: "r", scopeRaw: "show", scopeId: "k", handleKey: "h",
                                            refusedAt: EngineStore.baseNow)
        let promoted = PromotedProducer(orgKey: "p", addedAt: EngineStore.baseNow)
        let demoted = DemotedHouse(orgKey: "d", addedAt: EngineStore.baseNow)
        let excluded = ExcludedTown(town: "e", addedAt: EngineStore.baseNow)
        let allowed = AllowedSeedTown(town: "a", addedAt: EngineStore.baseNow)
        for model in [inquiry, answer, source, refusal, promoted, demoted, excluded, allowed] as [any PersistentModel] {
            context.insert(model)
        }
        try context.save()
        func labels(_ value: Any) -> Set<String> {
            RowFactsSchemaCoverageTests.labels(of: value).subtracting(["persistentModelID"])
        }
        return [
            ("Inquiry", labels(InquiryRecord(copying: inquiry))),
            ("OrgReachabilityAnswer", labels(OrgAnswerRecord(copying: answer))),
            ("WatchedSource", labels(WatchedSourceRecord(copying: source))),
            ("RefusedContactAddress", labels(RefusedAddressRecord(copying: refusal))),
            ("PromotedProducer", labels(ProducerOverrideRecord(copying: promoted))),
            ("DemotedHouse", labels(ProducerOverrideRecord(copying: demoted))),
            ("ExcludedTown", labels(TownRecord(copying: excluded))),
            ("AllowedSeedTown", labels(TownRecord(copying: allowed))),
        ]
    }

    @Test func everyRecordCarriesEveryStoredPropertyAndNothingElse() throws {
        let records = try Self.liveRecords()
        // Every model the FactStore keeps but the show has a record here (the show's is `RowFacts`).
        #expect(Set(records.map(\.entity)) == Set(FactStore.Table.allCases.map(\.rawValue)).subtracting(["Prospect"]))
        for record in records {
            // The positive control, per record: a walk that found nothing would agree with an empty schema (L98).
            #expect(!record.labels.isEmpty && !RowFactsSchemaCoverageTests.stored(record.entity).isEmpty,
                    "nothing was enumerated for \(record.entity), so this checked nothing")
            let found = RowFactsSchemaCoverageTests.findings(entity: record.entity, carried: record.labels, exempt: [:],
                                                             relationships: [:])
            #expect(found.isEmpty, Comment(rawValue: found.joined(separator: "\n")))
        }
    }

    // Each record's copy is checked field by field against the model it came from, through the writer the
    // RowFacts test uses, so a field copied from the wrong property is a red test, not just a missing one.
    @Test func everyRecordCopiesEachFieldFromItsOwnProperty() throws {
        // A store per variant: the writer sets every string to its field's name, so two rows of one table in
        // one store would share their unique key and merge.
        for variant in 0..<2 {
            let container = try TestModelContainer.inMemory(AppSchema.models)
            let context = container.mainContext
            let inquiry = Inquiry(source: .contactForm, inquirerName: "", inquirerEmail: nil, eventName: "")
            let source = WatchedSource(sourceId: "s\(variant)", orgName: "", kind: .html)
            let answer = OrgReachabilityAnswer(orgKey: "o\(variant)", result: .emailFound, probedAt: .distantPast,
                                               sourceNaturalKey: "", sourceGroupName: "", presenterName: "",
                                               foundEmails: [])
            let refusal = RefusedContactAddress(id: "", scopeRaw: "", scopeId: "", handleKey: "", refusedAt: .distantPast)
            let promoted = PromotedProducer(orgKey: "", addedAt: .distantPast)
            let demoted = DemotedHouse(orgKey: "", addedAt: .distantPast)
            let excluded = ExcludedTown(town: "", addedAt: .distantPast)
            let allowed = AllowedSeedTown(town: "", addedAt: .distantPast)
            for model in [inquiry, source, answer, refusal, promoted, demoted, excluded, allowed] as [any PersistentModel] {
                context.insert(model)
            }
            #expect(FactsFixture.populate(inquiry, variant: variant).isEmpty)
            #expect(FactsFixture.populate(source, variant: variant).isEmpty)
            #expect(FactsFixture.populate(answer, variant: variant).isEmpty)
            #expect(FactsFixture.populate(refusal, variant: variant).isEmpty)
            #expect(FactsFixture.populate(promoted, variant: variant).isEmpty)
            #expect(FactsFixture.populate(demoted, variant: variant).isEmpty)
            #expect(FactsFixture.populate(excluded, variant: variant).isEmpty)
            #expect(FactsFixture.populate(allowed, variant: variant).isEmpty)
            try context.save()
            try Self.expectCopied(InquiryRecord(copying: inquiry), from: inquiry)
            try Self.expectCopied(WatchedSourceRecord(copying: source), from: source)
            try Self.expectCopied(OrgAnswerRecord(copying: answer), from: answer)
            try Self.expectCopied(RefusedAddressRecord(copying: refusal), from: refusal)
            try Self.expectCopied(ProducerOverrideRecord(copying: promoted), from: promoted)
            try Self.expectCopied(ProducerOverrideRecord(copying: demoted), from: demoted)
            try Self.expectCopied(TownRecord(copying: excluded), from: excluded)
            try Self.expectCopied(TownRecord(copying: allowed), from: allowed)
        }
    }

    /// Each field of `record`, printed, against the model's own property of that name.
    static func expectCopied<Model: ScopeObserved>(_ record: Any, from model: Model) throws {
        let expected = FactsFixture.expected(model)
        for child in Mirror(reflecting: record).children {
            guard let label = child.label, label != "persistentModelID" else { continue }
            let wanted = try #require(expected[label], "\(label) is no stored property of \(Model.self)")
            #expect(String(describing: child.value) == wanted, "\(Model.self).\(label) was copied from elsewhere")
        }
    }
}

@Suite("The FactStore keeps one table per queue input model (#4358)")
@MainActor
struct FactStoreTablesTests {

    @Test func everyTableIsAMemberSpelledAsItsCase() {
        let members = Set(Mirror(reflecting: FactStore()).children.compactMap(\.label))
        #expect(members == Set(FactStore.Table.allCases.map { String(describing: $0) }),
                "the FactStore's members and its Table cases disagree")
    }

    // Both directions against `AppSchemaInputClass`: every root row and every small table the pass reads has a
    // table, and every table is one of those. A contact rides inside its show.
    @Test func theTablesAreExactlyTheQueueInputsThatAreRows() {
        var expected: Set<String> = []
        for (model, input) in AppSchemaInputClass.byModel {
            switch input {
            case .perRowFact(parent: nil, _), .smallTableInput: expected.insert(model)
            case .perRowFact, .notAQueueInput: continue
            }
        }
        #expect(expected.count == 9, "found \(expected.count) queue input models, so the classification was misread")
        #expect(Set(FactStore.Table.allCases.map(\.rawValue)) == expected)
    }

    // `differences` compares every table: one row removed from each counts once and is named. A table left out
    // of the comparison would read as unchanged here.
    @Test func differencesSeesEveryTable() throws {
        let store = try EngineStore(shows: 2, inquiries: 2, smallRows: 2, seed: 7)
        let before = try store.freshFacts()
        var after = before
        var removed: Set<PersistentIdentifier> = []
        func drop<R>(_ path: WritableKeyPath<FactStore, [PersistentIdentifier: R]>) {
            let id = after[keyPath: path].keys.sorted { "\($0)" < "\($1)" }[0]
            after[keyPath: path].removeValue(forKey: id)
            removed.insert(id)
        }
        drop(\.shows)
        drop(\.inquiries)
        drop(\.orgAnswers)
        drop(\.watchedSources)
        drop(\.refusedAddresses)
        drop(\.promotedProducers)
        drop(\.demotedHouses)
        drop(\.excludedTowns)
        drop(\.allowedSeedTowns)
        let (changed, gone) = before.differences(to: after)
        #expect(gone == removed && changed == FactStore.Table.allCases.count)
    }
}

// MARK: - The resolve step

// #4358 (plan v2 Phase 4 step 1, the resolve step over a DERIVED list, L96, L38).
//
// The resolve step purges and re-keys exactly the structures `QueueEngine.identityKeyedState` names. A list
// written by hand would check only what somebody remembered to write down, so this walks what the engine
// really holds, by Mirror, and fails on any dictionary, set or array keyed by a `PersistentIdentifier` or a
// `String` that the list does not name, and on any line in the list that names nothing. Seen to fail by adding
// an unregistered `[PersistentIdentifier: Int]` to the engine.
//
// Then one test per delete kind (a show and its contacts, a lone contact, an inquiry, a small table row): after
// the delete is saved and the turn has run, every identity-keyed structure the walk finds is free of the
// deleted identities and natural keys, and the facts equal a fresh read of the store. The walk, not the list, decides where to
// look, so a structure the list forgot is searched too (L70).
@Suite("Every identity keyed structure in the queue engine is resolved (#4358)")
@MainActor
struct EngineIdentityKeyedStateTests {

    @Test func everyIdentityKeyedStructureIsRegisteredAndNothingElseIs() throws {
        let store = try EngineStore(shows: 3, seed: 1)
        let engine = EngineHarness.started(store, EngineTurns())
        let (leaves, paths) = EngineIdentityWalk.walk(engine)
        let registered = Set(CountsEngine.identityKeyedState.map(\.path))
        // The positive control: the walk reaches the facts, so an empty finding is a reading, not a blind walk.
        #expect(leaves.contains { $0.path == "facts.shows" } && leaves.count > 10,
                "the walk found \(leaves.count) structures, so it did not reach the engine's state")
        let unregistered = leaves.map(\.path).filter { !registered.contains($0) }.sorted()
        #expect(unregistered.isEmpty, """
                these structures are keyed by identity and the resolve step does not know them, so a deleted or \
                re-keyed row would stay in them: \(unregistered.joined(separator: ", ")). Register each in \
                QueueEngine.identityKeyedState with what the resolve step does to it.
                """)
        let stale = registered.subtracting(paths).sorted()
        #expect(stale.isEmpty, "identityKeyedState names structures the engine does not hold: \(stale.joined(separator: ", "))")
        #expect(registered.count == CountsEngine.identityKeyedState.count, "a structure is registered twice")
    }

    // The detector itself, on shapes it must catch and must leave alone.
    @Test func theDetectorTellsIdentityKeyedShapesFromOthers() {
        let id: [PersistentIdentifier: Int] = [:]
        let keys: Set<String> = []
        let names: [String]? = []
        #expect(EngineIdentityWalk.isIdentityKeyed(id))
        #expect(EngineIdentityWalk.isIdentityKeyed(keys))
        #expect(EngineIdentityWalk.isIdentityKeyed(names as Any))
        #expect(!EngineIdentityWalk.isIdentityKeyed([1, 2]))
        #expect(!EngineIdentityWalk.isIdentityKeyed([Date.distantPast: 1]))
    }

    /// Every identity and natural key the engine still holds anywhere the walk reaches.
    private func held(by engine: CountsEngine) -> (ids: Set<PersistentIdentifier>, strings: Set<String>) {
        var ids: Set<PersistentIdentifier> = []
        var strings: Set<String> = []
        for leaf in EngineIdentityWalk.walk(engine).leaves {
            let found = EngineIdentityWalk.contents(of: leaf.value)
            ids.formUnion(found.ids)
            strings.formUnion(found.strings)
        }
        return (ids, strings)
    }

    /// Runs `delete`, saves, runs the turn, and asserts nothing the engine holds names `ids` or `keys`.
    private func expectGone(_ ids: Set<PersistentIdentifier>, keys: Set<String> = [], store: EngineStore,
                            turns: EngineTurns, engine: CountsEngine, _ delete: () -> Void) throws {
        let before = held(by: engine)
        // The positive control: the engine held every one of them before the delete, so absence afterwards is
        // the resolve step's doing and not a structure that never had them (L159).
        #expect(ids.isSubset(of: before.ids), "the engine did not hold the rows before they were deleted")
        #expect(keys.isSubset(of: before.strings), "the engine did not hold the keys before they were deleted")
        delete()
        try store.context.save()
        turns.run()
        let after = held(by: engine)
        let left = ids.intersection(after.ids)
        let leftKeys = keys.intersection(after.strings)
        #expect(left.isEmpty, "\(left.count) deleted identities are still held after the resolve step")
        #expect(leftKeys.isEmpty, "\(leftKeys.count) deleted natural keys are still held after the resolve step")
        #expect(try engine.facts == store.freshFacts(), "the facts differ from a fresh read after the delete")
    }

    @Test func aShowDeletedWithItsContactsLeavesNothingBehind() throws {
        let store = try EngineStore(shows: 6, seed: 2)
        let show = store.addShow(contacts: 2)
        try store.context.save()
        let turns = EngineTurns()
        let engine = EngineHarness.started(store, turns)
        // The surface keys the show by its natural key too, so the delete must reach those keys as well.
        engine.setViewInputs(QueueEngineViewInputs(focusedKeys: [show.naturalKey], requestedCardKeys: [show.naturalKey]))
        turns.run()
        let ids = Set([show.persistentModelID] + show.recipients.map(\.persistentModelID))
        try expectGone(ids, keys: [show.naturalKey], store: store, turns: turns, engine: engine) {
            store.context.delete(show)
        }
    }

    @Test func aContactDeletedOnItsOwnLeavesNothingBehind() throws {
        let store = try EngineStore(shows: 6, seed: 3)
        let show = store.addShow(contacts: 2)
        try store.context.save()
        let turns = EngineTurns()
        let engine = EngineHarness.started(store, turns)
        let contact = try #require(show.recipients.first)
        try expectGone([contact.persistentModelID], store: store, turns: turns, engine: engine) {
            store.context.delete(contact)
        }
    }

    @Test func anInquiryDeletedLeavesNothingBehind() throws {
        let store = try EngineStore(shows: 2, inquiries: 3, seed: 4)
        let turns = EngineTurns()
        let engine = EngineHarness.started(store, turns)
        let inquiry = try #require(try store.context.fetch(FetchDescriptor<Inquiry>()).first)
        try expectGone([inquiry.persistentModelID], store: store, turns: turns, engine: engine) {
            store.context.delete(inquiry)
        }
    }

    @Test func aSmallTableRowDeletedLeavesNothingBehind() throws {
        let store = try EngineStore(shows: 2, smallRows: 2, seed: 5)
        let turns = EngineTurns()
        let engine = EngineHarness.started(store, turns)
        let answer = try #require(try store.context.fetch(FetchDescriptor<OrgReachabilityAnswer>()).first)
        let town = try #require(try store.context.fetch(FetchDescriptor<ExcludedTown>()).first)
        try expectGone([answer.persistentModelID, town.persistentModelID], store: store, turns: turns, engine: engine) {
            store.context.delete(answer)
            store.context.delete(town)
        }
    }
}

// The engine knows a row has never been saved by its identifier carrying no store identifier. Pinned here,
// with a saved row as the positive control, because the re-key rests on it.
@Suite("A temporary identifier carries no store identifier (#4358)")
@MainActor
struct EngineTemporaryIdentifierTests {
    @Test func onlyAnUnsavedRowLacksAStoreIdentifier() throws {
        let store = try EngineStore(shows: 1, seed: 6)
        let saved = try #require(try store.shows().first)
        let fresh = store.addShow()
        #expect(saved.persistentModelID.storeIdentifier != nil, "a saved row carries no store identifier")
        #expect(fresh.persistentModelID.storeIdentifier == nil, "an unsaved row already carries a store identifier")
        let temporary = fresh.persistentModelID
        try store.context.save()
        #expect(fresh.persistentModelID != temporary && fresh.persistentModelID.storeIdentifier != nil)
    }
}

// MARK: - Intake

// #4358 (plan v7 D2, decision 3): every way a change reaches the queue engine.
//
// Trackers see an edit the moment it is made, saved or not; `didSave` sees a write no tracker was armed for. Each
// test below is one shape of change, and several pin what #4106 probe 2 measured about SwiftData, so an SDK that
// changes it turns a test red rather than silently breaking intake.
@Suite("How a change reaches the queue engine (#4358)")
@MainActor
final class QueueEngineIntakeTests {

    @Test func anUnsavedEditIsTakenInByItsTrackerAndTheSaveChangesNothingMore() throws {
        let store = try EngineStore(shows: 4, seed: 11)
        let turns = EngineTurns()
        let engine = EngineHarness.started(store, turns)
        let show = try #require(try store.shows().first)
        let changed = engine.counters.rowsChanged
        show.fitReason = "edited, not saved"
        #expect(turns.queued.count == 1, "the edit's tracker did not ask for a turn")
        turns.run()
        #expect(engine.facts.shows[show.persistentModelID]?.fitReason == "edited, not saved")
        #expect(engine.counters.rowsChanged == changed + 1)
        try store.context.save()
        turns.run()
        // The save names the row, which reads the same as the tracker already took in: nothing changes again.
        #expect(engine.counters.rowsChanged == changed + 1, "the save of an edit already taken in changed it again")
        #expect(try engine.facts == store.freshFacts())
    }

    // Probe 2 measured that an equal-value write fires the row's tracker and dirties the context. The equality
    // gate is what stops that being a change.
    @Test func anEqualValueWriteChangesNoStoredValue() throws {
        let store = try EngineStore(shows: 4, seed: 12)
        let turns = EngineTurns()
        let engine = EngineHarness.started(store, turns)
        let shows = try store.shows()
        let changed = engine.counters.rowsChanged
        let equal = engine.counters.equalValueReads
        for show in shows { show.groupName = show.groupName }
        try store.context.save()
        turns.run()
        #expect(engine.counters.rowsChanged == changed, "an equal-value write counted as a change")
        #expect(engine.counters.equalValueReads >= equal + shows.count,
                "the rows were not read again, so the gate was never asked")
    }

    // A whole night dismissed in one turn: forty trackers fire and one save names forty rows, and the engine
    // takes them in with ONE turn and derives ONE pass, which is the whole point of the flag.
    @Test func aNightDismissedInOneTurnIsTakenInByOneTurnAndOnePass() throws {
        let store = try EngineStore(shows: 60, seed: 34)
        let turns = EngineTurns()
        let engine = EngineHarness.started(store, turns)
        let passes = engine.counters.passes
        for show in try store.shows().prefix(40) { show.status = .dismissed }
        try store.context.save()
        #expect(turns.queued.count == 1, "forty changes in one turn asked for \(turns.queued.count) turns")
        #expect(turns.run() == 1)
        #expect(engine.counters.passes == passes + 1)
        #expect(try engine.facts == store.freshFacts())
    }

    @Test func aContactsEditReachesItsShow() throws {
        let store = try EngineStore(shows: 3, seed: 13)
        let show = store.addShow(contacts: 2)
        try store.context.save()
        let turns = EngineTurns()
        let engine = EngineHarness.started(store, turns)
        let contact = try #require(show.recipients.first)
        contact.name = "Renamed"
        try store.context.save()
        turns.run()
        let held = engine.facts.shows[show.persistentModelID]?.factContacts.first { $0.persistentModelID == contact.persistentModelID }
        #expect(held?.name == "Renamed")
        #expect(try engine.facts == store.freshFacts())
    }

    // Probe 2: moving a contact fires both parents. The map is what still finds the one it LEFT when only the
    // contact's own tracker reports the move.
    @Test func aContactMovedBetweenShowsChangesBoth() throws {
        let store = try EngineStore(shows: 2, seed: 14)
        let from = store.addShow(contacts: 2)
        let to = store.addShow(contacts: 0)
        try store.context.save()
        let turns = EngineTurns()
        let engine = EngineHarness.started(store, turns)
        let moved = try #require(from.recipients.first)
        from.recipients.removeAll { $0 === moved }
        to.recipients.append(moved)
        try store.context.save()
        turns.run()
        #expect(engine.facts.shows[to.persistentModelID]?.factContacts.map(\.persistentModelID) == [moved.persistentModelID])
        #expect(engine.facts.shows[from.persistentModelID]?.factContacts.count == 1)
        #expect(try engine.facts == store.freshFacts())
    }

    // Probe 2: inserting a show whose natural key is already stored merges it INTO the stored row, which changes
    // in place and fires no tracker. Measured for #4358 (in memory and on disk alike): the save names only the
    // newcomer's own identifier as inserted, a row the store does not hold, and never the row that changed, and
    // the newcomer stays registered and reads as live. So the engine cannot know which row moved, reads
    // everything, and counts it as the anomaly it is: the app's writers look a row up by its key first.
    @Test func anInsertMergedIntoAStoredRowByItsKeyIsReadInFull() throws {
        let store = try EngineStore(shows: 3, seed: 15)
        let turns = EngineTurns()
        let engine = EngineHarness.started(store, turns)
        let held = try #require(try store.shows().first)
        let twin = Prospect(naturalKey: held.naturalKey, groupName: "Upserted", discipline: "music", venue: "Hall",
                            performanceDate: "2027-03-01", sourceListingURL: nil, priorRelationship: "none",
                            production: "presenter", profile: "strong", coverage: "likely_uncovered",
                            fitScore: 9, tier: "mid", fitReason: "r", matchedClientName: nil, possibleMatchSource: nil,
                            possibleMatchName: nil, status: .drafted, ingestedAt: EngineStore.baseNow)
        #expect(engine.counters.insertsMergedAway == .neverFired)
        store.context.insert(twin)
        try store.context.save()
        turns.run()
        #expect(engine.facts.shows[held.persistentModelID]?.groupName == "Upserted")
        #expect(try engine.facts == store.freshFacts())
        #expect(engine.counters.insertsMergedAway.times == 1)
    }

    // #4327 step 0.4: an inserted row's identifier changes at its first save, and a tracker armed before it
    // still reports the old one.
    @Test func anUnsavedInsertIsReKeyedAtItsFirstSave() throws {
        let store = try EngineStore(shows: 2, seed: 16)
        let turns = EngineTurns()
        let engine = EngineHarness.started(store, turns)
        let fresh = store.addShow(contacts: 1)
        let temporary = fresh.persistentModelID
        engine.noteChanged(fresh)
        turns.run()
        #expect(engine.facts.shows[temporary] != nil, "the unsaved insert was not taken in")
        try store.context.save()
        turns.run()
        let permanent = fresh.persistentModelID
        #expect(permanent != temporary)
        #expect(engine.facts.shows[temporary] == nil && engine.facts.shows[permanent] != nil)
        #expect(try engine.facts == store.freshFacts())
        // Saved and not yet edited, nothing the engine holds names any temporary identifier, the contact's
        // included, so a session of inserts never edited again leaves nothing behind.
        let contacts = Set(engine.facts.shows[permanent]?.factContacts.map(\.persistentModelID) ?? [])
        func held() -> Set<PersistentIdentifier> {
            EngineIdentityWalk.walk(engine).leaves
                .reduce(into: []) { $0.formUnion(EngineIdentityWalk.identities(in: $1.value)) }
        }
        #expect(!held().contains(temporary) && held().allSatisfy { $0.storeIdentifier != nil },
                "the engine still holds a temporary identifier after the first save")
        #expect(contacts.allSatisfy { $0.storeIdentifier != nil })
        // The tracker armed before the save still fires with the temporary identifier, a stale fire dropped
        // unread; the row was armed again under its permanent one, so an UNSAVED edit still lands. Unsaved on
        // purpose: a save would name the row and hide a missing tracker.
        fresh.fitReason = "edited after the first save"
        turns.run()
        #expect(engine.facts.shows[permanent]?.fitReason == "edited after the first save",
                "an unsaved edit after the first save was lost: no tracker was armed under the permanent identifier")
        try store.context.save()
        turns.run()
        #expect(try engine.facts == store.freshFacts())
        #expect(!held().contains(temporary))
    }

    // A small table row has no tracker, so nothing will ever report its temporary identifier, and the engine
    // must not keep one for it after the re-key.
    @Test func anUnsavedSmallTableRowLeavesNoTemporaryIdentifierBehind() throws {
        let store = try EngineStore(shows: 2, seed: 22)
        let turns = EngineTurns()
        let engine = EngineHarness.started(store, turns)
        let town = ExcludedTown(town: "temporary town", addedAt: EngineStore.baseNow)
        store.context.insert(town)
        let temporary = town.persistentModelID
        engine.noteChanged(town)
        turns.run()
        #expect(engine.facts.excludedTowns[temporary] != nil, "the unsaved row was not taken in")
        try store.context.save()
        turns.run()
        #expect(try engine.facts == store.freshFacts())
        let held = EngineIdentityWalk.walk(engine).leaves
            .reduce(into: Set<PersistentIdentifier>()) { $0.formUnion(EngineIdentityWalk.identities(in: $1.value)) }
        #expect(!held.contains(temporary), "the engine still holds a temporary identifier nothing can report")
    }

    @Test func startingTwiceWatchesTheStoreOnce() throws {
        let store = try EngineStore(shows: 2, seed: 23)
        let turns = EngineTurns()
        let engine = EngineHarness.started(store, turns)
        #expect(engine.counters.fullReads == 1)
        engine.start()
        #expect(engine.counters.fullReads == 1, "a second start read the whole store again")
    }

    @Test func anInsertDeletedBeforeItsSaveLeavesNothing() throws {
        let store = try EngineStore(shows: 2, seed: 17)
        let turns = EngineTurns()
        let engine = EngineHarness.started(store, turns)
        let fresh = store.addShow(contacts: 1)
        let temporary = fresh.persistentModelID
        engine.noteChanged(fresh)
        turns.run()
        #expect(engine.facts.shows[temporary] != nil)
        store.context.delete(fresh)
        engine.noteChanged(fresh)
        try store.context.save()
        turns.run()
        #expect(engine.facts.shows[temporary] == nil)
        #expect(try engine.facts == store.freshFacts())
    }

    // A save through ANOTHER context leaves the main context's own copies stale (probe 2), so the engine faults
    // the rows it touched and recovery fetches them again in the same turn (decision 9(a), #4358 slice E2), and
    // counts it as the anomaly it is in the app. It no longer reads every row: that was E1a's interim, 795 ms on
    // the main thread at the live store's size.
    @Test func aSaveThroughAnotherContextFaultsTheRowsItTouchedAndRecoversThem() async throws {
        let store = try EngineStore(shows: 4, seed: 18)
        let turns = EngineTurns()
        let saves = StoreSaveCount()
        let engine = EngineHarness.started(store, turns, saves: saves)
        let fullReads = engine.counters.fullReads
        #expect(engine.counters.foreignSaves == .neverFired)
        let id = try #require(try store.shows().first).persistentModelID
        let container = store.container
        let failure: String? = await phase0OnThread("engine-foreign-save") {
            let other = ModelContext(container)
            guard let row = other.model(for: id) as? Prospect else { return "the row was not found" }
            row.fitReason = "written elsewhere"
            return Phase0.saveFailure(other)
        }
        try Phase0.requireSaved(failure, step: "the foreign save")
        #expect(saves.foreignSaveCount(for: container) == 1)
        await waitUntil("the foreign save asked for a turn") { !turns.queued.isEmpty }
        turns.run()
        #expect(engine.counters.foreignSaves.times == 1)
        #expect(engine.facts.shows[id]?.fitReason == "written elsewhere")
        #expect(try engine.facts == store.freshFacts())
        #expect(engine.counters.fullReads == fullReads, "the foreign save read every row again")
        #expect(engine.verifierFindings.map(\.kind) == [.foreignSave, .healed])
        #expect(!engine.isFaulted(id))
    }

    @Test func aSaveIntoAnotherStoreIsNotAChangeToThisOne() throws {
        let store = try EngineStore(shows: 2, seed: 19)
        let other = try EngineStore(shows: 2, seed: 20)
        let turns = EngineTurns()
        _ = EngineHarness.started(store, turns)
        other.addShow()
        try other.context.save()
        #expect(turns.queued.isEmpty, "a save into another store asked this engine for a turn")
    }

    @Test func smallTableAndInquiryWritesAreTakenInFromTheSave() throws {
        let store = try EngineStore(shows: 2, inquiries: 2, smallRows: 2, seed: 21)
        let turns = EngineTurns()
        let engine = EngineHarness.started(store, turns)
        store.addSmallTableRows()
        store.addInquiry()
        let answer = try #require(try store.context.fetch(FetchDescriptor<OrgReachabilityAnswer>()).first)
        answer.presenterName = "Renamed presenter"
        let inquiry = try #require(try store.context.fetch(FetchDescriptor<Inquiry>()).first)
        inquiry.notes = "a note"
        try store.context.save()
        turns.run()
        #expect(try engine.facts == store.freshFacts())
    }
}

// MARK: - Cost (opt in)

// #4358: what the queue engine's intake costs per change, on the live store's clone and on the 4x corpus, against
// plan v7's budget of 10 ms for intake and resolve at 5,376 shows.
//
// OPT IN, on #4106's rule for every probe of this kind: it clones Dan's store and runs a stopwatch, and a timing
// on a shared Mac measures whatever else the machine is doing (L224). Without the variable it says it did not
// run, rather than passing silently (L98):
//
//   TEST_RUNNER_MEASURE_4358_ENGINE=1 mac/scripts/run-tests-locked.sh \
//     -only-testing:OvertureTests/QueueEngineCostProbeTests
//
// Medians of five with their spread, Debug, load average beside each block (L395, L356). Counts and durations
// only, never a name (L222). The value pass is not timed here, and says so: `QueueRenderPass.make` over facts
// cannot run until #4357 finishes, so today's pass over models on the same corpus is timed beside the intake as
// the yardstick the plan's projection is judged against.
@Suite("#4358 queue engine intake cost (opt in, live store clone)")
@MainActor
final class QueueEngineCostProbeTests {

    private let sandboxes = TemporarySandboxes()

    private static var enabled: Bool { ProcessInfo.processInfo.environment["MEASURE_4358_ENGINE"] != nil }

    @Test(.enabled(if: Phase0.liveStoreExists, "no live store on this machine"))
    func intakeCostPerChangeAtOneAndFourTimesTheStore() async throws {
        guard Self.enabled else {
            print("engine-cost: not measured. Set TEST_RUNNER_MEASURE_4358_ENGINE=1 to run it.")
            return
        }
        let dir = try sandboxes.make(named: "engine-cost")
        guard let clone = try LiveStoreClone.makeClone(in: dir) else {
            throw LiveStoreClone.Refusal.backupFailed("no live store on this machine")
        }
        let big = try Phase0.scaledCopy(of: clone, factor: 4, in: dir)
        for (label, url) in [("live clone", clone), ("4x", big)] {
            let container = try Phase0.openContainer(at: url)
            container.mainContext.autosaveEnabled = false
            let context = container.mainContext
            let turns = EngineTurns()
            func engine() -> CountsEngine {
                QueueEngine(context: context, derivation: EngineDerivations.counts(), saves: StoreSaveCount(),
                            clock: EngineTestClock().clock,
                            events: QueueEngineSystemEvents(workspace: NotificationCenter(), system: NotificationCenter()),
                            schedule: turns.schedule, verifier: QueueEngineVerifierSetup(triggers: .byHand),
                            launch: QueueEngineLaunchSetup(reads: .inTurn), contextInputs: { EngineHarness.noSignals })
            }
            // The start with the launch's reads made in a turn: the first read and the whole fill back to back,
            // which the app spreads across turns and off the main thread (#4358 slice E3, measured batch by
            // batch in `launchFillInBatchesAtOneAndFourTimesTheStore`).
            let fullRead = Phase0.median5("intake-fullRead-\(label)") {
                engine().start()
                turns.run()
            }
            let live = engine()
            live.start()
            turns.run()
            let shows = Prospect.inKeyOrder(try context.fetch(FetchDescriptor<Prospect>()))
            let rows = shows.count
            // One row edited and saved: the turn that takes it in (the tracker, the save's identifiers, the
            // resolve step, the re-read and the equality gate), timed from the turn's start to its end.
            var edits: [Double] = []
            var equals: [Double] = []
            var nights: [Double] = []
            for sample in 1...5 {
                let show = shows[(sample * 977) % rows]
                show.fitReason = "engine cost sample \(sample)"
                try Phase0.save(context, step: "engine cost edit")
                edits.append(Phase0.time { turns.run() })
                let same = shows[(sample * 389) % rows]
                same.groupName = same.groupName
                try Phase0.save(context, step: "engine cost equal write")
                equals.append(Phase0.time { turns.run() })
                for (i, row) in shows.enumerated() where (i + sample) % max(1, rows / 40) == 0 {
                    row.reprepDraftRequested.toggle()
                }
                try Phase0.save(context, step: "engine cost night")
                nights.append(Phase0.time { turns.run() })
            }

            // The yardstick: today's pass over models on the same corpus, the viewport's cards built.
            let inquiries = try context.fetch(FetchDescriptor<Inquiry>())
            let answers = try context.fetch(FetchDescriptor<OrgReachabilityAnswer>())
            let sources = try context.fetch(FetchDescriptor<WatchedSource>())
            let refusals = ContactRefusal.ledger(from: try context.fetch(FetchDescriptor<RefusedContactAddress>()))
            let overrides = ProducerOverrides(promotedRows: try context.fetch(FetchDescriptor<PromotedProducer>()),
                                              demotedRows: try context.fetch(FetchDescriptor<DemotedHouse>()))
            func pass(_ keys: Set<String>?) -> QueueView.RenderData {
                QueueRenderPass.make(QueueRenderPass.Inputs(
                    allProspects: QueueRenderPass.Corpus(shows), inquiries: inquiries, orgAnswers: answers,
                    sources: sources, refusals: refusals, overrides: overrides,
                    context: .at(QueueModel.easternToday(), now: Date()),
                    focusedStage: .scout, focusedKeys: nil, requestedCardKeys: keys))
            }
            let viewport = Set(pass([]).focusedRows.prefix(QueueViewportAssumption.rows).map(\.id))
            _ = pass(viewport)
            let today = Phase0.median5("intake-todayPass-\(label)") { _ = pass(viewport) }
            // #4617: the engine's start and today's pass (the yardstick) are read against each other, the engine
            // timed first in every run, so that comparison inside a run carries the order effect, said here.
            Phase0.fixedOrder(["intake-fullRead-\(label)", "intake-todayPass-\(label)"])
            print("""
                engine-cost [\(label)] \(Phase0.load())
                  shape                                     \(Phase0.shape(shows))
                  start, read and whole fill in one go      \(fullRead.text)
                  turn taking in one edited row             \(Phase0.reading("intake-oneEditedRow-\(label)", runs: edits).text)
                  turn taking in one equal-value write      \(Phase0.reading("intake-oneEqualWrite-\(label)", runs: equals).text)
                  turn taking in about 40 rows in one save  \(Phase0.reading("intake-fortyRowSave-\(label)", runs: nights).text)
                  value pass over facts                     UNMEASURED: make over facts needs #4357 (plan: 68 to 155 ms at 1,344, 275 to 624 at 5,376)
                  today's pass over models, viewport cards  \(today.text)  (the yardstick)
                  engine turns \(live.counters.turns), rows read again \(live.counters.rowsReread), equal reads dropped \(live.counters.equalValueReads)
                """)
        }
    }

    // #4358 slice E3: the launch as the app runs it. The first read on the launch thread (its wall time, which holds
    // no main actor turn), then the fill, one batch per turn, against plan v7's "Launch: batches of 20 under 16 ms"
    // (section 14). Each batch is timed twice: by the engine's own uptime around the batch, and from outside around
    // the whole turn that ran it, so other work in the turn cannot hide behind the batch's figure (L345). Five
    // launches per corpus, each on a container opened afresh, every batch of all five pooled.
    @Test(.enabled(if: Phase0.liveStoreExists, "no live store on this machine"))
    func launchFillInBatchesAtOneAndFourTimesTheStore() async throws {
        guard Self.enabled else {
            print("engine-launch: not measured. Set TEST_RUNNER_MEASURE_4358_ENGINE=1 to run it.")
            return
        }
        let dir = try sandboxes.make(named: "engine-launch")
        guard let clone = try LiveStoreClone.makeClone(in: dir) else {
            throw LiveStoreClone.Refusal.backupFailed("no live store on this machine")
        }
        let big = try Phase0.scaledCopy(of: clone, factor: 4, in: dir)
        func ms(_ seconds: [TimeInterval]) -> [Double] { seconds.map { $0 * 1000 } }
        // #4617: the median's `probe reading:` line printed under `metric` as it is taken.
        func spread(_ metric: String, _ runs: [Double]) -> String {
            let sorted = runs.sorted()
            guard !sorted.isEmpty else { return "UNMEASURED: nothing ran" }
            let p99 = sorted[min(sorted.count - 1, Int((Double(sorted.count) * 0.99).rounded(.up)) - 1)]
            return String(format: "median %.1f ms, p99 %.1f, max %.1f over %d", Phase0.reading(metric, runs: runs).median, p99,
                          sorted[sorted.count - 1], sorted.count)
        }
        for (label, url) in [("live clone", clone), ("4x", big)] {
            var firstReads: [Double] = [], fills: [Double] = [], batches: [Double] = [], turnTimes: [Double] = []
            var inquiries: [Double] = []
            var shortfalls: [String] = []
            var shape = ""
            for _ in 0..<5 {
                let container = try Phase0.openContainer(at: url)
                container.mainContext.autosaveEnabled = false
                let turns = EngineTurns()
                let engine = QueueEngine(context: container.mainContext, derivation: EngineDerivations.counts(),
                                         saves: StoreSaveCount(), clock: EngineTestClock().clock,
                                         events: QueueEngineSystemEvents(workspace: NotificationCenter(),
                                                                         system: NotificationCenter()),
                                         schedule: turns.schedule, verifier: QueueEngineVerifierSetup(triggers: .byHand),
                                         launch: QueueEngineLaunchSetup(),
                                         contextInputs: { EngineHarness.noSignals })
                let started = Phase0.now()
                engine.start()
                let landed = await waitUntil("the launch's first read", timeout: .seconds(120)) {
                    if case .loading = engine.launch.firstPaint { return false }
                    return true
                }
                guard landed, engine.output != nil else {
                    Issue.record("engine-launch [\(label)]: the first read did not land: \(engine.launch.firstPaint)")
                    return
                }
                firstReads.append(Phase0.ms(since: started))
                let filling = Phase0.now()
                for _ in 0..<100_000 where !LaunchRig.fillEnded(engine) {
                    if turns.queued.isEmpty {
                        let moved = await waitUntil("the fill's next step", timeout: .seconds(120)) {
                            !turns.queued.isEmpty || LaunchRig.fillEnded(engine)
                        }
                        if !moved { break }
                        continue
                    }
                    turnTimes.append(Phase0.time { turns.runOne() })
                }
                fills.append(Phase0.ms(since: filling))
                guard let report = LaunchRig.report(engine) else {
                    Issue.record("engine-launch [\(label)]: the fill did not finish: \(engine.launch.fill)")
                    return
                }
                batches += ms(report.batchSeconds)
                inquiries.append(report.inquirySeconds * 1000)
                shortfalls.append("\(report.shortfall.map { "\($0)" } ?? "none")")
                shape = "\(report.shows) shows in \(report.batches) batches of up to \(QueueEngineLaunchFill.batchSize), "
                    + "\(report.inquiries) inquiries"
            }
            let budget = QueueEngineLaunchFill.batchBudgetSeconds * 1000
            print("""
                engine-launch [\(label)] \(Phase0.load())
                  shape                                     \(shape)
                  first read, launch thread, wall           \(Phase0.reading("launch-firstRead-\(label)", runs: firstReads).text)  (holds no main actor turn)
                  each batch, engine's own uptime           \(spread("launch-batch-\(label)", batches))
                  batches over \(String(format: "%.0f", budget)) ms                       \(batches.filter { $0 > budget }.count) of \(batches.count)
                  each fill turn, timed from outside        \(spread("launch-fillTurn-\(label)", turnTimes))
                  inquiries in one fetch                    \(Phase0.reading("launch-inquiries-\(label)", runs: inquiries).text)
                  fill, first output to done, wall          \(Phase0.reading("launch-fill-\(label)", runs: fills).text)
                  shortfall per launch                      \(shortfalls.joined(separator: ", "))
                """)
        }
    }
}
