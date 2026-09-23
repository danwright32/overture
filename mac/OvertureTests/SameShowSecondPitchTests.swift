import Testing
import Foundation
import SwiftData

// #3636, the outreach half. Dan asked directly, 2026-09-07: "if a show happens over multiple weekends
// from now until November and I pitch it once, what happens to the future recurrences in the scout
// queue? Does it come back?" For a source with no production id it does, as a second card, and nothing
// on the way OUT would tell him he had already pitched it.
//
// `DuplicateContactGuard` is the only net. Its window is 3 days:
//
//   private static let gapDays = 3  // mirrors RunGrouping's own window (#369)
//
// Every fragment of a multi-weekend run sits weeks apart, so the guard cannot fire on any of them.
//
// BOTH DECISION RECORDS WERE READ BEFORE THIS WAS WRITTEN, which #3636 asks for by name and which this
// repository has paid for skipping (L542). They do not conflict; they answer different questions, and
// one of them answers THIS one:
//
//   `RunGrouping.gapDays = 3` is "shared with EngagementLink ... and mirrored by DuplicateContactGuard
//   to pace how often Dan may contact one org. Deliberately NOT widened by #1558: those are different
//   questions, and nobody asked them." So the 3 was left deliberately, and the reason given is that
//   nobody had asked. #3636 is asking.
//
//   `RunGrouping.sameShowGapDays = 56` is "Dan's number, 2026-07-26 ... he pitches a run ONCE ('I'm not
//   going to send them an email every week pitching the show'), not once a week."
//
// That second record is the point. Dan's own stated reason for 56 is about EMAILING, not about
// grouping, and the guard that paces emailing is the one still on 3. So the window is not widened
// wholesale: the 3 day arm stays exactly as it is, because pacing one org about DIFFERENT shows is the
// separate question its record describes. What is added is a SAME SHOW arm out to 56.
@MainActor
@Suite("A second pitch for one show, weeks later (#3636)")
struct SameShowSecondPitchTests {
    private static let email = "boxoffice@asylumnyc.example"
    private static let venue = "Asylum NYC"

    private func container() throws -> ModelContainer {
        try ModelContainer(for: Schema([Prospect.self]),
                           configurations: [ModelConfiguration(isStoredInMemoryOnly: true)])
    }

    @discardableResult
    private func pitched(_ ctx: ModelContext, group: String, date: String, venue: String = venue) -> String {
        let key = Prospect.makeNaturalKey(groupName: group, performanceDate: date, venue: venue)
        let p = Prospect(naturalKey: key, groupName: group, discipline: "theater", venue: venue,
                         performanceDate: date, sourceListingURL: nil, priorRelationship: "none",
                         production: "self", profile: "strong", coverage: "likely_uncovered",
                         fitScore: 7, tier: "high", fitReason: "r", matchedClientName: nil,
                         possibleMatchSource: nil, possibleMatchName: nil, status: .queued)
        ctx.insert(p)
        p.addRecipient(Recipient(id: Self.email, email: Self.email, provenance: .act))
        try? ctx.save()
        return key
    }

    // THE DEFECT. One weekly show, pitched in September, fragmenting into a fresh card in October.
    // Twenty-eight days apart, so the 3 day window cannot see it, and today nothing does.
    @Test func aSecondPitchForTheSameShowWeeksLaterIsFlagged() throws {
        let ctx = ModelContext(try container())
        pitched(ctx, group: "The Infinite Wrench", date: "2026-09-04")

        let flagged = DuplicateContactGuard.duplicate(
            email: Self.email, venue: Self.venue, performanceDate: "2026-10-02",
            groupName: "The Infinite Wrench",
            excludingProspectKey: "a-second-card-for-one-show", in: ctx) != nil
        #expect(flagged, "the same show at the same venue, pitched to the same address, is a second pitch")
    }

    // A SUBTITLE IS STILL THE SAME SHOW, because that is how these fragments actually differ. The same
    // predicate #3917 shipped and #4032 now relies on, asked here for the same reason.
    @Test func aSubtitleVariantOfTheSameShowIsAlsoFlagged() throws {
        let ctx = ModelContext(try container())
        pitched(ctx, group: "The Infinite Wrench", date: "2026-09-04")

        let flagged = DuplicateContactGuard.duplicate(
            email: Self.email, venue: Self.venue, performanceDate: "2026-10-02",
            groupName: "The Infinite Wrench (A Neo-Futurist Show)",
            excludingProspectKey: "a-second-card-for-one-show", in: ctx) != nil
        #expect(flagged)
    }

