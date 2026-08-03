import Testing
import Foundation

// #297: the reply/booking wording is built in one place so the manual ack (ReconcileSummary) and the
// while-away alert (AwayAlert) can never phrase the same event two different ways. These tests pin the
// shared phrasing; the call sites just assert they route through it.
@Suite("Outreach event phrasing (#297)")
struct OutreachEventPhrasingTests {
    @Test func noNamesProducesNoPhrase() {
        #expect(OutreachEventPhrasing.replyPhrase([]) == nil)
        #expect(OutreachEventPhrasing.bookingPhrase([]) == nil)
    }

    @Test func oneReplyIsSingularAndNamed() {
        #expect(OutreachEventPhrasing.replyPhrase(["Carnegie Hall"]) == "1 new reply (Carnegie Hall)")
    }

    @Test func severalRepliesArePluralCountedAndNamed() {
        #expect(OutreachEventPhrasing.replyPhrase(["Carnegie Hall", "Joe's Pub"])
            == "2 new replies (Carnegie Hall, Joe's Pub)")
    }

    @Test func oneBookingIsSingularAndNamed() {
        #expect(OutreachEventPhrasing.bookingPhrase(["Carnegie Hall"]) == "1 new booking (Carnegie Hall)")
    }

    @Test func severalBookingsArePluralCountedAndNamed() {
        #expect(OutreachEventPhrasing.bookingPhrase(["Joe's Pub", "The Knights"])
            == "2 new bookings (Joe's Pub, The Knights)")
    }
}
