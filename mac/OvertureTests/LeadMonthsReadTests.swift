import Foundation
import SwiftData
import Testing
@testable import Overture

// #858. When Dan pastes a venue's calendar, Overture now reads four months of it rather than only the
// month the site happened to land him on. He has to be TOLD that, for two reasons.
//
// A shortfall must be able to say its own name. If September's page 404s, three months come back instead
// of four, and "fewer shows than the calendar really has" is indistinguishable from "that venue has a
// quiet autumn" unless we say so. The spike found the quiet season is the NORMAL state, which is exactly
// why an unread month can hide inside it.
//
// And silently swapping what he asked for is the kind of quiet cleverness that makes a tool untrustworthy
// (the same reason the ticket-link hop announces itself). He pasted one page; he is getting four.
@Suite("Telling Dan which months of a calendar were actually read (#858)")
@MainActor
struct LeadMonthsReadTests {

    private var scratch: ModelContext {
        ModelContext(try! ModelContainer(for: Schema([Prospect.self]),
                                         configurations: [ModelConfiguration(isStoredInMemoryOnly: true)]))
    }

    private static let calendarHTML =
        "<h1>Merkin Hall Calendar</h1>"
        + "<p>Kaufman Music Center presents concerts at Merkin Hall on the Upper West Side, with "
        + "tickets, discounts and directions available here throughout the season, and a full "
        + "programme of chamber music, recitals and new work running from autumn into the spring.</p>"
        + "<ul>"
        + "<li><a href=\"/mch/event/publiquartet\">October 17: PUBLIQuartet, an evening of new "
        + "commissions and improvisation in the main hall on the second floor</a></li>"
        + "<li><a href=\"/mch/event/orli-shaham\">October 5: Orli Shaham, In Clara's Hands, a recital "
        + "built around the works of Clara Schumann and her circle</a></li>"
        + "</ul>"

    private func model(_ page: FetchedPage) -> LeadIntakeModel {
        LeadIntakeModel(defaults: UserDefaults(suiteName: "LeadMonthsRead-\(UUID().uuidString)")!,
                        fetch: { _ in page },
                        pin: { _, _ in URL(fileURLWithPath: "/tmp/pinned.html") },
                        launch: { _ in },
                        readResults: { _ in nil })
    }

    private func page(read: [String], unread: [String], unreachable: [String] = []) -> FetchedPage {
        FetchedPage(normalizedHTML: Self.calendarHTML,
                    finalURL: "https://www.kaufmanmusiccenter.org/mch/calendar/",
                    contentHash: "h", monthsRead: read, monthsUnread: unread,
                    monthsUnreachable: unreachable)
    }

    private func start(_ m: LeadIntakeModel) async {
        m.urlText = "https://www.kaufmanmusiccenter.org/mch/calendar/"
        await m.start(into: scratch, now: Date(), today: ScoutTestClock.beforeAllFixtures,
                      pollEvery: 0, giveUpAfter: 0, sleep: { _ in })
    }

    // He pasted one page and is getting four months. Say so.
    @Test func heIsToldWhenFourMonthsOfACalendarWereRead() async {
        let m = model(page(read: ["2026-07", "2026-08", "2026-09", "2026-10"], unread: []))
        await start(m)

        #expect(m.monthsNote?.contains("4 months") == true)
        #expect(m.monthsNote?.contains("July") == true)
        #expect(m.monthsNote?.contains("October") == true)
    }

    // THE ONE THAT MATTERS. A month we could not read is NAMED. Otherwise a 404 on October's page is
    // indistinguishable from Kaufman having nothing on in October, and October is their busiest month.
    @Test func aMonthThatCouldNotBeReadIsNamedToHim() async {
        let m = model(page(read: ["2026-07", "2026-08", "2026-09"], unread: ["2026-10"]))
        await start(m)

        #expect(m.monthsNote?.contains("October 2026") == true)
        #expect(m.monthsNote?.lowercased().contains("couldn't read") == true)
    }

    // A single show page is not a calendar and was never paginated. Do not tell him about months he
    // never asked about: a note that fires on every lead is a note nobody reads.
    @Test func aPageThatWasNotACalendarSaysNothingAboutMonths() async {
        let m = model(page(read: [], unread: []))
        await start(m)

        #expect(m.monthsNote == nil)
    }

    // #900. THE CASE THAT SAID NOTHING AT ALL. The calendar's month links are a shape we cannot follow
    // (a query, a fragment, an opaque next), so there was never a page to fetch and never one to fail.
    // Nothing went wrong anywhere, and Dan was handed one month of a four month season.
    //
    // Which is indistinguishable, on the sheet, from a hall with a quiet autumn. So it is named.
    @Test func aCalendarWeCannotPageThroughSaysSoRatherThanLookingQuiet() async {
        let m = model(page(read: [], unread: [], unreachable: ["2026-08", "2026-09", "2026-10"]))
        await start(m)

        let note = try! #require(m.monthsNote)
        #expect(note.contains("August 2026"))
        #expect(note.contains("October 2026"))
        #expect(note.lowercased().contains("calendar"))
    }

    // ...and it is ACTIONABLE. A month whose link we cannot follow is not a dead end for Dan the way a
    // 404 is: that month's page is right there on the site, and he can paste it himself. Telling him a
    // month is missing without telling him what to do about it just makes him feel worse.
    @Test func heIsToldWhatHeCanDoAboutAMonthWeCannotReach() async {
        let m = model(page(read: [], unread: [], unreachable: ["2026-10"]))
        await start(m)

        #expect(m.monthsNote?.lowercased().contains("paste") == true)
    }

    // The two shortfalls are DIFFERENT and must not be collapsed into one sentence. October 404'd (it may
    // well work tomorrow); November's link is a shape we cannot follow (it never will, until the app
    // learns it). Only one of them is worth Dan pasting a link for.
    @Test func aMonthThat404edAndAMonthWeCannotReachAreToldApart() async {
        let m = model(page(read: ["2026-07", "2026-08"], unread: ["2026-10"], unreachable: ["2026-11"]))
        await start(m)

        let note = try! #require(m.monthsNote)
        #expect(note.lowercased().contains("couldn't read"))
        #expect(note.contains("October 2026"))
        #expect(note.contains("November 2026"))
        #expect(note.range(of: "October 2026")!.lowerBound < note.range(of: "November 2026")!.lowerBound)
    }
}
