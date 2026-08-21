import Testing
import Foundation
import SwiftUI
import ViewInspector
@testable import Overture

// #3068: `StandDownCopy.closingNoteOnStoodDownShow` was built by #1740 for the post-event row and never
// rendered, so the row asks how a show ended with no sign that Dan had already walked away from it.
//
// The state it speaks for is reachable, and the route matters, because the obvious reading is that it is
// not: `ProspectMutations.standDown(scope: .show)` writes the stand-down stamp AND `showOutcome`, and
// `PostEventPrompt.nextPromptDate` refuses on any recorded outcome, so a freshly stood-down show has no
// post-event row at all. `reopenOutcome` is what opens it: it clears the outcome and the contacts'
// resolutions and leaves the stamp, which is the whole point of the sentence. Dan reopened a show he had
// stopped working months ago, and the row that comes back says nothing about that.
//
// Measured on the live store 2026-08-21: one stood-down show, carrying `turned_them_down`. So the first
// test here is not decoration, it is the proof that the branch the other two read is one the app can
// actually be in (L159).
@MainActor
@Suite("The post-event row says the show was stood down (#3068)")
struct StoodDownShowNoteOnScreenTests {

    private func day(_ s: String) -> Date { EasternDate.date(from: s)! }
    private var now: Date { day("2026-08-21") }
    private var monthsAgo: Date { day("2026-05-20") }

    private func show() -> (Prospect, Recipient) {
        let p = Prospect(naturalKey: "k", groupName: "Aurora Strings", discipline: "music",
                         venue: "Rivermill Hall", performanceDate: "2026-06-10", sourceListingURL: nil,
                         websiteURL: nil, priorRelationship: "none", production: "self", profile: "strong",
                         coverage: "likely_uncovered", fitScore: 8, tier: "high", fitReason: "r",
                         matchedClientName: nil, possibleMatchSource: nil, possibleMatchName: nil,
                         status: .contacted)
        let r = Recipient(id: "rowan@aurorastrings.example", email: "rowan@aurorastrings.example",
                          name: "Rowan", provenance: .act)
        r.sendState = .sent
        r.sentAt = day("2026-05-01")
        r.gmailMessageId = "m1"
        r.gmailThreadId = "t1"
        r.sendGroupId = "g"
        p.setRecipients([r])
        p.sentAt = r.sentAt
        return (p, r)
    }

    private func texts(_ view: some View) -> [String] {
        ((try? view.inspect().findAll(ViewType.Text.self)) ?? []).compactMap { try? $0.string() }
    }

    private func drawn(_ p: Prospect, _ r: Recipient) -> some View {
        let prompt = PostEventPrompt.prompt(for: r, of: p, now: now)!
        return FollowUpsView()
            .postEventRow(PostEventPrompt.DueRecipient(prospect: p, recipient: r, prompt: prompt),
                          since: nil, sourceCalendars: [:], now: now)
    }

    // The reachable state, proved rather than assumed: stand the show down, then reopen the outcome, and
    // the post-event prompt comes back while the stand-down stamp stays.
    @Test func reopeningAStoodDownShowLeavesTheStampAndBringsTheRowBack() {
        let (p, r) = show()
        p.standDownOutreach(now: monthsAgo)
        p.showOutcome = .turnedThemDown
        #expect(PostEventPrompt.prompt(for: r, of: p, now: now) == nil)   // no row while the ending stands

        p.showOutcome = nil                                              // what reopenOutcome does
        #expect(p.outreachStoodDownAt == monthsAgo)
        #expect(PostEventPrompt.prompt(for: r, of: p, now: now) != nil)
    }

    // The defect: that row asks how the show ended with nothing saying he had already stopped working it.
    @Test func theRowSaysHeStoppedWorkingTheShow() {
        let (p, r) = show()
        p.standDownOutreach(now: monthsAgo)
        let expected = StandDownCopy.closingNoteOnStoodDownShow(stoodDownAt: monthsAgo, now: now)!

        #expect(texts(drawn(p, r)).contains(expected))
    }

    // And a show he never stood down does not gain a line about a decision he never made.
    @Test func aShowHeNeverStoodDownGainsNoLine() {
        let (p, r) = show()
        let lines = texts(drawn(p, r))

        #expect(lines.contains("Aurora Strings"))
        #expect(!lines.contains(where: { $0.contains("stopped working this show") }))
    }
}
