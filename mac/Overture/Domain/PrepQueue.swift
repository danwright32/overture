import Foundation
import SwiftData

// The work-list the app hands to the Prep run: which kept prospects need a contact
// and a draft. `naturalKey` is an OPAQUE token the run must echo back verbatim into
// PrepResults (never reconstruct it; that is what caused the silent-mismatch risk).
// The human-readable fields are for the run's research only.

struct PrepQueue: Codable, Equatable, Sendable {
    var version: Int
    var generatedAt: String
    var items: [PrepQueueItem]
}

struct PrepQueueItem: Codable, Equatable, Sendable {
    var naturalKey: String        // opaque; echo verbatim, do NOT rebuild
    var groupName: String         // research only
    var venue: String?
    var performanceDate: String?
    var discipline: String
    var websiteURL: String?
    var sourceListingURL: String?
    var possibleMatchName: String?
    var priorRelationship: String
    var production: String?       // v2 (#586): self | agency | unknown, from Prospect.production/#349
    // v3 (#367): "draft_only" | "contacts_only", absent means do both. Set only for a prospect Dan
    // asked to re-prep; tells the run which half to skip for this item.
    var reprepMode: String? = nil
}

enum PrepQueueBuilder {
    static let version = 3

    // A prospect is "to prep" when Dan kept it (.queued) and it has no draft yet, OR (#367) he
    // explicitly asked for a re-prep on a prospect that already has one, restricted to statuses
    // that still make sense to redraft/re-research (never .contacted or .dismissed). This is the
    // single source of truth every other eligibility check below should call, plain-Swift call
    // sites can call this function directly; the one SwiftData #Predicate-driven @Query
    // (RootView's "Prep kept" button gate) can't call an arbitrary function from inside a
    // #Predicate macro, so needsPrepPredicate below expresses the SAME logic as a standalone
    // Predicate value and PrepQueueEligibilityParityTests pins the two never drifting apart.
    static func needsPrep(status: ReviewStatus, hasDraft: Bool,
                          reprepDraftRequested: Bool = false,
                          reprepContactsRequested: Bool = false) -> Bool {
        if status == .queued && !hasDraft { return true }
        let reprepEligible = status == .queued || status == .drafted || status == .approved
        return reprepEligible && (reprepDraftRequested || reprepContactsRequested)
    }

    // A (Prospect) -> Bool wrapper over needsPrep, for passing straight to `.filter(...)` instead
    // of a closure with named arguments and defaults (the latter is slow enough for the Swift
    // type-checker to warn about in a plain-array `.filter { ... }`, this form checks instantly).
    static func needsPrepEligible(_ p: Prospect) -> Bool {
        needsPrep(status: p.status, hasDraft: p.hasDraft,
                 reprepDraftRequested: p.reprepDraftRequested,
                 reprepContactsRequested: p.reprepContactsRequested)
    }

    // The #Predicate mirror of needsPrep above, for the one call site (RootView's toPrep @Query)
    // that needs a compiled SwiftData predicate rather than a plain Swift function. Kept as a
    // single named, shared value so there is exactly one place this expression lives, not one
    // reinvented inline in RootView.swift.
    static var needsPrepPredicate: Predicate<Prospect> {
        #Predicate<Prospect> { p in
            (p.statusRaw == "queued" && p.draftBody == nil)
            || ((p.reprepDraftRequested || p.reprepContactsRequested)
                && (p.statusRaw == "queued" || p.statusRaw == "drafted" || p.statusRaw == "approved"))
        }
    }

    // #367: the wire value for a queue item's reprepMode, derived from the prospect's two
    // independent flags. Both true (a "both" request) or both false (a normal, never-drafted
    // prospect) both mean "do both", so both collapse to nil, exactly as an absent field always
    // has: the run's default behavior.
    static func reprepModeString(draftRequested: Bool, contactsRequested: Bool) -> String? {
        switch (draftRequested, contactsRequested) {
        case (true, false): return "draft_only"
        case (false, true): return "contacts_only"
        default: return nil
        }
    }

    static func build(from prospects: [PrepQueueItem], generatedAt: String) -> PrepQueue {
        PrepQueue(version: version, generatedAt: generatedAt, items: prospects)
    }

    static func encode(_ queue: PrepQueue) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(queue)
    }

    static var defaultURL: URL {
        StoreLocation.handoffDirectory
            .appendingPathComponent("overture-prep-queue.json")
    }
}
