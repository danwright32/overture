import Testing
import Foundation

// #1209: a known client's own calendar is read a full YEAR ahead (not the four-month default), so a
// returning client's far-future date is surfaced with enough lead time to pitch again. "Known client" is
// decided by ONE authority (ClientHorizon), read by both the fetch side (how many months to read) and the
// Prep side (how far out a show still defaults into a run), so the two windows can never drift apart.
//
// A source is a client's when Dan has TAGGED it, or (absent a tag) its org name confidently matches a
// Downbeat client. The tag overrides both directions: force-ON for a client performing at a shared venue
// the name-match cannot catch (the source's org name is the venue, not the client), and force-OFF for a
// coincidental name match that is not really a client.
@Suite("Client lookahead horizon authority (#1209)")
struct ClientHorizonTests {
    private func client(_ name: String, short: String? = nil) -> DownbeatClient {
        DownbeatClient(id: name, displayName: name, shortName: short, email: "", contractEmail: "",
                       phoneNumber: nil, isTaxExempt: nil, hasLeftReview: false, specialBehaviors: [],
                       notes: nil, hostingSite: "")
    }

    private func source(_ org: String, tag: Bool? = nil) -> WatchedSource {
        let s = WatchedSource(sourceId: org, orgName: org, listingsURL: "https://\(org).example/e", kind: .html)
        s.clientTagOverride = tag
        return s
    }

    private let clients = [DownbeatClient(id: "byc", displayName: "Brooklyn Youth Chorus", shortName: nil,
                                          email: "", contractEmail: "", phoneNumber: nil, isTaxExempt: nil,
                                          hasLeftReview: false, specialBehaviors: [], notes: nil, hostingSite: "")]

    @Test func aSourceWhoseOrgMatchesAClientReadsAFullYear() {
        #expect(ClientHorizon.isClient(source("Brooklyn Youth Chorus"), clients: clients))
        #expect(ClientHorizon.months(for: source("Brooklyn Youth Chorus"), clients: clients) == ClientHorizon.clientMonths)
        #expect(ClientHorizon.clientMonths == 12)
    }

    @Test func anUnrelatedSourceKeepsTheFourMonthDefault() {
        #expect(!ClientHorizon.isClient(source("Some Random Venue"), clients: clients))
        #expect(ClientHorizon.months(for: source("Some Random Venue"), clients: clients) == CalendarMonthIndex.defaultHorizon)
    }

    // The shared-venue case: the source's org name is the VENUE, so the name-match misses the client who
    // performs there. Dan tags it, and it gets the year horizon anyway.
    @Test func aManualTagForcesTheClientHorizonEvenWithNoNameMatch() {
        let venue = source("The Shared Venue", tag: true)
        #expect(ClientHorizon.isClient(venue, clients: clients))
        #expect(ClientHorizon.months(for: venue, clients: clients) == ClientHorizon.clientMonths)
    }

    // The other direction: a coincidental name match Dan knows is not a client is forced off.
    @Test func aManualUntagForcesTheDefaultEvenWithANameMatch() {
        let notReally = source("Brooklyn Youth Chorus", tag: false)
        #expect(!ClientHorizon.isClient(notReally, clients: clients))
        #expect(ClientHorizon.months(for: notReally, clients: clients) == CalendarMonthIndex.defaultHorizon)
    }

    // #1351: a client filed under a single-token acronym ("NYYS") auto-arms from its spelled-out watched
    // source ("New York Youth Symphony"), through the SAME matcher, with no manual tag needed.
    @Test func anAcronymClientArmsFromItsSpelledOutSource() {
        let acronymClients = [client("NYYS")]
        #expect(ClientHorizon.matchesClientName("New York Youth Symphony", clients: acronymClients))
        #expect(ClientHorizon.isClient(source("New York Youth Symphony"), clients: acronymClients))
        #expect(ClientHorizon.months(for: source("New York Youth Symphony"), clients: acronymClients) == ClientHorizon.clientMonths)
    }

    // The org-name arming is DERIVED, never stored, so it self-disarms the moment the org stops matching
    // (a client removed from Downbeat): no stale forever-flag.
    @Test func nameMatchArmingDisarmsWhenTheClientIsGone() {
        let s = source("Brooklyn Youth Chorus")
        #expect(ClientHorizon.isClient(s, clients: clients))
        #expect(!ClientHorizon.isClient(s, clients: []))            // client no longer on the list
    }

    // #1429: the Sources sheet used to call `isClient` once per row on EVERY redraw, and each call runs a
    // token-set fuzzy match against the whole Downbeat client list, so a long scroll (with the sheet's
    // scroll-hold re-running the list on every tick) added up on the main thread. `clientFlags` decides it
    // for every source in one pass so the sheet can cache the map and read each row's flag in O(1). It must
    // agree with `isClient` source-for-source, tag overrides in both directions included, or a row would
    // show the wrong returning-client state and horizon.
    @Test func clientFlagsAgreesWithIsClientForEverySource() {
        let nameMatch = source("Brooklyn Youth Chorus")          // auto-arms on name
        let noMatch = source("Some Random Venue")                 // no client matches
        let forcedOn = source("The Shared Venue", tag: true)      // tagged on with no name match
        let forcedOff = WatchedSource(sourceId: "byc-off", orgName: "Brooklyn Youth Chorus",
                                      listingsURL: "https://byc-off.example/e", kind: .html)
        forcedOff.clientTagOverride = false                       // tagged off despite a name match
        let sources = [nameMatch, noMatch, forcedOn, forcedOff]

        let flags = ClientHorizon.clientFlags(sources: sources, clients: clients)
        for s in sources {
            #expect(flags[s.sourceId] == ClientHorizon.isClient(s, clients: clients))
        }
    }

