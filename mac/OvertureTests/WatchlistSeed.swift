import Foundation
import SwiftData
@testable import Overture

// #359 one-time backfill helper. Reads the vetted list of presenters/venues (discovered from Dan's Google
// Calendar history) and adds each through the app's own WatchlistEditing.add, so every rule the hand-add
// path enforces (host de-dup, refusal, URL/name validation) applies here too. Lives in the test target: the
// app binary carries none of this.
enum WatchlistSeed {
    struct Entry: Decodable, Equatable {
        let orgName: String
        let listingsURL: String
    }

    struct Summary: Equatable {
        var added: [String] = []       // a fresh source now watched
        var resumed: [String] = []     // a source Dan had removed, revived rather than duplicated
        var duplicates: [String] = []  // same host as one already watched, skipped
        var refused: [String] = []     // org asked to stop; never re-added, by any route
        var invalid: [String] = []     // unusable URL or missing name, reported not silently dropped
    }

    static func decode(_ data: Data) throws -> [Entry] {
        try JSONDecoder().decode([Entry].self, from: data)
    }

    @MainActor
    static func importEntries(_ entries: [Entry], into context: ModelContext) -> Summary {
        var summary = Summary()
        for entry in entries {
            switch WatchlistEditing.add(orgName: entry.orgName, listingsURL: entry.listingsURL, into: context) {
            case .added:
                summary.added.append(entry.orgName)
            case .resumed:
                summary.resumed.append(entry.orgName)
            case .alreadyWatching:
                summary.duplicates.append(entry.orgName)
            case .refused:
                summary.refused.append(entry.orgName)
            case .invalidURL, .needsName:
                summary.invalid.append(entry.orgName)
            }
        }
        return summary
    }

    // Opens the store at `storeURL` with the app's EXACT schema (all four @Model types, matching
    // OvertureApp.init), imports the vetted JSON, and saves. Opening with the same schema the store was
    // created with is what keeps SwiftData from attempting a migration on the live data. Caller is
    // responsible for holding the single-writer lock (i.e. confirming the app is closed) around this.
    @MainActor
    static func runImport(storeURL: URL, jsonURL: URL) throws -> Summary {
        let schema = Schema([Prospect.self, Recipient.self, WatchedSource.self, DayOff.self])
        let container = try ModelContainer(
            for: schema,
            configurations: [ModelConfiguration(schema: schema, url: storeURL, cloudKitDatabase: .none)])
        let context = ModelContext(container)
        let entries = try decode(Data(contentsOf: jsonURL))
        let summary = importEntries(entries, into: context)
        try context.save()
        return summary
    }
}
