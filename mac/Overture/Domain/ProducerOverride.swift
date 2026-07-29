import Foundation
import SwiftData

// #1719 (milestone 34 Phase 2): Dan's own correction to a producer/house verdict, and the store that
// makes ProducerGate's `promoted` set mean something. It has taken that set since #1593 and every call
// site passed the default empty one, so the human half of the decision looked shipped while doing
// nothing (#1679, closed by this).
//
// Both models store the GATE'S OWN FOLDED KEY (ProducerGate.key), never the raw string and never a
// plain lowercasing. The gate folds a parenthetical qualifier and a leading "the" away before it
// compares, so a set keyed any other way would simply never match a presenter, and a set whose keys
// never match is indistinguishable from the empty set this issue exists to replace.
//
// The shape is ExcludedTown's (#991/#1221): SwiftData-only, grows by an in-app action, no relationship
// to Prospect, so adding it is a purely additive migration and no re-key or sweep can take a correction
// with it.

// "This IS a producer, despite carrying a room's name." Relaxes the venue-count and containment arms.
@Model
final class PromotedProducer {
    // Not `id`: PersistentModel already refines Identifiable through persistentModelID. Unique at the
    // STORE layer so two corrections racing on one organisation cannot leave two rows that disagree.
    @Attribute(.unique) var orgKey: String
    var addedAt: Date

    init(orgKey: String, addedAt: Date = Date()) {
        self.orgKey = orgKey
        self.addedAt = addedAt
    }
}

// "This IS a house, despite naming no room." The direction #1593 never had. FRIGID New York rents its
// rooms to 40 different companies across 33 untriaged rows, so it is a house in every sense Dan cares
// about, but its name is in no venue string (the rooms are Under St Marks and The Kraine Theater) and it
// runs more than one of them, so both automatic arms read it as a well travelled producer.
@Model
final class DemotedHouse {
    @Attribute(.unique) var orgKey: String
    var addedAt: Date

    init(orgKey: String, addedAt: Date = Date()) {
        self.orgKey = orgKey
        self.addedAt = addedAt
    }
}

// Both directions as ONE value, and the reason it is one rather than two loose sets: #1679 happened
// because a call site could quietly supply nothing. Two independent parameters make the same mistake
// cheaper still (pass `promoted`, forget `demoted`, and half the correction silently vanishes), and that
// half-wired state is invisible from the call site. One value travels together or not at all.
struct ProducerOverrides: Equatable, Sendable {
    var promoted: Set<String> = []
    var demoted: Set<String> = []

    // No corrections. The default for every caller with no store in hand (a unit test, the importer), so
    // a surface that never opted in cannot silently start applying somebody's judgment.
    static let none = ProducerOverrides()

    // Built straight from @Query rows, so a view has no membership rule of its own to get wrong (#863),
    // and so applying a correction re-derives every surface showing it rather than waiting for a relaunch.
    init(promotedRows: [PromotedProducer], demotedRows: [DemotedHouse]) {
        self.init(promoted: Set(promotedRows.map(\.orgKey)),
                  demoted: Set(demotedRows.map(\.orgKey)))
    }

    init(promoted: Set<String> = [], demoted: Set<String> = []) {
        self.promoted = promoted
        self.demoted = demoted
    }
}

// Applying and taking back a correction, kept OUT of the view that draws the action, for the same reason
// ExcludedTownEditing and WatchlistEditing are: a rule stated in a SwiftUI body is a rule no test can
// reach, and #863 is this repo's proof that such rules drift under a fully green suite.
@MainActor
enum ProducerOverrideEditing {
    enum Result: Equatable, Sendable {
        case promoted
        case demoted
        case alreadyPromoted
        case alreadyDemoted
        case noOrganisation   // nothing the gate can key, so nothing to correct
    }

    // What correction is in force for one organisation. What the inline control reads to decide which
    // action to offer and which to show as standing.
    enum Standing: Equatable, Sendable {
        case none
        case promoted
        case demoted
    }

    // The one fold both the store and the gate agree on. Deliberately ProducerGate.key itself rather than
    // a copy: a second normalization is exactly how the stored key and the looked-up key drift apart, and
    // the drift is silent because a set that never matches looks like a set that is empty.
    nonisolated static func normalize(_ raw: String) -> String? {
        ProducerGate.key(raw)
    }

    @discardableResult
    static func promote(_ raw: String, into context: ModelContext) -> Result {
        guard let key = normalize(raw) else { return .noOrganisation }
        if promoted(in: context).contains(key) { return .alreadyPromoted }
        // Mutual exclusion: the last thing Dan said is the thing in force, and the store never holds a
        // contradiction he cannot see.
        removeDemotion(key, in: context)
        context.insert(PromotedProducer(orgKey: key))
        try? context.save()
        return .promoted
    }

    @discardableResult
    static func demote(_ raw: String, into context: ModelContext) -> Result {
        guard let key = normalize(raw) else { return .noOrganisation }
        if demoted(in: context).contains(key) { return .alreadyDemoted }
        removePromotion(key, in: context)
        context.insert(DemotedHouse(orgKey: key))
        try? context.save()
        return .demoted
    }

    // The way back (#845): the same correction, reversed, in whichever direction it was made.
    static func clear(_ raw: String, in context: ModelContext) {
        guard let key = normalize(raw) else { return }
        removePromotion(key, in: context)
        removeDemotion(key, in: context)
        try? context.save()
    }

    static func standing(for raw: String, in context: ModelContext) -> Standing {
        guard let key = normalize(raw) else { return .none }
        if demoted(in: context).contains(key) { return .demoted }
        if promoted(in: context).contains(key) { return .promoted }
        return .none
    }

    // What every ProducerGate call site reads: both directions in one trip, from the store the caller
    // already holds. Every consumer loads it HERE rather than being handed it, following the same rule
    // ScoutService states for VenueBrands: read it where the corpus is read, so no caller can forget.
    // nonisolated, like the four readers below: applying a correction is a UI action and stays on the
    // main actor, but READING one happens wherever the corpus is read, and two of those callers
    // (ScoutService's sweep, PossibleMatchRecheck) are background work. Making the whole enum main-actor
    // would have forced those to either hop or skip the overrides, and skipping is #1679 all over again.
    nonisolated static func overrides(in context: ModelContext) -> ProducerOverrides {
        ProducerOverrides(promoted: promoted(in: context), demoted: demoted(in: context))
    }

    nonisolated static func promoted(in context: ModelContext) -> Set<String> {
        Set(promotedRows(in: context).map(\.orgKey))
    }

    nonisolated static func demoted(in context: ModelContext) -> Set<String> {
        Set(demotedRows(in: context).map(\.orgKey))
    }

    nonisolated static func promotedRows(in context: ModelContext) -> [PromotedProducer] {
        (try? context.fetch(FetchDescriptor<PromotedProducer>(sortBy: [SortDescriptor(\.orgKey)]))) ?? []
    }

    nonisolated static func demotedRows(in context: ModelContext) -> [DemotedHouse] {
        (try? context.fetch(FetchDescriptor<DemotedHouse>(sortBy: [SortDescriptor(\.orgKey)]))) ?? []
    }

    private static func removePromotion(_ key: String, in context: ModelContext) {
        for row in promotedRows(in: context) where row.orgKey == key { context.delete(row) }
    }

    private static func removeDemotion(_ key: String, in context: ModelContext) {
        for row in demotedRows(in: context) where row.orgKey == key { context.delete(row) }
    }
}
