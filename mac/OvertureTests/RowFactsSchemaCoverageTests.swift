import Foundation
import SwiftData
import Testing

// #4356 (plan v7 Phase 2, "two-way schema coverage"): the facts a retained row
// carries are held to the store's own schema in BOTH directions.
//
// One way, every stored property of `Prospect` and `Recipient` is either carried by `RowFacts` /
// `RecipientRecord` or exempt in `notReadByQueue` with a written reason. A property added to a model and
// forgotten here would otherwise be one whose edits a retained row never sees, so the queue keeps showing
// the old answer and nothing says so (L40). The other way, every carried field names a property the schema
// really stores, so a rename cannot leave a field carrying nothing.
//
// Derived from `AppSchema.schema`, the Schema the app opens its store with, and from `Mirror` over a real
// value, never from a list kept beside them (L41, L96). And the protocols are read from their source, so
// `ProspectFacts` cannot drift from the value that conforms to it.
@Suite("RowFacts carries every stored property or says why not (#4356)")
@MainActor
struct RowFactsSchemaCoverageTests {

    /// The fields on the value that are not stored properties of the model, and what each stands for.
    /// `factContacts` carries the relationship named beside it; the other two are the row's identity and
    /// its pre-folded keys, which the schema does not store.
    static let structural: [String: String?] = [
        "persistentModelID": nil,
        "foldedKeys": nil,
        "factContacts": "recipients",
    ]

    /// "property" for every attribute and relationship the schema stores on `entity`.
    static func stored(_ entity: String) -> Set<String> {
        guard let found = AppSchema.schema.entities.first(where: { $0.name == entity }) else { return [] }
        return Set(found.attributes.map(\.name)).union(found.relationships.map(\.name))
    }

    static func labels(of value: Any) -> Set<String> {
        Set(Mirror(reflecting: value).children.compactMap(\.label))
    }

