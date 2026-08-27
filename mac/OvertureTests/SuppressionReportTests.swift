import Testing
import Foundation
import SwiftData

// #802, Dan's 3rd decision (2026-07-11): a refused org whose shows still turn up on a calendar he
// watches must be VISIBLY reported, not just silently suppressed.
//
// The protection is already real. When an org asks Dan to stop, their own calendar comes off the
// watchlist, but their shows can still appear on a VENUE's calendar he legitimately keeps watching
// (Carnegie), and the #769 do-not-contact record suppresses each of those, one at a time, so no email
// can go out.
//
// His point is that a silent guard is a guard you have to take on faith. On the one mistake that cannot
// be taken back, he would rather SEE it working than trust that it is. So the scout now says so.
@MainActor
@Suite("Show the suppression working (#802)")
struct SuppressionReportTests {
    private func context() throws -> ModelContext {
        ModelContext(try ModelContainer(for: Schema([Prospect.self]),
                                        configurations: [ModelConfiguration(isStoredInMemoryOnly: true)]))
    }

    private func event(_ title: String, date: String = "2099-09-19") -> ExtractedEvent {
        ExtractedEvent(title: title, presenter: title, venue: "Stern Auditorium / Perelman Stage",
                       performanceDate: date,
                       sourceUrl: "https://www.carnegiehall.org/Calendar/\(title)")
    }

    // A refused org, recorded the way Dan records one: the do-not-contact flag on their prospects, which
    // is what LocalHistory turns into the suppression record the scout reads.
    private func refusedOrg(_ name: String, in ctx: ModelContext) {
        let p = Prospect(naturalKey: name, groupName: name, discipline: "music", venue: "Zankel Hall",
                         performanceDate: "2026-01-01", sourceListingURL: nil,
                         priorRelationship: "none", production: "self", profile: "strong",
                         coverage: "likely_uncovered", fitScore: 5, tier: "mid", fitReason: "r",
                         matchedClientName: nil, possibleMatchSource: nil, possibleMatchName: nil)
        p.orgDoNotContact = true
        ctx.insert(p)
    }

    private func run(_ events: [ExtractedEvent], in ctx: ModelContext) -> ScoutService.Outcome {
        let existing = (try? ctx.fetch(FetchDescriptor<Prospect>())) ?? []
        return ScoutService.apply(events: events, clients: [],
                                  history: LocalHistory.forMatching(existing: existing),
                                  blocked: .empty, today: ScoutTestClock.beforeAllFixtures,
                                  sourceIds: [WatchedSource.carnegieId], into: ctx)
    }

    // THE test. The guard fires, nothing is imported, and Dan is TOLD.
    @Test func aRefusedOrgsShowOnAWatchedCalendarIsReportedNotJustSuppressed() throws {
        let ctx = try context()
        refusedOrg("Brooklyn Youth Chorus", in: ctx)

        let outcome = run([event("Brooklyn Youth Chorus")], in: ctx)

        // Still suppressed: nothing about this changes what the guard does.
        #expect(outcome.inserted == 0)
        #expect(outcome.skipped == 1)

        // And now visible.
        #expect(outcome.suppressedOrgs.map(\.orgName) == ["Brooklyn Youth Chorus"])
        #expect(outcome.suppressedOrgs.first?.showCount == 1)
    }

    // Several shows by the same org on one calendar are ONE line, with a count. Four separate lines
    // saying the same thing is how a report becomes wallpaper.
    @Test func severalShowsByTheSameOrgAreOneLineWithACount() throws {
        let ctx = try context()
        refusedOrg("Brooklyn Youth Chorus", in: ctx)

        let outcome = run([event("Brooklyn Youth Chorus", date: "2099-09-19"),
                           event("Brooklyn Youth Chorus", date: "2099-10-03"),
                           event("Brooklyn Youth Chorus", date: "2099-11-14")], in: ctx)

        #expect(outcome.suppressedOrgs.count == 1)
        #expect(outcome.suppressedOrgs.first?.showCount == 3)
    }

    @Test func aRunWithNothingSuppressedReportsNothing() throws {
        let ctx = try context()
        let outcome = run([event("Vienna Philharmonic")], in: ctx)

        #expect(outcome.suppressedOrgs.isEmpty)
        #expect(outcome.inserted == 1)   // and the ordinary show is imported as normal
    }

    // A show on a BLOCKED DATE is not a refusal, and must never appear in this report. The whole value of
    // the report is that every line in it means "somebody asked you to stop".
    //
    // #901 changed what happens to such a show (it is now imported and flagged rather than dropped), and
    // this stays true through that change: whatever else a date clash does, it never reads as a refusal.
    @Test func aBlockedDateIsNotARefusalAndIsNotReportedAsOne() throws {
        let ctx = try context()
        let existing = (try? ctx.fetch(FetchDescriptor<Prospect>())) ?? []
        let outcome = ScoutService.apply(
            events: [event("Vienna Philharmonic")], clients: [],
            history: LocalHistory.forMatching(existing: existing),
            blocked: BlockedCalendar.build(
                bookings: [], exportedBlockedDates: ["2099-09-19"], daysOff: []),
            today: ScoutTestClock.beforeAllFixtures,
            sourceIds: [WatchedSource.carnegieId], into: ctx)

        #expect(outcome.inserted == 1)            // it is kept, flagged, for Dan to decide
        #expect(outcome.suppressedOrgs.isEmpty)   // and nobody refused him
    }

    // MARK: - What Dan reads

    @Test func theReportNamesTheOrgAndSaysNothingWentOut() {
        let line = ScoutService.SuppressedOrg(orgName: "Brooklyn Youth Chorus", showCount: 2)
        let text = SuppressionReport.summary(for: [line]) ?? ""

        #expect(text.contains("Brooklyn Youth Chorus"))
        #expect(text.contains("2"))
        // The point of the whole thing: he sees the guard WORKING, not a warning that something is wrong.
        #expect(text.localizedCaseInsensitiveContains("asked"))
        #expect(text.localizedCaseInsensitiveContains("nothing"))
    }

    @Test func oneOrgAndSeveralOrgsBothReadCorrectly() {
        let one = SuppressionReport.summary(for: [.init(orgName: "A", showCount: 1)]) ?? ""
        let many = SuppressionReport.summary(for: [.init(orgName: "A", showCount: 1),
                                                   .init(orgName: "B", showCount: 2)]) ?? ""
        #expect(one.contains("A"))
        #expect(many.contains("A") && many.contains("B"))
    }

    // #959: the verb agrees with the subject. Singular used to read "An organization that asked you to
    // stop still turn up", a subject/verb slip; plural stays "Organizations... turn up".
    @Test func theVerbAgreesWithOneOrManyOrgs() {
        let one = SuppressionReport.summary(for: [.init(orgName: "A", showCount: 1)]) ?? ""
        let many = SuppressionReport.summary(for: [.init(orgName: "A", showCount: 1),
                                                   .init(orgName: "B", showCount: 2)]) ?? ""

        #expect(one.contains("An organization that asked you to stop still turns up"))
        #expect(!one.contains("still turn up"))
        #expect(many.contains("Organizations that asked you to stop still turn up"))
    }

    @Test func nothingSuppressedMeansNoReportAtAll() {
        #expect(SuppressionReport.summary(for: []) == nil)
    }
}
