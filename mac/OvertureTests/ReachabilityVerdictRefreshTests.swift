import Testing
import Foundation
import SwiftData

// Milestone 61 Phase 0.3, under Dan's decision 7 of 2026-08-31.
//
// A stored reachability verdict is what a check CONCLUDED, and it never updates on its own, so it drifts
// away from what the show holds. Measured on the live store 2026-08-31 against a WAL inclusive copy:
// 4 rows carry a stored `no_email_found` over a live route.
//
// Dan's call, 2026-08-31, on being shown the narrow option first: "why wouldn't we refresh all 690 of
// them? Shouldn't it be accurate?", and again after being shown that some shows would move DOWN and why.
//
// SCOPE, confirmed with him in the same session and deliberately narrower than the plan's version: this
// is a ONE TIME repair, not a rule change. `contactRouteForScoring` still reads the stored verdict, so
// the score still follows what the paid check concluded and a contact deleted by hand still does not
// move it. That is his 2026-08-13 call and it is NOT reversed here; the tests defending it in
// `HeldReachabilityVerdictTests` are therefore kept, not deleted. What this fixes is the accumulated
// drift, once.
//
// The MARKER is stamped before a single value is rewritten, because the contradiction between a negative
// verdict and a stored route is a fact nothing recorded deliberately, it is the evidence base for #3345
// and for Phase 5.2's second stratum, and this repair is what destroys it (L277, L223).
@MainActor
@Suite("Refresh every stored reachability verdict, once (#3356 Phase 0.3)")
struct ReachabilityVerdictRefreshTests {

    private func container() throws -> ModelContainer {
        try ModelContainer(for: Schema([Prospect.self, Recipient.self]),
                           configurations: [ModelConfiguration(isStoredInMemoryOnly: true)])
    }

    private func defaults() -> UserDefaults {
        // Its own suite per test, so one test's "already run" flag can never answer for another's, and
        // nothing touches this Mac's real defaults.
        let d = UserDefaults(suiteName: "refresh-\(UUID().uuidString)")!
        return d
    }

    @discardableResult
    private func show(_ ctx: ModelContext, _ name: String, stored: Reachability.ProbeResult?,
                      email: String? = nil, formURL: String? = nil,
                      sentAt: Date? = nil) -> Prospect {
        let key = Prospect.makeNaturalKey(groupName: name, performanceDate: "2027-04-18",
                                          venue: "Rowan Hall")
        let p = Prospect(naturalKey: key, groupName: name, discipline: "music", venue: "Rowan Hall",
                         performanceDate: "2027-04-18", sourceListingURL: nil, priorRelationship: "none",
                         production: "unknown", profile: "strong", coverage: "likely_uncovered",
                         fitScore: 6, tier: "mid", fitReason: "r", matchedClientName: nil,
                         possibleMatchSource: nil, possibleMatchName: nil, status: .new)
        ctx.insert(p)
        p.reachabilityResult = stored
        p.sentAt = sentAt
        if email != nil || formURL != nil {
            let r = Recipient(id: "r-\(name)", email: email, name: name, role: nil,
                              provenance: .performer, contactMethodRaw: "generic_inbox",
                              contactConfidenceRaw: "medium", contactFormURL: formURL,
                              contactSourceURL: nil)
            p.addRecipient(r)
        }
        try? ctx.save()
        return p
    }

    // The defect the repair exists for: a stored verdict saying no way in, over a row holding one.
    @Test func aStaleNegativeVerdictIsRefreshedToWhatTheRowHolds() throws {
        let ctx = ModelContext(try container())
        let p = show(ctx, "Stale Negative", stored: .noEmailFound,
                     email: "booking@kestrelquartet.example")

        let report = try #require(ReachabilityVerdictRefresh.run(in: ctx, defaults: defaults()))

        #expect(p.reachabilityResult == .emailFound)
        #expect(report.lifted == 1)
        #expect(report.lowered == 0)
    }

