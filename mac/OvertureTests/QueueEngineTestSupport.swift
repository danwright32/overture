import Foundation
import SwiftData
import Testing

// #4358 (slice E1): what every queue engine test builds on: a seeded store holding every table the engine
// keeps, a schedule the test runs turn by turn, a clock it moves by hand, and the Mirror walk that finds every
// structure the engine keys by identity.
//
// Every name and address is invented (L155, L222) and every date is pinned (L130). The store is seeded (L339),
// so a failure names a seed that reproduces it.

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
        for _ in 0..<shows { _ = addShow() }
        for _ in 0..<inquiries { _ = addInquiry() }
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

/// A schedule the test runs by hand, so "one pass per turn" is something it can count.
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
                let cancelled: Bool = lock.withLock {
                    if Task.isCancelled { return true }
                    sleepers[key] = (instant.addingTimeInterval(interval), resume)
                    return false
                }
                if cancelled { resume.resume(throwing: CancellationError()) }
            }
        } onCancel: {
            let resume = lock.withLock { sleepers.removeValue(forKey: key)?.resume }
            resume?.resume(throwing: CancellationError())
        }
    }
}

/// Derivations a test hands the engine. None is a queue term: each answers only what the test asks about.
enum EngineDerivations {
    /// How many rows of each kind the facts hold, with an optional fixed next change.
    struct Counts: Equatable {
        var shows = 0
        var contacts = 0
        var inquiries = 0
        var smallRows = 0
        var minute = 0
    }

    static func counts(nextChange: Date? = nil, readsTheMinute: Bool = false) -> QueueEngineDerivation<Counts> {
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
            builtCardKeys: { _ in [] })
    }
}

/// Engines built the way every test builds them: the store's main context, a private save counter, the hand
/// run schedule, the hand moved clock, and notification centres of the test's own.
@MainActor
enum EngineHarness {
    static func engine<Value>(_ store: EngineStore, _ derivation: QueueEngineDerivation<Value>,
                              turns: EngineTurns, clock: EngineTestClock = EngineTestClock(),
                              events: QueueEngineSystemEvents = QueueEngineSystemEvents(workspace: NotificationCenter(),
                                                                                        system: NotificationCenter()),
                              saves: StoreSaveCount = StoreSaveCount(),
                              refused: @escaping @MainActor (Int, Int) -> Void = { published, incoming in
                                  Issue.record("a generation \(incoming) was refused over \(published)")
                              }) -> QueueEngine<Value> {
        QueueEngine(context: store.context, derivation: derivation, saves: saves, clock: clock.clock, events: events,
                    schedule: turns.schedule, refused: refused)
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
    /// only (a name holding `QueueEngine` or `FactStore`), and stops at a path the caller says is covered whole.
    static func walk(_ subject: Any, stoppingAt covered: Set<String> = []) -> (leaves: [Leaf], paths: Set<String>) {
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
                if covered.contains(here) { continue }
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

    /// Every identifier and string a leaf holds: a dictionary's keys and values, a set's or array's elements.
    static func contents(of leaf: Any) -> (ids: Set<PersistentIdentifier>, strings: Set<String>) {
        var ids: Set<PersistentIdentifier> = []
        var strings: Set<String> = []
        func take(_ item: Any) {
            if let id = item as? PersistentIdentifier { ids.insert(id) }
            if let string = item as? String { strings.insert(string) }
        }
        for child in Mirror(reflecting: unwrapped(leaf)).children {
            let entry = Mirror(reflecting: child.value)
            if entry.displayStyle == .tuple {
                for part in entry.children { take(part.value) }
            } else {
                take(child.value)
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
