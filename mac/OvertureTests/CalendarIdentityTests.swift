import Testing
import Foundation
import SwiftData

// #2377: two venues on one ticketing host read as the same calendar.
//
// Dan typed `La MaMa` / `https://ci.ovationtix.com/42` into the Sources sheet and was told "Already
// watching SoHo Playhouse's calendar." SoHo Playhouse is `https://ci.ovationtix.com/35583`: a different
// venue, on the same multi tenant ticketing host, distinguished only by the id in the PATH.
//
// The identity rule was the bare host, written out three times, and the third copy is the dangerous one:
// `newSourceId` stamps its answer on every prospect a source ever surfaces and names the pinned page in
// the handoff folder, so unblocking the add without fixing the id would have inserted La MaMa carrying
// SoHo Playhouse's identity, silently, at the moment it happened.
//
// The rule these tests pin is NOT "compare the whole address". An organisation that publishes /events and
// /calendar must still read as one calendar and collapse to one id, because that is what stops the same
// page being fetched, hashed and read three times a run. It is host, plus the tenant segment only on the
// hosts where the path is what scopes the feed to a venue.
@MainActor
@Suite("A ticketing host's tenants are separate calendars (#2377)")
struct CalendarIdentityTests {

    private func context() throws -> ModelContext {
        ModelContext(try ModelContainer(for: Schema([WatchedSource.self]),
                                        configurations: [ModelConfiguration(isStoredInMemoryOnly: true)]))
    }

    private func sources(_ ctx: ModelContext) throws -> [WatchedSource] {
        try ctx.fetch(FetchDescriptor<WatchedSource>())
    }

    // MARK: - The identity itself

