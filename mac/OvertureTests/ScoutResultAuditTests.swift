import Testing
import Foundation
@testable import Overture

// #857: treat the results file as untrusted input. Every rule in the runner's prompt is enforced by
// nothing but hope, and when a run quietly ignores one the failure is silent and plausible-looking.
// These check the cheapest, highest-value contradiction: a result whose verdict disagrees with the
// events it returned. A run that disagrees with itself is reported as a failure of THAT source, named,
// rather than ingested.
@Suite("Auditing a run's own results for self-contradiction (#857)")
struct ScoutResultAuditTests {
    private func event(_ title: String = "A Show") -> ScoutExtractEvent {
        ScoutExtractEvent(title: title, presenter: title, venue: "Merkin Hall",
                          performanceDate: "2099-09-19", sourceUrl: "https://org.example/\(title)")
    }

    private func result(_ verdict: PageVerdict, events: [ScoutExtractEvent] = []) -> ScoutExtractResult {
        ScoutExtractResult(sourceId: "org", verdict: verdict, events: events, note: nil)
    }

    // MARK: - Consistent results pass untouched

    @Test func upcomingListingsWithEventsIsConsistent() {
        #expect(ScoutResultAudit.contradiction(in: result(.upcomingListings, events: [event()])) == nil)
    }

    // An empty upcoming_listings is a documented healthy state (a run that read the page and left every
    // show out for a reason it explains), not the run disagreeing with itself. The audit must leave it
    // alone. See anEmptyButHealthyListingIsNotAFailure in the ingest suite.
    @Test func upcomingListingsWithNoEventsIsConsistent() {
        #expect(ScoutResultAudit.contradiction(in: result(.upcomingListings)) == nil)
    }

    @Test func allPastWithNoEventsIsConsistent() {
        #expect(ScoutResultAudit.contradiction(in: result(.allPast)) == nil)
    }

    @Test func noDatedContentWithNoEventsIsConsistent() {
        #expect(ScoutResultAudit.contradiction(in: result(.noDatedContent)) == nil)
    }

    @Test func unreadableWithNoEventsIsConsistent() {
        #expect(ScoutResultAudit.contradiction(in: result(.unreadable)) == nil)
    }

    @Test func notReadWithNoEventsIsConsistent() {
        #expect(ScoutResultAudit.contradiction(in: result(.notRead)) == nil)
    }

    // MARK: - A verdict that asserts emptiness while returning events is a contradiction

    @Test func allPastWithEventsContradicts() {
        #expect(ScoutResultAudit.contradiction(in: result(.allPast, events: [event()])) != nil)
    }

    @Test func noDatedContentWithEventsContradicts() {
        #expect(ScoutResultAudit.contradiction(in: result(.noDatedContent, events: [event()])) != nil)
    }

    @Test func unreadableWithEventsContradicts() {
        #expect(ScoutResultAudit.contradiction(in: result(.unreadable, events: [event()])) != nil)
    }

    @Test func notReadWithEventsContradicts() {
        #expect(ScoutResultAudit.contradiction(in: result(.notRead, events: [event()])) != nil)
    }

}
