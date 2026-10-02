import Testing
import Foundation
import SwiftData

// #4331 (A2 of #4275's plan): a scout landing stamps `ingestedAt` only on a row it CHANGED, from the
// landing's own `now` plus the row's apply ordinal, except on a row a merge reader still needs to read as
// LAST SEEN, which is restamped on every touch as before. See `IngestedAtStamp` for the rule and its reasons.
//
// THE CHANGE TEST IS DERIVED, NOT LISTED (L41, L96). `aReLandStampsARowExactlyWhenItChangedAnyOtherField`
// takes every `Prospect` property from `fixtures/stored-properties.txt` (which `StoredPropertyRatchetTests`
// holds to the schema), puts a different value in it alone, re-lands the same events, and asserts the stamp
// moved exactly when the land wrote some other field of the row. So a field added later is covered without
// anybody listing it, and a field the scout never writes is checked as one it never stamps for.
@MainActor
@Suite("A scout landing stamps ingestedAt only on a row it changed, or one a merge must read as last seen (#4331)")
struct IngestedAtStampTests {
    typealias Fixture = ScoutReLandWritesNothingTests

    // 15:00 and 16:00 Eastern, so a stamp derived from the day (`scoutNow`, Eastern midnight) or from the wall
    // clock cannot pass for one derived from the landing's `now`.
    static let t0 = ISO8601DateFormatter().date(from: "2026-10-01T19:00:00Z")!
    static let t1 = ISO8601DateFormatter().date(from: "2026-10-01T20:00:00Z")!

    static func context() throws -> (ModelContainer, ModelContext) {
        let container = try ModelContainer(for: AppSchema.schema,
                                           configurations: [ModelConfiguration(isStoredInMemoryOnly: true)])
        return (container, container.mainContext)
    }

    static let events: [ExtractedEvent] = [
        Fixture.event("Quiet Harbour Evening", "2026-11-05"),
        Fixture.event("Lantern Row Recital", "2026-11-06"),
        Fixture.event("Copper Bell Revue", "2026-11-07"),
    ]

    @discardableResult
    static func land(_ events: [ExtractedEvent], now: Date, into ctx: ModelContext,
                     landing: ScoutLandingStore? = nil, source: String = "src-a") -> ScoutService.Outcome {
        ScoutService.apply(events: events, clients: [Fixture.client], history: [], blocked: Fixture.blocked,
                           feed: Fixture.feed(source), today: Fixture.today, now: now, sourceIds: [source],
                           landing: landing, into: ctx)
    }

