import Testing
import Foundation

// #1598 (milestone 32 Phase 5): which shows inherit an answer Dan already paid for, and which must be
// paid for again. Every rule here fails toward paying again, because the two failures are not
// symmetrical: a wrongly reused "no email found" makes him dismiss a bookable show and he never learns
// of it, while a wasted check costs about a dollar and a half.
@Suite("OrgAnswerLedger")
struct OrgAnswerLedgerTests {

    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func answer(_ org: String, _ result: Reachability.ProbeResult,
                        daysAgo: Double = 1, emails: [String] = ["hello@tenet.example"])
        -> OrgAnswerLedger.Answer {
        OrgAnswerLedger.Answer(orgKey: OrgKey.stored(for: org)!, result: result,
                               probedAt: now.addingTimeInterval(-daysAgo * 86_400),
                               presenterName: org, emails: emails)
    }

    private func show(_ key: String, _ presenter: String?, at venue: String?,
                      ownAnswer: Reachability.ProbeResult? = nil) -> OrgAnswerLedger.Show {
        OrgAnswerLedger.Show(key: key, presenter: presenter, venue: venue,
                             hasOwnAnswer: ownAnswer != nil)
    }

    // TENET plays eight different churches and its name is never a venue, so it clears the gate.
    private var tenetShows: [OrgAnswerLedger.Show] {
        [show("paid", "Tenet Vocal Artists", at: "Church of the Ascension"),
         show("free", "Tenet Vocal Artists", at: "House of the Redeemer")]
    }

    @Test("a show by a qualifying organisation inherits an answer paid for on another of its shows")
    func aQualifyingOrganisationFansOut() {
        let map = OrgAnswerLedger.inherited(from: [answer("Tenet Vocal Artists", .emailFound)],
                                            shows: tenetShows, now: now)
        #expect(map["free"]?.emails == ["hello@tenet.example"])
        #expect(map["free"]?.organisation == "Tenet Vocal Artists")
    }

    // Dan's escalated decision, 2026-07-26. A wrong negative makes him dismiss a bookable show and he
    // would never learn of it, so a negative answer is recorded and NEVER travels. This costs more than
    // any windowed compromise and he accepted that explicitly.
    @Test("a negative answer never travels", arguments: [Reachability.ProbeResult.noEmailFound,
                                                         .weakContactOnly])
    func negativesNeverFanOut(_ result: Reachability.ProbeResult) {
        let map = OrgAnswerLedger.inherited(from: [answer("Tenet Vocal Artists", result)],
                                            shows: tenetShows, now: now)
        #expect(map["free"] == nil)
    }

    // The whole reason the gate exists. The Green Room 42's 142 shows are unrelated companies renting
    // one room, so one answer must never be stamped across them.
    @Test("a room that rents itself out never fans an answer across its shows")
    func aRoomNeverFansOut() {
        let shows = [show("paid", "The Green Room 42", at: "The Green Room 42"),
                     show("free", "The Green Room 42", at: "The Green Room 42")]
        let map = OrgAnswerLedger.inherited(from: [answer("The Green Room 42", .emailFound)],
                                            shows: shows, now: now)
        #expect(map["free"] == nil)
    }

    // #1620: the same refusal, for the form a house takes when it presents under its own brand.
    @Test("a venue's own presenting brand never fans an answer across its shows")
    func aHouseBrandNeverFansOut() {
        let shows = [show("paid", "Carnegie Hall Presents", at: "Stern Auditorium / Perelman Stage"),
                     show("free", "Carnegie Hall Presents", at: "Zankel Hall"),
                     show("other", "The Masterwork Chorus", at: "Carnegie Hall")]
        let map = OrgAnswerLedger.inherited(from: [answer("Carnegie Hall Presents", .emailFound)],
                                            shows: shows, now: now)
        #expect(map["free"] == nil)
    }

