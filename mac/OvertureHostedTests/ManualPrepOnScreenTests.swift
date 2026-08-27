import Testing
import SwiftUI
import ViewInspector
@testable import Overture

// #2007: the "Prep manually" control on a card, and the editor it opens.
//
// These render the real views. The RULES they draw are unit-tested elsewhere (QueueModel.manualPrepOffer,
// ManualPrepPrefill, ManualPrepEditing); what is checked here is that the rules reach the screen at all,
// which no pure test can see (L3: built is not wired).
@MainActor
@Suite("Prep manually on screen (#2007)")
struct ManualPrepOnScreenTests {
    private func item(status: ReviewStatus = .queued, draftBody: String? = nil,
                      conflicted: Bool = false) -> QueueItem {
        var i = QueueItem(id: "k", groupName: "Bargemusic", discipline: "classical", venue: "Boathouse",
                          performanceDate: "2026-11-14", sourceListingURL: nil,
                          priorRelationship: "booked", production: "self", profile: "strong",
                          coverage: "likely_uncovered", fitScore: 9, tier: "high", fitReason: "r",
                          matchedClientName: nil, possibleMatchSource: nil, possibleMatchName: nil,
                          status: status)
        i.draftBody = draftBody
        i.hasUnclearedConflict = conflicted
        i.conflictNote = conflicted ? "You blocked Nov 14 (Vacation)." : nil
        return i
    }

    private func texts(_ view: some View) throws -> [String] {
        try view.inspect().findAll(ViewType.Text.self).map { try $0.string() }
    }

    @Test func aKeptShowWithNoDraftOffersIt() throws {
        let view = ProspectRowView(item: item(), today: "2026-08-03", onKeep: {}, onDismiss: { _ in })
        #expect(try texts(view).contains("Prep manually"))
    }

    @Test func anUntriagedShowDoesNotOfferIt() throws {
        let view = ProspectRowView(item: item(status: .new), today: "2026-08-03",
                                   onKeep: {}, onDismiss: { _ in })
        #expect(try !texts(view).contains("Prep manually"))
    }

    @Test func aShowThatAlreadyHasAnEmailDoesNotOfferIt() throws {
        let view = ProspectRowView(item: item(status: .drafted, draftBody: "Hi Olga."),
                                   today: "2026-08-03", onKeep: {}, onDismiss: { _ in })
        #expect(try !texts(view).contains("Prep manually"))
    }

    // Blocked, not hidden: the control stays on screen so the reason can be read, and "I can shoot this
    // anyway" is right beside it.
    @Test func aShowOnANightHeCannotWorkStillDrawsItBlocked() throws {
        let view = ProspectRowView(item: item(conflicted: true), today: "2026-08-03",
                                   onKeep: {}, onDismiss: { _ in })
        #expect(try texts(view).contains("Prep manually"))
    }

    // MARK: - The editor

