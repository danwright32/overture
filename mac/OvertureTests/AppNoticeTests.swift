import Testing
import Foundation
import SwiftData

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


    // Which rows qualify is a pure decision beside the sentence, so the masthead holds no logic of its own
    // and every case can be produced by a fixture.
    //
    // Three states must be told apart, and only the first is a notice: a bounce nobody has dealt with, a
    // bounce on a show Dan has already closed out or stood down (he has moved on, and nagging about it is
    // an alert he learns to ignore, L36), and a contact that never bounced at all.
    @Test func onlyABounceNobodyHasDealtWithIsReported() {
        let live = bouncedProspect(show: "Live Show", email: "live@one.example")
        #expect(BounceDetection.unresolvedBounces(in: [live]).map(\.email) == ["live@one.example"])

        let stoodDown = bouncedProspect(show: "Stood Down", email: "down@two.example")
        stoodDown.standDownOutreach(now: Date())
        #expect(BounceDetection.unresolvedBounces(in: [stoodDown]).isEmpty)

        let closed = bouncedProspect(show: "Closed", email: "closed@three.example")
        closed.showOutcome = .booked
        #expect(BounceDetection.unresolvedBounces(in: [closed]).isEmpty)
    }

    @Test func aContactThatNeverBouncedIsNotReported() {
        let fine = bouncedProspect(show: "Fine", email: "fine@four.example")
        fine.recipients.forEach { $0.bounced = false }
        #expect(BounceDetection.unresolvedBounces(in: [fine]).isEmpty)
    }

    // The show is named from the row Dan reads, not from the natural key, because the line puts it in
    // front of him and he works by name.
    @Test func theShowIsNamedTheWayDanReadsIt() {
        let p = bouncedProspect(show: "Every Voice Choirs", email: "a@one.example")
        #expect(BounceDetection.unresolvedBounces(in: [p]).first?.show == "Every Voice Choirs")
    }


    // A prospect carrying one bounced contact. Built rather than stubbed, so the filter is asked about the
    // real model shape it will meet.
    private func bouncedProspect(show: String, email: String) -> Prospect {
        let p = Prospect(naturalKey: show, groupName: show, discipline: "music", venue: "Merkin Hall",
                         performanceDate: "2026-11-02", sourceListingURL: nil,
                         priorRelationship: "none", production: "self", profile: "strong",
                         coverage: "likely_uncovered", fitScore: 5, tier: "mid", fitReason: "r",
                         matchedClientName: nil, possibleMatchSource: nil, possibleMatchName: nil,
                         status: .approved)
        let r = Recipient(id: email, email: email, provenance: .act)
        r.sendState = .sent
        r.sentAt = Date()
        r.bounced = true
        p.addRecipient(r)
        return p
    }



    // --- #2036: a pitch that bounced is said out loud ---------------------------------------------------
    //
    // `BounceService.detectBounces` sets `bounced` on a contact whose thread carries a hard bounce, and
    // that flag correctly takes the contact out of follow-ups and the reached-out queue. Nothing ever told
    // Dan. The show quietly stops being chased, which is indistinguishable from one that was pitched and
    // simply got no answer, so at any real volume he stops pitching organisations whose address was merely
    // typed wrong and never finds out (L10, L13).

    @Test func oneBouncedPitchIsNamedWithItsAddressAndItsShow() {
        let notice = AppNotices.pitchesBounced([
            .init(email: "boxoffice@merkin.example", show: "Every Voice Choirs")
        ])
        #expect(notice?.tone == .warning)
        #expect(notice?.text.contains("boxoffice@merkin.example") == true)
        #expect(notice?.text.contains("Every Voice Choirs") == true)
    }

    // Several become a count, not a list of addresses in one line, exactly as `couldNotRead` does: the
    // addresses go in the help, where there is room for them.
    @Test func severalBouncedPitchesBecomeACountWithTheDetailBehindIt() {
        let notice = AppNotices.pitchesBounced([
            .init(email: "a@one.example", show: "Show One"),
            .init(email: "b@two.example", show: "Show Two")
        ])
        #expect(notice?.text.contains("2") == true)
        #expect(notice?.text.contains("a@one.example") == false)
        #expect(notice?.help?.contains("a@one.example") == true)
        #expect(notice?.help?.contains("b@two.example") == true)
    }

    // The help has to name the act that CLEARS the line, or Dan is left with a permanent alarm and no way
    // to learn what makes it go (L109, L148). That control exists and is on the show's own card.
    @Test func theHelpNamesWhatClearsIt() {
        let notice = AppNotices.pitchesBounced([.init(email: "a@one.example", show: "Show One")])
        #expect(notice?.help?.contains("Not really bounced") == true)
    }

    // Nothing bounced is not a notice. An empty list must produce silence rather than a reassuring line,
    // which is the same rule every other notice on this surface follows.
    @Test func nothingBouncedSaysNothing() {
        #expect(AppNotices.pitchesBounced([]) == nil)
    }

    // And it reaches the stack the masthead draws, which is the half a pure sentence cannot prove (L3).
    @Test func theBouncedLineReachesTheNoticeStack() {
        let notices = AppNotices.current(
            bouncedPitches: [.init(email: "a@one.example", show: "Show One")],
            status: StatusLine())
        #expect(notices.contains { $0.text.contains("a@one.example") })
    }
    // Each sentence is ONE literal, never a concatenation, which is the rule this file states about itself
    // and the thing the cold read depends on: the copy inventory lists literals, so a sentence built from
    // two pieces reaches that review as two fragments and cannot be read as what Dan actually sees (#843).
    // Guarded at the source because a correct sentence assembled from halves still passes every assertion
    // about its text.
    @Test func eachBounceSentenceIsASingleLiteral() {
        let source = SourceGuardHelper.source("Overture/Domain/AppNotice.swift")
        #expect(source.contains("bounced, so nobody ever read it.\""))
        #expect(source.contains("pitches bounced, so nobody ever read them.\""))
    }

    // The wiring the sentence and the filter cannot see between them (L3). Both halves can be perfectly
    // right while the masthead hands the notice an empty list for ever, and that is not a hypothetical
    // shape here: #1912 was exactly it, a field computed by #2741 that nothing ever read.
    //
    // At the source, because the site is a SwiftUI view body, which cannot be tested at all.
    @Test func themastheadHandsTheNoticeTheRowsItJudges() {
        let root = SourceGuardHelper.source("Overture/App/RootView.swift")
        #expect(root.contains("bouncedPitches: BounceDetection.unresolvedBounces("),
                "the masthead must pass the bounced rows, or the line can never be drawn")
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
