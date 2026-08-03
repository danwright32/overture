import Testing
import Foundation

// Dan's rule (2026-07-12), and it is a product decision that DELETES a bug rather than patching one:
//
//   "We just shouldn't allow the same link twice, because if I'm adding a lead that means we should
//    be scouting them regularly. So no need to check it again through that flow."
//
// The bug it removes: the sheet waited for the extract run by reading the results file, and a second
// paste of the SAME link would find the PREVIOUS run's file sitting there under the same id and hand
// back its stale shows instantly, without waiting for the fresh read. Dan would have seen old results
// and had no way to know.
//
// Once a link cannot be submitted twice, that can never happen. The right answer to "I already gave
// you this" is not to re-read it: it is to say so, because the org belongs on the watchlist and will
// be re-checked on its own.
@Suite("Lead submissions (#799)")
struct LeadSubmissionsTests {
    private func scratch() -> UserDefaults {
        let d = UserDefaults(suiteName: "LeadSubmissionsTests-\(UUID().uuidString)")!
        d.removePersistentDomain(forName: d.description)
        return d
    }

    @Test func alinkIsNotSubmittedUntilItIsActuallyAdded() {
        let d = scratch()
        let url = URL(string: "https://bargemusic.org/calendar")!
        #expect(!LeadSubmissions.contains(url, in: d))

        LeadSubmissions.record(url, in: d)
        #expect(LeadSubmissions.contains(url, in: d))
    }

    // The same page, spelled the three ways a person actually pastes it, is the SAME page. Otherwise
    // the rule is trivially defeated by a trailing slash and Dan re-reads the page he already gave us.
    @Test func theSameLinkSpelledDifferentlyIsStillTheSameLink() {
        let d = scratch()
        LeadSubmissions.record(URL(string: "https://www.bargemusic.org/calendar/")!, in: d)

        #expect(LeadSubmissions.contains(URL(string: "https://bargemusic.org/calendar")!, in: d))
        #expect(LeadSubmissions.contains(URL(string: "http://www.bargemusic.org/calendar")!, in: d))
        #expect(LeadSubmissions.contains(URL(string: "https://BARGEMUSIC.org/Calendar/")!, in: d))
    }

    // ...but a DIFFERENT page on the same site is a different lead. An org's events page and one show's
    // page are not interchangeable, and Dan may legitimately hand over both.
    @Test func aDifferentPageOnTheSameSiteIsADifferentLead() {
        let d = scratch()
        LeadSubmissions.record(URL(string: "https://bargemusic.org/calendar")!, in: d)

        #expect(!LeadSubmissions.contains(URL(string: "https://bargemusic.org/concert/beethoven")!, in: d))
    }

    // A query string is part of the page for these purposes: many season pages are ?season=2027.
    @Test func aQueryStringDistinguishesTwoPages() {
        let d = scratch()
        LeadSubmissions.record(URL(string: "https://org.example/events?season=2026")!, in: d)

        #expect(LeadSubmissions.contains(URL(string: "https://org.example/events?season=2026")!, in: d))
        #expect(!LeadSubmissions.contains(URL(string: "https://org.example/events?season=2027")!, in: d))
    }
}