    @Test func theEditorFillsInAnAddressHeHasEmailedAndSaysWhereItCameFrom() throws {
        let prior = ManualPrepPrefill.PriorOutreach(email: "info@everyvoice.org", showName: "Holiday Sing",
                                                    sentAt: EasternDate.date(from: "2025-11-02")!)
        let sheet = ManualPrepSheet(groupName: "Bargemusic",
                                    prefill: .init(filled: prior, suggestions: [], emptyReason: nil),
                                    onSave: { _, _, _, _, _ in })

        let rendered = try sheet.inspect()
        #expect(try rendered.find(ViewType.TextField.self).input() == "info@everyvoice.org")
        #expect(try rendered.findAll(ViewType.Text.self).map { try $0.string() }
                .contains("You emailed this address about Holiday Sing on Nov 2, 2025."))
    }

    // The failure path, on screen: an empty field that says which sources were checked, rather than an
    // empty field that says nothing.
    @Test func theEditorSaysWhatItCheckedWhenNothingPrefills() throws {
        let sheet = ManualPrepSheet(groupName: "Bargemusic",
                                    prefill: .init(filled: nil, suggestions: [], emptyReason: .nothingFound),
                                    onSave: { _, _, _, _, _ in })

        #expect(try sheet.inspect().findAll(ViewType.Text.self).map { try $0.string() }
                .contains(ManualPrepCopy.emptyRecipientNote(.nothingFound)))
    }

    @Test func aBookingSheetAddressAppearsAsSomethingToClickNotAsAFilledField() throws {
        let sheet = ManualPrepSheet(
            groupName: "Bargemusic",
            prefill: .init(filled: nil,
                           suggestions: [.init(email: "olga@bargemusic.org", source: .bookingSheet)],
                           emptyReason: nil),
            onSave: { _, _, _, _, _ in })

        let rendered = try sheet.inspect()
        // Offered as a button, and the field itself is left empty for him to decide.
        #expect(throws: Never.self) { try rendered.find(button: "olga@bargemusic.org") }
        #expect(try rendered.find(ViewType.TextField.self).input() == "")
    }

    // MARK: - Why Save draft is refusing (#2544)
    //
    // The rule and its wording are unit-tested in ManualPrepSaveReasonTests. What no pure test can see is
    // whether the sentence reaches the sheet: before this it was computed on every keystroke, thrown away,
    // and left Dan looking at a greyed out button with an empty Subject box and nothing joining the two.

    // Read off the footer's own first element rather than by searching the whole sheet for the sentence.
    // A deep search cannot tell a line Dan can SEE from one that only exists in the button's tooltip and
    // VoiceOver hint: `.help()` puts its string into the hierarchy, so the first version of these tests
    // passed with the visible line deleted, which is the very defect they exist to catch.
    private func footerReasonLine(_ sheet: ManualPrepSheet) throws -> String? {
        try? sheet.inspect().vStack().hStack(3).text(0).string()
    }

    // A freshly opened editor has an address and no subject yet, so the reason names the subject. Compared
    // against the domain's own answer rather than a copy of the sentence typed in here, so the screen
    // cannot drift from the gate.
    @Test func theEditorSaysWhySaveDraftIsRefusing() throws {
        let prior = ManualPrepPrefill.PriorOutreach(email: "olga@bargemusic.org", showName: "Bargemusic",
                                                    sentAt: EasternDate.date(from: "2025-11-02")!)
        let sheet = ManualPrepSheet(groupName: "Bargemusic",
                                    prefill: .init(filled: prior, suggestions: [], emptyReason: nil),
                                    onSave: { _, _, _, _, _ in })

        let expected = ManualPrepEditing.reasonSaveIsDisabled(email: "olga@bargemusic.org", subject: "",
                                                              body: "")
        #expect(expected != nil)
        #expect(try footerReasonLine(sheet) == expected)
    }

    // The clause that reports on a press nobody has made must not ride along onto the sheet. Asserted on
    // the rendered screen and not only on the string, because the sheet is where it would have been read.
    @Test func theReasonOnScreenDoesNotReportOnASaveThatHasNotHappened() throws {
        let sheet = ManualPrepSheet(groupName: "Bargemusic",
                                    prefill: .init(filled: nil, suggestions: [], emptyReason: .nothingFound),
                                    onSave: { _, _, _, _, _ in })

        for line in try texts(sheet) {
            #expect(!line.lowercased().contains("nothing was saved"),
                    "the opened sheet says \"\(line)\" before anything has been pressed")
        }
    }

    // With no address prefilled the reason is about the address, not the subject: the sheet names the first
    // field he would look at rather than whichever rule ran last.
    @Test func anEmptyEditorNamesTheAddressRatherThanTheSubject() throws {
        let sheet = ManualPrepSheet(groupName: "Bargemusic",
                                    prefill: .init(filled: nil, suggestions: [], emptyReason: .nothingFound),
                                    onSave: { _, _, _, _, _ in })

        #expect(try footerReasonLine(sheet) == "Add an address to send to")
    }

    // MARK: - What an idle card costs
    //
    // The prefill walks every prospect and reads the booking-history file off disk. A queue is hundreds
    // of these cards, so a card that is merely OFFERING the control must not pay for it (L62: a guard
    // inside a function does not make its call cheap, and this one is not even a guard). The lookup lives
    // in the sheet's presentation closure; this is what proves that closure does not run while closed.
    @Test func offeringTheControlLooksNothingUpUntilTheEditorIsOpened() throws {
        final class Counter: @unchecked Sendable { var calls = 0 }
        let counter = Counter()
        let view = ProspectRowView(item: item(), today: "2026-08-03", onKeep: {}, onDismiss: { _ in },
                                   manualPrepPrefill: {
                                       counter.calls += 1
                                       return .init(filled: nil, suggestions: [], emptyReason: .nothingFound)
                                   })

        _ = try view.inspect().findAll(ViewType.Text.self).map { try $0.string() }

        #expect(counter.calls == 0)
    }
}
