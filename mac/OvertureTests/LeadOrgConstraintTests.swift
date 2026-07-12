import Testing
import Foundation
@testable import Overture

// THE BUG DAN CAUGHT ON HIS OWN LEAD, and it is the most dangerous kind this feature can produce.
//
// He pasted his ensemble's show page. Overture could not read it, followed its "BUY TIX HERE" link to
// Lincoln Center, and read that page. Lincoln Center's page carries an "Alice Tully Hall upcoming
// events" sidebar, so it came back with FOUR SHOWS AT ALICE TULLY HALL, all pre-ticked, ready to add:
// Summer Evenings III, IV, V and The Ocean Etched in the Forest.
//
// Every one of them is real. Every one of them is at the right hall. And NOT ONE of them is his
// ensemble: they are presented by the Chamber Music Society of Lincoln Center and by Lincoln Center
// Presents. Meanwhile his ensemble's own concert (Mahler 1 "Titan", June 14) has already happened, so
// the honest answer was "nothing upcoming for them".
//
// The run actually SAID all of that in its note. The app showed "Found 4 shows" anyway and ticked them
// all. An honest note attached to a wrong action is worse than useless: it invites Dan to add four
// strangers' concerts to his pitch queue.
//
// The rule that was missing: WHEN WE FOLLOW A LINK AWAY FROM AN ORG'S OWN SITE, ONLY THAT ORG'S SHOWS
// ARE THE LEAD. A venue page lists the hall's whole calendar, and the hall's other tenants are not the
// organization Dan is trying to track.
@Suite("Lead org constraint (#799)")
struct LeadOrgConstraintTests {
    private func event(_ title: String, presenter: String) -> ScoutExtractEvent {
        ScoutExtractEvent(title: title, presenter: presenter, venue: "Alice Tully Hall",
                          performanceDate: "2026-07-18", sourceUrl: "https://lincolncenter.org/e/1")
    }

    private func results(_ events: [ScoutExtractEvent], note: String? = nil) -> ScoutExtractResults {
        ScoutExtractResults(version: 1, generatedAt: "2026-07-12T00:00:00Z",
                            results: [ScoutExtractResult(sourceId: "lead", verdict: .upcomingListings,
                                                         events: events, note: note)])
    }

    // Dan's exact case. The venue's other tenants must not come back as his lead.
    @Test func aVenuePagesOtherTenantsAreNotTheLead() {
        let r = results([
            event("Summer Evenings III", presenter: "Chamber Music Society of Lincoln Center"),
            event("Summer Evenings IV", presenter: "Chamber Music Society of Lincoln Center"),
            event("The Ocean Etched in the Forest", presenter: "Lincoln Center Presents"),
        ], note: "The lead's own concert has passed; these are the hall's other events.")

        let outcome = LeadIntake.outcome(from: r, sourceId: "lead", onlyForOrg: "Second Ending Ensemble")

        guard case .noUpcomingShows(let message) = outcome else {
            Issue.record("expected .noUpcomingShows, got \(outcome)"); return
        }
        #expect(message.contains("Second Ending Ensemble"))     // says WHOSE shows it was looking for
    }

    // ...and the org's OWN show, on that same venue page, is exactly what we do want.
    @Test func theOrgsOwnShowOnAVenuePageIsTheLead() {
        let r = results([
            event("Summer Evenings III", presenter: "Chamber Music Society of Lincoln Center"),
            event("Second Ending Ensemble: Mahler 1 \"Titan\"", presenter: "Second Ending Ensemble"),
            event("The Ocean Etched in the Forest", presenter: "Lincoln Center Presents"),
        ])

        let outcome = LeadIntake.outcome(from: r, sourceId: "lead", onlyForOrg: "Second Ending Ensemble")

        guard case .found(let events, _) = outcome else {
            Issue.record("expected .found, got \(outcome)"); return
        }
        #expect(events.count == 1)
        #expect(events.first?.title.contains("Mahler") == true)
    }

    // The org's name can be in the TITLE rather than the presenter field: a venue often lists a show as
    // "Second Ending Ensemble: Mahler 1" with itself as presenter.
    @Test func theOrgIsRecognizedInTheTitleToo() {
        let r = results([event("Second Ending Ensemble plays Mahler", presenter: "Lincoln Center")])

        let outcome = LeadIntake.outcome(from: r, sourceId: "lead", onlyForOrg: "Second Ending Ensemble")

        guard case .found(let events, _) = outcome else { Issue.record("expected .found"); return }
        #expect(events.count == 1)
    }

    // NO constraint means no filtering. When Dan pastes a VENUE's own calendar (Bargemusic, Carnegie),
    // every show on it is legitimately the lead: he is watching the hall, not one act. The constraint
    // exists ONLY because we wandered off an org's site onto somebody else's page.
    @Test func withoutAConstraintEverythingOnThePageCounts() {
        let r = results([
            event("Summer Evenings III", presenter: "Chamber Music Society of Lincoln Center"),
            event("The Ocean Etched in the Forest", presenter: "Lincoln Center Presents"),
        ])

        let outcome = LeadIntake.outcome(from: r, sourceId: "lead", onlyForOrg: nil)

        guard case .found(let events, _) = outcome else { Issue.record("expected .found"); return }
        #expect(events.count == 2)
    }
}

// Working out WHO the lead is about, from the page Dan actually pasted. Without this there is nothing
// to constrain the venue page against.
@Suite("Org identity (#799)")
struct OrgIdentityTests {
    private let url = URL(string: "https://www.secondendingensemble.com/single-project-1")!

    // The real page. Wix publishes og:site_name, but jammed together, so it has to be split back into
    // words or it will never match "Second Ending Ensemble" coming off the venue's page.
    @Test func readsTheOrgNameFromTheSitesOwnMetadata() {
        let html = """
        <meta property="og:site_name" content="SecondEndingEnsemble">
        <title>Upcoming Performances | SecondEndingEnsemble</title>
        """
        #expect(OrgIdentity.name(inPage: html, url: url) == "Second Ending Ensemble")
    }

    @Test func splitsAJammedTogetherNameBackIntoWords() {
        #expect(OrgIdentity.splitCamelCase("SecondEndingEnsemble") == "Second Ending Ensemble")
        #expect(OrgIdentity.splitCamelCase("Brooklyn Youth Chorus") == "Brooklyn Youth Chorus")
        #expect(OrgIdentity.splitCamelCase("BAM") == "BAM")           // an acronym is not three words
    }

    // Falls back to the page title, which is where most sites put the org's name.
    @Test func fallsBackToTheTitleThenTheDomain() {
        #expect(OrgIdentity.name(inPage: "<title>Brooklyn Youth Chorus | Home</title>", url: url)
                == "Brooklyn Youth Chorus")
        // Nothing usable at all: the domain is the last honest guess we have.
        #expect(OrgIdentity.name(inPage: "<div>nothing</div>", url: url)?.isEmpty == false)
    }
}
