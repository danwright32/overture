import Foundation
import SwiftData
import Testing

// #4356 (plan v7 Phase 2): `RowFacts.extract` reads every carried field from the live model into its own
// place, and runs off the main thread.
//
// Each field is checked by NAME against what the model holds under that name, where every field holds a
// value no other field holds (`FactsFixture`), never against a second extraction: two runs of one copy agree
// with each other whatever that copy gets wrong (L70). Run over all eight variants, so a swapped pair of
// `Bool` fields differs in at least one of them.
@Suite("RowFacts copies every field into its own place (#4356)")
@MainActor
struct RowFactsExtractionTests {

    /// The labels of `value`'s stored properties whose printed values differ from what `expected` holds under
    /// the same name. A label `expected` does not know is skipped: it is not a stored property of the model.
    static func differingFields(_ value: Any, from expected: [String: String]) -> [String] {
        Mirror(reflecting: value).children.compactMap { child -> String? in
            guard let label = child.label, let want = expected[label] else { return nil }
            return String(describing: child.value) == want ? nil : label
        }.sorted()
    }

    @Test(arguments: 0..<8)
    func extractReadsEveryFieldFromTheLiveModel(variant: Int) throws {
        let container = try TestModelContainer.inMemory([Prospect.self, Recipient.self])
        let (show, contacts, unset) = try FactsFixture.liveRow(variant: variant, in: container.mainContext)
        #expect(Set(unset).isSubset(of: ["recipients", "prospect"]), Comment(rawValue: "the fixture could "
            + "not set these, so a wrong copy of them would go unseen: " + unset.joined(separator: ", ")))

        let facts = RowFacts.extract(show)
        let expected = FactsFixture.expected(show)
        let wrong = Self.differingFields(facts, from: expected)
        #expect(wrong.isEmpty, Comment(rawValue: "variant \(variant): extract read these fields wrongly: "
            + wrong.joined(separator: ", ")))
        // The positive control: a comparison that matched no labels would pass the line above (L98).
        let compared = Mirror(reflecting: facts).children.filter { expected[$0.label ?? ""] != nil }.count
        #expect(compared > 120, "the comparison matched too few fields to have checked the value")

        // Both contacts carry the same `id` (the fixture writes each field's own name), so the canonical
        // order falls to the store's own identifier.
        let ordered = contacts.sorted { $0.persistentModelID < $1.persistentModelID }
        #expect(facts.factContacts.map(\.persistentModelID) == ordered.map(\.persistentModelID),
                "the contacts came back out of their canonical order")
        for (record, contact) in zip(facts.factContacts, ordered) {
            let wrongContact = Self.differingFields(record, from: FactsFixture.expected(contact))
            #expect(wrongContact.isEmpty, Comment(rawValue: "variant \(variant): a contact's fields were read "
                + "wrongly: " + wrongContact.joined(separator: ", ")))
        }
    }

    @Test func aValueCopiedFromAValueIsTheSameValue() throws {
        let container = try TestModelContainer.inMemory([Prospect.self, Recipient.self])
        let (show, _, _) = try FactsFixture.liveRow(variant: 3, in: container.mainContext)
        let facts = RowFacts.extract(show)
        #expect(RowFacts(copying: facts) == facts)
        // And an edit to the model is an inequality, which is what the engine's equality gate relies on.
        show.venue = "Another Room"
        #expect(RowFacts.extract(show) != facts, "a changed venue extracted to an equal value")
    }

    @Test func extractRunsOffTheMainActorFromItsOwnContext() async throws {
        let container = try TestModelContainer.inMemory([Prospect.self, Recipient.self])
        let (show, _, _) = try FactsFixture.liveRow(variant: 5, in: container.mainContext)
        let onMain = RowFacts.extract(show)

        let offMain = try await Task.detached {
            let context = ModelContext(container)
            let rows = try context.fetch(FetchDescriptor<Prospect>())
            return (rows.map(RowFacts.extract), pthread_main_np() != 0)
        }.value

        #expect(offMain.1 == false, "the detached extraction ran on the main thread, so it proved nothing")
        #expect(offMain.0 == [onMain], "a background context extracted a different value from the same row")
    }
}

// #4356 (plan v7 Phase 2): each pre-folded key in `RowKeys` is folded from the field its TERM folds, which
// is the mistake a retained key can make and a term's live answer cannot.
//
// The folds themselves are each term's own and have their own tests. What a key can get wrong is the
// INPUT: ShowLink buckets by the scout-anchored title and venue, never the display ones Dan can rename
// (#1274, #1846), while EngagementLink buckets by the display title. So the fixture makes every such pair
// disagree, and each key is asserted against the side its term reads AND away from the side it does not,
// so a key reading the wrong field cannot pass by both happening to fold the same.
@Suite("Each pre-folded key reads the field its term folds (#4356)")
@MainActor
struct RowKeysMatchTheTermsTests {

