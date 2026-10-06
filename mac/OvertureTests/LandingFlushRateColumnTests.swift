import Testing
import Foundation
import SwiftData

// #4338 (A10): `scripts/landing-flush-rate.sh` reads `LandingRun.entryFlushSaves` with SQL, by the column name
// SwiftData gives it, which is written in the script and in no other place. So the name is checked against the
// column a real store of THIS build has: a store is made on disk, a landing record saved into it, and its table
// read with sqlite3. The two sides come from two places (the script's text, the store SwiftData wrote), so a
// rename on either goes red here rather than leaving the script reporting every store as one from before #4338
// (L70, L46).
@MainActor
@Suite("The flush rate script reads the column this build stores the count in (#4338)")
final class LandingFlushRateColumnTests {
    private let sandboxes = TemporarySandboxes()

    private static func scriptColumn() throws -> String {
        let script = try String(contentsOf: RepoRoot.url.appendingPathComponent("scripts/landing-flush-rate.sh"),
                                encoding: .utf8)
        let prefix = "FLUSH_COLUMN=\""
        let line = try #require(script.split(separator: "\n").first { $0.hasPrefix(prefix) },
                                "the script names no FLUSH_COLUMN")
        return String(line.dropFirst(prefix.count).dropLast())
    }

    @Test func theColumnTheScriptReadsIsTheOneTheStoreHas() throws {
        let column = try Self.scriptColumn()
        let store = try sandboxes.make(named: "flush-rate-column").appendingPathComponent("Overture.store")
        let container = try FileStores.container(for: AppSchema.schema,
                                                 configurations: [ModelConfiguration(schema: AppSchema.schema, url: store,
                                                                                     cloudKitDatabase: .none)])
        let context = ModelContext(container)
        let run = LandingRun(runIdentity: "flush-rate-column", landedAt: Date(), sequence: 1,
                             entryPoint: .scoutExtractIngest, startedAt: Date())
        run.entryFlushSaves = 2
        context.insert(run)
        try context.save()

        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
        p.arguments = ["-readonly", store.path, "SELECT name FROM pragma_table_info('ZLANDINGRUN'); SELECT \(column) FROM ZLANDINGRUN;"]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = Pipe()
        try p.run()
        let text = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        p.waitUntilExit()
        let lines = text.split(separator: "\n").map(String.init)
        #expect(lines.contains(column), Comment(rawValue: "the store's columns: \(lines)"))
        #expect(lines.last == "2", "the column the script reads does not hold the count this build saved")
    }
}
