import Testing
import Foundation

// #1126: a recurring/weekly listing must never carry a fabricated far-future placeholder date.
//
// Dan's first real scout (2026-07-18) read Jalopy Theatre's "Jalopy Open Mic Every Wednesday!" and the
// run handed back performanceDate 2028-03-15, a nonsense far-future date, while every other Jalopy show
// got a correct near-term date. That date is not real: nobody scheduled an open mic for a specific day
// in 2028, the run simply invented one to satisfy a field that a weekly listing has no single answer
// for. It matters because performanceDate drives the Prep selection cutoff (#953, next four months) and
// the calendar horizon, so a show mis-dated to 2028 is silently held out of Prep, shown to Dan with a
// wrong date, and sorts and "performance passed" logic all read the fiction.
//
// The rule (safety first): never surface a far-future placeholder. When the recurring listing names a
// weekday, resolve to its NEXT occurrence from today (the honest, stable answer). When no weekday is
// determinable, OMIT the date rather than emit the run's placeholder. A non-recurring listing is left
// exactly as it came back.
@Suite("Recurring event date (#1126)")
struct RecurringEventDateGuardTests {
    // 2026-07-19 is a Sunday, so the next Wednesday from today is 2026-07-22.
    private let today = "2026-07-19"

    @Test func theJalopyWeeklyResolvesToTheNextWednesdayNotAFarFutureDate() {
        let resolved = RecurringEventDate.resolvedDate(
            title: "Jalopy Open Mic Every Wednesday!",
            performanceDate: "2028-03-15",
            today: today)
        #expect(resolved == "2026-07-22")
        #expect(resolved != "2028-03-15")
    }

    @Test func aPluralWeekdayTitleAlsoResolvesToTheNextOccurrence() {
        let resolved = RecurringEventDate.resolvedDate(
            title: "Open Mic Wednesdays",
            performanceDate: "2029-01-01",
            today: today)
        #expect(resolved == "2026-07-22")
    }

    @Test func aTodayThatIsTheNamedWeekdayResolvesToToday() {
        // 2026-07-22 is itself a Wednesday: the next occurrence on-or-after today is today.
        let resolved = RecurringEventDate.resolvedDate(
            title: "Every Wednesday Jam",
            performanceDate: "2030-05-05",
            today: "2026-07-22")
        #expect(resolved == "2026-07-22")
    }

    @Test func aRecurringListingWithNoDeterminableWeekdayOmitsTheDate() {
        let resolved = RecurringEventDate.resolvedDate(
            title: "Weekly Jam Session",
            performanceDate: "2028-03-15",
            today: today)
        #expect(resolved == nil)
    }

    @Test func aNonRecurringListingKeepsItsDateUntouched() {
        // A real one-off show, even one whose title merely names a weekday, is left exactly alone.
        #expect(RecurringEventDate.resolvedDate(
            title: "Wednesday Night Jazz", performanceDate: "2026-09-19", today: today) == "2026-09-19")
        #expect(RecurringEventDate.resolvedDate(
            title: "Aurora Strings in Recital", performanceDate: "2026-09-19", today: today) == "2026-09-19")
        // "everyone" must not read as the recurring keyword "every".
        #expect(RecurringEventDate.resolvedDate(
            title: "A Concert for Everyone", performanceDate: "2026-09-19", today: today) == "2026-09-19")
    }

    // The boundary contract: events(for:) is the single door the agent extract path passes through
    // (ScoutExtractResults filters and now normalizes there, by construction, so an ingest cannot
    // forget to call it). A weekly show must come out of that door with a near-term date, never 2028.
    @Test func theEventsBoundaryNormalizesTheRecurringDate() {
        let results = ScoutExtractResults(
            version: 3, generatedAt: today,
            results: [ScoutExtractResult(
                sourceId: "jalopytheatre-netlify-app",
                verdict: .upcomingListings,
                events: [ScoutExtractEvent(
                    title: "Jalopy Open Mic Every Wednesday!",
                    presenter: nil,
                    venue: "Jalopy Theatre",
                    performanceDate: "2028-03-15",
                    sourceUrl: "https://jalopytheatre.netlify.app/open-mic",
                    location: nil)],
                note: nil)])

        let events = results.events(for: "jalopytheatre-netlify-app", today: today)
        #expect(events.count == 1)
        #expect(events.first?.performanceDate == "2026-07-22")
    }
}
