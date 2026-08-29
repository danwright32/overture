import Testing
import Foundation

// #285: a manual "Run reconcile now" must never look like it did nothing. The reconcile returns a
// summary whose message acknowledges the run even when nothing changed, so the menu action always has
// visible feedback (Dan's no-silent-no-op rule).
@Suite("Reconcile summary (#285)")
struct ReconcileSummaryTests {
    @Test func emptyRunStillAcknowledgesItself() {
        let m = ReconcileSummary(omniFocusChanged: 0).message
        #expect(m.contains("nothing was due"))
    }

    // #297: bookings are named on the manual ack too, matching the while-away alert.
    @Test func reportsNewBookingsByName() {
        let m = ReconcileSummary(omniFocusChanged: 0,
                                 newBookings: ["Joe's Pub", "The Knights"]).message
        #expect(m.contains("2 new bookings (Joe's Pub, The Knights)"))
        #expect(!m.contains("nothing was due"))
    }

    @Test func reportsFollowUpUpdates() {
        let m = ReconcileSummary(omniFocusChanged: 3).message
        #expect(m.contains("3"))
        #expect(m.lowercased().contains("follow-up"))
    }

    @Test func reportsBothWhenBothChanged() {
        let m = ReconcileSummary(omniFocusChanged: 2, newBookings: ["Carnegie Hall"]).message
        #expect(m.contains("1 new booking (Carnegie Hall)"))
        #expect(m.contains("2"))
        #expect(!m.contains("nothing was due"))
    }

    // #287: a reply found this pass must be acknowledged too, so a reply-only run never reads as
    // "nothing was due".
    @Test func reportsASingleNewReplyAndNamesTheOrg() {
        let m = ReconcileSummary(omniFocusChanged: 0, newReplies: ["Carnegie Hall"]).message
        #expect(m.contains("1 new reply (Carnegie Hall)"))
        #expect(!m.contains("nothing was due"))
    }

    @Test func pluralizesCountsAndNamesSeveralReplies() {
        let m = ReconcileSummary(omniFocusChanged: 0,
                                 newReplies: ["Carnegie Hall", "Joe's Pub"]).message
        #expect(m.contains("2 new replies (Carnegie Hall, Joe's Pub)"))
        #expect(!m.contains("nothing was due"))
    }

    @Test func reportsRepliesAlongsideBookingsAndFollowUps() {
        let m = ReconcileSummary(omniFocusChanged: 2,
                                 newReplies: ["Carnegie Hall"], newBookings: ["Joe's Pub"]).message
        #expect(m.contains("1 new reply (Carnegie Hall)"))
        #expect(m.contains("1 new booking (Joe's Pub)"))
        #expect(m.contains("follow-up"))
        #expect(!m.contains("nothing was due"))
    }

    // #301: the away alert deep-links only when exactly one lead is new this tick (a reply OR a
    // booking). Zero or several new leads → no single target, so the tap just opens the window.
    @Test func deepLinkKeyIsTheSoleNewLeadWhenExactlyOneIsNew() {
        let s = ReconcileSummary(omniFocusChanged: 0, newReplies: ["Carnegie Hall"], newReplyKeys: ["carnegie|2026|hall"])
        #expect(s.deepLinkKey == "carnegie|2026|hall")
    }

    @Test func deepLinkKeyIsNilWhenSeveralLeadsAreNew() {
        let s = ReconcileSummary(omniFocusChanged: 0,
                                 newReplies: ["A", "B"], newReplyKeys: ["a|2026|v", "b|2026|v"])
        #expect(s.deepLinkKey == nil)
    }

    @Test func deepLinkKeyIsNilWhenOneReplyAndOneBookingAreBothNew() {
        let s = ReconcileSummary(omniFocusChanged: 0,
                                 newReplies: ["A"], newBookings: ["B"],
                                 newReplyKeys: ["a|2026|v"], newBookingKeys: ["b|2026|v"])
        #expect(s.deepLinkKey == nil)
    }

    @Test func deepLinkKeyIsNilWhenNothingIsNew() {
        #expect(ReconcileSummary(omniFocusChanged: 0).deepLinkKey == nil)
    }

    // #308: every new lead's key this tick (replies then bookings, aligned with the name arrays), so a
    // coalesced multi-lead away alert can carry the whole set and a tap can filter the queue to exactly
    // them. deepLinkKey is just the count==1 special case of this.
    @Test func newLeadKeysAreRepliesThenBookings() {
        let s = ReconcileSummary(omniFocusChanged: 0,
                                 newReplies: ["A"], newBookings: ["B"],
                                 newReplyKeys: ["a|2026|v"], newBookingKeys: ["b|2026|v"])
        #expect(s.newLeadKeys == ["a|2026|v", "b|2026|v"])
    }

    @Test func newLeadKeysIsEmptyWhenNothingIsNew() {
        #expect(ReconcileSummary(omniFocusChanged: 0).newLeadKeys.isEmpty)
    }

