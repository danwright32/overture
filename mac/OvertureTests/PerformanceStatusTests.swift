import Testing
@testable import Overture

// Phase F (#424): one pure function rolls a show's per-contact standings up to the show's
// performance status, first match wins: Booked > Active (in play) > Lost > New. Booking is a
// performance-level fact (lead outcome / a recipient booked); Active vs Lost is derived from the
// contacts. "Contacted" means an email actually went out (sendState == .sent); a show with nothing
// emailed is New, never vacuously Lost.
@Suite("Performance status derivation")
struct PerformanceStatusTests {
    private func sent(_ resolution: RecipientResolution? = nil, bounced: Bool = false) -> RecipientStanding {
        RecipientStanding(sendState: .sent, resolution: resolution, bounced: bounced, hasContactPath: true)
    }
    private func pending(reachable: Bool = true) -> RecipientStanding {
        RecipientStanding(sendState: .pending, resolution: nil, bounced: false, hasContactPath: reachable)
    }

    @Test func newWhenNothingEmailedYet() {
        #expect(PerformanceStatus.derive([pending(), pending()], leadBooked: false) == .new)
    }

    @Test func newWhenThereAreNoContactsAtAll() {
        #expect(PerformanceStatus.derive([], leadBooked: false) == .new)
    }

    @Test func bookedWhenTheLeadIsBooked() {
        // Booked is top precedence: it wins even over a contact that declined.
        #expect(PerformanceStatus.derive([sent(.declinedHard)], leadBooked: true) == .booked)
    }

    @Test func bookedWhenAnyContactIsBooked() {
        // A booked recipient is attribution for the single performance-level booking (#389).
        #expect(PerformanceStatus.derive([sent(.booked), sent(.declinedHard)], leadBooked: false) == .booked)
    }

    @Test func activeWhenAContactIsAwaitingOrInConversation() {
        // A sent, unresolved, un-bounced contact is in play (awaiting reply or mid-conversation).
        #expect(PerformanceStatus.derive([sent()], leadBooked: false) == .active)
    }

    @Test func activeWinsOverADeclineWhileAnotherContactIsStillInPlay() {
        // Keep pursuing the silent contact even though one already said no.
        #expect(PerformanceStatus.derive([sent(), sent(.declinedHard)], leadBooked: false) == .active)
    }

    @Test func lostDoorOpenWhenEveryContactedIsResolvedAndOneIsASoftNo() {
        #expect(PerformanceStatus.derive([sent(.declinedSoft), sent(.declinedHard)], leadBooked: false)
                == .lostDoorOpen)
    }

    @Test func lostNotInterestedWhenEveryContactedIsHardNoOrBounced() {
        #expect(PerformanceStatus.derive([sent(.declinedHard), sent(nil, bounced: true)], leadBooked: false)
                == .lostNotInterested)
    }

    @Test func aBounceIsNotInPlayAndCountsAsNotInterested() {
        #expect(PerformanceStatus.derive([sent(nil, bounced: true)], leadBooked: false) == .lostNotInterested)
    }

    // Dan's call (#424): stay active until everyone has been tried. A contact who declined while
    // another contact is still un-emailed and reachable keeps the show active (pursue the next one).
    @Test func aStillReachableUnemailedContactKeepsTheShowActive() {
        #expect(PerformanceStatus.derive([sent(.declinedHard), pending(reachable: true)], leadBooked: false)
                == .active)
    }

    // But an un-emailed contact with no way to reach them (no email, no form) is not "someone left to
    // try", so it does not hold the show open.
    @Test func anUnreachableUnemailedContactDoesNotHoldTheShowOpen() {
        #expect(PerformanceStatus.derive([sent(.declinedHard), pending(reachable: false)], leadBooked: false)
                == .lostNotInterested)
    }
}
