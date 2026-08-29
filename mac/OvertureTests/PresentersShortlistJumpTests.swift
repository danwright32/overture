import Testing
import Foundation
import SwiftData

// #1794: the Presenters shortlist names the organisations most likely to have been judged wrong, and
// then left Dan to find their shows himself.
//
// That gap is larger than it sounds because the sheet is EVIDENCE ONLY on his own call (2026-07-29): the
// correction lives on the row and nowhere else, so the walk from the suggestion to the place it can be
// acted on was the entire remaining distance. Measured 2026-07-29, the seven shortlisted organisations
// covered 68 rows between them and FRIGID New York alone had 27.
//
// Dan's answer, 2026-08-11: tapping an entry dismisses the sheet and FILTERS the queue to that
// organisation's shows, not opening the first of them. The grain is the reason: the correction is made
// per row, so landing on one card hides the scale and sends him back to the sheet for each of the others.
@Suite("A shortlist entry leads to that organisation's shows (#1794)")
struct PresentersShortlistJumpTests {

    private func store() throws -> ModelContext {
        let container = try ModelContainer(
            for: Prospect.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        return ModelContext(container)
    }

    private func prospect(_ context: ModelContext, group: String, presenter: String?,
                          venue: String, date: String) -> Prospect {
        let p = Prospect(naturalKey: "\(date)|\(venue)|\(group)".lowercased(),
                         groupName: group, discipline: "theatre", venue: venue,
                         performanceDate: date, sourceListingURL: nil, websiteURL: nil,
                         priorRelationship: "none", production: "", profile: "", coverage: "",
                         fitScore: 0, tier: "longshot", fitReason: "",
                         matchedClientName: nil, possibleMatchSource: nil, possibleMatchName: nil,
                         status: .new)
        p.presenter = presenter
        context.insert(p)
        return p
    }

    // The keys come back folded the SAME way the entry's own key was built, so the rows he lands on are
    // exactly the rows the entry counted. Two spellings of one organisation is the case that proves it:
    // a name comparison would return one of them and the count on screen would then be a promise the
    // list does not keep (#863, L16).
    @Test func everySpellingOfTheOrganisationComesBack() throws {
        let context = try store()
        _ = prospect(context, group: "Winter Shorts", presenter: "FRIGID New York",
                     venue: "Under St Marks", date: "2026-11-02")
        _ = prospect(context, group: "Late Night", presenter: "The FRIGID New York",
                     venue: "Kraine Theater", date: "2026-11-03")
        _ = prospect(context, group: "Somebody Else", presenter: "Ars Nova",
                     venue: "Ars Nova", date: "2026-11-04")
        let all = try context.fetch(FetchDescriptor<Prospect>())

        let key = try #require(ProducerGate.key("FRIGID New York"))
        let keys = OrganisationListing.naturalKeys(forOrganisation: key, in: all)

        #expect(keys.count == 2, "the leading 'The' is the same organisation, and the fold says so")
        #expect(keys.allSatisfy { $0.contains("winter shorts") || $0.contains("late night") })
    }

    // The negative direction, which is the half a filter has to get right: another organisation's shows
    // do not come along. A test that only shows the right rows arriving cannot tell that from a filter
    // returning everything.
    @Test func nobodyElsesShowsComeAlong() throws {
        let context = try store()
        _ = prospect(context, group: "Winter Shorts", presenter: "FRIGID New York",
                     venue: "Under St Marks", date: "2026-11-02")
        _ = prospect(context, group: "Somebody Else", presenter: "Ars Nova",
                     venue: "Ars Nova", date: "2026-11-04")
        let all = try context.fetch(FetchDescriptor<Prospect>())

        let key = try #require(ProducerGate.key("FRIGID New York"))
        let keys = OrganisationListing.naturalKeys(forOrganisation: key, in: all)
        #expect(keys.count == 1)
        #expect(!keys.contains { $0.contains("somebody else") })
    }

    // A show with no presenter at all is nobody's, and must not be swept into an organisation's list by a
    // fold that answers nil on both sides.
    @Test func aShowWithNoPresenterBelongsToNoOrganisation() throws {
        let context = try store()
        _ = prospect(context, group: "Unattributed", presenter: nil,
                     venue: "Merkin Hall", date: "2026-11-05")
        let all = try context.fetch(FetchDescriptor<Prospect>())

        let key = try #require(ProducerGate.key("FRIGID New York"))
        #expect(OrganisationListing.naturalKeys(forOrganisation: key, in: all).isEmpty)
    }

    // The request carries its own identity, so tapping one organisation, going back and tapping the SAME
    // one again is two events. Dan's note names this explicitly, and it is #1927's defect: a channel
    // carrying the destination reads the second tap as no change at all and does nothing.
    @Test func tappingTheSameOrganisationTwiceIsTwoRequests() {
        let first = LeadsDeepLink(keys: ["a", "b"], heading: "FRIGID New York")
        let second = LeadsDeepLink(keys: ["a", "b"], heading: "FRIGID New York")
        #expect(first.keys == second.keys)
        #expect(first.heading == second.heading)
        #expect(first != second)
    }

    // The focused list says what it was filtered BY. Without this the heading falls back to the generic
    // new-leads wording, and a filtered queue whose heading does not name the filter is a screen Dan has
    // to remember his own way out of.
    @Test func theFocusedListIsNamedForTheOrganisation() {
        #expect(LeadsDeepLink(keys: ["a"], heading: "FRIGID New York").heading == "FRIGID New York")
        // And the away-alert path is unchanged: no heading means the generic one it has always used.
        #expect(LeadsDeepLink(keys: ["a"]).heading == nil)
    }

    // The wiring, because a callback the sheet never invokes and a queue that never hears about it are
    // both invisible from the domain rules above.
    @Test func theSheetIsHandedARouteAndTheRowUsesIt() throws {
        let view = SourceGuardHelper.source("Overture/UI/OrganisationsView.swift")
        #expect(view.contains("var onShowShows: ((OrganisationListing.Entry) -> Void)?"))
        #expect(view.contains("Button { onShowShows(entry) }"),
                "the row must actually invoke it, or the shortlist still leads nowhere")

        let root = SourceGuardHelper.source("Overture/App/RootView.swift")
        #expect(root.contains("OrganisationsView(onShowShows:"),
                "and RootView must hand one in, or the sheet is drawn with no route at all")
        #expect(root.contains("deepLinkedKeys = LeadsDeepLink(keys: keys, heading: entry.name)"),
                "through the existing leads channel, never a second filter path (Dan's note)")
    }

    // The queue puts the heading on screen rather than accepting one and dropping it.
    @Test func theQueueAppliesTheHeadingItIsGiven() throws {
        let queue = SourceGuardHelper.source("Overture/UI/QueueView.swift")
        let body = try #require(SourceGuardHelper.bodyOfFunction(named: "focusOnLeads", in: queue))
        #expect(body.contains("focusedHeading = heading"))
    }
}
