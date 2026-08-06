import Testing
import Foundation

// #2145, step three: what the reply screen is DOING, as a value, so the three states CLAUDE.md requires
// (working, still-alive, failed) are decided somewhere a test can reach rather than in a view's private
// `@State`. Found while red-teaming the plan to merge the two reply screens; each of these is live today.
//
// 1. The elapsed counter's anchor was recomputed on every redraw, so it restarted whenever anything on the
//    panel changed and the stall timeout could never be reached. A send that hangs forever kept reading as
//    a send that had just started (L74).
// 2. "Sending" was shown while the signature was being fetched, which happens BEFORE Dan has approved
//    anything and before a single byte has left (L12: say what verifiably happened).
// 3. Cancel stayed live during the send, so dismissing mid-flight took the screen down with the failure
//    still to come, and he was never told it had failed.
@Suite("The reply screen says what it is actually doing (#2145)")
struct ReplySendPhaseTests {
    private let t0 = Date(timeIntervalSince1970: 1_000)

    // MARK: the anchor

    // The instant is CARRIED by the phase, so the counter measures from when the work began. A phase that
    // recomputed it would answer a different question every time it was asked.
    @Test func aRunningPhaseCarriesTheInstantItStarted() {
        #expect(ReplyPanel.SendPhase.preparing(since: t0).startedAt == t0)
        #expect(ReplyPanel.SendPhase.sending(since: t0).startedAt == t0)
    }

    @Test func aPhaseThatIsNotRunningHasNoElapsedToShow() {
        #expect(ReplyPanel.SendPhase.composing.startedAt == nil)
        #expect(ReplyPanel.SendPhase.failed("nope").startedAt == nil)
    }

    // MARK: what it says

    // Preparing is not sending. Nothing has left, and Dan has not even been shown what he is approving.
    @Test func preparingAndSendingSayDifferentThings() {
        let preparing = ReplyPanel.SendPhase.preparing(since: t0).runningLabel
        let sending = ReplyPanel.SendPhase.sending(since: t0).runningLabel
        #expect(preparing == ReplyPanelCopy.preparing)
        #expect(sending == ReplyPanelCopy.sending)
        #expect(preparing != sending)
    }

    @Test func aScreenAtRestRunsNoLabel() {
        #expect(ReplyPanel.SendPhase.composing.runningLabel == nil)
        #expect(ReplyPanel.SendPhase.failed("nope").runningLabel == nil)
    }

    // MARK: what he may do

    // Nothing has been sent while it is being prepared, so backing out is free.
    @Test func heMayCancelWhileNothingHasLeft() {
        #expect(ReplyPanel.SendPhase.composing.allowsCancel)
        #expect(ReplyPanel.SendPhase.preparing(since: t0).allowsCancel)
        #expect(ReplyPanel.SendPhase.failed("nope").allowsCancel)
    }

    // But not once the mail is going: taking the screen down mid-send means the failure it is about to
    // report has nowhere to land, and a send that failed reads exactly like one that worked (L12).
    @Test func heMayNotCancelOutOfASendInFlight() {
        #expect(!ReplyPanel.SendPhase.sending(since: t0).allowsCancel)
    }

    // MARK: his words

    // The box stays on screen in every state, which is what makes the failure sentence true: it promises
    // his reply is still there, and it has to be somewhere he can see it, not only in memory (L11).
    @Test func hisWordsStayOnScreenThroughEveryState() {
        #expect(ReplyPanel.SendPhase.composing.showsComposeBox)
        #expect(ReplyPanel.SendPhase.preparing(since: t0).showsComposeBox)
        #expect(ReplyPanel.SendPhase.sending(since: t0).showsComposeBox)
        #expect(ReplyPanel.SendPhase.failed(ReplyPanelCopy.sendFailed).showsComposeBox)
    }

    // Typing is refused only while the mail is actually going, so an edit cannot land on words already
    // handed to Gmail.
    @Test func theBoxIsFrozenOnlyWhileTheMailIsGoing() {
        #expect(ReplyPanel.SendPhase.sending(since: t0).freezesComposeBox)
        #expect(!ReplyPanel.SendPhase.composing.freezesComposeBox)
        #expect(!ReplyPanel.SendPhase.preparing(since: t0).freezesComposeBox)
        // Failed is the state he is meant to fix and retry from, so it must not be read-only.
        #expect(!ReplyPanel.SendPhase.failed(ReplyPanelCopy.sendFailed).freezesComposeBox)
    }

    // MARK: the failure itself

    @Test func onlyAFailedPhaseCarriesAMessage() {
        #expect(ReplyPanel.SendPhase.failed(ReplyPanelCopy.sendFailed).failure == ReplyPanelCopy.sendFailed)
        #expect(ReplyPanel.SendPhase.composing.failure == nil)
        #expect(ReplyPanel.SendPhase.sending(since: t0).failure == nil)
    }
}
