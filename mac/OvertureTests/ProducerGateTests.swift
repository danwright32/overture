import Testing
@testable import Overture

// #1593 (milestone 32 Phase 0.2): the gate that decides whether one reachability answer may be reused
// across every show from the same presenter. Getting this wrong in the permissive direction is the worst
// outcome the feature can produce: one organisation's contact stamped onto shows it has nothing to do
// with, with nothing on the card to reveal it. So the tests below pin the EXCLUSIONS at least as hard as
// the admissions, on real presenters measured in the live store on 2026-07-26.
@Suite("ProducerGate")
struct ProducerGateTests {

    private func show(_ presenter: String?, at venue: String?) -> ProducerGate.Show {
        ProducerGate.Show(presenter: presenter, venue: venue)
    }

    @Test("a presenter appearing at several venues, never itself a venue, qualifies")
    func multiVenuePresenterQualifies() {
        let shows = [
            show("Carnegie Hall Presents", at: "Zankel Hall"),
            show("Carnegie Hall Presents", at: "Bryant Park"),
        ]
        #expect(ProducerGate.qualifies("Carnegie Hall Presents", among: shows))
    }

    // Abrons Arts Center is the case that proves the venue count alone is not enough. In the live store
    // it presents under five different venue spellings, so it sails through the multi-venue arm, and its
    // own name is also a venue on 11 other rows. It is a house, so its answer must never fan out.
    @Test("a presenter whose own name is also a venue never qualifies, however many venues it plays")
    func aPresenterThatIsAlsoAVenueIsExcluded() {
        let shows = [
            show("Abrons Arts Center", at: "Playhouse Stage at Abrons Arts Center"),
            show("Abrons Arts Center", at: "Playhouse Theater, Abrons Arts Center"),
            show("Abrons Arts Center", at: "Abrons Arts Center"),
            show("Some Visiting Company", at: "Abrons Arts Center"),
        ]
        #expect(ProducerGate.qualifies("Abrons Arts Center", among: shows) == false)
    }

