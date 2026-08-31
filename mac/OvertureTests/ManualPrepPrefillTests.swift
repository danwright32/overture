import Testing
import Foundation

// #2007: what the manual-prep editor puts in the recipient field before Dan types anything.
//
// The rule is Dan's, and it is asymmetric BY SOURCE rather than one rule for both (his call,
// 2026-08-03). An address he has ALREADY EMAILED about this organisation is filled in: he wrote to it,
// so it is trusted. An address off the booking sheet is only ever OFFERED beside the field, with its
// source named, because that column "routinely holds an AGENT's address, an ensemble's, an unrelated
// org's, or no address at all" (HistoryMatch), and a prefilled field does not invite the second look
// that would catch it. With neither, the field is empty and says which sources were checked.
@Suite("Manual prep prefill (#2007)")
struct ManualPrepPrefillTests {
    private func prospect(_ group: String, presenter: String? = nil, date: String = "2026-11-14") -> Prospect {
        Prospect(naturalKey: "\(group)|\(date)|Boathouse", groupName: group, discipline: "classical",
                 venue: "Boathouse", performanceDate: date, sourceListingURL: nil,
                 priorRelationship: "booked", production: "self", profile: "strong",
                 coverage: "likely_uncovered", fitScore: 9, tier: "high", fitReason: "r",
                 matchedClientName: nil, possibleMatchSource: nil, possibleMatchName: nil, status: .queued)
            .withPresenter(presenter)
    }

    private func sent(_ p: Prospect, _ email: String, on date: Date) {
        let r = Recipient(id: email, email: email, provenance: .act)
        r.sendState = .sent
        r.sentAt = date
        p.addRecipient(r)
    }

    private func found(_ p: Prospect, _ email: String) {
        p.addRecipient(Recipient(id: email, email: email, provenance: .act))
    }

    // The warm case this feature exists for: an annual show he has emailed before.
    @Test func anAddressHeHasEmailedAboutThisOrgIsFilledIn() {
        let thisYear = prospect("Bargemusic")
        let lastYear = prospect("Bargemusic", date: "2025-11-14")
        sent(lastYear, "olga@bargemusic.org", on: Date(timeIntervalSince1970: 1_700_000_000))

        let result = ManualPrepPrefill.build(for: thisYear, amongst: [thisYear, lastYear], history: [])

        #expect(result.filled?.email == "olga@bargemusic.org")
        #expect(result.filled?.showName == "Bargemusic")
        #expect(result.suggestions.isEmpty)
        #expect(result.emptyReason == nil)
    }

    // "Most recent first": two past emails to the same org, the newer one wins.
    @Test func theMostRecentAddressHeEmailedWins() {
        let now = prospect("Bargemusic")
        let older = prospect("Bargemusic", date: "2024-11-14")
        let newer = prospect("Bargemusic", date: "2025-11-14")
        sent(older, "boxoffice@bargemusic.org", on: Date(timeIntervalSince1970: 1_600_000_000))
        sent(newer, "olga@bargemusic.org", on: Date(timeIntervalSince1970: 1_700_000_000))

        let result = ManualPrepPrefill.build(for: now, amongst: [now, older, newer], history: [])

        #expect(result.filled?.email == "olga@bargemusic.org")
    }

    // The presenting organisation is an identity too, not just the show's own name: the same annual
    // series can be listed under a different title each year.
    @Test func aPastEmailIsFoundThroughThePresenterAsWellAsTheTitle() {
        let thisYear = prospect("Winter Solstice Concert", presenter: "Every Voice Choirs")
        let lastYear = prospect("Holiday Sing", presenter: "Every Voice Choirs", date: "2025-12-20")
        sent(lastYear, "info@everyvoice.org", on: Date(timeIntervalSince1970: 1_700_000_000))

        let result = ManualPrepPrefill.build(for: thisYear, amongst: [thisYear, lastYear], history: [])

        #expect(result.filled?.email == "info@everyvoice.org")
    }

    // A different organisation's address is not this organisation's address.
    @Test func anAddressFromAnUnrelatedOrgIsNeverOffered() {
        let bargemusic = prospect("Bargemusic")
        let elsewhere = prospect("Brooklyn Youth Chorus", date: "2025-11-14")
        sent(elsewhere, "info@bycnyc.org", on: Date(timeIntervalSince1970: 1_700_000_000))

        let result = ManualPrepPrefill.build(for: bargemusic, amongst: [bargemusic, elsewhere], history: [])

        #expect(result.filled == nil)
        #expect(result.suggestions.isEmpty)
        #expect(result.emptyReason == .nothingFound)
    }

