import Testing
import Foundation
import SwiftData

// #4357 slice I1 (plan v7 Phase 3, step 7): the comparator's two guards and its behaviour.
//
// The comparator is only worth what it covers. Its list of members is written by hand (each member needs its
// own way to compare), so the first guard derives RenderData's real members by Mirror and fails on any member
// the comparator does not name, or names but RenderData no longer has (L96, L41). The second fails when a
// member holding a class or a model is compared any way but through a value projection: a class compared by
// its description agrees with itself whatever it holds, and a model compares by object identity, which two
// passes over one store never share (the plan's "class compared by description" guard).
@Suite("RenderDataComparison names every RenderData member, and never compares one by description (#4357)")
@MainActor
struct RenderDataComparisonCoversEveryFieldTests {

    static let asOf = "2026-10-01"
    static let now = Date(timeIntervalSince1970: 1_790_000_000)

    static func pass(_ rows: [Prospect], gmailConnected: Bool = false) -> QueueView.RenderData {
        var inputs = QueueRenderPass.Inputs(allProspects: QueueRenderPass.Corpus(rows), inquiries: [],
                                            orgAnswers: [], context: .at(asOf, now: now), focusedStage: .scout)
        inputs.gmailConnected = gmailConnected
        return QueueRenderPass.make(inputs)
    }

    static func members(_ data: QueueView.RenderData) -> [(label: String, value: Any)] {
        Mirror(reflecting: data).children.compactMap { child in child.label.map { ($0, child.value) } }
    }

    @Test func everyMemberIsComparedAndNothingElseIs() {
        let labels = Self.members(Self.pass([])).map(\.label)
        let named = RenderDataComparison.fields.map(\.name)
        // Cannot pass vacuously: a walk that found nothing has checked nothing (L98).
        #expect(labels.count > 25, "the walk of RenderData found too few members to have checked anything")
        #expect(Set(named).count == named.count, "the comparator names a member twice")
        let missing = Set(labels).subtracting(named).sorted()
        let extra = Set(named).subtracting(labels).sorted()
        #expect(missing.isEmpty, Comment(rawValue: "RenderData members the comparator never compares, so two "
            + "passes that differ only there would read as equal: " + missing.joined(separator: ", ")))
        #expect(extra.isEmpty, Comment(rawValue: "the comparator names members RenderData does not have: "
            + extra.joined(separator: ", ")))
    }

    /// A member holds a class or a model when its value is a class instance, or its type names one of the
    /// model types or the card store. Read from the live value and its type, not from a list of members.
    static func holdsAnObject(_ value: Any, depth: Int = 0) -> Bool {
        let mirror = Mirror(reflecting: value)
        if mirror.displayStyle == .class { return true }
        // And anything inside it, a few levels down, for a member whose type name says nothing (an enum
        // carrying a model in a payload, a struct of such enums).
        if depth < 6, mirror.children.prefix(8).contains(where: { holdsAnObject($0.value, depth: depth + 1) }) {
            return true
        }
        // Whole type names, so a value type merely named after a model (`InquiryRow`) is not taken for one.
        let type = String(reflecting: Swift.type(of: value))
        return type.range(of: #"\b(Prospect|Recipient|Inquiry|CardStore)\b"#, options: .regularExpression) != nil
    }

    @Test func noMemberHoldingAnObjectIsComparedByValueEquality() {
        let members = Self.members(Self.pass([]))
        let byName = Dictionary(uniqueKeysWithValues: RenderDataComparison.fields.map { ($0.name, $0.how) })
        let objectMembers = members.filter { Self.holdsAnObject($0.value) }.map(\.label)
        // The premise: today RenderData holds the card store and several model collections (until plan step 5
        // reshapes it), so a walk that found none measured nothing.
        #expect(objectMembers.contains("cards") && objectMembers.contains("queueScope"),
                "the walk found no member holding an object, so this checked nothing")
        let wrong = objectMembers.filter { byName[$0] != .projection }
        #expect(wrong.isEmpty, Comment(rawValue: "these members hold a class or a model and are compared "
            + "directly, which compares object identity or a description, never what they hold: "
            + wrong.joined(separator: ", ")))
    }

    @Test func theComparatorNeverComparesByDescription() {
        let source = SourceGuardHelper.source("OvertureTests/RenderDataComparison.swift")
        #expect(!source.isEmpty, "the comparator's source was not read")
        let code = SwiftSource.scannableLines(in: source).map(\.code).joined(separator: "\n")
        for spelling in ["describing:", "reflecting:", ".description", "debugDescription"] {
            #expect(!code.contains(spelling), Comment(rawValue: "the comparator compares something by its "
                + "description (\(spelling)), which agrees whatever the value holds"))
        }
    }
}

@Suite("RenderDataComparison finds what differs between two passes, by name (#4357)")
@MainActor
final class RenderDataComparisonTests {

    // The container is held by the suite for the test's whole life: a context does not keep its container
    // alive, and a container gone under a live context is SwiftData's own trap.
    private var held: [ModelContainer] = []

    private func context() throws -> ModelContext {
        let container = try TestModelContainer.inMemory(AppSchema.models)
        held.append(container)
        return ModelContext(container)
    }

