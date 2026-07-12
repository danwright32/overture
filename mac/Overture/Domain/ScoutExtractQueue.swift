import Foundation

// The work-list the app hands to the scout-extract run (#799): which watched sources' listings pages
// need reading. Mirrors PrepQueue, deliberately, so there is one convention for these handoffs and
// not two.
//
// `sourceId` is an OPAQUE token the run must echo back verbatim into the results. Never rebuild it.
// PrepQueue learned this the hard way ("that is what caused the silent-mismatch risk"): a key the run
// reconstructs matches nothing on the way back, and the work vanishes with no error anywhere.
//
// The run does NOT fetch the listings page. The app fetches it natively, writes it to disk, and hashes
// it, then points the run at that exact file (`pagePath`). That is what keeps the listing SET (which
// events exist, which are gone, the thing that re-keys prospects and drives reconcile) determined by
// bytes the app hashed, rather than by whatever a page happened to serve the agent a second later.
// The run may still follow each event's own detail page for the venue and the exact date, which the
// listings page usually does not carry (#770 spike, finding 4). A detail page is per-event enrichment,
// never the set.
struct ScoutExtractQueue: Codable, Equatable, Sendable {
    var version: Int
    var generatedAt: String
    var items: [ScoutExtractQueueItem]
}

struct ScoutExtractQueueItem: Codable, Equatable, Sendable {
    var sourceId: String        // opaque; echo verbatim, do NOT rebuild
    var orgName: String?        // research only: gives the run something to recognize on the page
    var listingsURL: String?    // where the pinned page came from; resolves the page's relative links
    var pagePath: String        // absolute path to the pinned HTML the run must Read
    // v2: return ONLY this organization's performances from this page, and ignore everything else on it.
    //
    // Set when the app had to follow a link OFF an org's own site (its page was unreadable) onto a
    // VENUE's page. A venue page is a page about many organizations: Lincoln Center's page for one
    // ensemble's concert also carries an "Alice Tully Hall upcoming events" sidebar. Without this, the
    // run returns the hall's other tenants (real shows, right hall, wrong org) and Dan is handed four
    // strangers' concerts to pitch. That happened.
    //
    // Absent means no constraint: Dan pasted a venue's calendar deliberately and every show on it counts,
    // because he is watching the hall, not one act.
    var onlyForOrg: String? = nil
}

enum ScoutExtractQueueBuilder {
    static let version = 2

    static func build(items: [ScoutExtractQueueItem], generatedAt: String) -> ScoutExtractQueue {
        ScoutExtractQueue(version: version, generatedAt: generatedAt, items: items)
    }

    static func encode(_ queue: ScoutExtractQueue) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(queue)
    }

    static var defaultURL: URL {
        StoreLocation.handoffDirectory
            .appendingPathComponent("overture-scout-extract-queue.json")
    }
}