    static func liveFacts() throws -> (row: RowFacts, contact: RecipientRecord, container: ModelContainer) {
        let container = try TestModelContainer.inMemory([Prospect.self, Recipient.self])
        let (show, _, _) = try FactsFixture.liveRow(variant: 0, in: container.mainContext)
        let row = RowFacts.extract(show)
        return (row, try #require(row.factContacts.first), container)
    }

    /// The names a protocol declares as `var name:`, read from its body in `QueueFacts.swift`.
    static func requirements(of proto: String) throws -> Set<String> {
        let file = try #require(AppSourceWalk.appFiles().first { $0.name == "QueueFacts.swift" })
        let lines = SwiftSource.scannableLines(in: file.text).map(\.code)
        // #4357 slice D1: `ContactFacts` now refines `ReplyArrivalFacts`, so its declaration reads
        // `protocol ContactFacts: ReplyArrivalFacts {`; both shapes open the body this reads.
        let start = try #require(lines.firstIndex {
            $0.contains("protocol \(proto) {") || $0.contains("protocol \(proto): ")
        })
        var names: Set<String> = []
        for line in lines[(start + 1)...] {
            if line.hasPrefix("}") { break }
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("var "), let colon = trimmed.firstIndex(of: ":") else { continue }
            names.insert(String(trimmed[trimmed.index(trimmed.startIndex, offsetBy: 4)..<colon]))
        }
        return names
    }

    /// Every finding about one model's coverage, empty when the value and the schema agree.
    static func findings(entity: String, carried: Set<String>, exempt: [String: String],
                         relationships: [String: String]) -> [String] {
        let schema = stored(entity)
        var out: [String] = []
        let carriedStored = carried.union(relationships.keys)
        let missing = schema.subtracting(carriedStored).subtracting(exempt.keys).sorted()
        if !missing.isEmpty {
            out.append("\(entity) stores these and the value neither carries them nor exempts them, so a "
                       + "retained row would never see them change: \(missing.joined(separator: ", "))")
        }
        let unreal = carriedStored.subtracting(schema).sorted()
        if !unreal.isEmpty {
            out.append("the value carries these as \(entity) properties and the schema stores none of them: "
                       + unreal.joined(separator: ", "))
        }
        let unrealExempt = Set(exempt.keys).subtracting(schema).sorted()
        if !unrealExempt.isEmpty {
            out.append("exempt but not stored on \(entity): " + unrealExempt.joined(separator: ", "))
        }
        let both = carriedStored.intersection(exempt.keys).sorted()
        if !both.isEmpty {
            out.append("carried AND exempt on \(entity): " + both.joined(separator: ", "))
        }
        // A reason must begin with a word, or the surrounding syntax satisfies it (L675).
        let reasonless = exempt.filter { $0.value.first?.isLetter != true }.keys.sorted()
        if !reasonless.isEmpty {
            out.append("exempt with no written reason on \(entity): " + reasonless.joined(separator: ", "))
        }
        return out
    }

    @Test func everyStoredProspectPropertyIsCarriedOrExemptAndNothingElse() throws {
        let (row, _, _) = try Self.liveFacts()
        let structural = Set(Self.structural.keys)
        let carried = Self.labels(of: row).subtracting(structural)
        // The positive control: a walk that found nothing would agree with an empty schema (L98).
        #expect(carried.count > 100 && Self.stored("Prospect").count > 100,
                "too few fields or stored properties were enumerated for this to have checked anything")
        let relationships = Dictionary(uniqueKeysWithValues: Self.structural.compactMap { entry in
            entry.value.map { ($0, entry.key) }
        })
        let found = Self.findings(entity: "Prospect", carried: carried, exempt: RowFacts.notReadByQueue,
                                  relationships: relationships)
        #expect(found.isEmpty, Comment(rawValue: found.joined(separator: "\n")))
    }

    @Test func everyStoredRecipientPropertyIsCarriedOrExemptAndNothingElse() throws {
        let (_, contact, _) = try Self.liveFacts()
        let carried = Self.labels(of: contact).subtracting(["persistentModelID"])
        #expect(carried.count > 100 && Self.stored("Recipient").count > 100,
                "too few fields or stored properties were enumerated for this to have checked anything")
        let found = Self.findings(entity: "Recipient", carried: carried, exempt: RecipientRecord.notReadByQueue,
                                  relationships: [:])
        #expect(found.isEmpty, Comment(rawValue: found.joined(separator: "\n")))
    }

    // The protocol is what a term written in Phase 3 can READ, and the value is what is retained. A field
    // retained and not readable is dead weight; one readable and not retained does not compile, so only
    // the first direction needs a test.
    @Test func theProtocolsDeclareExactlyWhatTheValuesCarry() throws {
        let (row, contact, _) = try Self.liveFacts()
        let prospectSide = try Self.requirements(of: "ProspectFacts")
        let contactSide = try Self.requirements(of: "ContactFacts")
        #expect(prospectSide.count > 100 && contactSide.count > 100,
                "the protocol bodies were not found, so nothing was compared")
        let rowExtra = Self.labels(of: row).subtracting(prospectSide).sorted()
        let contactExtra = Self.labels(of: contact).subtracting(contactSide).sorted()
        #expect(rowExtra.isEmpty, Comment(rawValue: "RowFacts carries fields ProspectFacts does not declare, "
            + "so no term can read them: " + rowExtra.joined(separator: ", ")))
        #expect(contactExtra.isEmpty, Comment(rawValue: "RecipientRecord carries fields ContactFacts does "
            + "not declare: " + contactExtra.joined(separator: ", ")))
    }
}

