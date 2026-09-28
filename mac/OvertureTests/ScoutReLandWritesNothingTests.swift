import Testing
import Foundation
import Observation
import SwiftData

// #4106 Phase 1a (plan v5's D1, carried unchanged into v7): a scout re-land that changes nothing writes
// nothing, except the one field it is still allowed to, `ingestedAt`.
//
// WHY. SwiftData's generated setter announces a mutation on every ASSIGNMENT, not on every change, and it
// marks the row dirty for the save to carry. `ScoutService.apply` used to assign roughly forty fields on
// every row a sweep touched, almost always with the value the row already held, so every re-land of an
// unchanged feed dirtied every row it listed and woke every observer of every one of them. Measured under
// #4275, a later sweep restamped the same roughly 400 rows. The rule since: a write reached from `apply`
// goes through `Prospect.assign(_:_:)` or a compare first setter, and writes only a value that differs.
//
// THE GATE IS THE STATE REACHED, NOT A LIST OF WRITES (L247, L96, L621). Observation is armed on EVERY
// stored property of every row, enumerated from `ScopeFields` (which `ScopeFieldsMatchTheSchemaTests`
// holds to `AppSchema.schema`), so a write reaching any field by any route is seen, including a route
// nobody listed. The fixture carries every state D1 names as one where a naive re-write hides: dropped
// nights, an open and a cleared conflict, a Dan overridden classification, an active performer match and
// one being cleared, a presenter a sweep wrote, two sources with different precedence keys, a multi night
// run with per night start times, a show Dan renamed, and a merge survivor.
//
// THE RESIDUE is named here and nowhere else: `ingestedAt`, still stamped `Date()` on every applied row
// until Phase 1b settles it (decision 6(b)). When 1b lands, this set shrinks and the test says so.
//
// A POSITIVE CONTROL in the same fixture changes one input and asserts exactly one field fires, so a
// harness that could not see a write at all fails rather than passing (L159, L467).
@MainActor
@Suite("A scout re-land that changes nothing writes nothing but ingestedAt (#4106 Phase 1a)")
struct ScoutReLandWritesNothingTests {

    // The fields a re-land of unchanged events may still write. Phase 1b (decision 6(b)) empties this.
    static let residue: Set<String> = ["ingestedAt"]

    static let today = "2026-10-01"
    static let venue = "Orchard Street Hall"
    static let otherVenue = "Delancey Black Box"
    static let blockedOpen = "2026-11-20"
    static let blockedCleared = "2026-11-21"

    // An invented roster: nothing here names a real person or organisation.
    static let client = DownbeatClient(id: "client-fernwood", displayName: "Fernwood Players", shortName: nil,
                                       email: "", contractEmail: "", phoneNumber: nil, isTaxExempt: nil,
                                       hasLeftReview: false, specialBehaviors: [], notes: nil, hostingSite: "")

    static let blocked = BlockedCalendar.build(availability: .measured, bookings: [],
                                               exportedBlockedDates: [blockedOpen, blockedCleared], daysOff: [])

    static func event(_ title: String, _ date: String, presenter: String? = "Quill Arts Collective",
                      venue: String = venue, url: String? = nil, series: String? = nil,
                      startTimes: [String] = ["19:30"], location: String = "New York, NY") -> ExtractedEvent {
        ExtractedEvent(title: title, presenter: presenter, venue: venue, performanceDate: date,
                       sourceUrl: url ?? "https://example.test/\(title.lowercased().replacingOccurrences(of: " ", with: "-"))/\(date)",
                       location: location, seriesId: series, startTimes: startTimes)
    }

