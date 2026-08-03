import Testing

// #77: a manual scout failure is a modal Dan expects after clicking; an automatic (scheduled) failure
// should be quiet, a status line and not a surprise dialog on launch he did not trigger.
//
// #802 changed what this type is FOR. It used to be "the calendar feed could not be reached", because
// with one source that was the only way a scout could fail and it killed the whole run. A single source
// failing is now a named, typed failure on that source's row, reported by org name in the outcome every
// run, and the loop carries on to the others.
//
// So what reaches here is a failure that killed the WHOLE run, and the copy must say that rather than
// blaming a calendar. Telling Dan "couldn't reach Carnegie's feed" when his store is what broke would
// send him to check his internet.
@Suite("Scout failure presentation (#77, #802)")
struct ScoutFailureTests {
    @Test func aManualFailureSaysTheWholeRunStoppedAndKeepsTheDetail() {
        let p = ScoutFailure.presentation(auto: false, message: "badResponse")
        #expect(p.status == nil)
        let alert = p.alert ?? ""

        // It stopped everything: no source was checked. That is the fact Dan needs, because it is what
        // distinguishes this from the ordinary case of one source being down (which is reported per
        // source and never stops anything).
        #expect(alert.localizedCaseInsensitiveContains("whole run"))
        #expect(alert.contains("badResponse"))     // the technical detail survives for diagnosis

        // And it must NOT name a calendar. A per-source failure has its own copy now, and this is not
        // that; blaming Carnegie for a broken store would send Dan to check his internet.
        #expect(alert.localizedCaseInsensitiveContains("carnegie") == false)
    }

    @Test func anAutomaticFailureStaysQuiet() {
        let p = ScoutFailure.presentation(auto: true, message: "badResponse")
        #expect(p.alert == nil)                    // never a surprise dialog on a run he did not start
        #expect((p.status ?? "").isEmpty == false)  // but never silent either
        #expect((p.status ?? "").localizedCaseInsensitiveContains("carnegie") == false)
    }
}
