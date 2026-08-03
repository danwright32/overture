import Testing
import Foundation

// #1895 (part of #1887). The reader for the shoot-history handoff, and its health verdict.
//
// Health is not decoration here. The file is refreshed by a MANUAL export Dan has to remember to
// redo, so an old one under-reports every room he has shot since, and the pitch quietly says less
// than it could. Absent, unreadable and stale are three different facts and each gets its own
// answer (L11).
@Suite("Shoot history file")
struct ShootHistoryTests {

    private func write(_ json: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("shoot-history-\(UUID().uuidString).json")
        try json.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private let now = ISO8601DateFormatter().date(from: "2026-07-31T18:00:00Z")!

    @Test func readsShootsFromAWellFormedFile() throws {
        let url = try write("""
        {"version":1,"generatedAt":"2026-07-31T12:00:00.000Z",
         "shoots":[{"venue":"Jalopy Theatre","date":"2024-05-25","title":"[Smoke Show Quartet] The Smoke Show"}]}
        """)
        defer { try? FileManager.default.removeItem(at: url) }

        let loaded = ShootHistory.loadWithHealth(from: url, now: now)
        #expect(loaded.health == .ok)
        #expect(loaded.shoots == [
            ShootRecord(venue: "Jalopy Theatre", date: "2024-05-25",
                        title: "[Smoke Show Quartet] The Smoke Show"),
        ])
    }

    // An absent file is a NORMAL state: Dan has not run the import yet. It must not read as a
    // fault, and it must not read as "he has never shot anywhere" either.
    @Test func anAbsentFileIsMissingRatherThanUnreadable() {
        let url = URL(fileURLWithPath: "/nonexistent/overture-shoot-history.json")
        let loaded = ShootHistory.loadWithHealth(from: url, now: now)
        #expect(loaded.shoots.isEmpty)
        #expect(loaded.health == .missing)
    }

    // The #754 trap, in a new place: a corrupt file used to be indistinguishable from a fresh
    // install, so every venue silently read as never-shot with no symptom at all.
    @Test func acorruptFileIsUnreadableAndSaysSo() throws {
        let url = try write("{ this is not json")
        defer { try? FileManager.default.removeItem(at: url) }

        let loaded = ShootHistory.loadWithHealth(from: url, now: now)
        #expect(loaded.shoots.isEmpty)
        #expect(loaded.health == .unreadable)
        #expect(ShootHistory.warningText(for: loaded.health) != nil)
    }

    // A version this build does not know is unreadable, not silently half-read.
    @Test func afutureVersionIsUnreadable() throws {
        let url = try write("""
        {"version":99,"generatedAt":"2026-07-31T12:00:00.000Z","shoots":[]}
        """)
        defer { try? FileManager.default.removeItem(at: url) }

        #expect(ShootHistory.loadWithHealth(from: url, now: now).health == .unreadable)
    }

    // Staleness is judged from the file's OWN `generatedAt`, not its modification time, so
    // copying or restoring the file cannot make an old export look fresh.
    @Test func anOldExportIsStaleAndKeepsItsShootsAnyway() throws {
        let url = try write("""
        {"version":1,"generatedAt":"2026-01-01T12:00:00.000Z",
         "shoots":[{"venue":"Merkin Hall","date":"2024-01-20","title":"[Every Voice Choir] Peace Seekers XI"}]}
        """)
        defer { try? FileManager.default.removeItem(at: url) }

        let loaded = ShootHistory.loadWithHealth(from: url, now: now)
        #expect(loaded.health == .stale(ageDays: 211))
        // Stale is a warning, never a reason to throw away real history: an old count is still
        // a floor on how many times Dan has shot the room.
        #expect(loaded.shoots.count == 1)
        #expect(ShootHistory.warningText(for: loaded.health)?.contains("211") == true)
    }

    @Test func aFreshExportCarriesNoWarning() {
        #expect(ShootHistory.warningText(for: .ok) == nil)
    }

    // A file whose generatedAt cannot be parsed is not silently treated as fresh: an unreadable
    // timestamp lands on the cautious side rather than the reassuring one (L50).
    @Test func anUnparseableTimestampIsNotTreatedAsFresh() throws {
        let url = try write("""
        {"version":1,"generatedAt":"whenever","shoots":[]}
        """)
        defer { try? FileManager.default.removeItem(at: url) }

        #expect(ShootHistory.loadWithHealth(from: url, now: now).health == .unreadable)
    }
}
