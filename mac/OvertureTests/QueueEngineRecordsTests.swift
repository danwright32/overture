import Foundation
import SwiftData
import Testing

// #4358 (slice E1): the engine's values are held to the store's own schema, and its tables to the models the
// pass reads.
//
// Each record carries every stored property of its model, by the same finder `RowFactsSchemaCoverageTests`
// holds `RowFacts` with, so a property added to one of these models is a red test until somebody carries it
// (L40). And the `FactStore` keeps one table per model `AppSchemaInputClass` says the pass reads, spelled as
// its own members, so a model classified as a queue input with nowhere to keep it, or a table nothing feeds,
// is a red test rather than a row the engine silently never holds (L96).
@Suite("The queue engine's records carry every stored property (#4358)")
@MainActor
struct QueueEngineRecordsCoverTheSchemaTests {

    /// One live row of every model the records copy, each field written, saved.
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

    // Each record's copy is checked field by field against the model it came from, through the same writer the
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

    // `differences` compares every table: one changed row in each table counts once, and a row removed from
    // each is named. A table left out of the comparison would read as unchanged here.
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