    // 5.3: the gate is judged over every prospect, including the ones the queue is not showing. Built
    // from the visible list, a house whose other shows were all dismissed would suddenly look like a
    // one-venue producer, or a producer would lose the second venue that qualifies it. Either way an
    // answer Dan paid for changes meaning because of a triage decision, and nothing on screen says so.
    @Test("the gate sees dismissed shows too, so triaging cannot change who qualifies")
    func theGateSeesTheWholeStore() {
        // Taconic Opera tours five Westchester rooms. Suppose Dan has dismissed all but one date: the
        // company still plays five venues, but a gate built from the rows the queue is SHOWING sees one,
        // reads a touring company as a single-room house, and quietly stops honouring an answer he has
        // already paid for. Nothing on the card would ever say that dismissing a show did that.
        let ledger = [answer("Taconic Opera", .emailFound)]
        let visibleOnly = [show("paid", "Taconic Opera", at: "Tarrytown Music Hall"),
                           show("free", "Taconic Opera", at: "Tarrytown Music Hall")]
        let wholeStore = visibleOnly + [show("gone", "Taconic Opera", at: "CV Rich Mansion")]
        #expect(OrgAnswerLedger.inherited(from: ledger, shows: visibleOnly, now: now)["free"] == nil)
        #expect(OrgAnswerLedger.inherited(from: ledger, shows: wholeStore, now: now)["free"] != nil)
    }

    // 5.5: the inherited answer carries the ORIGINAL check date, so an organisation goes stale rather
    // than renewing itself forever every time it picks up a new show.
    @Test("an answer past the freshness window stops travelling")
    func staleAnswersStopTravelling() {
        let stale = answer("Tenet Vocal Artists", .emailFound, daysAgo: 120)
        #expect(OrgAnswerLedger.inherited(from: [stale], shows: tenetShows, now: now)["free"] == nil)
    }

    @Test("an inherited answer reports the date of the check that earned it, not today")
    func inheritedAnswerCarriesTheOriginalDate() {
        let old = answer("Tenet Vocal Artists", .emailFound, daysAgo: 30)
        let map = OrgAnswerLedger.inherited(from: [old], shows: tenetShows, now: now)
        #expect(map["free"]?.probedAt == now.addingTimeInterval(-30 * 86_400))
    }

    // A show that was checked itself keeps its own verdict, whatever the organisation's says. Its own
    // check is about this show; the ledger's is about a different one.
    @Test("a show that was checked itself never has its own answer overwritten")
    func ownAnswerWins() {
        let shows = [show("paid", "Tenet Vocal Artists", at: "Church of the Ascension"),
                     show("free", "Tenet Vocal Artists", at: "House of the Redeemer",
                          ownAnswer: .noEmailFound)]
        let map = OrgAnswerLedger.inherited(from: [answer("Tenet Vocal Artists", .emailFound)],
                                            shows: shows, now: now)
        #expect(map["free"] == nil)
    }

    // An answer with no address behind it cannot claim there is somebody to email.
    @Test("a positive answer with no address does not travel")
    func aPositiveWithNoAddressDoesNotTravel() {
        let empty = answer("Tenet Vocal Artists", .emailFound, emails: [])
        #expect(OrgAnswerLedger.inherited(from: [empty], shows: tenetShows, now: now)["free"] == nil)
    }

    @Test("a show with no presenter inherits nothing")
    func noPresenterInheritsNothing() {
        let shows = tenetShows + [show("bare", nil, at: "House of the Redeemer")]
        let map = OrgAnswerLedger.inherited(from: [answer("Tenet Vocal Artists", .emailFound)],
                                            shows: shows, now: now)
        #expect(map["bare"] == nil)
    }

    // #1598 Phase 5.2 in the ledger rather than in the key helper: two organisations the venue rule
    // would have merged must not share an answer.
    @Test("two organisations sharing a first clause do not share an answer")
    func aTrailingPlaceNameKeepsTwoOrganisationsApart() {
        let shows = [show("paid", "Christ Church Cathedral, Oxford", at: "A Hall"),
                     show("paid2", "Christ Church Cathedral, Oxford", at: "B Hall"),
                     show("free", "Christ Church Cathedral", at: "A Hall"),
                     show("free2", "Christ Church Cathedral", at: "C Hall")]
        let map = OrgAnswerLedger.inherited(
            from: [answer("Christ Church Cathedral, Oxford", .emailFound)], shows: shows, now: now)
        #expect(map["paid2"] != nil)
        #expect(map["free"] == nil)
        #expect(map["free2"] == nil)
    }
}