    // Dan was shown that some shows move DOWN and chose the refresh anyway, so this direction is part of
    // what he approved rather than an accident of it, and it is counted separately so he can see it.
    @Test func aVerdictOverAShowThatNoLongerHoldsAnythingIsLowered() throws {
        let ctx = ModelContext(try container())
        let p = show(ctx, "Emptied By Hand", stored: .emailFound)

        let report = try #require(ReachabilityVerdictRefresh.run(in: ctx, defaults: defaults()))

        #expect(p.reachabilityResult == .noEmailFound)
        #expect(report.lowered == 1)
        #expect(report.lifted == 0)
    }

    // Never checked stays never checked. `reachabilityResultFromRecipients` answers `noEmailFound` for a
    // show with no contacts, and a show nobody has looked at has none either, so refreshing
    // unconditionally would stamp a verdict no check ever reached onto every unchecked show in the store.
    // Never checked and checked-and-empty are different screens (L10, L11).
    @Test func aShowNobodyHasCheckedIsLeftAlone() throws {
        let ctx = ModelContext(try container())
        let p = show(ctx, "Never Checked", stored: nil)

        let report = try #require(ReachabilityVerdictRefresh.run(in: ctx, defaults: defaults()))

        #expect(p.reachabilityResult == nil)
        #expect(report.skippedNeverChecked == 1)
    }

    // A show already pitched keeps the verdict it went out under, matching the badge's own rule
    // (`reachabilityResultAsHeld` returns the stored value once `sentAt` is set). The record of what was
    // true when Dan wrote to them is history, not drift.
    @Test func aShowAlreadyPitchedKeepsTheVerdictItWentOutUnder() throws {
        let ctx = ModelContext(try container())
        let p = show(ctx, "Already Pitched", stored: .noEmailFound,
                     email: "booking@kestrelquartet.example", sentAt: Date())

        let report = try #require(ReachabilityVerdictRefresh.run(in: ctx, defaults: defaults()))

        #expect(p.reachabilityResult == .noEmailFound)
        #expect(report.skippedSentOrBooked == 1)
    }

    // The marker, stamped BEFORE anything is rewritten. Without it the repair destroys the only record
    // that the contradiction ever existed, which is the evidence Phase 5.2 measures against (L277).
    @Test func aContradictedRowIsMarkedBeforeItIsRepaired() throws {
        let ctx = ModelContext(try container())
        let p = show(ctx, "Contradicted", stored: .noEmailFound,
                     email: "booking@kestrelquartet.example")

        let report = try #require(ReachabilityVerdictRefresh.run(in: ctx, defaults: defaults()))

        #expect(p.contradictionMarkedAt != nil)
        #expect(report.marked == 1)
    }

    // A row whose negative verdict is CORRECT is not marked, or the marker would count every checked
    // show and measure nothing (L90).
    @Test func anHonestNegativeVerdictIsNotMarked() throws {
        let ctx = ModelContext(try container())
        let p = show(ctx, "Honestly Empty", stored: .noEmailFound)

        _ = ReachabilityVerdictRefresh.run(in: ctx, defaults: defaults())

        #expect(p.contradictionMarkedAt == nil)
    }

    // One time, as Dan chose. A second launch must not rewrite anything, or the repair becomes the rule
    // change he did not ask for.
    @Test func itRunsOnceAndReportsNothingOnASecondLaunch() throws {
        let ctx = ModelContext(try container())
        let d = defaults()
        let p = show(ctx, "Run Twice", stored: .noEmailFound,
                     email: "booking@kestrelquartet.example")

        #expect(ReachabilityVerdictRefresh.run(in: ctx, defaults: d) != nil)
        #expect(p.reachabilityResult == .emailFound)

        // Now emulate the drift the one-time scope deliberately accepts: the contacts go away again.
        p.setRecipients([])
        try? ctx.save()

        #expect(ReachabilityVerdictRefresh.run(in: ctx, defaults: d) == nil,
                "a second run is refused outright, so the verdict below is untouched")
        #expect(p.reachabilityResult == .emailFound,
                "the stored verdict still says what the check concluded, which is Dan's 2026-08-13 rule")
    }
}
