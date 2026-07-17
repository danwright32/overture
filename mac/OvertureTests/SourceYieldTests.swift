import Testing
import Foundation
import SwiftData
@testable import Overture

// #794: which watched sources actually earn their place.
//
// A source can extract perfectly and still produce nothing Dan would ever photograph (the #770 spike
// found Symphony Space returns twelve upcoming events that are almost all film screenings and literary
// talks). Judged on shows FOUND, such a source looks busy; judged on shows KEPT, it is dead weight. This
// is the lifetime funnel per source, computed here as a pure function rather than inside the Sources
// sheet, so the rule the sheet shows has a test and cannot drift under a green suite (#863, #885).
//
// It deliberately removes nothing: per Dan's rule only a refusal (or his explicit removal) takes a source
// off the list. This makes dead weight VISIBLE, and leaves the decision his.
@Suite("A watched source's lifetime yield (#794)")
struct SourceYieldTests {

    private func show(_ key: String, sources: [String], status: ReviewStatus = .new,
                      sent: Bool = false, outcome: Outcome = .noResponse) -> Prospect {
        let p = Prospect(naturalKey: key, groupName: key, discipline: "music", venue: "V",
                         performanceDate: "2026-09-19", sourceListingURL: nil, websiteURL: nil,
                         priorRelationship: "none", production: "concert", profile: "unknown",
                         coverage: "unknown", fitScore: 50, tier: "medium", fitReason: "r",
                         matchedClientName: nil, possibleMatchSource: nil, possibleMatchName: nil,
                         status: status)
        p.sourceIds = sources
        p.outcome = outcome
        if sent { p.sentAt = Date(timeIntervalSince1970: 1_000) }
        return p
    }

    // Found is every show this source surfaced, whatever became of it. A show surfaced by a DIFFERENT
    // source contributes nothing here.
    @Test func countsOnlyTheShowsThisSourceSurfaced() {
        let prospects = [
            show("a", sources: ["carnegie"]),
            show("b", sources: ["carnegie"]),
            show("c", sources: ["symphony-space"]),
        ]
        #expect(SourceYield.tally(sourceId: "carnegie", in: prospects).found == 2)
        #expect(SourceYield.tally(sourceId: "symphony-space", in: prospects).found == 1)
    }

    // The funnel is cumulative: a booked show is also sent, approved, and kept; a sent show is also
    // approved and kept. So found >= kept >= approved >= sent >= booked always holds, and the reader can
    // never see "1 sent" above "0 kept".
    @Test func theFunnelIsCumulativeAndMonotonic() {
        let prospects = [
            show("new", sources: ["s"], status: .new),
            show("kept", sources: ["s"], status: .queued),
            show("approved", sources: ["s"], status: .approved),
            show("sent", sources: ["s"], status: .contacted, sent: true),
            show("booked", sources: ["s"], status: .contacted, sent: true, outcome: .booked),
        ]
        let t = SourceYield.tally(sourceId: "s", in: prospects)
        #expect(t.found == 5)
        #expect(t.unreviewed == 1) // the untouched .new one, and only it
        #expect(t.kept == 4)      // everything but the untouched .new one
        #expect(t.approved == 3)  // approved, sent, booked
        #expect(t.sent == 2)      // sent, booked
        #expect(t.booked == 1)
        #expect(t.found >= t.kept && t.kept >= t.approved && t.approved >= t.sent && t.sent >= t.booked)
    }

    // The regression case that would break monotonicity if kept were read from status alone: a show sent
    // and LATER dismissed keeps status .dismissed, but it was still sent, so it still counts as sent (and
    // therefore as kept and approved). Otherwise the sheet would show sent above a smaller kept.
    @Test func aShowDismissedAfterSendStillCountsAsSent() {
        let prospects = [show("x", sources: ["s"], status: .dismissed, sent: true)]
        let t = SourceYield.tally(sourceId: "s", in: prospects)
        #expect(t.sent == 1)
        #expect(t.approved == 1)
        #expect(t.kept == 1)
    }

    // A show Dan dismissed before ever keeping it did not earn the source anything: he decided not to
    // pursue it. It counts as found, never as kept.
    @Test func aShowDismissedBeforeKeepingCountsOnlyAsFound() {
        let prospects = [show("x", sources: ["s"], status: .dismissed)]
        let t = SourceYield.tally(sourceId: "s", in: prospects)
        #expect(t.found == 1)
        #expect(t.kept == 0)
    }

    // A show surfaced by two sources (the upsert merges a venue's calendar and the presenter's own site
    // into one row) credits BOTH: each source genuinely did surface it.
    @Test func aMergedShowCreditsEverySourceThatSurfacedIt() {
        let prospects = [show("shared", sources: ["carnegie", "presenter-b"], status: .queued)]
        #expect(SourceYield.tally(sourceId: "carnegie", in: prospects).kept == 1)
        #expect(SourceYield.tally(sourceId: "presenter-b", in: prospects).kept == 1)
    }