    // Source A carries every state; source B co-lists one show with a different presenter, so the row has
    // two sources with different precedence keys and each re-land asks the precedence rule both ways.
    static func sourceA(survivorLocation: String = "New York, NY") -> [ExtractedEvent] {
        [
            event("Plain Evening", "2026-11-05"),
            event("Renamed Evening", "2026-11-06"),
            event("Overridden Evening", "2026-11-07"),
            event("Performer Evening", "2026-11-08", presenter: "Nobody Anyone Knows"),
            event("Client Evening", "2026-11-09", presenter: "Fernwood Players"),
            event("Swept Evening", "2026-11-10", presenter: nil),
            event("Conflicted Evening", blockedOpen),
            event("Cleared Evening", blockedCleared, venue: otherVenue),
            event("Survivor Evening", "2026-11-12", location: survivorLocation),
            // A multi night run with per night start times, one of which differs.
            event("Long Run", "2026-11-13", series: "run-long", startTimes: ["19:00"]),
            event("Long Run", "2026-11-14", series: "run-long", startTimes: ["14:00"]),
            event("Long Run", "2026-11-15", series: "run-long", startTimes: ["19:00"]),
            // A run whose OPENING night Dan dropped, so the date, the nights and the end date all go through
            // the drop subtraction on every re-land.
            event("Dropped Run", "2026-11-16", series: "run-dropped"),
            event("Dropped Run", "2026-11-17", series: "run-dropped"),
            event("Dropped Run", "2026-11-18", series: "run-dropped"),
        ]
    }

    static let sourceB: [ExtractedEvent] = [
        event("Plain Evening", "2026-11-05", presenter: "Harbour Light Opera Guild"),
    ]

    static func feed(_ id: String) -> ScoutService.FeedCheck {
        ScoutService.FeedCheck(sourceId: id, baseline: 20, successfulCheckCount: 10)
    }

    // One re-land, as `ScoutExtractIngest` lands one: every source applied in order against one working
    // set, then ONE reconcile with every source's report.
    static func land(_ a: [ExtractedEvent], _ b: [ExtractedEvent], into ctx: ModelContext) {
        let landing = ScoutLandingStore(context: ctx)
        var reports: [FeedReconcile.SourceReport] = []
        for (id, events) in [("src-a", a), ("src-b", b)] {
            let outcome = ScoutService.apply(events: events, clients: [client], history: [], blocked: blocked,
                                             feed: feed(id), today: today, sourceIds: [id], landing: landing,
                                             into: ctx)
            reports += outcome.allReports
        }
        FeedReconcile.reconcile(stored: (try? landing.rows()) ?? [], reports: reports, today: today)
    }

    // Seeds the store: a first land inserts, the states Dan, a sweep, Prep and a merge leave behind are put on
    // the rows, a second land settles the transitions they cause (a performer match cleared by a confident
    // org match, a merge survivor's question answered), and the store is saved. What remains is the steady
    // state a third land of the same events must leave exactly as it found it.
    static func seeded() throws -> (ModelContainer, ModelContext) {
        let container = try ModelContainer(for: AppSchema.schema,
                                           configurations: [ModelConfiguration(isStoredInMemoryOnly: true)])
        let ctx = container.mainContext
        land(sourceA(), sourceB, into: ctx)
        try ctx.save()

        let rows = try ctx.fetch(FetchDescriptor<Prospect>())
        func row(_ title: String) throws -> Prospect {
            try #require(rows.first { $0.scoutGroupName == title }, "the first land did not insert \(title)")
        }
        let renamed = try row("Renamed Evening")
        renamed.groupName = "Dan's Name For It"
        renamed.groupNameOverriddenByDan = true

        let overridden = try row("Overridden Evening")
        overridden.discipline = Discipline.dance.rawValue
        overridden.classificationOverriddenByDan = true

        for performer in [try row("Performer Evening"), try row("Client Evening")] {
            performer.relationshipCorrectedByPerformerMatch = true
            performer.priorRelationship = "booked"
            performer.matchedPerformerName = "Ines Calloway"
            performer.performerMatchNote = "a past client plays in it"
            performer.performerMatchPreviousRelationship = "none"
            performer.performerMatchPreviousFitScore = 7
            performer.performerMatchPreviousTier = "low"
        }

        try row("Swept Evening").setPresenter("Lantern Street Presents", from: .sweep)
        try row("Cleared Evening").clearConflict()
        try row("Survivor Evening").survivedMergeAt = Date(timeIntervalSince1970: 1_790_000_000)

        let dropped = try row("Dropped Run")
        dropped.droppedRunNights = [DroppedNight(night: "2026-11-16", reason: .notAFit,
                                                 at: Date(timeIntervalSince1970: 1_790_000_000)).stored]

        try ctx.save()
        land(sourceA(), sourceB, into: ctx)
        try ctx.save()
        return (container, ctx)
    }

