import Testing
import Foundation
import SwiftData
@testable import Overture

// #800 / #768: a source Overture re-checks every run. Carnegie stops being hardcoded and becomes row
// one of this table.
//
// The two fields these tests defend hardest are `isActive` and `health`, and the point of the pair is
// that they are SEPARATE. Dan named the confusion he fears: a source that is merely broken must never
// read as "they asked us to stop". One status enum would make that confusion representable, and every
// future UI change would be one careless `if !isActive` away from committing it.
@MainActor
@Suite("WatchedSource, the watchlist's row (#800)")
struct WatchedSourceTests {
    private func context() throws -> ModelContext {
        ModelContext(try ModelContainer(for: Schema([WatchedSource.self]),
                                        configurations: [ModelConfiguration(isStoredInMemoryOnly: true)]))
    }

    @Test func aSourceRoundTripsThroughTheStore() throws {
        let ctx = try context()
        ctx.insert(WatchedSource(sourceId: "bargemusic", orgName: "Bargemusic",
                                 listingsURL: "https://bargemusic.org/events", kind: .html))
        try ctx.save()

        let stored = try #require(try ctx.fetch(FetchDescriptor<WatchedSource>()).first)
        #expect(stored.orgName == "Bargemusic")
        #expect(stored.kind == .html)
        #expect(stored.isActive)                       // a new source is watched
        #expect(stored.inactiveReason == nil)
        #expect(stored.health == .neverChecked)        // and has no health record of its own yet
        #expect(stored.lastFailure == nil)
        #expect(stored.lastContentHash == nil)
        #expect(stored.successfulCheckCount == 0)
    }

    // sourceId is the identity every prospect's `sourceIds` points at, so two rows can never share one.
    @Test func sourceIdIsUnique() throws {
        let ctx = try context()
        ctx.insert(WatchedSource(sourceId: "dup", orgName: "First", kind: .html))
        ctx.insert(WatchedSource(sourceId: "dup", orgName: "Second", kind: .html))
        try ctx.save()

        #expect(try ctx.fetch(FetchDescriptor<WatchedSource>()).count == 1)
    }

    // The distinction Dan asked for, held apart at the level of the data rather than the UI.
    @Test func brokenAndStoppedAreDifferentStates() throws {
        let ctx = try context()
        let broken = WatchedSource(sourceId: "broken", orgName: "Broken Org", kind: .html)
        broken.health = .failing
        broken.lastFailure = .fetch(.http(404))
        let stopped = WatchedSource(sourceId: "stopped", orgName: "Stopped Org", kind: .html)
        stopped.isActive = false
        stopped.inactiveReason = .orgRefusal
        ctx.insert(broken)
        ctx.insert(stopped)
        try ctx.save()

        // A broken source is still being watched. It reports as failing, every run, and nothing
        // deactivates it: only Dan or the org can do that.
        #expect(broken.isActive)
        #expect(broken.health == .failing)
        #expect(broken.inactiveReason == nil)

        // A source that asked to be left alone is not "failing". There is nothing wrong with it.
        #expect(stopped.isActive == false)
        #expect(stopped.inactiveReason == .orgRefusal)
        #expect(stopped.health == .neverChecked)
    }

    // A source Dan removed because it was permanently dead is NOT a source that refused him. Phase 5's
    // unmark must never silently resurrect the former, so the reason has to survive the round trip.
    @Test func removedByDanIsNotAnOrgRefusal() throws {
        let ctx = try context()
        let dead = WatchedSource(sourceId: "dead", orgName: "Dead Site", kind: .html)
        dead.isActive = false
        dead.inactiveReason = .removedByDan
        ctx.insert(dead)
        try ctx.save()

        let stored = try #require(try ctx.fetch(FetchDescriptor<WatchedSource>()).first)
        #expect(stored.inactiveReason == .removedByDan)
        #expect(stored.inactiveReason != .orgRefusal)
    }

    // The dispatch rule Phase 4's loop has to honor, stated here as a property of the row so that loop
    // cannot be written any other way. Carnegie's endpoint is a POST search API needing two auth
    // headers and a JSON body: SourceFetcher cannot GET it, hash it, or diff it. Steps 1 to 4 of the
    // html path (fetch, hash, budget, queue) must never run against it.
    @Test func onlyAnHtmlSourceIsFetchedGenerically() {
        let carnegie = WatchedSource(sourceId: WatchedSource.carnegieId, orgName: "Carnegie Hall",
                                     kind: .algolia)
        let org = WatchedSource(sourceId: "org", orgName: "Some Org", kind: .html)

        #expect(carnegie.usesNativeExtractor)
        #expect(carnegie.isGenericallyFetchable == false)
        #expect(org.usesNativeExtractor == false)
        #expect(org.isGenericallyFetchable)
    }
}

// The named reason a check produced no usable listings. Deliberately NOT a third hand-written list of
// error names: it is derived from the two types that already own these facts, so it cannot drift away
// from what the fetcher actually throws or what the extractor actually reports.
@Suite("A source's failure is typed and named (#800)")
struct SourceFailureTests {
    @Test func everyFailureRoundTripsThroughItsStoredString() {
        let cases: [SourceFailure] = [
            .fetch(.http(401)), .fetch(.http(429)), .fetch(.unreachable),
            .fetch(.notHTML("application/pdf")), .fetch(.redirectedAway("thirdstreetmusicschool.org")),
            .verdict(.noDatedContent), .verdict(.unreadable),
        ]
        for failure in cases {
            #expect(SourceFailure(raw: failure.raw) == failure, "\(failure.raw) did not round-trip")
        }
    }

    // The payloads are what make a failure actionable rather than merely named, so they survive storage.
    @Test func aFailureNamesWhatWentWrong() {
        #expect(SourceFailure.fetch(.http(429)).message.contains("429"))
        #expect(SourceFailure.fetch(.redirectedAway("example.org")).message.contains("example.org"))
        #expect(SourceFailure.verdict(.unreadable).message.isEmpty == false)
    }

    // A quiet off-season is the NORMAL state (5 of the 7 spike sites, in July). It is not a failure,
    // and a row must not be able to record it as one, or Dan learns to ignore the failing section.
    @Test func aQuietOffSeasonIsNotAFailure() {
        #expect(SourceFailure(verdict: .allPast) == nil)
        #expect(SourceFailure(verdict: .upcomingListings) == nil)
        #expect(SourceFailure(verdict: .noDatedContent) == .verdict(.noDatedContent))
        #expect(SourceFailure(verdict: .unreadable) == .verdict(.unreadable))
    }

    // #1012: a partial read is not a failure either, unlike noDatedContent/unreadable/notRead. Real
    // events came back and are trustworthy enough to ingest; what must not happen is the hash latching,
    // which is handled by ScoutExtractIngest's own partial-check path, not by SourceFailure.
    @Test func aPartialReadIsNotAFailure() {
        #expect(SourceFailure(verdict: .incompleteExtraction) == nil)
    }

    @Test func anUnknownStoredStringIsRefusedRatherThanGuessed() {
        #expect(SourceFailure(raw: "wat") == nil)
        #expect(SourceFailure(raw: "") == nil)
    }
}
