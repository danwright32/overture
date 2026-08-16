import Testing
import Foundation

// #360: the send confirmation is now a first-class branded sheet, not a stock system alert. Its
// copy lives in one testable place (SendConfirmCopy) rather than being computed inside the SwiftUI
// view, where a wording rule can silently drift under a green suite. These lock the words Dan reads
// at the single most consequential moment (a real email leaving).
@Suite("Send confirmation sheet copy")
struct SendConfirmSheetTests {
    @Test func titleAsksBeforeSending() {
        #expect(SendConfirmCopy.title == "Send this email now?")
    }

    @Test func reassuranceIsTheOneEmailPromise() {
        #expect(SendConfirmCopy.reassurance ==
                "This sends one email right now, to this recipient only. Nothing else goes out.")
    }

    @Test func fieldLabelsAndActionsAreStable() {
        #expect(SendConfirmCopy.fromLabel == "From")
        #expect(SendConfirmCopy.toLabel == "To")
        #expect(SendConfirmCopy.subjectLabel == "Subject")
        #expect(SendConfirmCopy.previewLabel == "The email that will send")
        #expect(SendConfirmCopy.send == "Send")
        #expect(SendConfirmCopy.cancel == "Cancel")
        #expect(SendConfirmCopy.sentSeal == "Sent")   // #361: the leaving-row gold seal
    }

    @Test func theSharedModifierPresentsASheetNotAPlainAlert() {
        let source = SourceGuardHelper.source("Overture/UI/SendConfirmAndReconnectAlerts.swift")
        #expect(!source.isEmpty)
        #expect(source.contains(".sheet("),
                "The send confirmation must present the branded SendConfirmSheet, not a stock .alert (#360).")
        #expect(!source.contains(".alert(\"Send this email now?\""),
                "The plain system send-confirm alert must be gone once the branded sheet replaces it (#360).")
    }

    // #948: the follow-up confirmation carries its own heading and reassurance through the shared sheet.
    //
    // #2710: the note's three strings went with the closing note. Only the draft and the follow-up can
    // claim "nothing else goes out", and after this change they are the only two that claim anything.
    @Test func theFollowUpCopyIsStable() {
        #expect(SendConfirmCopy.followUpTitle == "Send this follow-up now?")
        #expect(SendConfirmCopy.followUpReassurance
                == "This sends one follow-up right now, to this recipient only. Nothing else goes out.")
    }

    // #948 wiring: the follow-up and note sends must present the branded SendConfirmSheet, not the stock
    // system alerts they used before. The guard and its wiring are two claims (#887): the model tests
    // above pass even if the view still shows a plain alert, so the view itself is checked here.
    @Test func followUpsViewPresentsTheBrandedSheetNotStockAlerts() {
        let source = SourceGuardHelper.source("Overture/UI/FollowUpsView.swift")
        #expect(!source.isEmpty)
        #expect(source.contains("SendConfirmSheet("),
                "The follow-up and note sends must route through the branded SendConfirmSheet (#948).")
        #expect(!source.contains(".alert(\"Send this follow-up now?\""),
                "The stock follow-up alert must be gone once the branded sheet replaces it (#948).")
        #expect(!source.contains(".alert(\"Send this note now?\""),
                "The stock note alert must be gone once the branded sheet replaces it (#948).")
    }

    // #948 anti-drift: the sender builds its outgoing mail from the same nudgeContent helper the
    // confirmation reads, so what Dan confirms cannot differ from what goes out. Before this, the
    // follow-up confirm previewed nudgeSubject while the send used replySubject.
    @Test func theSenderBuildsFromTheSharedNudgeContent() {
        let source = SourceGuardHelper.source("Overture/Integration/SendService.swift")
        #expect(!source.isEmpty)
        #expect(source.contains("FollowUp.nudgeContent("))
        // #2710: `PostEventPrompt.nudgeContent(` stood here. There is one composed outbound body left.
    }
}