    // MARK: The Prep-run default window uses the same authority

    private func prospect(_ key: String, date: String, sourceIds: [String] = [],
                          relationship: String = "none", matched: String? = nil) -> Prospect {
        let p = Prospect(naturalKey: key, groupName: key, discipline: "music", venue: "V",
                         performanceDate: date, sourceListingURL: nil, websiteURL: nil,
                         priorRelationship: relationship, production: "concert", profile: "unknown",
                         coverage: "unknown", fitScore: 50, tier: "medium", fitReason: "t",
                         matchedClientName: matched, possibleMatchSource: nil, possibleMatchName: nil)
        p.sourceIds = sourceIds
        return p
    }

    private func fixedNow() -> Date {
        var c = DateComponents(); c.year = 2026; c.month = 7; c.day = 15
        c.timeZone = TimeZone(identifier: "America/New_York")
        return Calendar(identifier: .gregorian).date(from: c)!
    }

    @Test func prepMonthsFollowsTheSourceAndTheClientMatch() {
        let clientSource = source("Anytown Venue", tag: true)   // tagged a client's
        let plainSource = source("Some Org")
        // From a client source: the year window.
        #expect(ClientHorizon.prepMonths(for: prospect("a", date: "2027-05-01", sourceIds: ["Anytown Venue"]),
                                         sources: [clientSource], clients: []) == ClientHorizon.clientMonths)
        // A booked prospect from an untagged source: still the year window, because it matched a client.
        #expect(ClientHorizon.prepMonths(for: prospect("b", date: "2027-05-01", sourceIds: ["Some Org"], relationship: "booked"),
                                         sources: [plainSource], clients: []) == ClientHorizon.clientMonths)
        // An ordinary prospect from an ordinary source: the four-month default.
        #expect(ClientHorizon.prepMonths(for: prospect("c", date: "2027-05-01", sourceIds: ["Some Org"]),
                                         sources: [plainSource], clients: []) == CalendarMonthIndex.defaultHorizon)
    }

    // The point of Phase B: a client's far-future show DEFAULTS IN, where an identical non-client show is
    // held out, and a near-term ordinary show is still in.
    @Test func prepDefaultSelectionKeepsAClientsFarFutureShowButHoldsANonClientsAtTheSameDate() {
        let clientSource = source("Anytown Venue", tag: true)
        let plainSource = source("Some Org")
        let farClient = prospect("far-client", date: "2027-05-01", sourceIds: ["Anytown Venue"])   // ~10 months out
        let farPlain = prospect("far-plain", date: "2027-05-01", sourceIds: ["Some Org"])          // ~10 months out
        let nearPlain = prospect("near-plain", date: "2026-09-01", sourceIds: ["Some Org"])        // ~2 months out

        let selected = PrepQueueBuilder.prepDefaultSelection(
            prospects: [farClient, farPlain, nearPlain],
            sources: [clientSource, plainSource], clients: [], now: fixedNow())

        #expect(selected.contains("far-client"))       // client show a year out defaults IN
        #expect(!selected.contains("far-plain"))        // identical non-client show is held out
        #expect(selected.contains("near-plain"))        // ordinary near-term show still defaults in
    }

    // MARK: The Sources-sheet wording

    @Test func theSourceLabelStatesWhyAndOnlyWhenThereIsSomethingToSay() {
        #expect(ClientTagCopy.stateLabel(isClient: true, override: true)?.contains("year") == true)
        #expect(ClientTagCopy.stateLabel(isClient: false, override: false) == "Not treated as a returning client.")
        #expect(ClientTagCopy.stateLabel(isClient: true, override: nil)?.contains("Downbeat") == true)
        // The overwhelmingly common case: an untagged source no client matches says nothing at all.
        #expect(ClientTagCopy.stateLabel(isClient: false, override: nil) == nil)
        // #1358: when the "always" tag names a specific Downbeat client, the line names it, and still
        // states the year-ahead horizon. A bare "always" (no named client) keeps the unnamed wording.
        #expect(ClientTagCopy.stateLabel(isClient: true, override: true, namedClient: "Brooklyn Youth Chorus")?
            .contains("Brooklyn Youth Chorus") == true)
        #expect(ClientTagCopy.stateLabel(isClient: true, override: true, namedClient: "Brooklyn Youth Chorus")?
            .contains("year") == true)
        #expect(ClientTagCopy.stateLabel(isClient: true, override: true, namedClient: nil)?
            .contains("Brooklyn") == false)
    }
}

// #1429: the "Always" override submenu on the Sources sheet listed the whole client roster sorted by name,
// and re-sorted it every time a row's menu was built. Sorting is done once, through this pure helper, so it
// can be tested and so the sheet sorts the roster a single time at load instead of per menu per redraw.
@Suite("Downbeat client display sort (#1429)")
struct DownbeatClientSortTests {
    private func client(_ name: String) -> DownbeatClient {
        DownbeatClient(id: name, displayName: name, shortName: nil, email: "", contractEmail: "",
                       phoneNumber: nil, isTaxExempt: nil, hasLeftReview: false, specialBehaviors: [],
                       notes: nil, hostingSite: "")
    }

    @Test func sortsByDisplayNameCaseInsensitivelyAscending() {
        let sorted = DownbeatClient.sortedByName([client("Zeta"), client("alpha"), client("Beta")])
        #expect(sorted.map(\.displayName) == ["alpha", "Beta", "Zeta"])
    }
}
