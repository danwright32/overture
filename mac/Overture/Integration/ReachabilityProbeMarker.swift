import Foundation

// #1308 Layer 2: a small side marker written when a reachability probe launches, recording WHICH shows the
// probe is researching. A probe reuses the same detached runner and results file as a normal Prep, so on
// completion the app needs its own record to know (a) the finished run was a probe, not a prep, and (b)
// which shows to mark probed, even if the run produced an empty results file (a total miss). Written on
// launch, read and cleared on completion. Its PRESENCE is what tells the completion path "this was a probe".
struct ReachabilityProbeMarker: Codable, Equatable, Sendable {
    var keys: Set<String>
    var startedAt: String

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
