import Testing
import Foundation
import SwiftData

// #803: CHECKED and READ are not the same thing, and until now the Sources sheet could not tell Dan
// which had happened.
//
// The free daily run fetches and hashes every calendar and reads none of them (his own decision). So a
// source can report "Watching, checked an hour ago" for weeks while nobody has ever actually looked at
// what is on it. That is not a bug, it is the design, but it is invisible, and invisible is how a
// calendar he is counting on goes months without being read while reporting as perfectly healthy.
//
// It is also what makes a page that changes on EVERY load visible. Such a page is re-read on every scout
// Dan runs, forever, and costs him tokens with nothing to show, and the only symptom is a source that is
// somehow never "unchanged".
@Suite("Checked is not the same as read (#803)")
struct SourceReadStateTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private func hoursAgo(_ n: Int) -> Date { now.addingTimeInterval(-Double(n) * 3600) }

    private func source(checked: Date? = nil, succeeded: Date? = nil,
                        unread: Bool = false, kind: SourceKind = .html) -> WatchedSource {
        let s = WatchedSource(sourceId: "org", orgName: "Org",
                              listingsURL: "https://org.example/events", kind: kind)
        s.lastCheckedAt = checked
        s.lastSucceededAt = succeeded
        s.hasUnreadChanges = unread
        return s
    }

    @Test func aCalendarNobodyHasEverReadSaysSo() {
        let s = source(checked: hoursAgo(1))   // fetched and hashed, never read
        #expect(SourceReadState.of(s) == .neverRead)
    }

    @Test func aCalendarWeHaveReadSaysWhen() {
        let s = source(checked: hoursAgo(1), succeeded: hoursAgo(72))
        #expect(SourceReadState.of(s) == .read(at: hoursAgo(72)))
    }

    // THE state this exists for. The daily run noticed new listings and did not spend a token reading
    // them, exactly as designed. Dan needs to see that they are WAITING, or the design becomes a leak:
    // shows sitting unread on a calendar that reports as healthy.
    @Test func newListingsWaitingToBeReadAreSaidOutLoud() {
        let s = source(checked: hoursAgo(1), succeeded: hoursAgo(72), unread: true)
        #expect(SourceReadState.of(s) == .unreadChangesWaiting(lastRead: hoursAgo(72)))
    }

    @Test func newListingsOnACalendarNeverReadAreAlsoWaiting() {
        let s = source(checked: hoursAgo(1), unread: true)
        #expect(SourceReadState.of(s) == .unreadChangesWaiting(lastRead: nil))
    }

    // Carnegie has no page to read: its shows arrive from a structured feed, natively, on every run.
    // Reporting it as "never read" would be a lie that Dan cannot act on.
    @Test func aNativeFeedIsNotJudgedOnWhetherItsPageWasRead() {
        let s = source(checked: hoursAgo(1), succeeded: hoursAgo(1), kind: .algolia)
        #expect(SourceReadState.of(s) == .read(at: hoursAgo(1)))
    }

    // MARK: - What Dan reads

    @Test func everyStateSaysWhatItIsInWords() {
        #expect(SourceReadState.neverRead.label.localizedCaseInsensitiveContains("read"))
        #expect(SourceReadState.unreadChangesWaiting(lastRead: nil).label
                    .localizedCaseInsensitiveContains("new"))
        #expect(SourceReadState.read(at: now).label(now: now).isEmpty == false)
    }

    // The waiting state is the one that needs Dan to DO something (run a scout), so it says so, and it
    // is the only one that does.
    @Test func onlyTheWaitingStateAsksDanForAnything() {
        #expect(SourceReadState.unreadChangesWaiting(lastRead: nil).needsAScout)
        #expect(SourceReadState.neverRead.needsAScout == false)
        #expect(SourceReadState.read(at: now).needsAScout == false)
    }
}

