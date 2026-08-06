import Testing
import Foundation

// #661 follow-up: the lightweight reached-out row must color an overdue reach-out in rust, the
// same urgency cue the old full show card gave it, rather than the plain color used for a future
// "in N days" timing. Source-guarded since QueueView's row isn't directly invokable in a test.
@Suite("Reached-out row urgency color")
struct ReachedOutRowGuardTests {
    @Test func rowColorsTheTimingTextByDueNow() throws {
        let src = SourceGuardHelper.source("Overture/UI/QueueView.swift")
        #expect(!src.isEmpty)
        let body = try SourceGuard.functionBody(named: "reachedOutRow", in: src)
        #expect(body.contains("ReachedOutQueue.isDueNow("),
                "reachedOutRow no longer checks isDueNow to decide the timing text's color (#661).")
        #expect(body.contains("OVColor.rust"),
                "reachedOutRow lost the rust urgency color for an overdue reach-out (#661).")
    }

    // #675: the lightweight row (#661) dropped the delivery-delay hint the embedded DraftReviewView
    // used to show (#656) for a recipient in this same pipeline. Must reuse hasRecentDeliveryDelay
    // rather than reimplementing the fade-window check, so the two can't drift apart (#656/#675).
    @Test func rowReusesTheSharedDeliveryDelayCheck() throws {
        let src = SourceGuardHelper.source("Overture/UI/QueueView.swift")
        #expect(!src.isEmpty)
        let body = try SourceGuard.functionBody(named: "reachedOutRow", in: src)
        #expect(body.contains("hasRecentDeliveryDelay("),
                "reachedOutRow doesn't surface the soft-delay hint via the shared hasRecentDeliveryDelay check (#675).")
    }

    // #2128: answering a reply is the actual job on this row, so the row has to OFFER it, and it has to
    // offer it about the peer who WROTE. The row stands on whoever sorts first, which is routinely a
    // colleague who said nothing, so a route keyed on the row's own recipient would open the panel about
    // the wrong person and send Dan's answer to them.
    //
    // Source-guarded because QueueView cannot be constructed in a test at all: it holds nine @Query
    // properties. The decisions themselves are pure and covered in ReplyPanelTests; this pins that the
    // shipping row actually asks them.
    @Test func rowOffersAnsweringKeyedOnTheContactWhoWrote() throws {
        let src = SourceGuardHelper.source("Overture/UI/QueueView.swift")
        #expect(!src.isEmpty)
        let body = try SourceGuard.functionBody(named: "reachedOutRow", in: src)
        #expect(body.contains("ReplyPanel.isOffered("),
                "reachedOutRow no longer offers the reply panel where a reply is waiting (#2128).")
        #expect(body.contains("ReplyIdentity.answering("),
                "reachedOutRow opens the reply panel about its own recipient rather than the one who wrote (#2128).")
    }

    // #2128: and the panel is presented from QueueView, not built inside the row, so the compose box's
    // text lives one level down. Owned by the row it would put every keystroke through the queue's whole
    // derivation, which is the defect #1774, #1922 and #1923 each fought.
    @Test func theReplyPanelIsASheetAndOwnsItsOwnText() throws {
        let queueView = SourceGuardHelper.source("Overture/UI/QueueView.swift")
        let panel = SourceGuardHelper.source("Overture/UI/ReplyPanelSheet.swift")
        #expect(queueView.contains(".sheet(item: $answeringReply)"))
        #expect(!queueView.contains("@State private var replyPanelBody"),
                "the reply text must live in the panel, never on QueueView (#2128).")
        #expect(panel.contains("@State private var body_"),
                "ReplyPanelSheet must own the text it is composing (#2128).")
    }

    // #2145: the panel's send states come from the tested phase, not from the view's own guesses. A
    // rendered test cannot reach this, because the phase is private `@State` with no way in from outside,
    // so the wiring is pinned at the source. Each of these three was a live defect.
    @Test func thePanelTakesItsSendStatesFromTheTestedPhase() throws {
        let panel = SourceGuardHelper.source("Overture/UI/ReplyPanelSheet.swift")
        #expect(!panel.isEmpty)

        // The elapsed counter measures from when the step began. Anchored on a fresh `Date()` at render
        // time it restarted on every redraw, so a hung send could never reach its stall timeout (L74).
        #expect(panel.contains("since: phase.startedAt"),
                "the running label must count from the instant the step began, never from this redraw.")
        #expect(!panel.contains("LiveRunLabel(base: ReplyPanelCopy.sending, since: Date()"),
                "an elapsed counter anchored on now measures the time since the last redraw.")

        // Cancel is refused while the mail is going, and his words stay on screen through a failure.
        #expect(panel.contains(".disabled(!phase.allowsCancel)"),
                "Cancel must be refused once the send is in flight, or the failure has nowhere to land.")
        #expect(panel.contains("if phase.showsComposeBox"),
                "the compose box must survive a failure whose sentence promises his reply is still there.")

        // And the step before the send names itself, rather than claiming the mail is already going.
        #expect(panel.contains("phase = .preparing(since:"),
                "fetching the signature is not sending; it must not claim to be (#2145).")
    }
}