    // Every stored property of every row, armed one tracking per field so a fire names its field.
    final class Fires: @unchecked Sendable {
        private let lock = NSLock()
        private var fired: [String: Set<String>] = [:]
        private(set) var armed = 0
        func record(_ row: String, _ field: String) {
            lock.lock(); fired[row, default: []].insert(field); lock.unlock()
        }
        func countArmed() { armed += 1 }
        var byRow: [String: Set<String>] { lock.lock(); defer { lock.unlock() }; return fired }
    }

    // What every save of `ctx` carried, by identifier, so the dirty set is read from the store's own
    // account of the writes rather than from the observation it is checking.
    final class SaveTap: @unchecked Sendable {
        private let lock = NSLock()
        private var ids: Set<PersistentIdentifier> = []
        private var others = 0
        private var token: NSObjectProtocol?
        init(_ ctx: ModelContext) {
            token = NotificationCenter.default.addObserver(forName: ModelContext.didSave, object: ctx,
                                                           queue: nil) { [weak self] note in
                let info = note.userInfo ?? [:]
                let updated = info[ModelContext.NotificationKey.updatedIdentifiers.rawValue]
                    as? [PersistentIdentifier] ?? []
                let inserted = info[ModelContext.NotificationKey.insertedIdentifiers.rawValue]
                    as? [PersistentIdentifier] ?? []
                let deleted = info[ModelContext.NotificationKey.deletedIdentifiers.rawValue]
                    as? [PersistentIdentifier] ?? []
                self?.add(updated, others: inserted.count + deleted.count)
            }
        }
        private func add(_ updated: [PersistentIdentifier], others count: Int) {
            lock.lock(); ids.formUnion(updated); others += count; lock.unlock()
        }
        var updated: Set<PersistentIdentifier> { lock.lock(); defer { lock.unlock() }; return ids }
        var insertedOrDeleted: Int { lock.lock(); defer { lock.unlock() }; return others }
        func stop() { if let token { NotificationCenter.default.removeObserver(token) } }
    }

    nonisolated static func fieldName(_ path: AnyKeyPath) -> String {
        let printed = String(describing: path)
        return printed.split(separator: ".").last.map(String.init) ?? printed
    }

    static func arm<M: ScopeObserved>(_ model: M, label: String, into fires: Fires, seen: inout Set<ObjectIdentifier>) {
        guard seen.insert(ObjectIdentifier(model)).inserted else { return }
        for field in M.scopeFields {
            let name = fieldName(field.keyPath)
            withObservationTracking { field.arm(model) } onChange: { fires.record(label, name) }
            fires.countArmed()
            for next in field.reaches(model) {
                arm(next, label: "\(label) > \(type(of: next))", into: fires, seen: &seen)
            }
        }
    }

    // Returns the rows it armed, and the caller must HOLD them: a context does not keep an unchanged row
    // alive, so a row nobody holds is deallocated and the land below fetches a fresh instance whose
    // registrar nobody armed. Measured while writing this: the control saw no fire at all, not even the
    // residue, until the rows were held.
    static func armEverything(in ctx: ModelContext) throws
        -> (Fires, labelOf: [PersistentIdentifier: String], held: [Prospect]) {
        let fires = Fires()
        var seen = Set<ObjectIdentifier>()
        var labels: [PersistentIdentifier: String] = [:]
        let rows = try ctx.fetch(FetchDescriptor<Prospect>())
        for p in rows {
            labels[p.persistentModelID] = p.naturalKey
            arm(p, label: p.naturalKey, into: fires, seen: &seen)
        }
        return (fires, labels, rows)
    }

