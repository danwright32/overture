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

    static func pass(_ rows: [Prospect], gmailConnected: Bool = false,
                     focusedStage: StageFocus = .scout) -> QueueView.RenderData {
        var inputs = QueueRenderPass.Inputs(allProspects: QueueRenderPass.Corpus(rows), inquiries: [],
                                            orgAnswers: [], context: .at(asOf, now: now),
                                            focusedStage: focusedStage)
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
        // A store identifier is a VALUE whose equality is the row it names, which two passes over one store
        // share: the opposite of the object identity this guard exists to keep out. Its storage reflects as
        // a class, so without this a row carrying its show's identifier (#4357 slice I2) read as holding a
        // model, and `rows` and `visibleRows` were flagged for comparing by value, which is right for them.
        if value is PersistentIdentifier { return false }
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

    /// A pass whose model-carrying members are POPULATED: one show still in Scout and one already pitched, so
    /// the Reached out list and its entries hold real models. Over an empty pass every such collection is
    /// empty, and a walk of its values can find no model inside it whatever it is compared by (L101, L159).
    /// The container comes back with the pass because a context does not keep its container alive.
    static func populatedPass() throws -> (data: QueueView.RenderData, container: ModelContainer) {
        let container = try TestModelContainer.inMemory(AppSchema.models)
        let ctx = ModelContext(container)
        func show(_ key: String) -> Prospect {
            let p = Prospect(naturalKey: key, groupName: "Ensemble \(key)", discipline: "music",
                             venue: "Quillon Room", performanceDate: "2026-10-20", sourceListingURL: nil,
                             priorRelationship: "none", production: "self", profile: "strong",
                             coverage: "likely_uncovered", fitScore: 7, tier: "mid", fitReason: "r",
                             matchedClientName: nil, possibleMatchSource: nil, possibleMatchName: nil, status: .new)
            ctx.insert(p)
            return p
        }
        _ = show("populated scout")
        let pitched = show("populated pitched")
        pitched.setRecipients([Recipient(id: "pitched@example.invalid", email: "pitched@example.invalid",
                                         provenance: .act)])
        DebugStaging.stageAsSent(pitched, now: now.addingTimeInterval(-20 * 86_400))
        try ctx.save()
        // Focused on Reached out, the one stage the pass builds the Reached out list for; every other focus
        // publishes it empty.
        return (pass(try ctx.fetch(FetchDescriptor<Prospect>()), focusedStage: .reachedOut), container)
    }

    @Test func noMemberHoldingAnObjectIsComparedByValueEquality() throws {
        let populated = try Self.populatedPass()
        let members = Self.members(populated.data)
        let byName = Dictionary(uniqueKeysWithValues: RenderDataComparison.fields.map { ($0.name, $0.how) })
        let objectMembers = members.filter { Self.holdsAnObject($0.value) }.map(\.label)
        // The premise: RenderData still holds the card store (a class, whose sources are the models until the
        // engine builds the pass, #4358). A walk that did not find it measured less than it claims.
        // `queueScope` and `reachedOut` hold identities since #4357 step 5, and the Reached out list since #4358
        // slice E4a (#4371), which `OutputsHoldNoModelTests` holds them to; the list is populated here, so its
        // absence from the walk's findings is a finding rather than an empty list.
        #expect(objectMembers.contains("cards"), Comment(rawValue: "the walk did not see the card store holding a "
            + "class, so the fixture or the walk is too thin to check it"))
        #expect(!populated.data.reachedOutList.entries.isEmpty && !objectMembers.contains("reachedOutList"),
                "the Reached out list is empty, or still holds a model")
        withExtendedLifetime(populated.container) {}
        let wrong = objectMembers.filter { byName[$0] != .projection }
        #expect(wrong.isEmpty, Comment(rawValue: "these members hold a class or a model and are compared "
            + "directly, which compares object identity or a description, never what they hold: "
            + wrong.joined(separator: ", ")))
    }

    // The card store is compared through `contents` and its preamble, both written by hand, so both are held
    // to the real types by Mirror the way `fields` is held to RenderData (L96, L41).
    @Test func everyPreambleMemberIsCompared() {
        let labels = Mirror(reflecting: Self.pass([]).cards.preamble).children.compactMap(\.label)
        let named = RenderDataComparison.preambleFields.map(\.name)
        #expect(labels.count >= 6, "the walk of the card preamble found too few members to have checked anything")
        #expect(Set(named).count == named.count, "the preamble comparison names a member twice")
        let missing = Set(labels).subtracting(named).sorted()
        let extra = Set(named).subtracting(labels).sorted()
        #expect(missing.isEmpty, Comment(rawValue: "card preamble members never compared, so two passes differing "
            + "only there would read as equal: " + missing.joined(separator: ", ")))
        #expect(extra.isEmpty, Comment(rawValue: "the preamble comparison names members the preamble does not "
            + "have: " + extra.joined(separator: ", ")))
    }

    @Test func everyCardStoreMemberIsAccountedFor() {
        let store = Self.pass([]).cards
        let labels = Mirror(reflecting: store).children.compactMap(\.label)
        let accounted = RenderDataComparison.cardStoreMembers
        #expect(labels.count >= 7, "the walk of the card store found too few members to have checked anything")
        let missing = Set(labels).subtracting(accounted.keys).sorted()
        let extra = Set(accounted.keys).subtracting(labels).sorted()
        #expect(missing.isEmpty, Comment(rawValue: "card store members neither compared nor left out with a "
            + "reason: " + missing.joined(separator: ", ")))
        #expect(extra.isEmpty, Comment(rawValue: "accounted card store members the store does not have: "
            + extra.joined(separator: ", ")))
        // Every member said to be compared through `contents` really is a member of it, and `contents` holds
        // nothing that no store member is said to reach.
        let contents = Set(Mirror(reflecting: store.contents).children.compactMap(\.label))
        // A member may reach several (`sources` holds both the shows and their contacts), comma separated.
        let targets = Set(accounted.values.filter { $0.hasPrefix("contents.") }
            .flatMap { $0.components(separatedBy: ", ") }.map { String($0.dropFirst(9)) })
        #expect(targets == contents, Comment(rawValue: "contents holds " + contents.sorted().joined(separator: ", ")
            + " but the store's members are said to reach " + targets.sorted().joined(separator: ", ")))
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
    }
}

