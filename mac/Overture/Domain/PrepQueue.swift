import Foundation

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
}

enum PrepQueueBuilder {
    static let version = 2

    // A prospect is "to prep" when Dan kept it (.queued) and it has no draft yet.
    // Already-drafted/approved ones are left alone so a re-run does not redo work.
    static func needsPrep(status: ReviewStatus, hasDraft: Bool) -> Bool {
        status == .queued && !hasDraft
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