    static let listing = "https://thegreenroom42.venuetix.com/showdetails/seasonToken/5512"

    static func show(in context: ModelContext, venue: String?) throws -> Prospect {
        let show = Prospect(naturalKey: "k", groupName: "Renamed By Dan", discipline: "theatre", venue: venue,
                            performanceDate: "2026-11-01", sourceListingURL: listing,
                            priorRelationship: "none", production: "self", profile: "strong",
                            coverage: "likely_uncovered", fitScore: 1, tier: "low", fitReason: "r",
                            matchedClientName: nil, possibleMatchSource: nil, possibleMatchName: nil,
                            runNights: ["2026-11-01", "2026-11-02"])
        show.scoutGroupName = "The Scouted Title"
        show.scoutVenue = "Scouted Room"
        show.presenter = "The Acme Players (NYC)"
        show.droppedRunNights = [DroppedNight(night: "2026-11-03", reason: .dateConflict,
                                              at: Date(timeIntervalSince1970: 1_800_000_000)).stored]
        context.insert(show)
        try context.save()
        return show
    }

    @Test func eachKeyFoldsTheFieldItsTermReads() throws {
        let container = try TestModelContainer.inMemory([Prospect.self, Recipient.self])
        let show = try Self.show(in: container.mainContext, venue: "Display Room (Downstairs)")
        let keys = RowFacts.extract(show).foldedKeys

        // ShowLink: the SCOUT-anchored title and venue.
        #expect(keys.showLinkTitle == ShowLink.foldedTitle("The Scouted Title"))
        #expect(keys.showLinkTitle != ShowLink.foldedTitle("Renamed By Dan"))
        #expect(keys.showLinkVenue == ShowLink.foldedVenue("Scouted Room"))
        #expect(keys.showLinkVenue != ShowLink.foldedVenue("Display Room (Downstairs)"))
        // Its nights: the kept ones and the dropped one, which still counts toward the night set.
        #expect(keys.showLinkNights == ["2026-11-01", "2026-11-02", "2026-11-03"])
        #expect(keys.droppedNights == ["2026-11-03"])
        #expect(keys.productionTokens == ["seasonToken"])

        // EngagementLink: the DISPLAY title.
        #expect(keys.engagementTitle == GroupNameMatch.normalize("Renamed By Dan"))
        #expect(keys.engagementTitle != GroupNameMatch.normalize("The Scouted Title"))

        // The producer gate and the ledger: the display presenter and venue.
        #expect(keys.presenterKey == ProducerGate.key("The Acme Players (NYC)"))
        #expect(keys.presenterKey != nil)
        #expect(keys.venueKey == ProducerGate.key("Display Room (Downstairs)"))
        #expect(keys.venueKey != ProducerGate.key("Scouted Room"))
        #expect(keys.orgKey == OrgKey.stored(for: "The Acme Players (NYC)"))
        #expect(keys.orgKey != nil)

        // Contradictions and feed breaks: the display venue, each through its own fold.
        #expect(keys.contradictionRoom == ContradictedCancellation.canonicalVenue("Display Room (Downstairs)"))
        #expect(keys.feedBreakRoom == FeedBreakEvent.canonicalVenue("Display Room (Downstairs)"))
        #expect(keys.contradictionRoom != ContradictedCancellation.canonicalVenue("Scouted Room"))
    }

    // A venueless row shares the one room `""` with every other venueless row (#4106 fact 10), and a key
    // that turned nil into anything else would split them.
    @Test func aRowWithNoVenueFoldsToTheSharedEmptyRoom() throws {
        let container = try TestModelContainer.inMemory([Prospect.self, Recipient.self])
        let show = try Self.show(in: container.mainContext, venue: nil)
        let keys = RowFacts.extract(show).foldedKeys
        #expect(keys.contradictionRoom == "")
        #expect(keys.feedBreakRoom == FeedBreakEvent.canonicalVenue(nil))
        #expect(keys.venueKey == nil)
    }

    // A model computes its keys on every read and a value carries them; the two must be one answer.
    @Test func aModelAndItsValueFoldTheSameKeys() throws {
        let container = try TestModelContainer.inMemory([Prospect.self, Recipient.self])
        let show = try Self.show(in: container.mainContext, venue: "Display Room (Downstairs)")
        #expect(RowFacts.extract(show).foldedKeys == show.foldedKeys)
    }
}