    static func describe(_ fired: [String: Set<String>]) -> String {
        fired.keys.sorted().map { "\($0): \(fired[$0]!.sorted().joined(separator: ", "))" }.joined(separator: "; ")
    }

    @Test func reLandingTheSameEventsFiresNothingButTheResidue() throws {
        let (container, ctx) = try Self.seeded()
        defer { withExtendedLifetime(container) {} }
        #expect(!ctx.hasChanges, "the seed left unsaved changes, so the land below is not judged alone")

        let rows = try ctx.fetch(FetchDescriptor<Prospect>())
        // The fixture really holds the states it claims, or the gate below judges an easier store (L165).
        #expect(rows.count == 11, "expected 11 shows, found \(rows.count)")
        #expect(rows.contains { $0.groupNameOverriddenByDan })
        #expect(rows.contains { $0.classificationOverriddenByDan })
        #expect(rows.contains { $0.hasActivePerformerMatch })
        #expect(rows.contains { $0.scoutGroupName == "Client Evening" && !$0.relationshipCorrectedByPerformerMatch },
                "the confident org match did not clear the performer match, so that transition is untested")
        #expect(rows.contains { $0.presenterSource == PresenterSource.sweep.rawValue })
        #expect(rows.contains { $0.conflictOpen })
        #expect(rows.contains { $0.conflictKey != nil && $0.conflictClearedKey == $0.conflictKey && !$0.conflictOpen })
        #expect(rows.contains { $0.sourceIds == ["src-a", "src-b"] })
        #expect(rows.contains { $0.startTimesVary && $0.nightStartTimes.count == 3 })
        #expect(rows.contains { !$0.droppedRunNights.isEmpty && $0.runNights == ["2026-11-17", "2026-11-18"] })
        #expect(rows.contains { $0.scoutGroupName == "Survivor Evening" && $0.survivedMergeAt == nil },
                "the merge survivor's question was not answered, so that transition is untested")

        let (fires, labels, held) = try Self.armEverything(in: ctx)
        defer { withExtendedLifetime(held) {} }
        let saves = SaveTap(ctx)
        defer { saves.stop() }
        #expect(fires.armed > 100 * rows.count, "only \(fires.armed) fields were armed, so part of the store was unwatched")

        Self.land(Self.sourceA(), Self.sourceB, into: ctx)

        let fired = fires.byRow
        // The in-fixture proof that the observation sees writes at all: the residue is written on every row
        // the land applied, so every row must have fired. When Phase 1b empties the residue, this line goes
        // with it and the positive control below is the only proof left.
        #expect(fired.count == rows.count, Comment(rawValue:
            "only \(fired.count) of \(rows.count) rows fired even the residue, so the harness cannot see writes"))
        let beyond = fired.compactMapValues { fields -> Set<String>? in
            let extra = fields.subtracting(Self.residue)
            return extra.isEmpty ? nil : extra
        }
        #expect(beyond.isEmpty, Comment(rawValue:
            "a re-land of unchanged events wrote fields other than the residue "
            + "\(Self.residue.sorted()): " + Self.describe(beyond)))

        // The dirty set, read from the context itself rather than from the observation above (L345). `apply`
        // saves once per source, so what a land wrote is what its saves CARRIED plus what is still pending
        // (the reconcile runs after the last save). Every such row must be one whose only fires were the
        // residue, and a row carried with no fire at all is a write the observation could not see.
        let written = saves.updated.union(ctx.changedModelsArray.map(\.persistentModelID))
        let residueFired = fired.values.contains { !$0.isDisjoint(with: Self.residue) }
        #expect(!written.isEmpty == residueFired, Comment(rawValue:
            "the land wrote \(written.count) rows (hasChanges \(ctx.hasChanges)) while the residue "
            + (residueFired ? "fired" : "did not fire")))
        #expect(saves.insertedOrDeleted == 0, Comment(rawValue:
            "a re-land of unchanged events inserted or deleted \(saves.insertedOrDeleted) rows"))
        let unexplained = written.compactMap { id -> String? in
            guard let label = labels[id] else { return "an unarmed \(id.entityName)" }
            let f = fired[label] ?? []
            return !f.isEmpty && f.isSubset(of: Self.residue) ? nil : label
        }
        #expect(unexplained.isEmpty, Comment(rawValue:
            "written for a reason other than the residue: " + unexplained.sorted().joined(separator: "; ")))
    }

    // The positive control, in the same fixture: one input changes, and exactly one field of one row fires
    // beyond the residue. A harness blind to writes would pass the test above and fail this one.
    @Test func changingOneInputFiresExactlyThatField() throws {
        let (container, ctx) = try Self.seeded()
        defer { withExtendedLifetime(container) {} }
        let (fires, _, held) = try Self.armEverything(in: ctx)
        defer { withExtendedLifetime(held) {} }

        Self.land(Self.sourceA(survivorLocation: "Brooklyn, NY"), Self.sourceB, into: ctx)

        let beyond = fires.byRow.compactMapValues { fields -> Set<String>? in
            let extra = fields.subtracting(Self.residue)
            return extra.isEmpty ? nil : extra
        }
        let count = beyond.values.reduce(0) { $0 + $1.count }
        #expect(count == 1 && beyond.values.first == ["location"], Comment(rawValue:
            "a changed location should fire exactly one field beyond the residue, fired: " + Self.describe(beyond)
            + " (armed \(fires.armed), every fire: " + Self.describe(fires.byRow) + ")"))
    }
}

