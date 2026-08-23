import Testing
import Foundation

// #2967: confirming a proposed conversation from the Follow-ups sheet reaches Gmail, so that sheet can
// now meet a dead connection. Two things had to be true of the prompt it shows, and neither is about
// the Due count this arrived with.
//
// It has to CARRY the action. A message naming what is wrong, on a surface with no way to act on it,
// leaves Dan exactly where he started and reads as the app being broken (L80, L148). The Follow-ups
// sheet had no connect action of its own, so RootView hands it one; a defaulted empty closure would
// draw a button that does nothing, which is worse than no button.
//
// And it has to say what was actually LOST. The send alert's sentence ("nothing was sent, try Send
// again") is wrong here in both halves: nothing was being sent, and there is no Send to try again. A
// single sentence covering both cases would have to describe neither, which is why the shared type
// shares the title, the buttons and the cause and deliberately not the consequence (L11).
@Suite("The reconnect prompt carries its action and names what was lost (#2967)")
struct ReconnectPromptCarriesItsActionTests {

    // MARK: - What was lost

    @Test func theTwoConsequencesAreDifferentSentences() {
        #expect(GmailReconnectCopy.afterSend != GmailReconnectCopy.afterLinkAttempt)
    }

    // A failed send is a message a stranger never received. That is the fact, and the retry is a real
    // one, because the draft is still there to send.
    @Test func theSendSentenceSaysNothingWasSentAndOffersTheRetryThatExists() {
        #expect(GmailReconnectCopy.afterSend.contains("nothing was sent"))
        #expect(GmailReconnectCopy.afterSend.contains("try Send again"))
    }

    // A failed link changed nothing at all, which is the part Dan needs before he goes looking for a
    // side effect that is not there. It must NOT borrow the send sentence's retry: there is no Send on
    // this screen, so naming one sends him to a control that is not in front of him (L111).
    @Test func theLinkSentenceSaysNothingChangedAndDoesNotNameASendToRetry() {
        #expect(GmailReconnectCopy.afterLinkAttempt.contains("could not be linked"))
        #expect(GmailReconnectCopy.afterLinkAttempt.contains("nothing changed"))
        #expect(!GmailReconnectCopy.afterLinkAttempt.contains("try Send again"),
                "the link failure tells Dan to try a Send that this screen does not offer")
    }

    // Both sentences tell Dan to press something. The instruction has to name the button by the SAME
    // literal the button is drawn from, or it names a control that is not there.
    @Test func bothSentencesNameTheButtonTheyAskHimToPress() {
        #expect(GmailReconnectCopy.afterSend.contains(GmailReconnectCopy.connect))
        #expect(GmailReconnectCopy.afterLinkAttempt.contains(GmailReconnectCopy.connect))
    }

    // MARK: - Built is not wired (L3)

    // The sheet raises the prompt where the connection is found dead, and the prompt it raises carries
    // the connect action rather than only the news.
    @Test func theFollowUpsSheetRaisesThePromptAndOffersTheAction() throws {
        let source = SourceGuardHelper.source("Overture/UI/FollowUpsView.swift")
        #expect(!source.isEmpty)

        #expect(SourceGuardHelper.containsCode("case .notConnected: showReconnect = true", in: source),
                "confirming a conversation with dead Gmail access says nothing at all (#2967)")
        #expect(SourceGuardHelper.containsCode("Button(GmailReconnectCopy.connect) { onConnectGmail() }",
                                               in: source),
                "the reconnect prompt in the Follow-ups sheet has no way to reconnect (L80)")
        #expect(source.contains("GmailReconnectCopy.afterLinkAttempt"),
                "the Follow-ups sheet borrows a sentence about a send that never happened here")
    }

    // The action is a REAL one. `onConnectGmail` is defaulted to an empty closure so a test can render
    // this sheet without one, and a shipping caller that took the default would draw a live-looking
    // button that does nothing, with no error anywhere: the exact shape of a dead control (L109).
    @Test func rootViewHandsTheSheetItsOwnConnectAction() throws {
        let source = SourceGuardHelper.source("Overture/App/RootView.swift")
        #expect(!source.isEmpty)

        // Scoped to the FollowUpsView CALL SITE, the idiom FollowUpsRowArchiveJumpGuardTests already
        // uses on this same call. A whole-file match is satisfied by any occurrence in the file (L135),
        // and RootView legitimately passes `onConnectGmail: connectGmail` to ArchiveView as well, so a
        // bare search stays green with this wiring deleted. Measured: it did, and mutate.sh reported
        // SURVIVED on a mutation that removed the argument entirely.
        guard let callSite = source.range(of: "FollowUpsView(") else {
            Issue.record("FollowUpsView call site not found in RootView")
            return
        }
        let wiring = source[callSite.lowerBound...].prefix(300)
        #expect(wiring.contains("onConnectGmail: connectGmail"),
                "RootView presents FollowUpsView without a connect action, so its Connect Gmail button is dead (#2967)")
    }

    // The words live in ONE place. Two screens show this prompt now, and a second copy of a sentence is
    // what #631 shared the alert itself to prevent.
    @Test func neitherScreenHoldsItsOwnCopyOfTheWords() throws {
        for file in ["Overture/UI/FollowUpsView.swift", "Overture/UI/SendConfirmAndReconnectAlerts.swift"] {
            let source = SourceGuardHelper.source(file)
            #expect(!source.isEmpty)
            #expect(!source.contains("Your Gmail access has expired"),
                    Comment(rawValue: "\(file) writes the reconnect sentence out for itself again (#631)"))
            #expect(!SourceGuardHelper.containsCode("Button(\"Connect Gmail\")", in: source),
                    Comment(rawValue: "\(file) writes the button's own words out again (#631)"))
        }
    }
}
