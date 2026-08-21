import Testing
import Foundation

// #2876. Dan, 2026-08-17: "it prompts me to send reply when in reality it's going to let me review it,
// so it feels final when it's not."
//
// The control that reads as irreversible is the SAFE one, and it is the only one he meets while he is
// still reading his own draft. A label promising a send when it opens a review is a contract broken in
// the cautious direction, which sounds harmless and is not: it spends the weight the genuinely final
// button needs.
//
// The class, derived from the code rather than from the issue: every button that presents
// `SendConfirmSheet`. There are three, and one more that reads like them and is honest.
@Suite("A button that opens the review says so (#2876)")
struct ReviewButtonNamesTheReviewTests {
    // The one Dan reported, and the two siblings, share ONE constant. Three copies of a rule about
    // naming is how two of them come to say different things (L26).
    @Test func theopeningButtonNamesTheReviewRatherThanTheSend() {
        #expect(SendConfirmCopy.openReview.lowercased().contains("review"))
        #expect(ReplyPanelCopy.send == SendConfirmCopy.openReview)
    }

    // The FINAL button is still "Send", and must stay: there it is true, and the whole point is that the
    // two read differently.
    @Test func thefinalButtonStillSaysSendAndOnlyIt() {
        #expect(SendConfirmCopy.send == "Send")
        #expect(SendConfirmCopy.send != SendConfirmCopy.openReview)
    }

    // "now" is the word that makes a tooltip a promise. It belongs on the sheet's own heading, which is
    // asked at the moment it is true, and nowhere on the button that opens that sheet.
    @Test func theopeningHelpDoesNotPromiseThatAnythingLeavesNow() {
        let helps = [ReplyPanelCopy.sendHelp,
                     SendConfirmCopy.openReviewHelp("email"),
                     SendConfirmCopy.openReviewHelp("reply")]
        for help in helps {
            #expect(help.contains(" now") == false, "the opening tooltip promised a send: \(help)")
        }
        // The sheet's own headings still say it, because there it is the question being asked.
        #expect(SendConfirmCopy.title.contains("now"))
        #expect(SendConfirmCopy.replyTitle.contains("now"))
        #expect(SendConfirmCopy.followUpTitle.contains("now"))
    }

    // The wiring, per surface. The rule above is about a sentence; these are about which sentence each
    // surface actually renders, which is the half that a copy-only guard cannot see (L46).
    @Test func everySurfaceThatOpensTheReviewRendersThatLabel() {
        for file in ["Overture/UI/ReplySheet.swift",
                     "Overture/UI/DraftReviewView.swift",
                     "Overture/UI/FollowUpsView.swift"] {
            let source = SourceGuardHelper.source(file)
            #expect(source.contains("SendConfirmCopy.openReview") || source.contains("ReplyPanelCopy.send"),
                    "\(file) presents SendConfirmSheet, so its opening button must use the shared label")
        }
    }

    // #2050 had already reached this rule for the UNAPPROVED branch of the draft card, and named it: a
    // button naming an act it does not perform is the thing this screen can least afford. It covered one
    // branch. The approved branch ran the same `onSend()` under "Send", so one action carried two labels
    // on one screen, and a guard reading the whole file would have found the honest one and stopped
    // (L135). Neither label may come back.
    @Test func onescreenDoesNotCarryTwoLabelsForOneAction() {
        let source = SourceGuardHelper.source("Overture/UI/DraftReviewView.swift")
        let labels = ["Text(\"Final review\")", "Label(\"Send\", systemImage"]
        for label in labels {
            #expect(source.contains(label) == false,
                    "both branches of this card run onSend(); they cannot name it differently: \(label)")
        }
    }

    // And the one that is NOT in the class, proved by reading what it does rather than what it says.
    // The conversation card's Send reply calls `ProspectMutations.sendReply` directly: no sheet, no
    // review, the mail leaves. Its label is honest and must not be swept up by a rule about wording.
    @Test func acontrolThatReallySendsKeepsItsSendLabel() {
        let source = SourceGuardHelper.source("Overture/UI/ReplyConversationView.swift")

        #expect(source.contains("Send reply"))
        #expect(source.contains("SendConfirmCopy.openReview") == false,
                "this one sends; naming a review it does not open would be the same defect reversed")
    }
}
