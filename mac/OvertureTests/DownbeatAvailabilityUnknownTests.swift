import Testing
import Foundation

// #3298: an export Overture could not read must not read as "no nights are blocked".
//
// `loadWithHealth` answers a refusal with empty clients, empty bookings AND empty `blockedDates`, and an
// empty blocked-date list is indistinguishable from a diary with nothing in it (L98). The scout then stops
// suppressing nights Dan is already shooting and can pitch a show on a booked night. It happened for real
// on 2026-08-30: Downbeat bumped its export to version 3, the installed build accepted only [1, 2], and 16
// blocked dates plus 31 clients went invisible with nothing loud saying so.
//
// #3193 fixed the version half by making the gate a MINIMUM with no ceiling. What is left, and what this
// covers, is every OTHER way a read can fail: a corrupt file, a truncated one, a shape this build does not
// understand, or no file at all.
@Suite("A Downbeat export nobody could read (#3298)")
struct DownbeatAvailabilityUnknownTests {
    // #3298 stored the verdict on the calendar as a `blockedDaysAreUnknown` flag and three tests here
    // pinned it. Dan's call, 2026-09-02: removed, because nothing ever read it. The masthead notice reads
    // the export's health directly and is the surface that tells him the nights are unknown, so the flag
    // was a second value for the same fact with no reader.
    //
    // What is left is the part that still decides something: `Availability(health:)`, tested below, and
    // the fact that a readable export judges its blocked days exactly as before.
    @Test func aReadableExportStillJudgesItsOwnBlockedDays() {
        let cal = BlockedCalendar.build(availability: .measured, bookings: [],
                                        exportedBlockedDates: ["2026-10-29"], daysOff: [])
        #expect(cal.conflict(performanceDate: "2026-10-29", runEndDate: String?.none) != nil)
        #expect(BlockedCalendar.build(availability: .unknown, bookings: [],
                                      exportedBlockedDates: [], daysOff: []).days.isEmpty)
    }

    // The health verdict decides it, so a caller cannot get the two out of step by hand.
    @Test func theHealthVerdictDecidesWhetherAvailabilityWasMeasured() {
        #expect(BlockedCalendar.Availability(health: .ok) == .measured)
        #expect(BlockedCalendar.Availability(health: .stale(ageDays: 90)) == .measured)
        #expect(BlockedCalendar.Availability(health: .missing) == .unknown)
        #expect(BlockedCalendar.Availability(health: .unreadable) == .unknown)
    }

    // A STALE export is readable: its nights are known, they are just old. Folding it in with the
    // unreadable case would take a real answer away and replace it with "we do not know", which is
    // false and which #3299 is separately about saying properly.
    @Test func aStaleExportIsStillMeasured() {
        #expect(BlockedCalendar.Availability(health: .stale(ageDays: 90)) == .measured)
        let stale = BlockedCalendar.build(availability: BlockedCalendar.Availability(health: .stale(ageDays: 90)),
                                          bookings: [], exportedBlockedDates: ["2026-10-29"], daysOff: [])
        #expect(stale.conflict(performanceDate: "2026-10-29", runEndDate: String?.none) != nil)
    }
}

// The loud half. Before this the only surfaces carrying an unreadable export were `DownbeatBridge.warningText`,
// which ONLY `ScoutService` reads, and the coverage box inside the Sources sheet, which Dan has to open.
// So the state that stops Overture knowing which nights are taken had nothing on the surface he actually
// looks at, while the code claimed it "already has the loudest line on the masthead".
@Suite("The masthead says when Overture cannot see the booked nights (#3298)")
struct DownbeatAvailabilityNoticeTests {
    private func notices(_ health: DownbeatBridge.Health?) -> [AppNotice] {
        AppNotices.current(downbeatAvailability: health, status: StatusLine())
    }

    @Test func anUnreadableExportPutsAWarningOnTheMasthead() {
        let notice = notices(.unreadable).first
        #expect(notice?.tone == .warning)
        #expect(notice?.text == "Overture can't read your Downbeat export, so it doesn't know which nights you're already shooting.")
    }

    // Distinct causes get distinct messages (L11). A file that was never exported and a file that is
    // corrupt need different things done about them, and both differ from a file that is merely old.
    @Test func aMissingExportSaysSomethingDifferentFromACorruptOne() {
        let missing = notices(.missing).first?.text
        let unreadable = notices(.unreadable).first?.text
        #expect(missing == "Overture has no Downbeat export, so it doesn't know which nights you're already shooting.")
        #expect(missing != unreadable)
    }

    // Each one names a remedy that actually changes the state Dan is stuck in (L111).
    @Test func eachCauseNamesItsOwnRemedy() {
        #expect(notices(.missing).first?.help?.contains("Export your client list from Downbeat") == true)
        #expect(notices(.unreadable).first?.help?.contains("Re-export it from Downbeat") == true)
    }

    // A stale export is readable. Its nights are known, so this notice must not claim otherwise; what a
    // stale export needs to say is #3299's question, not this one's.
    @Test func aStaleExportRaisesNoUnknownAvailabilityNotice() {
        #expect(notices(.stale(ageDays: 90)).isEmpty)
    }

