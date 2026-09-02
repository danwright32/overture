import Testing
import SwiftUI
import ViewInspector
@testable import Overture

// #1249: the self double-booking confirms (Approve, per-row Re-prep, batch Prep) are now a first-party
// branded sheet, not a stock system confirmationDialog. Two claims are checked (#887): the sheet renders the
// title / message / proceed the caller passes and fires the right callback (render tests), AND the two views
// actually present it instead of the stock dialog (source guards, since a render test passes even if the
// view still shows an OS dialog).
// @MainActor: creating a SwiftUI view and inspecting it must run on the main actor, or it crashes
// intermittently via MainActor.assumeIsolated depending on the parallel runner's thread. Every ViewInspector
// suite in this repo carries it (DraftReviewViewSendStateTests, SendConfirmSheetTests, ...); omitting it here
// was the cause of the flaky mid-run test-host crashes on #1249.
@MainActor
@Suite("Self-booking confirm is a branded sheet (#1249)")
struct SelfBookingConfirmSheetTests {
    @Test func showsTheTitleMessageAndBothButtons() throws {
        let sheet = SelfBookingConfirmSheet(
            // #3369: the title comes from PrepLaunchCopy now, which owns the launch confirm since a
            // calendar clash reaches the same sheet. This one is the self-booking-only case.
            title: try #require(PrepLaunchCopy.confirmTitle(selfBooking: true, calendar: false)),
            message: "This date already holds a pitch to Aurora Strings.",
            proceedLabel: PrepLaunchCopy.proceedLabel, onProceed: {}, onCancel: {})
        let texts = try sheet.inspect().findAll(ViewType.Text.self).map { try $0.string() }
        #expect(texts.contains(try #require(PrepLaunchCopy.confirmTitle(selfBooking: true,
                                                                        calendar: false))))  // the title
        #expect(texts.contains("This date already holds a pitch to Aurora Strings.")) // the clash message
        _ = try sheet.inspect().find(button: PrepLaunchCopy.proceedLabel)  // the proceed action, wired to onProceed
        _ = try sheet.inspect().find(button: SendConfirmCopy.cancel)                 // and Cancel, wired to onCancel
    }

    @Test func queueViewPresentsTheBrandedSheetNotAStockDialog() {
        let source = SourceGuardHelper.source("Overture/UI/QueueView.swift")
        #expect(!source.isEmpty)
        #expect(source.contains("SelfBookingConfirmSheet("),
                "The Approve/Re-prep self-booking confirm must route through the branded sheet (#1249).")
        #expect(!source.contains(".confirmationDialog("),
                "The stock system confirmationDialog must be gone once the branded sheet replaces it (#1249).")
    }

    @Test func prepSelectionSheetPresentsTheBrandedSheetNotAStockDialog() {
        let source = SourceGuardHelper.source("Overture/UI/PrepSelectionSheet.swift")
        #expect(!source.isEmpty)
        #expect(source.contains("SelfBookingConfirmSheet("),
                "The batch-Prep self-booking confirm must route through the branded sheet (#1249).")
        #expect(!source.contains(".confirmationDialog("),
                "The stock system confirmationDialog must be gone once the branded sheet replaces it (#1249).")
    }
}
