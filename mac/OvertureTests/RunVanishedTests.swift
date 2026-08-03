import Testing
import Foundation
import SwiftData

// #856: a detached run that exits without results writes an honest failure, instead of vanishing.
//
// Three times in one evening a run did real work and produced nothing usable: it stopped to ask a
// question (#847), it hit a broken prompt (#853), and in between it left the app polling for a file that
// never came (#848). Each time the fix was to instruct the model better. Instructions are not a
// guarantee, and "the run vanished" should not be a state the app can be in.
//
// The runner script now speaks for every source it queued (see lib/results-guard.sh, tested in
// results-guard.test.sh). This is the app's half: what `not_read` MEANS when it arrives.
//
// It is deliberately not `unreadable`. Those are different failures and must never look alike:
// `unreadable` means the page itself is broken, and the app says so to Dan in those exact words ("that
// calendar is drawn by JavaScript"). A page nobody looked at is not a broken page. Telling him a healthy
// calendar was JavaScript-drawn would send him to fix a page that was never the problem, and teach him
// to distrust the failing section, which is precisely where the genuinely broken source has to be seen.
@MainActor
@Suite("A run that exits without results reports an honest failure (#856)")
struct RunVanishedTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func context() throws -> ModelContext {
        ModelContext(try ModelContainer(for: Schema([Prospect.self, WatchedSource.self]),
                                        configurations: [ModelConfiguration(isStoredInMemoryOnly: true)]))
    }

    @discardableResult
    private func queuedSource(_ ctx: ModelContext, id: String = "kaufman") -> WatchedSource {
        let s = WatchedSource(sourceId: id, orgName: "Kaufman Music Center",
                              listingsURL: "https://\(id).example/events", kind: .html)
        s.lastContentHash = "old-hash"
        s.pendingContentHash = "new-hash"
        s.hasUnreadChanges = true
        ctx.insert(s)
        return s
    }

    private func results(_ sourceId: String, verdict: PageVerdict, note: String? = nil) -> ScoutExtractResults {
        ScoutExtractResults(version: 1, generatedAt: "2026-07-12T00:00:00Z",
                            results: [ScoutExtractResult(sourceId: sourceId, verdict: verdict,
                                                         events: [], note: note)])
    }

    // MARK: - What `not_read` means

    // The whole point of the verdict: the page has NOT been read, so it must be read next time. Stamping
    // the hash here would be the single worst thing the watchlist can do: the source would report as
    // healthy and unchanged forever, having never once been read.
    @Test func aSourceTheRunNeverReachedIsTriedAgainRatherThanSkippedForever() throws {
        let ctx = try context()
        let source = queuedSource(ctx)

        ScoutExtractIngest.ingest(results("kaufman", verdict: .notRead),
                                  clients: [], history: [], blocked: .empty, now: now, into: ctx)

        #expect(source.lastContentHash == "old-hash", "the hash of a page nobody read must never be stamped")
        #expect(source.hasUnreadChanges, "there is still something on that page we have not read")
        #expect(source.health == .failing)
        #expect(source.lastFailure == .verdict(.notRead))
    }

    // It must be LOUD. A run that lost a source and said nothing is the bug; a run that lost a source and
    // named it is the fix.
    @Test func theLostSourceIsNamedToDan() throws {
        let ctx = try context()
        queuedSource(ctx)

        let outcome = ScoutExtractIngest.ingest(results("kaufman", verdict: .notRead),
                                                clients: [], history: [], blocked: .empty, now: now, into: ctx)

        let warning = try #require(outcome.warning)
        #expect(warning.contains("Kaufman Music Center"))
    }

    // The sentence Dan actually reads has to be TRUE. `unreadable` tells him the calendar is drawn by
    // JavaScript; saying that about a page the run never opened would send him to fix a page that was
    // never broken.
    @Test func itNeverClaimsTheCalendarIsBroken() {
        let message = SourceFailure.verdict(.notRead).message

        #expect(!message.contains("JavaScript"))
        #expect(message.lowercased().contains("not been read") || message.lowercased().contains("did not read"))
        #expect(message != SourceFailure.verdict(.unreadable).message,
                "a dead run and a broken calendar must never read the same")
    }

    // A source the run DID read still lands normally. The guard speaks only for what came back missing.
    @Test func aSourceTheRunDidReadIsUnaffected() throws {
        let ctx = try context()
        let source = queuedSource(ctx)

        ScoutExtractIngest.ingest(results("kaufman", verdict: .allPast),
                                  clients: [], history: [], blocked: .empty, now: now, into: ctx)

        #expect(source.lastContentHash == "new-hash", "a page we genuinely read is stamped")
        #expect(source.hasUnreadChanges == false)
        #expect(source.health != .failing, "a quiet off-season is not a failure")
    }

    // MARK: - The contract

    // The verdict crosses a file boundary written by a script and read by the app (docs/contracts.md), so
    // the wire spelling is load-bearing: a typo here is a results file the app silently rejects, which is
    // the exact silence #856 exists to end.
    @Test func theWireSpellingIsPinned() throws {
        #expect(PageVerdict.notRead.rawValue == "not_read")

        let json = """
        {"version":1,"generatedAt":"2026-07-12T00:00:00Z","results":[
          {"sourceId":"kaufman","verdict":"not_read","events":[],
           "note":"The run exited with status 137 and produced no results for this source."}]}
        """
        let decoded = try ScoutExtractResultsDecoder.decode(Data(json.utf8))

        #expect(decoded.results.first?.verdict == .notRead)
        #expect(decoded.results.first?.note?.contains("137") == true)
    }

    // The model is told four verdicts and is never asked to write this one: the script writes it, about a
    // run the model was not around to report on. If it ever leaked into the runbook the model could start
    // claiming it read nothing, which is a claim only the script is in a position to make.
    @Test func theRunbookNeverOffersThisVerdictToTheModel() {
        let runbook = SourceGuardHelper.source("../docs/scout-extract-runbook.md")
        #expect(!runbook.contains("not_read"))
    }
}
