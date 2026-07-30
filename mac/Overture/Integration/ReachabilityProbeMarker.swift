import Foundation

// #1308 Layer 2: a small side marker written when a reachability probe launches, recording WHICH shows the
// probe is researching. A probe reuses the same detached runner and results file as a normal Prep, so on
// completion the app needs its own record to know (a) the finished run was a probe, not a prep, and (b)
// which shows to mark probed, even if the run produced an empty results file (a total miss). Written on
// launch, read and cleared on completion. Its PRESENCE is what tells the completion path "this was a probe".
struct ReachabilityProbeMarker: Codable, Equatable, Sendable {
    var keys: Set<String>
    var startedAt: String
    // #1677/#1809: how many times settling this run has been attempted and failed to SAVE. A settle whose
    // stamp cannot commit leaves the marker in place so the run tries again (the run is not finished if the
    // record of it did not land), and this is what stops that becoming a forever loop.
    //
    // OPTIONAL, and it has to be: Swift's synthesized decoding does not apply a property's default value,
    // so a non-optional here would fail to decode every marker written before this field existed, which is
    // exactly the paid run whose answers this field was added to protect.
    var settleAttempts: Int?

    // Dan's call (2026-07-30): retry, but give up rather than trying forever. Three is enough to ride out a
    // transient lock or a store busy behind another writer, and few enough that a genuinely broken store is
    // reported and closed out rather than re-announcing on every launch until he notices.
    static let maxSettleAttempts = 3

    static func write(_ marker: ReachabilityProbeMarker, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try JSONEncoder().encode(marker).write(to: url, options: .atomic)
    }

    // nil when absent (no probe was launched) or unreadable, so the completion path falls back to the
    // normal prep ingest rather than guessing.
    static func read(from url: URL) throws -> ReachabilityProbeMarker? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try JSONDecoder().decode(ReachabilityProbeMarker.self, from: data)
    }

    static func clear(at url: URL) {
        try? FileManager.default.removeItem(at: url)
    }
}
