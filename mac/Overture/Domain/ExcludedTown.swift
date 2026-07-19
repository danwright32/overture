import Foundation
import SwiftData

// #991: a town Dan has refused from inside the app, so the geography rule can finally learn.
//
// EventPlace.excludedTowns is the SEED: nineteen towns that are plainly out of range, so Dan does not
// have to refuse the obvious ones himself. This is the other half, the one the whole design turns on
// (#979): the exclude list starts permissive and ONLY his refusal narrows it. The gate reads the UNION
// of the seed and these rows at queue time, and because the verdict is derived rather than stored
// (#990), a fresh refusal re-decides every row at once with no migration.
//
// The shape is deliberately the watchlist's (#768): a SwiftData-only model that GROWS by an in-app add
// and is seeded once (here the seed lives in code, not as rows). Kept off source code so Dan can add a
// twentieth town without a developer, which was the entire point.
@Model
final class ExcludedTown {
    // Not `id`: PersistentModel already refines Identifiable through persistentModelID, and a stored
    // `var id` collides with it (the same convention as Prospect.naturalKey, WatchedSource.sourceId,
    // DayOff's fields). Stored NORMALIZED (lowercased, trimmed), so the unique constraint dedupes
    // "Boston" and "boston" and the resolver, which matches lowercased tokens, can compare directly.
    @Attribute(.unique) var town: String
    var addedAt: Date

    init(town: String, addedAt: Date = Date()) {
        self.town = town
        self.addedAt = addedAt
    }
}

// Adding and removing a refused town, kept OUT of the view that draws the action, for the same reason
// WatchlistEditing and DayOffEditing are: a rule stated in a SwiftUI body is a rule no test can reach,
// and this repo's #863 is the proof that such rules drift under a fully green suite.
@MainActor
enum ExcludedTownEditing {
    enum Result: Equatable, Sendable {
        case added
        case alreadyExcluded    // already on the seed list OR already stored. Either way, a no-op.
        case noTown             // nothing placeable to exclude (a blank string)
    }

    // The one normalization both storage and the resolver agree on, so "Boston", " boston " and
    // "BOSTON" are the same town everywhere.
    static func normalize(_ raw: String) -> String {
        raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    // Idempotent by construction: a town already covered by the seed OR already stored stores nothing
    // new, so the set can never carry a duplicate of what the union already excludes.
    @discardableResult
    static func exclude(town raw: String, into context: ModelContext) -> Result {
        let name = normalize(raw)
        guard !name.isEmpty else { return .noTown }
        if EventPlace.excludedTowns.contains(name) || names(in: context).contains(name) {
            return .alreadyExcluded
        }
        context.insert(ExcludedTown(town: name))
        try? context.save()
        return .added
    }

    // The way back (the #845 principle): the same refusal, reversed. Used by the Undo the banner offers,
    // so a mis-click never costs Dan a town he wanted, and a seed town (never a stored row) is simply
    // left alone.
    static func remove(town raw: String, in context: ModelContext) {
        let name = normalize(raw)
        guard let row = rows(in: context).first(where: { $0.town == name }) else { return }
        context.delete(row)
        try? context.save()
    }

    static func rows(in context: ModelContext) -> [ExcludedTown] {
        (try? context.fetch(FetchDescriptor<ExcludedTown>(sortBy: [SortDescriptor(\.town)]))) ?? []
    }

    // What the queue gate reads: the stored refusals as a plain lowercased set, unioned with the seed by
    // EventPlace at resolve time.
    static func names(in context: ModelContext) -> Set<String> {
        Set(rows(in: context).map(\.town))
    }
}

// #1118: the management surface's data, kept OUT of the view for the same reason the add/remove is (#863):
// a listing rule stated in a SwiftUI body is a rule no test can reach.
extension ExcludedTownEditing {
    // The two halves the "Skipped towns" sheet draws, held apart because Dan can only take back one of
    // them. The SEED (EventPlace.excludedTowns) is built into the app so he never had to refuse the obvious
    // far towns himself, and it lives in code, not as rows, so this sheet shows it but does not remove it.
    // His OWN refusals are the stored rows, his to take back. Both sorted here so the view has no ordering
    // or membership rule of its own to get wrong.
    struct Listing: Equatable, Sendable {
        var seed: [String]        // the built-in far towns, normalized, sorted
        var userAdded: [String]   // Dan's own stored refusals, normalized, sorted
    }

    static func listing(in context: ModelContext) -> Listing {
        Listing(seed: EventPlace.excludedTowns.sorted(),
                userAdded: rows(in: context).map(\.town).sorted())
    }

    // The town as Dan reads it. Towns are stored and seeded lowercased so the resolver can compare tokens
    // directly (see ExcludedTown.town); this is the one place a town is upper-cased, for display only.
    // `remove` lowercases its argument again, so handing this capitalized string back to it still matches
    // the stored row: the sheet never keeps a second normalization rule of its own.
    static func displayName(_ town: String) -> String {
        town.capitalized
    }
}
