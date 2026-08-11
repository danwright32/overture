import Testing
import Foundation
import SwiftUI
import ViewInspector
@testable import Overture

// #2204: the messages reaching the SCREEN, which is a separate claim from the decision about which to
// show being right (L3). That gap is the whole issue here: the decision was correct for months, the
// priority rule protecting it was correct, and none of it was ever on screen at the width Dan uses.
@MainActor
@Suite("The app's messages on screen (#2204)")
struct AppNoticeLinesOnScreenTests {
    // The sentences actually drawn. A tooltip is a Text too as far as ViewInspector is concerned, so the
    // help strings are dropped: this suite is about what is ON SCREEN, which is the whole point of #2204.
    private func lines(_ notices: [AppNotice]) -> [String] {
        let view = AppNoticeLines(notices: notices)
        let all = ((try? view.inspect().findAll(ViewType.Text.self)) ?? []).compactMap { try? $0.string() }
        let helps = Set(notices.compactMap(\.help))
        return all.filter { !helps.contains($0) && !$0.isEmpty }
    }

    @Test func aquietAppDrawsNothing() {
        #expect(lines([]).isEmpty)
    }

    @Test func awarningIsOnScreenInItsOwnWords() {
        let notices = [AppNotice(text: "12 sources couldn't be checked", tone: .warning)]
        #expect(lines(notices) == ["12 sources couldn't be checked"])
    }

    // Both, in order, on separate lines. One slot could only ever show one of them.
    @Test func afaultAndTheLastRunsNoteBothRender() {
        let notices = AppNotices.current(
            omniFocusFailing: true,
            status: { var s = StatusLine(); s.set("Prep finished", priority: .info); return s }())

        // #2250: the fault's own line, the control it carries, then the run's note. The control being in
        // this list is the point: a remedy that renders only as a tooltip is one nobody reads (L49), so it
        // is proven to reach the screen rather than merely defined.
        #expect(lines(notices) == [AppNotices.omniFocusFailing.text,
                                   AppNoticeAction.retryOmniFocusSync.title,
                                   "Prep finished"])
    }

    // #2250: and a receipt grows no control, so an ordinary run's note never sprouts a button beside it.
    @Test func areceiptCarriesNoControl() {
        let notices = AppNotices.current(
            omniFocusFailing: false,
            status: { var s = StatusLine(); s.set("Prep finished", priority: .info); return s }())
        #expect(lines(notices) == ["Prep finished"])
    }

    // #2478: the broken-export warning, and its control, on the screen Dan reads. The whole issue is a
    // fault nothing told him about, so "the notice exists" is not the claim worth proving; "the sentence
    // and the button are drawn" is.
    @Test func abrokenBookingExportIsOnScreenWithItsControl() {
        let vanished = DownbeatBookingFeed.Vanished(
            bookingCount: 15, evidence: .theExportCarriedThemUntil("2027-06-13"))
        let notices = AppNotices.current(omniFocusFailing: false, bookingsVanished: vanished,
                                         status: StatusLine())
        #expect(lines(notices) == [AppNotices.downbeatShootsVanished(vanished).text,
                                   AppNoticeAction.recheckDownbeatExport.title])
    }

    // A warning is rust, the colour the possible-match and watch-gap lines beside it use for "this is not
    // a status, something is wrong". A receipt is the faint ink the freshness line uses. Read off the
    // rendered view rather than trusted, since the tone is the only thing telling the two apart at a
    // glance and it renders in both themes.
    @Test func awarningAndAReceiptAreDrawnDifferently() throws {
        func colour(_ notice: AppNotice) throws -> Color? {
            let view = AppNoticeLines(notices: [notice])
            return try view.inspect().find(ViewType.Text.self).attributes().foregroundColor()
        }
        let warned = try colour(AppNotice(text: "12 sources couldn't be checked", tone: .warning))
        let receipt = try colour(AppNotice(text: "Prep finished", tone: .receipt))

        #expect(warned == OVColor.rust)
        #expect(receipt == OVColor.inkFaint)
        #expect(warned != receipt)
    }
}