// #4106 Phase 1a: the compare first writers D1 names, each on its own. The gate above only reaches the
// branches a steady re-land takes, so the ones it cannot reach on a steady state are pinned here: the
// performer match reset (reached only when a confident org match supersedes one, so its first field always
// changes and the other nine may already hold their defaults), and the launch merge's carry of the feed
// identity onto a survivor that already holds it.
@MainActor
@Suite("The compare first writers write only what differs (#4106 Phase 1a)")
struct CompareFirstWritersTests {
    private func row(_ key: String, in ctx: ModelContext) -> Prospect {
        let p = Prospect(naturalKey: key, groupName: "Same Show", discipline: "theater", venue: "Hall",
                         performanceDate: "2026-11-05", sourceListingURL: "https://example.test/same",
                         priorRelationship: "none", production: "self", profile: "neutral",
                         coverage: "unknown", fitScore: 5, tier: "low", fitReason: "", matchedClientName: nil,
                         possibleMatchSource: nil, possibleMatchName: nil)
        p.runSourceURLs = ["https://example.test/same"]
        p.sourceIds = ["src-a"]
        ctx.insert(p)
        return p
    }

    @Test func aSurvivorThatAlreadyMatchesTheLiveRowIsNotWritten() throws {
        let container = try ModelContainer(for: AppSchema.schema,
                                           configurations: [ModelConfiguration(isStoredInMemoryOnly: true)])
        let ctx = container.mainContext
        let live = row("live", in: ctx)
        let survivor = row("survivor", in: ctx)
        try ctx.save()

        let fires = ScoutReLandWritesNothingTests.Fires()
        var seen = Set<ObjectIdentifier>()
        ScoutReLandWritesNothingTests.arm(survivor, label: "survivor", into: fires, seen: &seen)
        #expect(fires.armed > 100, "only \(fires.armed) fields were armed")

        #expect(NaturalKeyVenueMigration.carryTheFeedIdentity(onto: survivor, from: [live, survivor]) == "live")
        #expect(fires.byRow.isEmpty, Comment(rawValue:
            "the carry wrote fields that already held the live row's values: "
            + ScoutReLandWritesNothingTests.describe(fires.byRow)))
        #expect(!ctx.hasChanges)
    }

    private func armed(_ p: Prospect) -> ScoutReLandWritesNothingTests.Fires {
        let fires = ScoutReLandWritesNothingTests.Fires()
        var seen = Set<ObjectIdentifier>()
        ScoutReLandWritesNothingTests.arm(p, label: "row", into: fires, seen: &seen)
        return fires
    }

    @Test func clearingAPerformerMatchWritesOnlyTheFieldsThatHeldOne() throws {
        let container = try ModelContainer(for: AppSchema.schema,
                                           configurations: [ModelConfiguration(isStoredInMemoryOnly: true)])
        let p = row("match", in: container.mainContext)
        p.relationshipCorrectedByPerformerMatch = true
        let fires = armed(p)
        p.clearPerformerMatch()
        #expect(fires.byRow["row"] == ["relationshipCorrectedByPerformerMatch"], Comment(rawValue:
            "fired: " + ScoutReLandWritesNothingTests.describe(fires.byRow)))
    }

    @Test func restatingTheSameConflictPresenterAndGenreWritesNothing() throws {
        let container = try ModelContainer(for: AppSchema.schema,
                                           configurations: [ModelConfiguration(isStoredInMemoryOnly: true)])
        let p = row("same", in: container.mainContext)
        p.setScoutConflict("2026-11-05")
        p.setPresenter("Quill Arts Collective", from: .scout)
        let fires = armed(p)
        p.setScoutConflict("2026-11-05")
        p.setPresenter("Quill Arts Collective", from: .scout)
        GenreVisibility.write(.theater, to: p)
        #expect(fires.byRow.isEmpty, Comment(rawValue:
            "fired: " + ScoutReLandWritesNothingTests.describe(fires.byRow)))
        // The positive half in the same fixture: a real change still writes (L159).
        p.setScoutConflict(nil)
        #expect(fires.byRow["row"]?.contains("conflictKey") == true)
    }
}

