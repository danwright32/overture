import Testing
@testable import Overture

// #722: a lightweight heuristic backstop for the runbook's own "hard press/media-disqualify
// rule" (#635), the same shape as VenueContactGuard (#388): flag, don't reject, dismissible.
@Suite("Press contact guard (#722)")
struct PressContactGuardTests {
    @Test func aPublicRelationsLocalPartIsCaught() {
        #expect(PressContactGuard.looksLikePressContact(email: "publicrelations@carnegiehall.org", role: nil) == true)
    }

    @Test func aPressLocalPartIsCaught() {
        #expect(PressContactGuard.looksLikePressContact(email: "press@venue.example", role: nil) == true)
    }

    @Test func aMediaLocalPartIsCaught() {
        #expect(PressContactGuard.looksLikePressContact(email: "media@venue.example", role: nil) == true)
    }

    @Test func aRoleOnlyGiveawayIsCaughtEvenWithAnUnrelatedAddress() {
        #expect(PressContactGuard.looksLikePressContact(email: "jane@venue.example", role: "Media Relations Manager") == true)
    }

    @Test func anUnrelatedEmailAndRoleIsNotFlagged() {
        #expect(PressContactGuard.looksLikePressContact(email: "jane@venue.example", role: "Artistic Director") == false)
    }

    @Test func nilEmailAndRoleNeverMatches() {
        #expect(PressContactGuard.looksLikePressContact(email: nil, role: nil) == false)
    }
}