// #4356 (plan v7 Phase 2, "no-model walk"): a retained row holds VALUES, never a live model.
//
// A model inside a retained value would be read later, after the store has moved on, and would answer with
// whatever the context holds then: a stale or faulted row presented as the fact the value was built from,
// and a `Sendable` claim that is false. Three checks, because each misses what the others see:
//
//   1. `Sendable`, which the compiler enforces: a model is not `Sendable`, so a field holding one does not
//      build. Asserted below by requiring the conformance, so a later `@unchecked` would have to be written
//      on purpose.
//   2. A reflection walk over a value built from `FactsFixture`, where every optional is set and
//      every collection holds something. It first proves it reached a populated child for EVERY stored
//      property (the positive control, L159), so a field left nil cannot hide what it would have held, and
//      only then fails on anything that is a `PersistentModel`.
//   3. A source scan of each value type's declared field types, which sees a model type named on a field
//      that happens to be empty at run time.
@Suite("A retained row holds no model (#4356)")
@MainActor
struct RowFactsHoldNoModelTests {

    static func requireSendable<T: Sendable>(_: T.Type) {}

    /// Every path under `value` at which a `PersistentModel` sits.
    static func models(in value: Any, path: String, depth: Int = 0) -> [String] {
        if value is any PersistentModel { return [path] }
        // #4357 step 5: a store identifier is a VALUE naming its row, the opposite of a live model, but an
        // unsaved row's TEMPORARY identifier carries its model's TYPE inside it, which reads as a model to the
        // test above. Measured: every identity a pass over unsaved rows published was reported at
        // `showID.id.backing.temporaryIdentifier._modelType`. So the walk stops at an identifier.
        if value is PersistentIdentifier { return [] }
        guard depth < 16 else { return [] }
        var found: [String] = []
        for (index, child) in Mirror(reflecting: value).children.enumerated() {
            found += models(in: child.value, path: path + "." + (child.label ?? "\(index)"), depth: depth + 1)
        }
        return found
    }

    /// Whether a stored property's value holds something: a set optional, a non-empty collection or
    /// string, or any other value at all.
    static func isPopulated(_ value: Any) -> Bool {
        if let text = value as? String { return !text.isEmpty }
        let mirror = Mirror(reflecting: value)
        switch mirror.displayStyle {
        case .optional:
            guard let wrapped = mirror.children.first?.value else { return false }
            return isPopulated(wrapped)
        case .collection, .set, .dictionary:
            return !mirror.children.isEmpty
        default:
            return true
        }
    }

    static func fullyPopulatedValue(variant: Int) throws -> (RowFacts, ModelContainer) {
        let container = try TestModelContainer.inMemory([Prospect.self, Recipient.self])
        let (show, _, _) = try FactsFixture.liveRow(variant: variant, in: container.mainContext)
        return (RowFacts.extract(show), container)
    }

    @Test func theRetainedTypesAreSendable() {
        Self.requireSendable(RowFacts.self)
        Self.requireSendable(RecipientRecord.self)
        Self.requireSendable(RowKeys.self)
    }