// #4106 Phase 1a, D1's ADVISORY half: a source scan of `apply` and its callees that REPORTS any write to a
// stored property not routed through `Prospect.assign` or a compare on the same line. It never gates,
// because a scan of named functions cannot see every route a write takes (L621); the gate above, which
// watches every stored property, is the guard. What this adds is a name and a line for a reviewer, before
// the gate has to be read backwards from a field list.
//
// It does refuse one thing: finding nothing to scan. A function renamed out from under it would otherwise
// report a clean tree for ever (L98).
@Suite("Advisory: writes in the scout's re-land path not routed through assign (#4106 Phase 1a)")
struct ScoutReLandWriteScanTests {
    // (file under mac/, a marker that starts the declaration uniquely, the function name to balance from)
    static let scanned: [(file: String, marker: String, name: String)] = [
        ("Overture/Integration/ScoutService.swift", "private static func apply(_ p: AssembledProspect", "apply"),
        ("Overture/Integration/ScoutService.swift", "private static func takeIncomingClassification(",
         "takeIncomingClassification"),
        ("Overture/Domain/Prospect.swift", "func setScoutConflict(", "setScoutConflict"),
        ("Overture/Domain/Prospect.swift", "func clearPerformerMatch(", "clearPerformerMatch"),
        ("Overture/Domain/Prospect.swift", "func setPresenter(", "setPresenter"),
        ("Overture/Domain/GenreVisibility.swift", "static func write(", "write"),
        ("Overture/Domain/FeedReconcile.swift", "static func reconcile(stored:", "reconcile"),
        ("Overture/Domain/FeedReconcile.swift", "private static func answerAnyMergeSurvivorQuestion(",
         "answerAnyMergeSurvivorQuestion"),
        ("Overture/Domain/NaturalKeyVenueMigration.swift", "static func carryTheFeedIdentity(",
         "carryTheFeedIdentity"),
    ]