    // The live shape that caused the report. Two OvationTix venues differ only by the numeric client id
    // in the path, which is the only thing that scopes the feed to a venue at all.
    @Test func twoOvationTixTenantsAreDifferentCalendars() {
        #expect(!CalendarIdentity.same("https://ci.ovationtix.com/35583",
                                       "https://ci.ovationtix.com/42"))
    }

    // The non regression that stops this becoming "compare the whole address". Watching an org three
    // times would fetch, hash and read the same page three times every run.
    @Test func onePublishersPagesStillReadAsOneCalendar() {
        #expect(CalendarIdentity.same("https://bargemusic.org/events",
                                      "https://www.bargemusic.org/calendar/2026"))
        #expect(!CalendarIdentity.same("https://bargemusic.org/events",
                                       "https://merkin.example/events"))
    }

    // Deeper paths under one tenant are still that tenant: a production page and the calendar root are
    // the same venue's feed, and OvationTix's own client id parsing is what says so.
    @Test func deeperPathsUnderOneTenantAreStillOneCalendar() {
        #expect(CalendarIdentity.same("https://ci.ovationtix.com/35583",
                                      "https://ci.ovationtix.com/35583/production/1207795"))
    }

    // The Players Theatre's address. The tenant sits under a longer path here, so an identity that read
    // only the first path segment would fold every `web.ovationtix.com` venue back together.
    @Test func theTenantIsFoundWhereverItSitsInAnOvationTixPath() {
        #expect(!CalendarIdentity.same("https://web.ovationtix.com/trs/cal/277",
                                       "https://web.ovationtix.com/trs/cal/9999"))
        #expect(CalendarIdentity.same("https://web.ovationtix.com/trs/cal/277",
                                      "https://web.ovationtix.com/trs/cal/277/performance/5"))
    }

    // #2377 names this one as the same instance waiting to happen: ChorusConnection is multi tenant too,
    // and its tenant is a NAME rather than a number (`/stonewall/events/1599`). Fixing the class rather
    // than the instance (L30) means it is covered before a second chorus is ever typed in.
    @Test func chorusConnectionTenantsAreSeparateCalendars() {
        #expect(!CalendarIdentity.same("https://tickets.chorusconnection.com/stonewall/events/1599",
                                       "https://tickets.chorusconnection.com/otherchorus/events/12"))
        #expect(CalendarIdentity.same("https://tickets.chorusconnection.com/stonewall/events/1599",
                                      "https://tickets.chorusconnection.com/stonewall"))
    }

    // VenueTix gives each venue its own SUBDOMAIN, so the host genuinely IS the identity there. Treating
    // its path as a tenant would split one venue's calendar into a row per page.
    @Test func aPerVenueSubdomainKeepsItsHostAsItsIdentity() {
        #expect(CalendarIdentity.same("https://thegreenroom42.venuetix.com/events",
                                      "https://thegreenroom42.venuetix.com/calendar/2026"))
        #expect(!CalendarIdentity.same("https://thegreenroom42.venuetix.com/events",
                                       "https://otherroom.venuetix.com/events"))
    }

    // MARK: - The source id

    // The dangerous one. A `sourceId` is stamped on every prospect a source surfaces and names its pinned
    // page, so two tenants sharing one id would share one identity in the store and overwrite one pin.
    @Test func twoTenantsOnOneHostGetDifferentSourceIds() {
        #expect(WatchedSource.newSourceId(for: "https://ci.ovationtix.com/35583")
                != WatchedSource.newSourceId(for: "https://ci.ovationtix.com/42"))
    }

    // The same non regression, at the id. One organisation's several pages must still collapse to one id.
    @Test func onePublishersPagesStillCollapseToOneSourceId() {
        #expect(WatchedSource.newSourceId(for: "https://bargemusic.org/events")
                == WatchedSource.newSourceId(for: "https://www.bargemusic.org/calendar/2026"))
    }

    // An id still has to be safe to put in a filename and readable in a queue file.
    @Test func aTenantIdIsStillSafeToPutInAFilename() {
        let id = WatchedSource.newSourceId(for: "https://ci.ovationtix.com/42")
        #expect(id == "ci-ovationtix-com-42")
    }

    // MARK: - The two add routes

    // The visible block Dan hit.
    @Test func aSecondTenantOnAWatchedHostCanBeAdded() throws {
        let ctx = try context()
        #expect(WatchlistEditing.add(orgName: "SoHo Playhouse",
                                     listingsURL: "https://ci.ovationtix.com/35583", into: ctx) == .added)

        #expect(WatchlistEditing.add(orgName: "La MaMa",
                                     listingsURL: "https://ci.ovationtix.com/42", into: ctx) == .added)

        let all = try sources(ctx)
        #expect(all.count == 2)
        #expect(Set(all.map(\.sourceId)).count == 2)
    }

    // And the same host, same tenant, is still refused: the collision this rule exists to prevent.
    @Test func theSameTenantStillCannotBeWatchedTwice() throws {
        let ctx = try context()
        _ = WatchlistEditing.add(orgName: "SoHo Playhouse",
                                 listingsURL: "https://ci.ovationtix.com/35583", into: ctx)

        let again = WatchlistEditing.add(orgName: "SoHo Playhouse Again",
                                         listingsURL: "https://ci.ovationtix.com/35583/production/12",
                                         into: ctx)

        #expect(again == .alreadyWatching(orgName: "SoHo Playhouse"))
        #expect(try sources(ctx).count == 1)
    }

    // The pasted lead route is a second door onto the same rule. Fixing only the Sources sheet would
    // leave the same URL refused by the other one.
    @Test func theLeadRouteAgreesWithTheSourcesSheet() throws {
        let ctx = try context()
        _ = WatchlistEditing.add(orgName: "SoHo Playhouse",
                                 listingsURL: "https://ci.ovationtix.com/35583", into: ctx)
        let existing = try sources(ctx)

        let verdict = WatchedSourceProposal.verdict(
            pageURL: "https://ci.ovationtix.com/42",
            verdict: .upcomingListings,
            events: [ExtractedEvent(title: "Show", presenter: "La MaMa", venue: "La MaMa",
                                    performanceDate: "2099-10-03", sourceUrl: "https://ci.ovationtix.com/42")],
            existing: existing)

        #expect(verdict == .propose(orgName: "La MaMa", listingsURL: "https://ci.ovationtix.com/42"))
    }

    // The same door, on the tenant already watched, still says so.
    @Test func theLeadRouteStillNamesAnAlreadyWatchedTenant() throws {
        let ctx = try context()
        _ = WatchlistEditing.add(orgName: "SoHo Playhouse",
                                 listingsURL: "https://ci.ovationtix.com/35583", into: ctx)
        let existing = try sources(ctx)

        let verdict = WatchedSourceProposal.verdict(
            pageURL: "https://ci.ovationtix.com/35583/production/1207795",
            verdict: .upcomingListings,
            events: [ExtractedEvent(title: "Show", presenter: "SoHo Playhouse", venue: "SoHo Playhouse",
                                    performanceDate: "2099-10-03",
                                    sourceUrl: "https://ci.ovationtix.com/35583")],
            existing: existing)

        #expect(verdict == .alreadyWatching(orgName: "SoHo Playhouse"))
    }

    // A refusal is the one mistake that cannot be taken back, so it must still hold on the tenant that
    // asked, by either door, however deep the path Dan pastes.
    @Test func aRefusedTenantIsStillRefusedByBothDoors() throws {
        let ctx = try context()
        _ = WatchlistEditing.add(orgName: "SoHo Playhouse",
                                 listingsURL: "https://ci.ovationtix.com/35583", into: ctx)
        let row = try #require(try sources(ctx).first)
        row.isActive = false
        row.inactiveReason = .orgRefusal
        try ctx.save()

        #expect(WatchlistEditing.add(orgName: "SoHo Playhouse",
                                     listingsURL: "https://ci.ovationtix.com/35583/production/12",
                                     into: ctx) == .refused(orgName: "SoHo Playhouse"))

        let verdict = WatchedSourceProposal.verdict(
            pageURL: "https://ci.ovationtix.com/35583",
            verdict: .upcomingListings,
            events: [ExtractedEvent(title: "Show", presenter: "SoHo Playhouse", venue: "SoHo Playhouse",
                                    performanceDate: "2099-10-03",
                                    sourceUrl: "https://ci.ovationtix.com/35583")],
            existing: try sources(ctx))
        #expect(verdict == .refused(orgName: "SoHo Playhouse"))

        // And a DIFFERENT tenant on that host is untouched by their refusal. The refusal belongs to the
        // organisation that asked, not to everyone who happens to sell tickets through the same company.
        #expect(WatchlistEditing.add(orgName: "La MaMa",
                                     listingsURL: "https://ci.ovationtix.com/42", into: ctx) == .added)
    }

    // MARK: - The edit route

    // Correcting a source's address goes through the same rule, so repointing La MaMa onto SoHo
    // Playhouse's tenant is a collision while moving it to a free tenant is a plain save.
    @Test func editingAnAddressUsesTheSameIdentity() throws {
        let ctx = try context()
        _ = WatchlistEditing.add(orgName: "SoHo Playhouse",
                                 listingsURL: "https://ci.ovationtix.com/35583", into: ctx)
        _ = WatchlistEditing.add(orgName: "La MaMa",
                                 listingsURL: "https://ci.ovationtix.com/42", into: ctx)
        let laMaMa = try #require(try sources(ctx).first { $0.orgName == "La MaMa" })

        #expect(WatchlistEditing.editURL(laMaMa, to: "https://ci.ovationtix.com/35583", in: ctx)
                == .conflict(orgName: "SoHo Playhouse"))

        #expect(WatchlistEditing.editURL(laMaMa, to: "https://ci.ovationtix.com/43", in: ctx)
                == .saved(sourceId: laMaMa.sourceId))
    }
}