    @Test func aHealthyExportAndNoVerdictAtAllBothStaySilent() {
        #expect(notices(.ok).isEmpty)
        #expect(notices(nil).isEmpty)
    }
}

// #3299: the coverage box inside the Sources sheet described a STALE export as one that is "missing or
// could not be read". It branched on `clientsHealth != .ok`, and `.stale` fails that test exactly as
// `.missing` and `.unreadable` do, so a perfectly readable export that is simply old was reported as
// corrupt AND its coverage was hidden entirely.
//
// The two states need different things done about them and have different urgency (L11): a missing export
// means coverage cannot be judged at all; a stale one means it can be judged, and a client booked since
// the export was written may be absent from the answer.
@Suite("The coverage box names the real cause (#3299)")
struct CoverageHealthCopyTests {
    // A healthy export hides nothing and says nothing extra.
    @Test func aHealthyExportShowsTheCoverageWithNoCaveat() {
        #expect(CoverageCopy.unavailable(.ok) == nil)
        #expect(CoverageCopy.staleCaveat(.ok) == nil)
    }

    // Missing and unreadable both stop coverage being judged, and each names its own remedy.
    @Test func missingAndUnreadableEachSayWhatIsWrongAndWhatToDo() {
        #expect(CoverageCopy.unavailable(.missing)
                == "Coverage can't be checked: there's no Downbeat client export. Export your client list from Downbeat.")
        #expect(CoverageCopy.unavailable(.unreadable)
                == "Coverage can't be checked: the Downbeat client export couldn't be read. Re-export it from Downbeat.")
    }

    // THE DEFECT. A stale export is readable, so coverage IS shown; what it gets is a caveat naming the
    // age, not a sentence calling it missing or corrupt.
    @Test func aStaleExportStillShowsItsCoverage() {
        #expect(CoverageCopy.unavailable(.stale(ageDays: 47)) == nil)
    }

    @Test func aStaleExportCarriesACaveatNamingItsAge() {
        #expect(CoverageCopy.staleCaveat(.stale(ageDays: 47))
                == "Your Downbeat client export is 47 days old, so a client booked since then may be missing from this list.")
    }

    // The caveat belongs to staleness alone: a state that hides coverage outright must not also carry a
    // note about the list beneath it, because there is no list beneath it.
    @Test func theCaveatIsSilentForEveryStateThatHidesTheList() {
        #expect(CoverageCopy.staleCaveat(.missing) == nil)
        #expect(CoverageCopy.staleCaveat(.unreadable) == nil)
    }

    // Exactly one of the two speaks for any given verdict, so the box can never draw both or neither.
    @Test func everyVerdictIsAnsweredByExactlyOneOfThem() {
        for health: DownbeatBridge.Health in [.ok, .missing, .unreadable, .stale(ageDays: 1)] {
            let hides = CoverageCopy.unavailable(health) != nil
            let caveats = CoverageCopy.staleCaveat(health) != nil
            #expect(!(hides && caveats), "\(health) both hides the list and annotates it")
        }
    }
}

// Built is not wired (L3). Both of these are pure values a test can check all day while nothing on screen
// ever reads them, which is precisely the failure #3298 was filed about: the honest verdict existed, and
// the only surfaces carrying it were a run summary and a sheet Dan has to open.
@Suite("The availability verdict reaches the screen (#3298, #3299)")
struct DownbeatAvailabilityWiringGuardTests {
    private var rootView: String { SourceGuardHelper.source("Overture/App/RootView.swift") }
    private var sourcesView: String { SourceGuardHelper.source("Overture/UI/SourcesView.swift") }

    // The masthead is HANDED the verdict. Without this the notice is a function nothing calls.
    @Test func theMastheadIsHandedTheExportsHealth() {
        #expect(rootView.contains("downbeatAvailability: downbeatHealth"))
    }

    // ...and something actually reads the file, or the state stays nil forever and the notice is silent
    // in exactly the case it exists for (L98).
    @Test func somethingReadsTheHealthAtLaunchAndOnTheRecheck() {
        #expect(rootView.contains(".task { readDownbeatHealth() }"))
        // The recheck control's own handler: pressing it on the unreadable-export line has to be able to
        // clear that line, or the control does nothing visible and reads as broken (L12).
        #expect(rootView.contains("case .recheckDownbeatExport:"))
        #expect(rootView.components(separatedBy: "readDownbeatHealth()").count >= 4)
    }

    // #3299: the coverage box asks the health CASE, never `!= .ok`. That comparison is what folded a stale
    // export in with a missing one, and it is one character away from coming back.
    @Test func theCoverageBoxDoesNotFoldStaleInWithUnreadable() {
        #expect(sourcesView.contains("CoverageCopy.unavailable(clientsHealth)"))
        #expect(!sourcesView.contains("clientsHealth != .ok"))
    }

    @Test func theCoverageBoxDrawsTheStaleCaveatBesideTheListRatherThanInsteadOfIt() {
        #expect(sourcesView.contains("CoverageCopy.staleCaveat(clientsHealth)"))
    }
}