    // Writes the scan knows about and why each stands, so the report is only what nobody has looked at.
    static let accounted: [String: String] = [
        "ingestedAt": "the named residue, Phase 1b (decision 6(b))",
        "missedScoutCount": "the += 1 always changes the value; FeedBreakEvent buckets on it",
        "mergeSurvivorUnseenAt": "written only on the asked and absent answer, which is always a change",
        "survivedMergeAt": "cleared only where set, or with the answer above",
    ]

    static var storedNames: Set<String> {
        Set(Prospect.scopeFields.map { ScoutReLandWritesNothingTests.fieldName($0.keyPath) })
    }

    // A direct write to a stored property: `x.name = `, `x.name += `, or a bare `name = ` inside the model.
    static func directWrites(in body: String) -> [(line: Int, property: String, code: String)] {
        let stored = storedNames
        let pattern = try! NSRegularExpression(pattern: #"(?:^|[^\w.])(?:(?:\w+)\.)?(\w+)\s*(?:\+=|-=|=)(?!=)"#)
        var out: [(Int, String, String)] = []
        for (line, code) in SwiftSource.scannableLines(in: body, skipping: []) {
            let trimmed = code.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("let ") || trimmed.hasPrefix("var ") || trimmed.hasPrefix("guard ") { continue }
            let ns = code as NSString
            for m in pattern.matches(in: code, range: NSRange(location: 0, length: ns.length)) {
                let name = ns.substring(with: m.range(at: 1))
                guard stored.contains(name) else { continue }
                // Compare first on the same line: `if p.x != nil { p.x = nil }`.
                if code.contains("\(name) != ") || code.contains("\(name) == ") { continue }
                out.append((line, name, trimmed))
            }
        }
        return out
    }

    @Test func reportWritesNotRoutedThroughAssign() {
        var missing: [String] = []
        var findings: [String] = []
        var scannedLines = 0
        for entry in Self.scanned {
            let source = SourceGuardHelper.source(entry.file)
            guard let start = source.range(of: entry.marker),
                  let body = SourceGuardHelper.bodyOfFunction(named: entry.name,
                                                              in: String(source[start.lowerBound...])) else {
                missing.append("\(entry.file): \(entry.marker)")
                continue
            }
            scannedLines += body.split(separator: "\n").count
            for w in Self.directWrites(in: body) where Self.accounted[w.property] == nil {
                findings.append("\(entry.file) \(entry.name) +\(w.line): \(w.property) in `\(w.code)`")
            }
        }
        #expect(missing.isEmpty, Comment(rawValue:
            "the scan could not find what it scans, so it would report a clean tree for ever: "
            + missing.joined(separator: "; ")))
        #expect(scannedLines > 200, "only \(scannedLines) lines were scanned")
        // Advisory: printed, never asserted.
        if findings.isEmpty {
            print("scout re-land write scan: no write outside assign in \(Self.scanned.count) functions, "
                  + "\(scannedLines) lines")
        } else {
            print("scout re-land write scan, ADVISORY (the gate is ScoutReLandWritesNothingTests): "
                  + "\(findings.count) direct writes to check")
            for f in findings { print("  " + f) }
        }
    }

    // The scan's own positive control: a direct write it must report, and the two shapes it must not.
    @Test func theScanSeesADirectWriteAndSkipsTheRoutedOnes() {
        let body = """
        func sample() {
            existing.location = p.location
            existing.assign(\\.venue, p.venue)
            if p.survivedMergeAt != nil { p.survivedMergeAt = nil }
            let fitScore = 3
        }
        """
        let found = Self.directWrites(in: body).map(\.property)
        #expect(found == ["location"], "found \(found)")
    }
}