// #1758: the row's most prominent, most scannable line said "Checked 1 hour ago" on two sources whose
// own body said the page had never been read. Measured on the live app 2026-07-29, both rows sitting in
// "Needs a look".
//
// The word was doing two jobs. Inside the app it means "a run touched this source", which is true on the
// failure path too (`ScoutExtractIngest.fail` stamps `lastCheckedAt`). On screen, beside an org name, it
// reads as "we have current information about this org", which is false when nothing was read. The
// reader has to get to the third line of the row to find out the first one was wrong.
//
// It matters beyond those two rows: if "Checked" can mean "attempted and got nothing", the timestamp is
// untrustworthy everywhere on the sheet, and a stale source sits looking fresh.
@Suite("The checked line may not claim a read that did not happen (#1758)")
struct CheckedLineIsHonestTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private func hoursAgo(_ n: Int) -> Date { now.addingTimeInterval(-Double(n) * 3600) }

    private func line(_ failure: SourceFailure?, at: Date? = nil) -> String {
        SourceReadState.lastCheckedLine(at: at ?? hoursAgo(1), now: now, failure: failure)
    }

    // The ordinary, healthy case, and the one the sheet is mostly made of: the daily run fetched and
    // hashed this calendar and came home clean. Nothing about that changes. Reading is a separate
    // question the read-state line below it answers (#803).
    @Test func aCheckThatCameHomeCleanStillReadsAsChecked() {
        #expect(line(nil) == "Checked 1 hour ago")
    }

    // Dan's two rows. The run died before opening the page, so nothing about this org was learned, and
    // the line may not imply otherwise.
    @Test func aRunThatDiedBeforeOpeningThePageSaysItWasTried() {
        #expect(line(.verdict(.notRead)) == "Tried 1 hour ago")
    }

    // Never reached the site at all: a 404, a dead host, a certificate the fetch refused.
    @Test func aFetchThatNeverGotThePageSaysItWasTried() {
        #expect(line(.fetch(.unreachable)) == "Tried 1 hour ago")
        #expect(line(.fetch(.http(404))) == "Tried 1 hour ago")
    }

    // #958: the page came back as an empty shell because the calendar is drawn by JavaScript. Fetched,
    // yes; read, no.
    @Test func aJavaScriptDrawnPageSaysItWasTried() {
        #expect(line(.verdict(.unreadable)) == "Tried 1 hour ago")
    }

    // #857: the page was opened, but the run's results contradicted themselves and nothing from it was
    // used. Whatever is on that calendar, Overture does not know it.
    @Test func aRunWhoseResultsWereDiscardedSaysItWasTried() {
        #expect(line(.inconsistentResult) == "Tried 1 hour ago")
    }

    // The distinction that keeps this honest in BOTH directions. A `no_dated_content` page was read, in
    // full, and simply had nothing dated on it: that IS current information about the org, so calling it
    // an attempt would understate what Overture knows and would put a second false line where the first
    // one was. The failure line beneath still says the page is empty.
    @Test func aPageReadInFullWithNothingDatedOnItIsStillAChecked() {
        #expect(line(.verdict(.noDatedContent)) == "Checked 1 hour ago")
    }

    // Every verdict is classified, and only two of them mean the page went unread. Stated over the whole
    // enum rather than the two the sheet happens to show, because the classification is a fact about the
    // verdict, not about which rows are on screen today. A verdict added later is a compile error in the
    // switch behind this, so nobody can add one and leave the sheet quietly claiming a read.
    @Test func exactlyTheTwoVerdictsThatNeverOpenedThePageCountAsUnread() {
        let unread = Set(PageVerdict.allCases.filter(\.leftThePageUnread))
        #expect(unread == [.unreadable, .notRead])
    }

    // "Never" is a real answer and stays one, whatever the row's failure says: there is no attempt to
    // date, so there is nothing for the word to be wrong about.
    @Test func aSourceNothingHasHappenedToStillSaysNeverChecked() {
        #expect(SourceReadState.lastCheckedLine(at: nil, now: now, failure: nil) == "Never checked")
        #expect(SourceReadState.lastCheckedLine(at: nil, now: now, failure: .verdict(.notRead))
                == "Never checked")
    }

    // The guard and its wiring are two claims (#887). The rule above is only true on screen if the sheet
    // actually hands the row's failure to it; without that argument every row reads "Checked" again with
    // every domain test still green. This is the same wiring defect #843 had to pin one line lower.
    @Test func theSheetHandsTheFailureToTheCheckedLine() {
        let sourcesView = SourceGuardHelper.source("Overture/UI/SourcesView.swift")
        #expect(sourcesView.contains(
            "SourceReadState.lastCheckedLine(at: source.lastCheckedAt, now: Date(), failure: source.lastFailure)"))
    }
}
