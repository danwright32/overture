import Testing
import Foundation
@testable import Overture

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
}