    @Test func theWalkReachesEveryFieldAndFindsNoModel() throws {
        let (row, _) = try Self.fullyPopulatedValue(variant: 1)
        let contact = try #require(row.factContacts.first)

        let emptyRow = Mirror(reflecting: row).children.filter { !Self.isPopulated($0.value) }.compactMap(\.label)
        let emptyContact = Mirror(reflecting: contact).children.filter { !Self.isPopulated($0.value) }
            .compactMap(\.label)
        #expect(emptyRow.isEmpty && emptyContact.isEmpty, Comment(rawValue: "the walk reached these fields "
            + "empty, so a model they could hold would not be seen: "
            + (emptyRow + emptyContact).sorted().joined(separator: ", ")))

        let found = Self.models(in: row, path: "RowFacts")
        #expect(found.isEmpty, Comment(rawValue: "a live model sits inside the retained value at: "
            + found.joined(separator: ", ")))
    }

    // The walk's own positive control: handed a value that DOES hold a model, it says so. A walk that could
    // not see one would pass every value above (L159).
    @Test func theWalkSeesAModelWhenOneIsThere() throws {
        let container = try TestModelContainer.inMemory([Prospect.self, Recipient.self])
        let (show, _, _) = try FactsFixture.liveRow(variant: 0, in: container.mainContext)
        let holding: (Int, [Prospect?]) = (1, [show])
        #expect(Self.models(in: holding, path: "probe").count == 1,
                "the walk was handed one live model inside a value and did not report it")
    }

    @Test func noRetainedTypeDeclaresAFieldOfAModelType() throws {
        let modelNames = Set(AppSchema.models.map { String(describing: $0) })
        let files = AppSourceWalk.appFiles().filter { ["RowFacts.swift", "QueueFacts.swift"].contains($0.name) }
        #expect(files.count == 2, "the value types' source files were not both found, so nothing was scanned")
        var fields = 0
        var offenders: [String] = []
        for file in files {
            var inside: String?
            for (line, code) in SwiftSource.scannableLines(in: file.text) {
                for type in ["RowFacts", "RecipientRecord", "RowKeys"] where code.hasPrefix("struct \(type):") {
                    inside = type
                }
                if code.hasPrefix("}") { inside = nil }
                guard let owner = inside else { continue }
                let trimmed = code.trimmingCharacters(in: .whitespaces)
                guard trimmed.hasPrefix("let ") || trimmed.hasPrefix("var "),
                      let colon = trimmed.firstIndex(of: ":") else { continue }
                fields += 1
                let declared = trimmed[trimmed.index(after: colon)...]
                let words = Set(declared.split { !$0.isLetter && !$0.isNumber && $0 != "_" }.map(String.init))
                for model in modelNames.intersection(words) {
                    offenders.append("\(file.name):\(line) \(owner) declares a field of type \(model)")
                }
            }
        }
        #expect(fields > 250, "too few fields were read for the scan to have covered the value types")
        #expect(offenders.isEmpty, Comment(rawValue: offenders.joined(separator: "\n")))
    }
}

// #4357 step 5 (plan v7 Phase 3): the same guard, extended from the retained row to what the pass PUBLISHES:
// `QueueView.RenderData`, the cards in it (`QueueItem`) and the card store (`CardStore`).
//
// The same three checks as above, each where it can apply. `RenderData` and the card store are not `Sendable`
// (the store is a class that builds a missed card while drawing), so the compiler says nothing about them and
// the walk and the scan carry the whole of it there. The walk over a whole pass runs in `TermsOverFactsTests`
// (`aPopulatedPassHoldsAModelOnlyWhereItIsStillAllowed`), because that is where the fixture lives in which
// every pill and stage counts something.
//
// THREE MEMBERS STILL HOLD A MODEL, named below with the issue that takes each out, and nothing else may.
// Each is a reason, not a convenience: the card store needs a value for every row in scope and only the
// engine retains them (a store over facts built by today's pass would extract every row on every pass, which
// the live store cost probe prices); the other two carry an `Inquiry`, which has no identity to resolve a
// press through yet.
@Suite("What the queue pass publishes holds no model (#4357)")
@MainActor
struct OutputsHoldNoModelTests {

    /// The RenderData members still allowed a model, each with the issue that takes it out.
    static let stillHoldingAModel: [String: String] = [
        "cards": "#4358: today's pass hands the card store its models; the engine's pass hands it RowFacts",
        "reachedOutList": "#4579 and #4371: its rows draw from the live show, contact and inquiry",
        "inquiriesByRowID": "#4579: an inquiry has no identity to resolve a press through yet",
    ]

    @Test func thePublishedValueTypesAreSendable() {
        RowFactsHoldNoModelTests.requireSendable(QueueItem.self)
        RowFactsHoldNoModelTests.requireSendable(RecipientSnapshot.self)
        RowFactsHoldNoModelTests.requireSendable(QueueScopeRow.self)
        RowFactsHoldNoModelTests.requireSendable(ShowIdentity.self)
        RowFactsHoldNoModelTests.requireSendable(ReachedOutSnapshot.self)
    }

