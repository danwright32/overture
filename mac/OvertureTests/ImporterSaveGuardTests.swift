import Testing
import Foundation

// Regression guard for #499: PrepImporter.ingest and ReplyClassifyImporter.ingest each swallow a
// context.save() failure with a bare try?, so a Prep or reply-classify run's results could
// silently fail to persist with no signal, unlike their existing unmatchedKeys field (already
// surfaced, never swallowed). Fixed to set Outcome.saveFailed on each, surfaced through
// RootView's existing statusMessage flow. Nothing else stops a future edit from quietly
// reverting either back to a bare try?, so this scans each function body specifically for that
// one forbidden shape reappearing.
@Suite("Importer save guard")
struct ImporterSaveGuardTests {

    private static let forbidden = "try? context.save()"

    @Test func prepImporterIngestNeverRevertsToSilentSave() throws {
        let prepImporter = RepoRoot.mac
            .appendingPathComponent("Overture/Persistence/PrepImporter.swift")
        let src = try String(contentsOf: prepImporter, encoding: .utf8)
        let body = try SourceGuard.functionBody(named: "ingest", in: src)
        #expect(!body.contains(Self.forbidden),
                "PrepImporter.ingest reintroduced a bare try? context.save(): a save failure must surface via Outcome.saveFailed, not fail silently (#499).")
    }

    @Test func replyClassifyImporterIngestNeverRevertsToSilentSave() throws {
        let replyClassifyImporter = RepoRoot.mac
            .appendingPathComponent("Overture/Persistence/ReplyClassifyImporter.swift")
        let src = try String(contentsOf: replyClassifyImporter, encoding: .utf8)
        let body = try SourceGuard.functionBody(named: "ingest", in: src)
        #expect(!body.contains(Self.forbidden),
                "ReplyClassifyImporter.ingest reintroduced a bare try? context.save(): a save failure must surface via Outcome.saveFailed, not fail silently (#499).")
    }
}
