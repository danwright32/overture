import Foundation
import SwiftData

// #4358 (plan v7 Phase 4, the FactStore): every queue input the store holds, as values, keyed by identity.
//
// The queue engine keeps this instead of the live models, so the value pass reads values that cannot fault the
// store or change underneath it, and so an edit that changed nothing a term reads is recognised by `==` and
// dropped (D2's equality gate). One dictionary per model the pass reads, each keyed by `persistentModelID` and
// never by `naturalKey` (merges and re-keys reassign it) or by `Recipient.id` (one address sits on several
// shows), and each named in `Table` by the model it holds, which is how a saved identifier says which table it
// belongs to (`PersistentIdentifier.entityName`). A contact has no table: it rides inside its show's `RowFacts`.
//
// `extractAll(from:)` is the whole read, over ANY context. The engine fills itself through the same initialiser
// (`init(shows:inquiries:smallTablesFrom:)`), and the verifier (#4358, slice E2) and the change-kind matrix read
// a fresh store through `extractAll` on a context of their own, so the two sides of every comparison share the
// extraction and nothing else (L70): neither ever reads the other's dictionaries.
struct FactStore: Equatable, Sendable {
    var shows: [PersistentIdentifier: RowFacts] = [:]
    var inquiries: [PersistentIdentifier: InquiryRecord] = [:]
    var orgAnswers: [PersistentIdentifier: OrgAnswerRecord] = [:]
    var watchedSources: [PersistentIdentifier: WatchedSourceRecord] = [:]
    var refusedAddresses: [PersistentIdentifier: RefusedAddressRecord] = [:]
    var promotedProducers: [PersistentIdentifier: ProducerOverrideRecord] = [:]
    var demotedHouses: [PersistentIdentifier: ProducerOverrideRecord] = [:]
    var excludedTowns: [PersistentIdentifier: TownRecord] = [:]
    var allowedSeedTowns: [PersistentIdentifier: TownRecord] = [:]

    /// Every table, by the model whose rows it holds. Each case is spelled as its dictionary above, which
    /// `FactStoreTablesTests` holds to the struct's own members by Mirror, and to `AppSchemaInputClass`, so a
    /// model the pass reads cannot be classified without a table to keep it in.
    enum Table: String, CaseIterable, Sendable {
        case shows = "Prospect"
        case inquiries = "Inquiry"
        case orgAnswers = "OrgReachabilityAnswer"
        case watchedSources = "WatchedSource"
        case refusedAddresses = "RefusedContactAddress"
        case promotedProducers = "PromotedProducer"
        case demotedHouses = "DemotedHouse"
        case excludedTowns = "ExcludedTown"
        case allowedSeedTowns = "AllowedSeedTown"

        /// The table holding rows of the model `entityName` names, or nil for a model the pass never reads.
        static func holding(_ entityName: String) -> Table? { Table(rawValue: entityName) }

        /// The live row `id` names in this table, read through `context`, or nil when it is gone. A row the
        /// context already holds is answered from it; any other is FETCHED by identity, because `model(for:)` on
        /// a row deleted and saved hands back a model that reads as live (#4106 probe 2), and a fetch that
        /// finds nothing is a deletion (decision 9). A fetch that fails THROWS rather than answering nil: a
        /// failed read is never a deletion (L215).
        func liveRow(_ id: PersistentIdentifier, in context: ModelContext) throws -> (any PersistentModel)? {
            switch self {
            case .shows: return try FactStore.liveRow(Prospect.self, id, in: context)
            case .inquiries: return try FactStore.liveRow(Inquiry.self, id, in: context)
            case .orgAnswers: return try FactStore.liveRow(OrgReachabilityAnswer.self, id, in: context)
            case .watchedSources: return try FactStore.liveRow(WatchedSource.self, id, in: context)
            case .refusedAddresses: return try FactStore.liveRow(RefusedContactAddress.self, id, in: context)
            case .promotedProducers: return try FactStore.liveRow(PromotedProducer.self, id, in: context)
            case .demotedHouses: return try FactStore.liveRow(DemotedHouse.self, id, in: context)
            case .excludedTowns: return try FactStore.liveRow(ExcludedTown.self, id, in: context)
            case .allowedSeedTowns: return try FactStore.liveRow(AllowedSeedTown.self, id, in: context)
            }
        }
    }