    static func preamble() -> QueueModel.CardPreamble {
        QueueModel.CardPreamble(linked: [:], inherited: [:],
                                venueBrands: ProducerGate.VenueBrands(shows: [], overrides: .none),
                                rowCounts: [:], calendarBySourceId: [:], overrides: .none, clients: .none,
                                contradictedCancellations: [], sameShowGroups: [:], titlesByKey: [:],
                                collapsedFronts: [:], collapsedHidden: [], laterLookalikesByKey: [:],
                                nightsByKey: [:], now: Date(timeIntervalSince1970: 1_790_000_000), day: "2026-10-01")
    }

    /// A store over this row with every member set: one prebuilt card, the row's contacts, a requested key set
    /// and a registry, so the walk below has something in each place a model could sit.
    static func store<Row: ProspectFacts>(over row: Row, preamble pre: QueueModel.CardPreamble) -> QueueModel.CardStore {
        QueueModel.CardStore(cards: [row.naturalKey: QueueModel.card(row, among: row.factContacts, preamble: pre)],
                             shows: [row], contactsByKey: [row.naturalKey: row.factContacts], preamble: pre,
                             requestedKeys: [row.naturalKey], registry: QueueModel.CardKeyRegistry())
    }

    @Test func aCardStoreOverFactsHoldsNoModelAndBuildsTheModelsCard() throws {
        let container = try TestModelContainer.inMemory([Prospect.self, Recipient.self])
        let (show, contacts, _) = try FactsFixture.liveRow(variant: 1, in: container.mainContext)
        // The fixture writes each string field with its own name, so both contacts would share the id "id",
        // which the card's own grouping refuses (it traps on a duplicate key). Two distinct addresses instead.
        for (index, contact) in contacts.enumerated() { contact.id = "contact\(index)@example.invalid" }
        try container.mainContext.save()
        let facts = RowFacts.extract(show)
        let pre = Self.preamble()
        let overFacts = Self.store(over: facts, preamble: pre)

        // Positive control (L159): every stored member of the store holds something, and the sources reach the
        // show and both its contacts, so a model in any of them would be in reach of the walk.
        let empty = Mirror(reflecting: overFacts).children
            .filter { !RowFactsHoldNoModelTests.isPopulated($0.value) }.compactMap(\.label)
        #expect(empty.isEmpty, Comment(rawValue: "the store holds these members empty, so the walk sees nothing "
            + "in them: " + empty.joined(separator: ", ")))
        #expect(overFacts.contents.shows.count == 1 && overFacts.contents.contacts[show.naturalKey]?.count == 2,
                "the store does not hold the show and both its contacts, so the walk reached less than it says")

        let found = RowFactsHoldNoModelTests.models(in: overFacts, path: "CardStore")
        #expect(found.isEmpty, Comment(rawValue: "a card store built over facts holds a live model at: "
            + found.joined(separator: ", ")))

        // The walk's own control, and what today's pass hands the store: built over the live show, it holds it.
        let overModels = Self.store(over: show, preamble: pre)
        #expect(!RowFactsHoldNoModelTests.models(in: overModels, path: "CardStore").isEmpty,
                "the walk was handed a store holding the live show and did not report it")

        // And a card the pass did not build comes out of a store over facts as it does out of one over models.
        let row = QueueScopeRow(show, facts: RecipientFacts.of(show, contacts: show.factContacts))
        let fromFacts = QueueModel.CardStore(cards: [:], shows: [facts], contactsByKey: [:], preamble: pre,
                                             requestedKeys: []).card(for: row)
        let fromModels = QueueModel.CardStore(cards: [:], shows: [show], contactsByKey: [:], preamble: pre,
                                              requestedKeys: []).card(for: row)
        #expect(fromFacts.showID == show.persistentModelID, "the missed card was not built from the show")
        #expect(fromFacts.contacts.count == 2, "the missed card was built without the show's own contacts")
        #expect(fromFacts == fromModels, Comment(rawValue: "a missed card over facts differs from one over the "
            + "model in: " + QueueModel.differingFieldNames(fromFacts, fromModels).joined(separator: ", ")))
        #expect(RowFactsHoldNoModelTests.models(in: fromFacts, path: "QueueItem").isEmpty,
                "a card built over facts holds a live model")
        withExtendedLifetime(container) {}
    }

    // The scan: a stored field whose DECLARED type names a model, on each published type, which sees a model
    // field that happens to be empty at run time. A model name followed by a dot is a namespace
    // (`Recipient.HoldReason` is an enum the card carries by value), not the model.
    static let publishedTypes: [(file: String, declaration: String, owner: String)] = [
        ("QueueView+Model.swift", "struct QueueItem:", "QueueItem"),
        ("QueueView+Model.swift", "struct RecipientSnapshot:", "RecipientSnapshot"),
        ("QueueView+Model.swift", "final class CardStore {", "CardStore"),
        ("QueueView+Model.swift", "struct CardSourcesOf<", "CardSourcesOf"),
        ("QueueScopeRow.swift", "struct QueueScopeRow:", "QueueScopeRow"),
        ("QueueView.swift", "struct RenderData {", "RenderData"),
    ]

    @Test func noPublishedTypeDeclaresAFieldOfAModelType() throws {
        let modelNames = AppSchema.models.map { String(describing: $0) }
        let model = try Regex(#"\b("# + modelNames.joined(separator: "|") + #")\b(?!\.)"#)
        let files = AppSourceWalk.appFiles().filter { file in Self.publishedTypes.contains { $0.file == file.name } }
        #expect(Set(files.map(\.name)).count == 3, "the published types' source files were not all found")
        var seen: [String: Int] = [:]
        var offenders: [String] = []
        for file in files {
            var inside: (owner: String, indent: Int)?
            for (line, code) in SwiftSource.scannableLines(in: file.text) {
                let indent = code.prefix { $0 == " " }.count
                let trimmed = code.trimmingCharacters(in: .whitespaces)
                if inside == nil, let type = Self.publishedTypes.first(where: {
                    $0.file == file.name && trimmed.hasPrefix($0.declaration)
                }) {
                    inside = (type.owner, indent)
                    continue
                }
                guard let (owner, depth) = inside else { continue }
                if trimmed == "}" && indent == depth { inside = nil; continue }
                guard indent == depth + 4 else { continue }
                var field = trimmed
                for modifier in ["private(set) ", "private ", "fileprivate ", "nonisolated "] where field.hasPrefix(modifier) {
                    field.removeFirst(modifier.count)
                }
                guard field.hasPrefix("let ") || field.hasPrefix("var "),
                      let colon = field.firstIndex(of: ":") else { continue }
                var declared = String(field[field.index(after: colon)...])
                if let equals = declared.firstIndex(of: "=") { declared = String(declared[..<equals]) }
                // A computed property is not storage.
                if declared.contains("{") { continue }
                let name = field.dropFirst(4).prefix { $0 != ":" }.trimmingCharacters(in: .whitespaces)
                seen[owner, default: 0] += 1
                guard declared.contains(model) else { continue }
                if owner == "RenderData", Self.stillHoldingAModel[name] != nil { continue }
                offenders.append("\(file.name):\(line) \(owner).\(name) is declared as\(declared)")
            }
        }
        // Every type was found, and read deeply enough to have covered its fields (L98).
        for type in Self.publishedTypes {
            #expect(seen[type.owner, default: 0] >= 2, "too few fields of \(type.owner) were read to have covered it")
        }
        #expect(seen["QueueItem", default: 0] > 80 && seen["RenderData", default: 0] > 25,
                "the scan read too few fields of the card or the pass to have covered them")
        #expect(offenders.isEmpty, Comment(rawValue: offenders.joined(separator: "\n")))
    }
}