    private func show(_ ctx: ModelContext, _ key: String, opens: String) -> Prospect {
        let p = Prospect(naturalKey: key, groupName: "Ensemble \(key)", discipline: "music", venue: "Quillon Room",
                         performanceDate: opens, sourceListingURL: nil, priorRelationship: "none",
                         production: "self", profile: "strong", coverage: "likely_uncovered", fitScore: 7,
                         tier: "mid", fitReason: "r", matchedClientName: nil, possibleMatchSource: nil,
                         possibleMatchName: nil, status: .new)
        ctx.insert(p)
        return p
    }

    @Test func twoPassesOverOneStoreAgreeOnEveryMember() throws {
        let ctx = try context()
        _ = show(ctx, "comparison a", opens: "2026-10-20")
        _ = show(ctx, "comparison b", opens: "2026-10-22")
        try ctx.save()
        let rows = try ctx.fetch(FetchDescriptor<Prospect>())
        let first = RenderDataComparisonCoversEveryFieldTests.pass(rows)
        // Positive control (L159): the pass drew rows, so agreement is about something.
        #expect(first.rows.count == 2)
        let again = RenderDataComparisonCoversEveryFieldTests.pass(try ctx.fetch(FetchDescriptor<Prospect>()))
        #expect(RenderDataComparison.differingFields(first, again).isEmpty,
                Comment(rawValue: RenderDataComparison.differingFields(first, again).joined(separator: ", ")))
    }

    @Test func aChangedInputIsNamedByTheMembersItMoved() throws {
        let ctx = try context()
        let a = show(ctx, "comparison a", opens: "2026-10-20")
        _ = show(ctx, "comparison b", opens: "2026-10-22")
        try ctx.save()
        let rows = try ctx.fetch(FetchDescriptor<Prospect>())
        let before = RenderDataComparisonCoversEveryFieldTests.pass(rows)

        let gmail = RenderDataComparisonCoversEveryFieldTests.pass(rows, gmailConnected: true)
        let named = RenderDataComparison.differingFields(before, gmail)
        #expect(named.contains("gmailConnected"), Comment(rawValue: named.joined(separator: ", ")))
        #expect(!named.contains("rows"), "a connection flip moved the rows, which it cannot")

        a.status = .dismissed
        try ctx.save()
        let dismissed = RenderDataComparisonCoversEveryFieldTests.pass(try ctx.fetch(FetchDescriptor<Prospect>()))
        let moved = RenderDataComparison.differingFields(before, dismissed)
        // A dismissed show leaves the scope, the rows, the Scout placement and the triage count, so each of the
        // four, compared four different ways, has to see it.
        for member in ["rows", "queueScope", "placement", "agentInputs"] {
            #expect(moved.contains(member), Comment(rawValue: "a dismissal was not seen in \(member): "
                + moved.joined(separator: ", ")))
        }
        // By name only, never a value: no title or key reaches the answer (L222).
        #expect(!moved.contains { $0.contains("comparison") || $0.contains("Ensemble") })
    }
}

// The card store is compared through its preamble's tables, and `TableReader`'s equality is written by hand
// beside its private tables, so it is held here table by table: a reader differing in ONE table is unequal,
// and the read log never makes two readers over the same tables differ.
@Suite("Two table readers are equal exactly when every table they hold is (#4357)")
struct TableReaderEqualityTests {

    private static func reader(rowCounts: [String: Int] = [:], contradicted: Set<String> = [],
                               sameShowGroups: [String: [String]] = [:], titles: [String: String] = [:],
                               collapsedFronts: [String: [String]] = [:], collapsedHidden: Set<String> = [],
                               laterLookalikes: [String: [String]] = [:], nights: [String: String] = [:])
        -> TableReader {
        TableReader(linked: [:], inherited: [:], venueBrands: .none, rowCounts: rowCounts,
                    contradicted: contradicted, sameShowGroups: sameShowGroups, titles: titles,
                    collapsedFronts: collapsedFronts, collapsedHidden: collapsedHidden,
                    laterLookalikes: laterLookalikes, nights: nights)
    }

    @Test func aReaderDifferingInAnyOneTableIsUnequal() {
        let base = Self.reader()
        #expect(base == Self.reader(), "two readers over the same empty tables differ")
        // `linked`, `inherited` and `venueBrands` hold domain values built by their own terms; the other eight
        // are plain collections, so each is moved alone here.
        let variants: [(String, TableReader)] = [
            ("rowCounts", Self.reader(rowCounts: ["a": 1])),
            ("contradicted", Self.reader(contradicted: ["a"])),
            ("sameShowGroups", Self.reader(sameShowGroups: ["a": ["b"]])),
            ("titles", Self.reader(titles: ["a": "b"])),
            ("collapsedFronts", Self.reader(collapsedFronts: ["a": ["b"]])),
            ("collapsedHidden", Self.reader(collapsedHidden: ["a"])),
            ("laterLookalikes", Self.reader(laterLookalikes: ["a": ["b"]])),
            ("nights", Self.reader(nights: ["a": "2026-10-01"])),
        ]
        for (table, variant) in variants {
            #expect(variant != base, Comment(rawValue: "a reader differing only in \(table) compared equal"))
        }
    }

    @Test func readingAReaderDoesNotChangeWhatItEquals() {
        let log = TableReader.Log()
        let read = Self.reader(titles: ["a": "b"]).recording(into: log)
        _ = read.title("a")
        #expect(!log.reads.isEmpty, "the read was not recorded, so this compared nothing")
        #expect(read == Self.reader(titles: ["a": "b"]))
    }
}