    // The booking sheet is OFFERED, never filled, and it names where it came from.
    @Test func aBookingSheetAddressIsOfferedButNeverFilledIn() {
        let p = prospect("Bargemusic")
        let history = [HistoryRecord(groupName: "Bargemusic", status: "booked",
                                     origin: .bookingImport, email: "olga@bargemusic.org")]

        let result = ManualPrepPrefill.build(for: p, amongst: [p], history: history)

        #expect(result.filled == nil)
        #expect(result.suggestions == [ManualPrepPrefill.Suggestion(email: "olga@bargemusic.org",
                                                                    source: .bookingSheet)])
        #expect(result.emptyReason == nil)
    }

    // That column is free text: it holds "DM on instagram" and Instagram handles as often as addresses.
    // Only things actually shaped like an address are offered.
    @Test func aBookingSheetCellThatIsNotAnAddressIsNotOffered() {
        let p = prospect("Bargemusic")
        let history = [HistoryRecord(groupName: "Bargemusic", status: "booked",
                                     origin: .bookingImport, email: "DM on instagram")]

        let result = ManualPrepPrefill.build(for: p, amongst: [p], history: history)

        #expect(result.suggestions.isEmpty)
        #expect(result.emptyReason == .nothingFound)
    }

    // An address Overture's own research put on this show has the same problem the booking sheet does:
    // nobody has written to it. So it is offered with its source named, never filled.
    @Test func anAddressFoundForThisShowButNeverWrittenToIsOfferedNotFilled() {
        let p = prospect("Bargemusic")
        found(p, "info@bargemusic.org")

        let result = ManualPrepPrefill.build(for: p, amongst: [p], history: [])

        #expect(result.filled == nil)
        #expect(result.suggestions == [ManualPrepPrefill.Suggestion(email: "info@bargemusic.org",
                                                                    source: .foundOnThisShow)])
    }

    // The failure path the issue names: an empty field is not a silent failure. It says which sources
    // were checked and came back empty.
    @Test func withNothingAnywhereTheFieldIsEmptyAndSaysWhatWasChecked() {
        let p = prospect("Bargemusic")

        let result = ManualPrepPrefill.build(for: p, amongst: [p], history: [])

        #expect(result.filled == nil)
        #expect(result.suggestions.isEmpty)
        #expect(result.emptyReason == .nothingFound)
        #expect(ManualPrepCopy.emptyRecipientNote(.nothingFound)
                == "No address to fill in. Checked past emails to this organisation and the booking sheet.")
    }

    // A booking sheet that could not be READ is a different answer from one that held nothing, and the
    // sentence must not claim it was checked (L11).
    @Test func anUnreadableBookingSheetIsReportedAsUnreadableNotAsEmpty() {
        let p = prospect("Bargemusic")

        let result = ManualPrepPrefill.build(for: p, amongst: [p], history: [], historyUnreadable: true)

        #expect(result.emptyReason == .historyUnreadable)
        #expect(ManualPrepCopy.emptyRecipientNote(.historyUnreadable)
                == "No past email to this organisation, and the booking sheet could not be read.")
    }

    // The filled note says where the address came from, so an address that appears by itself is never a
    // mystery: he can see WHICH show and when he wrote to it.
    @Test func theFilledNoteNamesADifferentShowAndWhenHeWroteToIt() {
        let outreach = ManualPrepPrefill.PriorOutreach(
            email: "info@everyvoice.org", showName: "Holiday Sing",
            sentAt: EasternDate.date(from: "2025-11-02")!)

        #expect(ManualPrepCopy.filledRecipientNote(outreach, prepping: "Winter Solstice Concert")
                == "You emailed this address about Holiday Sing on Nov 2, 2025.")
    }

    // #843: on an annual booking the show he emailed and the show he is prepping are the same name, and
    // repeating the name he is already looking at tells him nothing the line above it did not.
    @Test func theFilledNoteDoesNotRepeatTheShowHeIsAlreadyLookingAt() {
        let outreach = ManualPrepPrefill.PriorOutreach(
            email: "olga@bargemusic.org", showName: "Bargemusic",
            sentAt: EasternDate.date(from: "2025-11-02")!)

        #expect(ManualPrepCopy.filledRecipientNote(outreach, prepping: "Bargemusic")
                == "You emailed this address on Nov 2, 2025.")
    }
}

private extension Prospect {
    func withPresenter(_ presenter: String?) -> Prospect {
        self.presenter = presenter
        return self
    }
}