    // #499: a save failure is the most actionable outcome of a tick, since whatever this pass found
    // may not have persisted; it must take precedence over every other message, including a "nothing
    // was due" no-op or a genuine new booking/reply this same tick.
    @Test func saveFailedTakesPrecedenceOverNothingWasDue() {
        let m = ReconcileSummary(omniFocusChanged: 0, saveFailed: true).message
        #expect(m.contains("couldn't save"))
        #expect(!m.contains("nothing was due"))
    }

    @Test func saveFailedTakesPrecedenceOverNewBookings() {
        let m = ReconcileSummary(omniFocusChanged: 0, newBookings: ["Joe's Pub"], saveFailed: true).message
        #expect(m.contains("couldn't save"))
        #expect(!m.contains("Joe's Pub"))
    }

    // --- #1912: a reply watcher stopped by dead Gmail credentials says so ------------------------------
    //
    // `GmailReplyChecker.checkReplies` returned a bare `false` for both auth cases and its own header said
    // it "skips silently". So a revoked or expired refresh token stopped the reply watching outright with
    // no alert, no status line and no record, and the first symptom was that replies stopped arriving.
    // #2741 gave the outcome a `notConnected` field, and nothing in the tick ever read it, so the silence
    // was unchanged. A background job must report a failure AND the absence of an expected run (L13).
    //
    // Two fields rather than one, and separate sentences, because the REMEDY differs: connecting Gmail for
    // the first time is not the same act as reconnecting a credential that died, and a message may claim
    // only what its check measured (L11). This is the same split #2798 made for the inquiry half.

    @Test func aWatcherThatNeverConnectedSaysSoAndNamesConnecting() {
        let m = ReconcileSummary(omniFocusChanged: 0, replyWatchNotConnected: true).message
        #expect(m.contains("Gmail isn't connected"))
        #expect(m.contains("whether anyone replied"))
        #expect(!m.contains("nothing was due"))
    }

    @Test func aWatcherWhoseCredentialDiedSaysThatInstead() {
        let m = ReconcileSummary(omniFocusChanged: 0, replyWatchTokenExpired: true).message
        // "couldn't refresh", never "expired": the check measures a nil access token, which a revoked
        // credential produces and so does a network failure reaching the refresh endpoint, and a message
        // may claim only what its check measured (L11). Caught by the cold read of the generated copy
        // inventory, which is what that step exists for.
        #expect(m.contains("couldn't refresh your Gmail sign-in"))
        #expect(!m.contains("expired"))
        #expect(m.contains("whether anyone replied"))
        #expect(!m.contains("isn't connected"))
    }

    // Neither may be swallowed by the ordinary report, which is the whole defect: a tick that could not
    // look has established nothing about who wrote, and "nothing was due" claims it did (L98).
    @Test func neitherAuthFailureReadsAsNothingWasDue() {
        for summary in [ReconcileSummary(omniFocusChanged: 0, replyWatchNotConnected: true),
                        ReconcileSummary(omniFocusChanged: 0, replyWatchTokenExpired: true)] {
            #expect(!summary.message.contains("nothing was due"))
        }
    }

    // A save failure is more actionable than either, so it still leads, exactly as it does over every
    // other concern on this summary.
    @Test func aSaveFailureStillOutranksTheWatcherLines() {
        let m = ReconcileSummary(omniFocusChanged: 0, saveFailed: true,
                                 replyWatchNotConnected: true, replyWatchTokenExpired: true).message
        #expect(m.contains("couldn't save"))
    }

    // And the two are told apart from the read failure beside them, which is a different fault with a
    // different remedy: Gmail refused these particular threads, rather than refusing Overture outright.
    @Test func anUnreadableThreadIsNotAnExpiredCredential() {
        let m = ReconcileSummary(omniFocusChanged: 0, replyWatchUnreadable: true).message
        #expect(!m.contains("couldn't refresh your Gmail sign-in"))
        #expect(!m.contains("Gmail isn't connected"))
    }


    // The wiring the pure logic cannot see (L3). Both fields were already computed by #2741's outcome and
    // simply never read, which is the entire defect, so a sentence that is right about a fact nobody hands
    // it changes nothing at all. Guarded at the source, like #2478's and #1456's own wiring tests, because
    // the site needs a live SwiftData context and a real Gmail credential to run.
    //
    // Scoped to the summary the tick BUILDS rather than to the file, so a mention of either field anywhere
    // else in a 300 line scheduler cannot stand in for the tick actually carrying it (L63, L135).
    @Test func theReconcileTickCarriesBothOfTheWatchersAuthFactsIntoItsSummary() {
        let sched = SourceGuardHelper.source("Overture/App/ReconcileScheduler.swift")
        #expect(sched.contains("replyWatchNotConnected: replyCheck.notConnected"),
                "the tick must hand the summary the not-connected fact, or its sentence can never be said")
        #expect(sched.contains("replyWatchTokenExpired: replyCheck.tokenRefreshFailed"),
                "the tick must hand the summary the dead-credential fact, the state that used to be silent")
    }

}