    static func row(_ title: String, in ctx: ModelContext) throws -> Prospect {
        try #require(try ctx.fetch(FetchDescriptor<Prospect>()).first { $0.scoutGroupName == title },
                     "no row for \(title)")
    }

    // Within the microseconds a landing of a few rows can add to its `now`.
    static func isStamp(_ date: Date, from now: Date) -> Bool {
        date >= now && date < now.addingTimeInterval(0.001)
    }

    // MARK: the stamp's clock

    // The decision's own test: a landing with an injected `now` of 15:00 Eastern stamps each row at 15:00
    // plus its apply ordinal, an insert as well as a change, and a row it did not change keeps its stamp.
    @Test func aChangedRowIsStampedAtTheLandingsNowPlusItsApplyOrdinal() throws {
        let (container, ctx) = try Self.context()
        defer { withExtendedLifetime(container) {} }
        Self.land(Self.events, now: Self.t0, into: ctx)
        try ctx.save()

        let rows = try ctx.fetch(FetchDescriptor<Prospect>())
        let stamps = Set(rows.map(\.ingestedAt))
        let expected = Set((0..<3).map { IngestedAtStamp.at(Self.t0, ordinal: $0) })
        #expect(stamps == expected, Comment(rawValue:
            "the three inserts were not stamped at now plus ordinals 0, 1 and 2: \(rows.map(\.ingestedAt))"))
        #expect(rows.allSatisfy { $0.firstSeenAt == $0.ingestedAt }, "an insert's first sighting is its stamp")

        let before = Dictionary(uniqueKeysWithValues: rows.map { ($0.naturalKey, $0.ingestedAt) })
        var moved = Self.events
        moved[1] = Fixture.event("Lantern Row Recital", "2026-11-06", location: "Brooklyn, NY")
        Self.land(moved, now: Self.t1, into: ctx)

        let changed = try Self.row("Lantern Row Recital", in: ctx)
        #expect(Self.isStamp(changed.ingestedAt, from: Self.t1), Comment(rawValue:
            "the changed row was stamped \(changed.ingestedAt), not from the landing's now \(Self.t1)"))
        for p in try ctx.fetch(FetchDescriptor<Prospect>()) where p !== changed {
            #expect(p.ingestedAt == before[p.naturalKey], Comment(rawValue:
                "\(p.groupName) did not change and was restamped \(p.ingestedAt)"))
        }
    }

    // Each of the three entry points that land shows hands `apply` its OWN now (the decision's "a real now
    // threaded into apply from ingest's now, runScout's now and the lead paste's"). The oracle corpus seeds
    // every row at its `now`; landed a day later, every row the landing stamped must carry that later instant,
    // and every other row its seed. A stamp from the wall clock or from Eastern midnight is neither.
    @Test(arguments: LandingOracleCorpus.Path.allCases)
    func everyEntryPointStampsFromItsOwnNow(path: LandingOracleCorpus.Path) async throws {
        let landedAt = LandingOracleCorpus.now.addingTimeInterval(86_400)
        let container = try await LandingOracleCorpus.land(path, landedAt: landedAt)
        let rows = try ModelContext(container).fetch(FetchDescriptor<Prospect>())
        let stray = rows.filter { $0.ingestedAt != LandingOracleCorpus.now && !Self.isStamp($0.ingestedAt, from: landedAt) }
        #expect(stray.isEmpty, Comment(rawValue: "\(path.rawValue) stamped rows from neither the seed nor its own now: "
            + stray.map { "\($0.groupName) \($0.ingestedAt)" }.joined(separator: "; ")))
        #expect(rows.contains { Self.isStamp($0.ingestedAt, from: landedAt) },
                "\(path.rawValue) stamped no row at all, so this cannot see where a stamp comes from")
    }

    // MARK: the change test, derived from the stored property list

    static func prospectFields() throws -> [String] {
        try StoredPropertyRatchetTests.recorded()
            .filter { $0.hasPrefix("Prospect.") }
            .map { String($0.dropFirst("Prospect.".count)) }
            .filter { $0 != "ingestedAt" }
            .sorted()
    }

    // A different value in one stored property, whatever its type. Nil when the type is one this does not
    // know, which the caller reports by name rather than skipping (L98).
    static func perturb(_ field: String, of p: Prospect, in ctx: ModelContext) -> Bool? {
        guard let path = Prospect.scopeFields.map(\.keyPath).first(where: { Fixture.fieldName($0) == field })
        else { return nil }
        let later = Date(timeIntervalSince1970: 1_800_000_000)
        switch path {
        case let k as ReferenceWritableKeyPath<Prospect, String>: p[keyPath: k] += " changed"
        case let k as ReferenceWritableKeyPath<Prospect, String?>: p[keyPath: k] = (p[keyPath: k] ?? "") + " changed"
        case let k as ReferenceWritableKeyPath<Prospect, Bool>: p[keyPath: k].toggle()
        case let k as ReferenceWritableKeyPath<Prospect, Bool?>: p[keyPath: k] = !(p[keyPath: k] ?? false)
        case let k as ReferenceWritableKeyPath<Prospect, Int>: p[keyPath: k] += 1
        case let k as ReferenceWritableKeyPath<Prospect, Int?>: p[keyPath: k] = (p[keyPath: k] ?? 0) + 1
        case let k as ReferenceWritableKeyPath<Prospect, Date>: p[keyPath: k] = p[keyPath: k].addingTimeInterval(1_000)
        case let k as ReferenceWritableKeyPath<Prospect, Date?>:
            p[keyPath: k] = (p[keyPath: k] ?? later).addingTimeInterval(1_000)
        case let k as ReferenceWritableKeyPath<Prospect, [String]>: p[keyPath: k] += ["changed"]
        case let k as ReferenceWritableKeyPath<Prospect, [Recipient]>:
            let added = Recipient(id: "added", email: "someone@example.test", provenance: .manual)
            ctx.insert(added)
            p[keyPath: k] += [added]
        default: return nil
        }
        return true
    }

    // For each stored property: a fresh landing, that property alone given a different value and saved, the
    // same events landed again, and the stamp must have moved exactly when the land wrote any OTHER field of
    // the row. The two counts at the end are the control: a rule that stamped every row, or none, fails them.
    @Test func aReLandStampsARowExactlyWhenItChangedAnyOtherField() throws {
        let fields = try Self.prospectFields()
        #expect(fields.count > 100, "only \(fields.count) Prospect properties were read from the list")
        var stamped: [String] = []
        var unstamped: [String] = []
        for field in fields {
            let (container, ctx) = try Self.context()
            Self.land(Self.events, now: Self.t0, into: ctx)
            try ctx.save()
            let target = try Self.row("Quiet Harbour Evening", in: ctx)
            guard Self.perturb(field, of: target, in: ctx) != nil else {
                Issue.record(Comment(rawValue: "Prospect.\(field) has a type this test cannot change, so it is unchecked"))
                continue
            }
            try ctx.save()

            let fires = Fixture.Fires()
            var seen = Set<ObjectIdentifier>()
            Fixture.arm(target, label: "target", into: fires, seen: &seen)
            let before = target.ingestedAt
            Self.land(Self.events, now: Self.t1, into: ctx)

            let wrote = (fires.byRow["target"] ?? []).subtracting(["ingestedAt"])
            let moved = target.ingestedAt != before
            #expect(moved == !wrote.isEmpty, Comment(rawValue:
                "Prospect.\(field) changed alone: the re-land wrote \(wrote.sorted()) and the stamp "
                + (moved ? "moved" : "did not move")))
            if moved {
                #expect(Self.isStamp(target.ingestedAt, from: Self.t1), Comment(rawValue:
                    "Prospect.\(field): stamped \(target.ingestedAt), not from the landing's now"))
                stamped.append(field)
            } else {
                unstamped.append(field)
            }
            withExtendedLifetime(container) {}
        }
        print("ingestedAt change test: \(stamped.count) fields the re-land wrote back and stamped for, "
              + "\(unstamped.count) it left alone and did not stamp for")
        #expect(stamped.count > 10, "only \(stamped.count) fields drew a stamp: \(stamped)")
        #expect(unstamped.count > 10, "only \(unstamped.count) fields drew none: \(unstamped)")
    }

    // And the case with nothing changed at all: no row is written, the stamp included.
    @Test func aReLandThatChangesNothingStampsNothing() throws {
        let (container, ctx) = try Self.context()
        defer { withExtendedLifetime(container) {} }
        Self.land(Self.events, now: Self.t0, into: ctx)
        try ctx.save()
        let before = try ctx.fetch(FetchDescriptor<Prospect>()).map(\.ingestedAt).sorted()
        Self.land(Self.events, now: Self.t1, into: ctx)
        let after = try ctx.fetch(FetchDescriptor<Prospect>()).map(\.ingestedAt).sorted()
        #expect(after == before, Comment(rawValue: "an unchanged re-land restamped: \(before) became \(after)"))
    }

    // MARK: the rows a merge reader still reads as last seen

    // A stored row that is NOT in the feed and shares one merge candidate key with the listed row. The listed
    // row is unchanged by the re-land, so only its twin can earn it a stamp.
    static func twin(_ kind: String, of p: Prospect, in ctx: ModelContext) {
        let t = Prospect(naturalKey: "twin \(kind)", groupName: "Unrelated Matinee \(kind)", discipline: p.discipline,
                         venue: "Somewhere Else Hall", performanceDate: "2026-12-30",
                         sourceListingURL: "https://elsewhere.example/\(kind)", priorRelationship: "none",
                         production: p.production, profile: p.profile, coverage: p.coverage, fitScore: 1,
                         tier: "low", fitReason: "r", matchedClientName: nil, possibleMatchSource: nil,
                         possibleMatchName: nil, ingestedAt: Date(timeIntervalSince1970: 1_000))
        switch kind {
        case "series": t.seriesId = p.seriesId
        case "token": t.sourceListingURL = p.sourceListingURL
        case "anchor":
            t.scoutGroupName = p.scoutGroupName
            t.performanceDate = p.performanceDate
            t.scoutVenue = p.scoutVenue
        case "display":
            t.groupName = p.groupName
            t.performanceDate = p.performanceDate
            t.venue = p.venue
            t.scoutGroupName = "Its Own Scout Name"
        case "night":
            t.groupName = p.groupName + " Encore"
            t.performanceDate = p.performanceDate
        default: Issue.record(Comment(rawValue: "no twin of kind \(kind)"))
        }
        ctx.insert(t)
    }

    // One per key kind `MergeCandidateIndex` derives from the readers, so a kind dropped from it goes red.
    @Test(arguments: ["series", "token", "anchor", "display", "night"])
    func aListedRowWithATwinIsRestampedOnEveryTouch(kind: String) throws {
        let (container, ctx) = try Self.context()
        defer { withExtendedLifetime(container) {} }
        var listed = Fixture.event("Quiet Harbour Evening", "2026-11-05",
                                   url: "https://harbour.venuetix.com/showdetails/qh-4417/2026-11-05",
                                   series: "series-qh")
        // The display key alone separates two rows only where there is no night: two DATED rows sharing it
        // share a night and a title too, which the night test already answers, so that twin is UNDATED.
        if kind == "display" { listed.performanceDate = nil }
        let alone = Fixture.event("Lantern Row Recital", "2026-11-06")
        Self.land([listed, alone], now: Self.t0, into: ctx)
        let row = try Self.row("Quiet Harbour Evening", in: ctx)
        Self.twin(kind, of: row, in: ctx)
        try ctx.save()
        let loneBefore = try Self.row("Lantern Row Recital", in: ctx).ingestedAt

        Self.land([listed, alone], now: Self.t1, into: ctx)

        #expect(Self.isStamp(row.ingestedAt, from: Self.t1), Comment(rawValue:
            "a listed row sharing a \(kind) key with another row was not restamped: \(row.ingestedAt)"))
        #expect(try Self.row("Lantern Row Recital", in: ctx).ingestedAt == loneBefore,
                "the row with no twin was restamped")
    }

    // A twin made LATER in the same landing, by another source: the row source A left unstamped is stamped
    // at the end of source B's apply, with the stamp it would have taken when A touched it, so it still reads
    // older than the twin B brought, as it would have before.
    @Test func aTwinALaterSourceBringsStampsTheRowAnEarlierSourceLeftAlone() throws {
        let (container, ctx) = try Self.context()
        defer { withExtendedLifetime(container) {} }
        Self.land(Self.events, now: Self.t0, into: ctx)
        try ctx.save()
        let row = try Self.row("Quiet Harbour Evening", in: ctx)
        let before = row.ingestedAt

        let landing = ScoutLandingStore(context: ctx)
        Self.land(Self.events, now: Self.t1, into: ctx, landing: landing, source: "src-a")
        #expect(row.ingestedAt == before, "the row had no twin yet and was stamped anyway")
        Self.land([Fixture.event("Quiet Harbour Evening Encore", "2026-11-05", venue: Fixture.otherVenue)],
                  now: Self.t1, into: ctx, landing: landing, source: "src-b")

        let twin = try Self.row("Quiet Harbour Evening Encore", in: ctx)
        #expect(Self.isStamp(row.ingestedAt, from: Self.t1), Comment(rawValue:
            "a twin source B brought did not earn the row source A touched a stamp: \(row.ingestedAt)"))
        #expect(row.ingestedAt < twin.ingestedAt, Comment(rawValue:
            "the row source A touched first reads newer than the twin source B brought after it"))
    }

    // The working set answers the twin question incrementally; the reference policy asks it whole over a
    // fresh read every time. Both must leave every row with the same stamp (#4275's equality pattern).
    @Test func theWorkingSetStampsTheSameRowsAsAFreshReadPerQuestion() throws {
        func landed(_ policy: ScoutLandingStore.Policy) throws -> [String] {
            let (container, ctx) = try Self.context()
            defer { withExtendedLifetime(container) {} }
            Self.land(Self.events, now: Self.t0, into: ctx)
            for kind in ["series", "night"] {
                Self.twin(kind, of: try Self.row("Lantern Row Recital", in: ctx), in: ctx)
            }
            try ctx.save()
            let landing = ScoutLandingStore(context: ctx, policy: policy)
            Self.land(Self.events, now: Self.t1, into: ctx, landing: landing, source: "src-a")
            Self.land([Fixture.event("Copper Bell Revue Encore", "2026-11-07", venue: Fixture.otherVenue)],
                      now: Self.t1, into: ctx, landing: landing, source: "src-b")
            return try ctx.fetch(FetchDescriptor<Prospect>())
                .map { "\($0.naturalKey) \($0.ingestedAt.timeIntervalSinceReferenceDate)" }.sorted()
        }
        let current = try landed(.once)
        let reference = try landed(.everyRead)
        #expect(current == reference, Comment(rawValue:
            "the working set stamped differently from a fresh read:\n" + current.joined(separator: "\n")
            + "\nfresh:\n" + reference.joined(separator: "\n")))
    }
}