    // With everything reviewed (nothing waiting), the line is the lifetime kept ratio, kept-first:
    // "3 of 12 kept after review", with sent and booked appended only when they are above zero (his choice), so the
    // common case stays quiet. The denominator is the shows he has REVIEWED, which here is all of them.
    @Test func theLineLeadsWithTheKeptRatioOnceEverythingIsReviewed() {
        var t = SourceYield.Tally(found: 12, unreviewed: 0, kept: 3, approved: 2, sent: 1, booked: 1)
        #expect(SourceYield.line(t) == "3 of 12 kept after review · 1 sent · 1 booked")

        t = SourceYield.Tally(found: 4, unreviewed: 0, kept: 2, approved: 0, sent: 0, booked: 0)
        #expect(SourceYield.line(t) == "2 of 4 kept after review")

        t = SourceYield.Tally(found: 5, unreviewed: 0, kept: 3, approved: 2, sent: 2, booked: 0)
        #expect(SourceYield.line(t) == "3 of 5 kept after review · 2 sent")
    }

    // #1029: a freshly scouted source is ALL unreviewed. It must read as the shows waiting for Dan, not
    // as "0 of N kept": nothing has been reviewed, so nothing has been kept OR passed over. This is the
    // 54 Below case ("extensive shows through August, only 5 counted and 0 kept") the issue is about.
    @Test func aFreshlyScoutedSourceReadsAsShowsWaitingNotZeroKept() {
        let t = SourceYield.Tally(found: 8, unreviewed: 8, kept: 0, approved: 0, sent: 0, booked: 0)
        #expect(SourceYield.line(t) == "8 new shows waiting for you")
        // The old wording must be gone: a fresh source is not dead weight.
        #expect(SourceYield.line(t) != "0 of 8 kept after review")
    }

    // #1029: one waiting show reads in the singular, not "1 new shows waiting for you".
    @Test func oneWaitingShowReadsInTheSingular() {
        let t = SourceYield.Tally(found: 1, unreviewed: 1, kept: 0, approved: 0, sent: 0, booked: 0)
        #expect(SourceYield.line(t) == "1 new show waiting for you")
    }

    // #1029: the two states the issue forbids collapsing. "Not reviewed yet" (all `.new`) and "reviewed
    // and kept none" (all reviewed, none kept) are dead weight only in the SECOND case, and they read as
    // two different sentences.
    @Test func notReviewedYetAndReviewedKeptNoneReadDifferently() {
        let waiting = SourceYield.Tally(found: 8, unreviewed: 8, kept: 0, approved: 0, sent: 0, booked: 0)
        let deadWeight = SourceYield.Tally(found: 8, unreviewed: 0, kept: 0, approved: 0, sent: 0, booked: 0)
        #expect(SourceYield.line(waiting) == "8 new shows waiting for you")
        #expect(SourceYield.line(deadWeight) == "0 of 8 kept after review")
        #expect(SourceYield.line(waiting) != SourceYield.line(deadWeight))
    }

    // Dead weight: found many, all REVIEWED, kept none. The line says so plainly rather than staying
    // silent, because making this visible is the entire point of the feature (#794).
    @Test func deadWeightReadsZeroOfManyOnceReviewed() {
        let t = SourceYield.Tally(found: 12, unreviewed: 0, kept: 0, approved: 0, sent: 0, booked: 0)
        #expect(SourceYield.line(t) == "0 of 12 kept after review")
    }

    // #1029: a source with both a review history AND new shows shows BOTH facts: what to do now, and
    // what it has earned. The kept ratio's denominator is the REVIEWED shows (here 4), never the found
    // total, or the 5 still waiting would read as shows he looked at and passed over. The sent suffix
    // carries through the combined line just as it does the standalone one.
    @Test func aSourceWithBothWaitingAndKeptShowsBoth() {
        let t = SourceYield.Tally(found: 9, unreviewed: 5, kept: 3, approved: 3, sent: 1, booked: 0)
        #expect(SourceYield.line(t) == "5 new shows waiting for you · 3 of 4 kept after review · 1 sent")
    }

    // A source that has surfaced nothing yet says nothing at all: "0 of 0 kept after review" would read like a
    // failure, and a brand-new or off-season source is neither dead weight nor broken.
    @Test func aSourceThatFoundNothingSaysNothing() {
        let t = SourceYield.Tally(found: 0, unreviewed: 0, kept: 0, approved: 0, sent: 0, booked: 0)
        #expect(SourceYield.line(t) == nil)
        #expect(SourceYield.line(SourceYield.tally(sourceId: "s", in: [])) == nil)
    }

    // #1029, against NAMED rows through the real tally rather than a hand-built Tally, so the test pins
    // what the sheet renders and not the function restating its own definition (#996). A source whose
    // three shows are all still `.new` reads as waiting; the same source once all three are dismissed
    // reads as dead weight.
    @Test func namedRowsRenderWaitingWhileNewAndDeadWeightOnceDismissed() {
        let waiting = [show("a", sources: ["s"], status: .new),
                       show("b", sources: ["s"], status: .new),
                       show("c", sources: ["s"], status: .new)]
        #expect(SourceYield.line(SourceYield.tally(sourceId: "s", in: waiting))
                == "3 new shows waiting for you")

        let reviewedKeptNone = [show("a", sources: ["s"], status: .dismissed),
                                show("b", sources: ["s"], status: .dismissed),
                                show("c", sources: ["s"], status: .dismissed)]
        #expect(SourceYield.line(SourceYield.tally(sourceId: "s", in: reviewedKeptNone))
                == "0 of 3 kept after review")
    }
}