// The card store is compared through its preamble's tables, and `TableReader`'s equality is written by hand
// beside its private tables, so it is held here table by table: a reader differing in ONE table is unequal,
// and the read log never makes two readers over the same tables differ.
@Suite("Two table readers are equal exactly when every table they hold is (#4357)")
struct TableReaderEqualityTests {

    private static func reader(linked: [String: [EngagementLink.Member]] = [:],
                               inherited: [String: OrgAnswerLedger.Inherited] = [:],
                               rowCounts: [String: Int] = [:], contradicted: Set<String> = [],
                               sameShowGroups: [String: [String]] = [:], titles: [String: String] = [:],
                               collapsedFronts: [String: [String]] = [:], collapsedHidden: Set<String> = [],
                               laterLookalikes: [String: [String]] = [:], nights: [String: String] = [:])
        -> TableReader {
        TableReader(linked: linked, inherited: inherited, venueBrands: .none, rowCounts: rowCounts,
                    contradicted: contradicted, sameShowGroups: sameShowGroups, titles: titles,
                    collapsedFronts: collapsedFronts, collapsedHidden: collapsedHidden,
                    laterLookalikes: laterLookalikes, nights: nights)
    }

    @Test func aReaderDifferingInAnyOneTableIsUnequal() {
        let base = Self.reader()
        #expect(base == Self.reader(), "two readers over the same empty tables differ")
        // Every table that can be set from outside is moved alone. `venueBrands` has no public builder (it is a
        // judgement object built by its own term), so its clause is held by the source check below instead.
        let inherited = OrgAnswerLedger.Inherited(result: .emailFound, probedAt: Date(timeIntervalSince1970: 0),
                                                  organisation: "o", emails: [])
        let variants: [(String, TableReader)] = [
            ("linked", Self.reader(linked: ["a": [EngagementLink.Member(venue: "v", date: "2026-10-01")]])),
            ("inherited", Self.reader(inherited: ["a": inherited])),
            ("visible", Self.reader().answeringOnly([])),
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

    // The equality is written by hand, so its clauses are held to the reader's REAL stored members, derived by
    // Mirror (L96): every stored member but the read log must be compared in `==`, as `lhs.<member> ==
    // rhs.<member>`. A table added later, or a clause dropped, fails here by name.
    @Test func theEqualityComparesEveryStoredMemberButTheLog() {
        let labels = Mirror(reflecting: Self.reader()).children.compactMap(\.label).filter { $0 != "log" }
        #expect(labels.count >= 12, "the walk of TableReader found too few members to have checked anything")
        let source = SourceGuardHelper.source("Overture/Domain/TableReader.swift")
        let body = source.components(separatedBy: "extension TableReader: Equatable").last ?? ""
        #expect(!body.isEmpty && body.count < source.count, "the equality's source was not found")
        let missing = labels.filter { !body.contains("lhs.\($0) == rhs.\($0)") }
        #expect(missing.isEmpty, Comment(rawValue: "TableReader's == never compares these stored members, so two "
            + "readers differing only there compare equal: " + missing.joined(separator: ", ")))
    }

    @Test func readingAReaderDoesNotChangeWhatItEquals() {
        let log = TableReader.Log()
        let read = Self.reader(titles: ["a": "b"]).recording(into: log)
        _ = read.title("a")
        #expect(!log.reads.isEmpty, "the read was not recorded, so this compared nothing")
        #expect(read == Self.reader(titles: ["a": "b"]))
    }
}