    // WHAT MUST NOT CHANGE, and it is the whole reason the window is not simply widened to 56. Pacing
    // one organisation about DIFFERENT shows is the question `RunGrouping.gapDays`' own record
    // describes, and a venue's booking address legitimately receives pitches for different productions
    // weeks apart. Flagging those would be the guard crying wolf (L36).
    @Test func aDifferentShowAtTheSameVenueWeeksLaterIsNotFlagged() throws {
        let ctx = ModelContext(try container())
        pitched(ctx, group: "The Infinite Wrench", date: "2026-09-04")

        let flagged = DuplicateContactGuard.duplicate(
            email: Self.email, venue: Self.venue, performanceDate: "2026-10-02",
            groupName: "Gross Prophets: A Comedy Musical",
            excludingProspectKey: "another-show-entirely", in: ctx) != nil
        #expect(!flagged, "a different production at one venue weeks later is ordinary outreach")
    }

    // The existing 3 day arm, unchanged and asserted here rather than left to the older suite, because
    // this change is the one that could remove it. It does not test the title, deliberately: two rows
    // three days apart at one venue on one address are the #726 case whatever they are called.
    @Test func theThreeDayArmStillFiresForADifferentTitle() throws {
        let ctx = ModelContext(try container())
        pitched(ctx, group: "The Infinite Wrench", date: "2026-09-04")

        let flagged = DuplicateContactGuard.duplicate(
            email: Self.email, venue: Self.venue, performanceDate: "2026-09-06",
            groupName: "Gross Prophets: A Comedy Musical",
            excludingProspectKey: "another-show-entirely", in: ctx) != nil
        #expect(flagged, "the 3 day org pacing arm must survive this change")
    }

    // The far edge. Beyond `sameShowGapDays` a silence is a SEPARATE engagement that "earns its own
    // card", which is `RunGrouping`'s own recorded reason, so a fresh pitch there is correct and must
    // not be flagged. Written against the constant rather than a literal, so the day it moves this test
    // moves with it (L401).
    @Test func aSameShowPitchBeyondTheEngagementWindowIsNotFlagged() throws {
        let ctx = ModelContext(try container())
        let opening = "2026-09-04"
        pitched(ctx, group: "The Infinite Wrench", date: opening)
        let wellBeyond = "2026-12-20"
        // The fixture's MEANING comes from the constant, not from the literal: if `sameShowGapDays`
        // ever grows past this gap the date stops testing the far edge, and this line says so rather
        // than the test quietly becoming a duplicate of the one above it (L401, L130).
        let gap = EasternDate.daysUntil(from: opening, to: wellBeyond)
        #expect((gap ?? 0) > RunGrouping.sameShowGapDays,
                "this fixture must sit BEYOND the engagement window to test anything")

        let flagged = DuplicateContactGuard.duplicate(
            email: Self.email, venue: Self.venue, performanceDate: wellBeyond,
            groupName: "The Infinite Wrench",
            excludingProspectKey: "a-much-later-run", in: ctx) != nil
        #expect(!flagged, "a return after a long silence is its own engagement and its own pitch")
    }

    // The touring act, which the guard's own header calls out: one booking address pitching the same
    // production at two DIFFERENT rooms is legitimate and was never flagged. The venue arm still does
    // that work and the same-show arm must not go around it.
    @Test func theSameShowAtADifferentVenueIsStillNotFlagged() throws {
        let ctx = ModelContext(try container())
        pitched(ctx, group: "The Infinite Wrench", date: "2026-09-04", venue: "Asylum NYC")

        let flagged = DuplicateContactGuard.duplicate(
            email: Self.email, venue: "The Players Theatre", performanceDate: "2026-10-02",
            groupName: "The Infinite Wrench",
            excludingProspectKey: "a-tour-stop", in: ctx) != nil
        #expect(!flagged)
    }
}
