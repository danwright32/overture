import Testing
import Foundation

// #2204. Everything the app had to say about itself lived in one `ToolbarItem(placement: .status)`. Dan
// runs Overture at about half screen width, and at that width macOS moves that slot into the toolbar's
// overflow chevron, so its message was not on screen at all. He has never clicked the chevron, so he has
// never read any of them: the do-not-contact receipt (#802, the guard he asked to SEE working), the
// unattended scout's "N sources couldn't be checked" warning, the reply-classify save failure, #2104's
// run-died message.
//
// Every mechanism protecting those messages, StatusLine's priority rule most of all, was worth nothing
// while the surface holding them was off screen at his normal width (L79).
@Suite("What the app has to say for itself (#2204)")
struct AppNoticeTests {
    private func status(_ text: String?, _ priority: StatusPriority = .info) -> StatusLine {
        var line = StatusLine()
        line.set(text, priority: priority)
        return line
    }

    // A quiet app says nothing at all, so the masthead grows no permanent row of reassurance.
    @Test func aquietAppAddsNoLines() {
        #expect(AppNotices.current(status: StatusLine()).isEmpty)
    }

    // A warning and a receipt are different things and are drawn differently. They were one faint grey
    // line in one slot, so "your contact guard stopped an email" and "12 sources couldn't be checked"
    // arrived identically.
    @Test func awarningIsNotDrawnLikeAReceipt() {
        let warned = AppNotices.current(
                                        status: status("12 sources couldn't be checked", .warning))
        let receipt = AppNotices.current(
                                         status: status("Skipped 2 shows for an organisation that asked not to be contacted"))

        #expect(warned.map(\.tone) == [.warning])
        #expect(receipt.map(\.tone) == [.receipt])
    }

    // BOTH show. In the toolbar the OmniFocus failure won the slot outright and the status line was not
    // drawn at all, so an unattended scout's warning could be hidden by an unrelated sync problem: the
    // same silent erasure StatusLine's priority rule exists to prevent, reaching it from outside the rule.
    @Test func asyncFailureNeverHidesWhatTheLastRunHadToSay() {
        let notices = AppNotices.current(omniFocusFailure: (.unexplained, "a reason nobody classified"),
                                         status: status("12 sources couldn't be checked", .warning))

        #expect(notices.count == 2)
        #expect(notices.map(\.text)
                == [AppNotices.omniFocusFailing(.unexplained, reason: "a reason nobody classified").text,
                    "12 sources couldn't be checked"])
        #expect(notices.allSatisfy { $0.tone == .warning })
    }

    // The standing fault reads first: it is true until something is done about it, where the line below
    // it is about one run that has already finished.
    @Test func thestandingFaultIsReadFirst() {
        let notices = AppNotices.current(omniFocusFailure: (.unexplained, "a reason nobody classified"), status: status("Prep finished"))
        #expect(notices.first?.text
                == AppNotices.omniFocusFailing(.unexplained, reason: "a reason nobody classified").text)
    }

    // The sync failure says what to do, not just that something is wrong (L80). #2250 moved the remedy
    // out of the tooltip: the retry is now a CONTROL on the line, and the line itself states what is at
    // stake, so neither depends on Dan hovering. What stays in the tooltip is what to look at if the
    // retry does not clear it, which explains rather than instructs.
    //
    // #2883/#2884: the sentence and the button now come from the KIND. The unexplained case is the one
    // this test was written about and keeps every property it asserted; the kinds' own differences are
    // pinned in `OmniFocusFailureKindTests`.
    @Test func thesyncFailureSaysWhatToDoAboutIt() throws {
        let unexplained = AppNotices.omniFocusFailing(.unexplained, reason: "AppleEvent timed out")
        #expect(unexplained.action == .retryOmniFocusSync)
        #expect(unexplained.text.contains("follow-up tasks"))
        let help = try #require(unexplained.help)
        #expect(help.contains("AppleEvent timed out"), "the stored reason has to reach a surface (#2884)")

        // The deterministic one withholds the control that cannot work, and says so rather than going
        // quiet (#2883, L109).
        let refused = AppNotices.omniFocusFailing(
            .refusedSomeShows, reason: "OmniFocus updated 3 of 4 reminders. It could not update Aurora Strings.")
        #expect(refused.action == nil)
        #expect(refused.text.contains("Aurora Strings"))
        #expect(refused.text.contains("will not change it"))
    }

    // A run's own line carries no tooltip: whatever it had to say is the sentence itself. A notice that
    // hid half of what it meant behind a hover would be a caveat nobody reads (L49).
    @Test func arunsOwnLineSaysEverythingInTheLineItself() {
        let notices = AppNotices.current(status: status("Prep finished"))
        #expect(notices.first?.help == nil)
    }
}

// The wiring: the toolbar no longer holds any of this, and the masthead does.
@Suite("The app's messages are on the masthead, not in the toolbar (#2204)")
struct AppNoticePlacementGuardTests {
    @Test func thetoolbarHasNoStatusSlotLeft() {
        let root = SourceGuardHelper.source("Overture/App/RootView.swift")
        // In a comment explaining why it is gone, and nowhere else.
        let code = root.split(separator: "\n")
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")
        #expect(!code.contains("ToolbarItem(placement: .status)"),
                "macOS hides that slot in the overflow chevron at Dan's ordinary window width")
        #expect(!code.contains("OmniFocus sync failing"))
    }

    @Test func themastheadDrawsThem() throws {
        let queue = SourceGuardHelper.source("Overture/UI/QueueView.swift")
        let masthead = try #require(SourceGuardHelper.bodyOfFunction(named: "masthead", in: queue))
        // #1805: the masthead may filter an offer it cannot serve on the way in, so what this pins is that
        // the notices REACH it, not the exact call shape.
        #expect(masthead.contains("AppNoticeLines("))
        #expect(masthead.contains("notices"))

        let root = SourceGuardHelper.source("Overture/App/RootView.swift")
        // #2478 added the booking-feed verdict to the same call, and #1900 the shoot history's, so this
        // pins each ARGUMENT that decides what the masthead is given, one at a time.
        //
        // Deliberately not one exact line any more: it was pinned as a two-line rendering, and the third
        // argument re-wrapped it, so the guard went red on a change it exists to permit while the wiring
        // it protects was intact (L103).
        for argument in ["notices: AppNotices.current(omniFocusFailure: omniFocusFailure",
                         "bookingsVanished: bookingsVanished",
                         "shootHistory: shootHistoryHealth",
                         "status: status)"] {
            #expect(root.contains(argument),
                    "the masthead has to be given \(argument), or it draws an empty list forever")
        }
    }

    // It wraps rather than clips. That is the property the move exists to gain: #1411's rule was that the
    // one thing Dan can act on is never truncated, and in the toolbar that needed a capsule allowed to
    // grow. A masthead line only has to be allowed to wrap.
    @Test func anoticeWrapsRatherThanBeingCutOff() {
        let lines = SourceGuardHelper.source("Overture/UI/AppNoticeLines.swift")
        #expect(lines.contains("fixedSize(horizontal: false, vertical: true)"))
        #expect(!lines.contains("lineLimit"))
        #expect(!lines.contains("truncationMode"))
    }
}