    init() {}

    /// Every queue input in the store `context` reads, as values. A context of its own sees what is SAVED; the
    /// main context also sees its own unsaved changes.
    nonisolated static func extractAll(from context: ModelContext) throws -> FactStore {
        try FactStore(shows: context.fetch(FetchDescriptor<Prospect>()),
                      inquiries: context.fetch(FetchDescriptor<Inquiry>()),
                      smallTablesFrom: context)
    }

    /// The store from shows and inquiries the caller already fetched (the engine holds them, to watch them),
    /// with every small table read through `context`.
    nonisolated init(shows: [Prospect], inquiries: [Inquiry], smallTablesFrom context: ModelContext) throws {
        self.shows = Self.keyed(shows, RowFacts.extract)
        self.inquiries = Self.keyed(inquiries, InquiryRecord.init(copying:))
        orgAnswers = try Self.keyed(context.fetch(FetchDescriptor<OrgReachabilityAnswer>()),
                                    OrgAnswerRecord.init(copying:))
        watchedSources = try Self.keyed(context.fetch(FetchDescriptor<WatchedSource>()),
                                        WatchedSourceRecord.init(copying:))
        refusedAddresses = try Self.keyed(context.fetch(FetchDescriptor<RefusedContactAddress>()),
                                          RefusedAddressRecord.init(copying:))
        promotedProducers = try Self.keyed(context.fetch(FetchDescriptor<PromotedProducer>()),
                                           ProducerOverrideRecord.init(copying:))
        demotedHouses = try Self.keyed(context.fetch(FetchDescriptor<DemotedHouse>()),
                                       ProducerOverrideRecord.init(copying:))
        excludedTowns = try Self.keyed(context.fetch(FetchDescriptor<ExcludedTown>()), TownRecord.init(copying:))
        allowedSeedTowns = try Self.keyed(context.fetch(FetchDescriptor<AllowedSeedTown>()),
                                          TownRecord.init(copying:))
    }

    /// Which of `ids` the store really holds, by one FETCH per table, never through the context's registered
    /// objects: a row merged into another by its unique key stays registered and reads as live, and only a
    /// fetch finds that its identifier names no row (#4358). Identifiers of a model with no table are left out.
    nonisolated static func storedIdentifiers(among ids: Set<PersistentIdentifier>,
                                              in context: ModelContext) throws -> Set<PersistentIdentifier> {
        var found: Set<PersistentIdentifier> = []
        let byTable = Dictionary(grouping: ids) { Table.holding($0.entityName) }
        for (table, members) in byTable {
            guard let table else { continue }
            switch table {
            case .shows: found.formUnion(try stored(Prospect.self, members, in: context))
            case .inquiries: found.formUnion(try stored(Inquiry.self, members, in: context))
            case .orgAnswers: found.formUnion(try stored(OrgReachabilityAnswer.self, members, in: context))
            case .watchedSources: found.formUnion(try stored(WatchedSource.self, members, in: context))
            case .refusedAddresses: found.formUnion(try stored(RefusedContactAddress.self, members, in: context))
            case .promotedProducers: found.formUnion(try stored(PromotedProducer.self, members, in: context))
            case .demotedHouses: found.formUnion(try stored(DemotedHouse.self, members, in: context))
            case .excludedTowns: found.formUnion(try stored(ExcludedTown.self, members, in: context))
            case .allowedSeedTowns: found.formUnion(try stored(AllowedSeedTown.self, members, in: context))
            }
        }
        return found
    }

