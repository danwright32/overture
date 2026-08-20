import Testing
import Foundation
import SwiftData

// #2546: the sweep #2544 opened. Five more controls went grey with nothing on screen saying why, and the
// shape that fixes each one is the shape #2544 settled: ONE predicate, read three ways (whether the
// control is refusing, the reason shown beside it, and the button's help and VoiceOver hint), so a grey
// control and the words next to it cannot disagree (L109).
//
// Two of the five dim for more than one reason, and a single "not yet" would collapse them into one
// sentence that is wrong for whichever cause is not the one that fired (L11). That is what the
// distinct-sentence tests below are for.
//
// The wording rule is #2544's too: a REASON is what the control is refusing and is true BEFORE any press,
// so it may never report on a press that has not happened. Only an acknowledgement may say what became
// of one.
@MainActor
@Suite("Why a greyed out control is refusing (#2546)")
struct ControlRefusalReasonTests {

    // A clause of this shape under a button nobody has pressed reports on an event that has not happened.
    // Held as one list so a new refusal cannot pick up a past-tense wording in a corner nothing checks.
    private static let pastTenseClauses = ["nothing was saved", "nothing was sent", "was not sent",
                                           "did not send", "nothing happened"]

    private func expectStandingReason(_ reason: String?, _ what: String) {
        #expect(reason != nil, "\(what) refuses with no reason to put beside it")
        let text = reason ?? ""
        #expect(!text.isEmpty, "\(what) has an empty reason")
        for clause in Self.pastTenseClauses {
            #expect(!text.lowercased().contains(clause),
                    "\(what): the standing reason talks about a press that has not happened: \(text)")
        }
    }

    // MARK: - Send (FollowUpsView's two send buttons, ReplyConversationView's Send reply)

    // Both causes, each named, and never the same sentence for the two: a row whose contact has no
    // address is not fixed by connecting Gmail, and telling him to connect Gmail when he already has
    // sends him to a screen that will not help.
    @Test func eachReasonASendIsRefusedHasItsOwnSentence() {
        let noAddress = SendGate.reason(gmailConnected: true, hasAddress: false)
        let noGmail = SendGate.reason(gmailConnected: false, hasAddress: true)
        expectStandingReason(noAddress, "a contact with no address")
        expectStandingReason(noGmail, "Gmail not connected")
        #expect(noAddress != noGmail,
                "both causes say the same sentence, so one of them is being told the wrong thing")
    }

    // The missing address is named first when both are true. It is the fact about the row he is looking
    // at, and it survives connecting Gmail, so naming Gmail first would change the sentence under him
    // and still leave the button grey.
    @Test func aRowWithNeitherNamesTheAddressFirst() {
        #expect(SendGate.refusal(gmailConnected: false, hasAddress: false) == .noAddress)
    }

    // The sentence about Gmail is the one already on screen elsewhere, not a second wording of it (#843).
    @Test func theGmailSentenceIsTheOneTheRestOfTheAppAlreadyUses() {
        #expect(SendGate.reason(gmailConnected: false, hasAddress: true) == GmailCopy.notConnected)
    }

    @Test func aSendableRowHasNoReasonToShow() {
        #expect(SendGate.reason(gmailConnected: true, hasAddress: true) == nil)
        #expect(SendGate.canSend(gmailConnected: true, hasAddress: true))
    }

    // The gate and the reason are one call, over every combination there is.
    @Test func aSendReasonAndADisabledSendAlwaysAgree() {
        for gmail in [true, false] {
            for address in [true, false] {
                let canSend = SendGate.canSend(gmailConnected: gmail, hasAddress: address)
                let reason = SendGate.reason(gmailConnected: gmail, hasAddress: address)
                #expect(canSend == (reason == nil),
                        "gmail \(gmail) address \(address): canSend \(canSend) but reason \(reason ?? "nil")")
            }
        }
    }

    // MARK: - Log an inquiry (InquiryIntakeSheet)

    // Only the name is required, so the reason names it rather than saying the form is incomplete.
    @Test func anInquiryWithNoNameSaysWhichFieldIsMissing() {
        expectStandingReason(InquiryIntake.reasonSaveIsDisabled(name: ""), "an inquiry with no name")
        expectStandingReason(InquiryIntake.reasonSaveIsDisabled(name: "   "),
                             "an inquiry whose name is only spaces")
        #expect(InquiryIntake.reasonSaveIsDisabled(name: "")?.lowercased().contains("name") == true,
                "the reason does not name the field it is about")
    }

    @Test func anInquiryWithANameHasNoReasonToShow() {
        #expect(InquiryIntake.reasonSaveIsDisabled(name: "Olga") == nil)
    }

    @Test func anInquiryReasonAndADisabledSaveAlwaysAgree() {
        for name in ["", " ", "\n", "Olga", " Olga "] {
            let canSave = InquiryIntake.canSave(name: name)
            let reason = InquiryIntake.reasonSaveIsDisabled(name: name)
            #expect(canSave == (reason == nil),
                    "name \"\(name)\": canSave \(canSave) but reason \(reason ?? "nil")")
        }
    }

    // MARK: - Prep kept (RootView's toolbar menu)

    // Two causes behind one dimming, and they call for opposite things: one means go and keep a show,
    // the other means wait. One shared "not yet" would be wrong for whichever of the two fired.
    @Test func eachReasonPrepKeptIsRefusedHasItsOwnSentence() {
        let nothingKept = PrepStartGate.reason(keptToPrep: 0, ownSlotRunInFlight: nil)
        let alreadyRunning = PrepStartGate.reason(keptToPrep: 3, ownSlotRunInFlight: .prep)
        expectStandingReason(nothingKept, "nothing kept to prep")
        expectStandingReason(alreadyRunning, "a prep run already in flight")
        #expect(nothingKept != alreadyRunning,
                "both causes say the same sentence, so one of them is being told the wrong thing")
    }

    // A run in flight is named first when both are true: it is the state that clears itself, and telling
    // him to go and keep a show would have him queue work into a run he cannot start anyway.
    @Test func nothingKeptDuringARunNamesTheRun() {
        #expect(PrepStartGate.refusal(keptToPrep: 0, ownSlotRunInFlight: .prep) == .runInFlight(.prep))
    }

    @Test func keptShowsAndNoRunHaveNoReasonToShow() {
        #expect(PrepStartGate.reason(keptToPrep: 1, ownSlotRunInFlight: nil) == nil)
        #expect(PrepStartGate.canStart(keptToPrep: 1, ownSlotRunInFlight: nil))
    }

    @Test func aPrepReasonAndADisabledPrepAlwaysAgree() {
        for kept in [0, 1, 7] {
            for running in [true, false] {
                let canStart = PrepStartGate.canStart(keptToPrep: kept, ownSlotRunInFlight: running ? .prep : nil)
                let reason = PrepStartGate.reason(keptToPrep: kept, ownSlotRunInFlight: running ? .prep : nil)
                #expect(canStart == (reason == nil),
                        "kept \(kept) running \(running): canStart \(canStart) but reason \(reason ?? "nil")")
            }
        }
    }

    // MARK: - Add a Lead (the menu bar command)

    // #899 greyed this out because there is no store to add a lead into and the command would fire into
    // nothing. The greying was right and the silence was the other half of the same defect.
    @Test func addALeadWithNoStoreSaysSo() {
        expectStandingReason(AddLeadPresenter(store: nil).reasonAddLeadIsDisabled,
                             "Add a Lead with no store")
    }

    @Test func addALeadReasonAndTheDisabledCommandAlwaysAgree() {
        let withoutStore = AddLeadPresenter(store: nil)
        #expect(withoutStore.canAddLead == (withoutStore.reasonAddLeadIsDisabled == nil))
        let withStore = AddLeadPresenter(store: try! ModelContainer(
            for: Prospect.self, configurations: ModelConfiguration(isStoredInMemoryOnly: true)))
        #expect(withStore.canAddLead == (withStore.reasonAddLeadIsDisabled == nil))
        #expect(withStore.reasonAddLeadIsDisabled == nil)
    }
}