// #4356: a live show and its contacts with EVERY stored field set, each to a value no other field holds.
//
// Two jobs, both of which a hand-picked fixture cannot do. The no-model walk (`RowFactsHoldNoModelTests`)
// needs every optional populated and every collection non-empty, or a `nil` hides whatever a field would
// have held (#4106 plan Phase 2, step 3). And the wiring test (`RowFactsExtractionTests`) needs each field
// distinguishable from every other, so a copy that reads the wrong field (`venue: source.presenter`) is a
// visible mismatch rather than two equal defaults agreeing.
//
// Driven by each model's own `scopeKeyPaths`, which `ScopeFieldsMatchTheSchemaTests` holds to the schema, so
// a property added to a model is populated here without anybody remembering to. A string or list holds the
// field's own name, a number and a date its position. A `Bool` has two values, so `variant` picks one bit of
// the position plus one: across variants 0 to 7 any two of the fewer than 255 fields differ in at least one,
// and each is true in some variant and false in another, so a run over all eight sees any swap of two Bools
// and any Bool copied as a constant. A field of a type this cannot set is returned, never skipped silently.
enum FactsFixture {

    /// Sets every stored attribute of `model` it can, and returns the names of those it could not.
    @discardableResult
    static func populate<Model: ScopeObserved>(_ model: Model, variant: Int) -> [String] {
        var unset: [String] = []
        let paths = Model.scopeKeyPaths.sorted { name(of: $0) < name(of: $1) }
        for (index, path) in paths.enumerated() {
            let field = name(of: path)
            let bit = ((index + 1) >> variant) & 1 == 1
            let date = Date(timeIntervalSince1970: 1_000_000 + Double(index) * 1000)
            switch path {
            case let p as ReferenceWritableKeyPath<Model, String>: model[keyPath: p] = field
            case let p as ReferenceWritableKeyPath<Model, String?>: model[keyPath: p] = field
            case let p as ReferenceWritableKeyPath<Model, [String]>: model[keyPath: p] = [field]
            case let p as ReferenceWritableKeyPath<Model, [String]?>: model[keyPath: p] = [field]
            case let p as ReferenceWritableKeyPath<Model, Bool>: model[keyPath: p] = bit
            case let p as ReferenceWritableKeyPath<Model, Bool?>: model[keyPath: p] = bit
            case let p as ReferenceWritableKeyPath<Model, Int>: model[keyPath: p] = 1000 + index
            case let p as ReferenceWritableKeyPath<Model, Int?>: model[keyPath: p] = 1000 + index
            case let p as ReferenceWritableKeyPath<Model, Double?>: model[keyPath: p] = 1000.5 + Double(index)
            case let p as ReferenceWritableKeyPath<Model, Date>: model[keyPath: p] = date
            case let p as ReferenceWritableKeyPath<Model, Date?>: model[keyPath: p] = date
            default: unset.append(field)
            }
        }
        return unset
    }

    /// Every stored attribute of `model` as it now reads, printed, by name: what a correct copy must hold.
    static func expected<Model: ScopeObserved>(_ model: Model) -> [String: String] {
        var out: [String: String] = [:]
        for path in Model.scopeKeyPaths {
            guard let partial = path as? PartialKeyPath<Model> else { continue }
            out[name(of: path)] = String(describing: model[keyPath: partial])
        }
        return out
    }

    /// `\Prospect.venue` prints as itself, and the name is what follows the last dot.
    static func name(of path: AnyKeyPath) -> String {
        String(describing: path).split(separator: ".").last.map(String.init) ?? ""
    }

    /// A live show with two contacts, every field written, saved so every identifier is permanent. Returns
    /// the fields neither model could set, which a caller asserts empty for the fields it carries.
    @MainActor
    static func liveRow(variant: Int, in context: ModelContext) throws
        -> (show: Prospect, contacts: [Recipient], unset: [String]) {
        let show = Prospect(naturalKey: "seed", groupName: "Seed", discipline: "theatre", venue: nil,
                            performanceDate: nil, sourceListingURL: nil, priorRelationship: "none",
                            production: "self", profile: "strong", coverage: "likely_uncovered",
                            fitScore: 1, tier: "low", fitReason: "r", matchedClientName: nil,
                            possibleMatchSource: nil, possibleMatchName: nil)
        context.insert(show)
        let contacts = [Recipient(id: "a", email: nil, provenance: .manual),
                        Recipient(id: "b", email: nil, provenance: .manual)]
        for contact in contacts {
            context.insert(contact)
            contact.prospect = show
        }
        var unset = populate(show, variant: variant)
        for contact in contacts { unset += populate(contact, variant: variant) }
        try context.save()
        return (show, contacts, unset)
    }
}