    // Nothing in the store separates the Metropolitan Opera (produces its own work at its own house)
    // from FRIGID New York (rents its room to 40 companies): both are many different shows at one venue.
    // So the automatic rule excludes both, and Dan promotes the real producers by hand, once each.
    @Test("Dan can promote a single-venue producer the automatic rule excludes")
    func promotionAdmitsASingleVenueProducer() {
        let shows = [
            show("Metropolitan Opera", at: "Metropolitan Opera House"),
            show("Metropolitan Opera", at: "Metropolitan Opera House"),
        ]
        #expect(ProducerGate.qualifies("Metropolitan Opera", among: shows) == false)
        #expect(ProducerGate.qualifies("Metropolitan Opera", among: shows,
                                       promoted: ["metropolitan opera"]))
    }

    // Promotion overrides the venue count ONLY. Dan's standing rule is that a room's own address is never
    // a real contact, so no promotion, mistaken or otherwise, can fan a house's answer across its shows.
    @Test("promotion cannot override the room-name arm")
    func promotionCannotAdmitARoom() {
        let shows = [
            show("The Green Room 42", at: "The Green Room 42"),
            show("The Green Room 42", at: "The Green Room 42, 570 Tenth Ave"),
            show("A Visiting Act", at: "The Green Room 42"),
        ]
        #expect(ProducerGate.qualifies("The Green Room 42", among: shows,
                                       promoted: ["the green room 42"]) == false)
    }

    // LIVE-STORE-CLAIM verified=2026-07-26 measure="presenter and venue pairs per organisation, and whether the folded presenter name is also a folded venue key, over all 714 prospects"
    // FROZEN FIXTURE. Presenter and venue pairs taken verbatim from Dan's live store on 2026-07-26. These
    // pin behaviour rather than drive it: they exist so a later edit to VenueNormalization or to either
    // arm cannot silently re-admit a room or drop a producer, which is invisible from inside the code and
    // costs real money and real bookings when it goes wrong.
    private static let liveStoreSample: [ProducerGate.Show] = [
        // Producers: several genuinely distinct venues, name never used as a venue.
        .init(presenter: "Carnegie Hall Presents", venue: "Stern Auditorium / Perelman Stage"),
        .init(presenter: "Carnegie Hall Presents", venue: "Bryant Park"),
        .init(presenter: "Carnegie Hall Presents", venue: "Historic Richmond Town"),
        .init(presenter: "Young Concert Artists", venue: "Merkin Hall"),
        .init(presenter: "Young Concert Artists", venue: "Zankel Hall"),
        .init(presenter: "Tenet Vocal Artists", venue: "St Ann and the Holy Trinity"),
        .init(presenter: "Tenet Vocal Artists", venue: "Church of the Ascension"),

        // Houses: the name is itself a venue somewhere in the set.
        .init(presenter: "The Green Room 42", venue: "The Green Room 42"),
        .init(presenter: "The Cutting Room", venue: "The Cutting Room"),
        .init(presenter: "Jalopy Theatre", venue: "Jalopy Theatre, Red Hook, Brooklyn, NY"),
        .init(presenter: "Jalopy Theatre", venue: "Jalopy Theatre"),
        .init(presenter: "Merkin Hall", venue: "Merkin Hall"),
        .init(presenter: "SoHo Playhouse", venue: "SoHo Playhouse"),
        .init(presenter: "54 Below", venue: "54 Below, 254 W 54th St. Cellar, NYC 10019"),
        .init(presenter: "54 Below", venue: "54 Below"),
        .init(presenter: "Abrons Arts Center", venue: "Playhouse Stage at Abrons Arts Center"),
        .init(presenter: "Abrons Arts Center", venue: "Abrons Arts Center"),

        // Single-venue presenters. Excluded automatically, promotable by hand. FRIGID rents Under St
        // Marks to 40 different companies; the Met produces its own work. The store cannot tell them
        // apart, which is exactly why neither is admitted without Dan saying so.
        .init(presenter: "FRIGID New York", venue: "Under St Marks"),
        .init(presenter: "Metropolitan Opera", venue: "Metropolitan Opera House"),
        .init(presenter: "DCINY", venue: "Stern Auditorium / Perelman Stage"),
    ]

    @Test("frozen fixture: real producers are admitted", arguments: [
        "Carnegie Hall Presents", "Young Concert Artists", "Tenet Vocal Artists",
    ])
    func liveStoreProducersQualify(_ presenter: String) {
        #expect(ProducerGate.qualifies(presenter, among: Self.liveStoreSample))
    }

    @Test("frozen fixture: houses are never admitted", arguments: [
        "The Green Room 42", "The Cutting Room", "Jalopy Theatre", "Merkin Hall",
        "SoHo Playhouse", "54 Below", "Abrons Arts Center",
    ])
    func liveStoreHousesAreExcluded(_ presenter: String) {
        #expect(ProducerGate.qualifies(presenter, among: Self.liveStoreSample) == false)
    }

    // The correction that prompted this gate. The plan-council plan shipped a room-name test alone, which
    // admits FRIGID because "FRIGID" is never a venue string, and would have fanned one contact across 40
    // unrelated productions. It stays out unless Dan promotes it.
    @Test("frozen fixture: single-venue presenters stay out until promoted", arguments: [
        "FRIGID New York", "Metropolitan Opera", "DCINY",
    ])
    func liveStoreSingleVenuePresentersAreExcluded(_ presenter: String) {
        #expect(ProducerGate.qualifies(presenter, among: Self.liveStoreSample) == false)
    }

    @Test("a blank or missing presenter never qualifies", arguments: ["", "   "])
    func blankPresenterNeverQualifies(_ presenter: String) {
        #expect(ProducerGate.qualifies(presenter, among: Self.liveStoreSample) == false)
    }
}
