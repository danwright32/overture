import Testing
import Foundation

// #3074: `storeUnreadableKeys` had four writers and no reader.
//
// #2758 / #2999 added it beside the `storeUnreadable` COUNT: which shows a run refused to touch, not just
// how many. The count reaches Dan on screen. The list reached nobody, and it was kept deliberately, as the
// evidence for the next occurrence: the count tells him a run refused three shows, the list is the only
// thing that can say WHICH three when somebody comes to diagnose it. A field written and never read looks
// alive to any is-this-used check while the purpose it was added for silently never happens (L46).
//
// So it is given a reader, at the one place the count already speaks: the run summary's info block.
@Suite("Which shows a run refused reaches the summary (#3074)")
struct RefusedShowKeysReachASurfaceTests {

    private let keyA = "aurora strings at rivermill|2026-11-20|rivermill hall"
    private let keyB = "meridian quartet in recital|2026-12-02|the boathouse"

    private func outcome(unreadable: Int, keys: [String]) -> ScoutService.Outcome {
        var o = ScoutService.Outcome(found: unreadable, inserted: 0, updated: 0, skipped: 0)
        o.storeUnreadable = unreadable
        o.storeUnreadableKeys = keys
        return o
    }

    // The defect, stated as the thing that was missing: the keys reach the section the count is already in.
    @Test func theRefusedKeysReachTheSummarySection() throws {
        let warnings = ScoutWarnings.from(native: outcome(unreadable: 2, keys: [keyA, keyB]),
                                          extract: nil, finishedEmpty: nil)

        #expect(warnings.storeUnreadableKeys == [keyA, keyB])
        let section = try #require(warnings.sections.first { section in
            if case .storeUnreadable = section { return true }
            return false
        })
        guard case let .storeUnreadable(count, keys) = section else { return }
        #expect(count == 2)
        #expect(keys == [keyA, keyB])
    }

    // And they reach the words, which is the only part Dan can actually read.
    @Test func theSentenceNamesTheShowsThatWereLeftOut() {
        let said = ScoutWarningCopy.storeUnreadable(count: 2, keys: [keyA, keyB])

        #expect(said.contains(keyA))
        #expect(said.contains(keyB))
    }

    // A run that refused nothing gains no list, and the sentence for a run whose keys were not recorded is
    // the sentence it always was. The second half matters: the extract half can carry a count with no
    // keys, and a heading over an empty list reads as a promise about rows that are not there (#863).
    @Test func aRunWithNoKeysSaysWhatItAlwaysSaid() {
        let bare = ScoutWarningCopy.storeUnreadable(count: 1, keys: [])

        #expect(bare == ScoutWarningCopy.storeUnreadable(count: 1))
        #expect(!bare.contains("left out:"))
    }

    // Both halves of a run contribute, deduplicated, for the same reason the failures and the empties are:
    // a co-listed show refused in both halves must not be named twice.
    @Test func bothHalvesContributeAndACoListedShowIsNamedOnce() {
        let warnings = ScoutWarnings.from(native: outcome(unreadable: 2, keys: [keyA, keyB]),
                                          extract: outcome(unreadable: 1, keys: [keyB]),
                                          finishedEmpty: nil)

        #expect(warnings.storeUnreadableCount == 3)   // the count is a sum, unchanged by this
        #expect(warnings.storeUnreadableKeys == [keyA, keyB])
    }

    // The quiet line an unattended run leaves is ONE line in the masthead, so it keeps saying the count and
    // does not try to carry the list. Asserted rather than assumed, because the tempting change is to put
    // the keys everywhere the count goes.
    @Test func theQuietLineStillSaysOnlyTheCount() throws {
        let warnings = ScoutWarnings.from(native: outcome(unreadable: 2, keys: [keyA, keyB]),
                                          extract: nil, finishedEmpty: nil)
        let line = try #require(warnings.quietLine)

        #expect(line.contains("2 shows were left out"))
        #expect(!line.contains(keyA))
    }
}