    /// Stores `model` as its value in the table it belongs to, and says whether the stored value CHANGED. An
    /// equal value is still stored (the same value), so a caller can tell "read and unchanged" from "absent".
    mutating func record(_ model: any PersistentModel) -> Bool {
        switch model {
        case let m as Prospect: return Self.put(RowFacts.extract(m), m.persistentModelID, in: &shows)
        case let m as Inquiry: return Self.put(InquiryRecord(copying: m), m.persistentModelID, in: &inquiries)
        case let m as OrgReachabilityAnswer:
            return Self.put(OrgAnswerRecord(copying: m), m.persistentModelID, in: &orgAnswers)
        case let m as WatchedSource:
            return Self.put(WatchedSourceRecord(copying: m), m.persistentModelID, in: &watchedSources)
        case let m as RefusedContactAddress:
            return Self.put(RefusedAddressRecord(copying: m), m.persistentModelID, in: &refusedAddresses)
        case let m as PromotedProducer:
            return Self.put(ProducerOverrideRecord(copying: m), m.persistentModelID, in: &promotedProducers)
        case let m as DemotedHouse:
            return Self.put(ProducerOverrideRecord(copying: m), m.persistentModelID, in: &demotedHouses)
        case let m as ExcludedTown: return Self.put(TownRecord(copying: m), m.persistentModelID, in: &excludedTowns)
        case let m as AllowedSeedTown:
            return Self.put(TownRecord(copying: m), m.persistentModelID, in: &allowedSeedTowns)
        default: return false
        }
    }

    /// Whether any table holds a row under `id`.
    func holds(_ id: PersistentIdentifier) -> Bool {
        guard let table = Table.holding(id.entityName) else { return false }
        switch table {
        case .shows: return shows[id] != nil
        case .inquiries: return inquiries[id] != nil
        case .orgAnswers: return orgAnswers[id] != nil
        case .watchedSources: return watchedSources[id] != nil
        case .refusedAddresses: return refusedAddresses[id] != nil
        case .promotedProducers: return promotedProducers[id] != nil
        case .demotedHouses: return demotedHouses[id] != nil
        case .excludedTowns: return excludedTowns[id] != nil
        case .allowedSeedTowns: return allowedSeedTowns[id] != nil
        }
    }

    /// How `fresh` differs from this store: the rows whose value changed or appeared, and the identities this
    /// store holds that `fresh` does not. Every table is compared; `FactStoreTablesTests` holds the list below to
    /// the struct's members.
    func differences(to fresh: FactStore) -> (changed: Int, gone: Set<PersistentIdentifier>) {
        var changed = 0
        var gone: Set<PersistentIdentifier> = []
        func compare<R: Equatable>(_ path: KeyPath<FactStore, [PersistentIdentifier: R]>) {
            let old = self[keyPath: path]
            let new = fresh[keyPath: path]
            for (id, value) in new where old[id] != value { changed += 1 }
            for id in old.keys where new[id] == nil {
                gone.insert(id)
                changed += 1
            }
        }
        compare(\.shows)
        compare(\.inquiries)
        compare(\.orgAnswers)
        compare(\.watchedSources)
        compare(\.refusedAddresses)
        compare(\.promotedProducers)
        compare(\.demotedHouses)
        compare(\.excludedTowns)
        compare(\.allowedSeedTowns)
        return (changed, gone)
    }

    private static func put<R: Equatable>(_ value: R, _ id: PersistentIdentifier,
                                          in table: inout [PersistentIdentifier: R]) -> Bool {
        table.updateValue(value, forKey: id) != value
    }

    private nonisolated static func keyed<M: PersistentModel, R>(_ rows: [M],
                                                                 _ make: (M) -> R) -> [PersistentIdentifier: R] {
        var out: [PersistentIdentifier: R] = [:]
        out.reserveCapacity(rows.count)
        for row in rows { out[row.persistentModelID] = make(row) }
        return out
    }

    private nonisolated static func stored<M: PersistentModel>(_ type: M.Type, _ ids: [PersistentIdentifier],
                                                               in context: ModelContext) throws -> [PersistentIdentifier] {
        try context.fetch(FetchDescriptor<M>(predicate: #Predicate<M> { ids.contains($0.persistentModelID) }))
            .map(\.persistentModelID)
    }

    private nonisolated static func liveRow<M: PersistentModel>(_ type: M.Type, _ id: PersistentIdentifier,
                                                                in context: ModelContext) throws -> M? {
        if let held: M = context.registeredModel(for: id) { return StoreRows.isLive(held) ? held : nil }
        var descriptor = FetchDescriptor<M>(predicate: #Predicate<M> { $0.persistentModelID == id })
        descriptor.fetchLimit = 1
        return try context.fetch(descriptor).first
    }
}
