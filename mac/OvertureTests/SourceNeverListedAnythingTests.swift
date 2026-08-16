import Testing
import Foundation

// #2496: a check that warns by comparing now against remembered previous state cannot fire when its
// memory starts empty.
//
// On a Mac where the fault is ALREADY happening the first time the check runs, the baseline it needs was
// never captured, so the check is silent for exactly the machine it was written for, and silence is
// indistinguishable from health.
//
// The instance covered here: `emptyStreak` only counts once `baselineFeedCount > 0`
// (`WatchedSource.recordSuccessfulRead`), and a source that was empty the first time it was read never
// earns a baseline. So the streak stays 0 forever, `hasGoneQuiet` can never fire, and `hasNeverRead`
// cannot catch it either because an empty read is a SUCCESSFUL read. A source mis-pointed from the day it
// was added is the case none of the three report.
@Suite("A source that has never listed anything (#2496)")
struct SourceNeverListedAnythingTests {

    private func source(reads: Int, everListed: Bool = false, baseline: Int = 0) -> WatchedSource {
        let s = WatchedSource(sourceId: "s", orgName: "Mis-pointed Room",
                              listingsURL: "https://example.test/whats-on", kind: .html)
        s.successfulCheckCount = reads
        s.lastSucceededAt = Date()
        s.baselineFeedCount = baseline
        if everListed { s.lastNonEmptyAt = Date() }
        return s
    }

    // MARK: the hole itself, shown before the fix is asserted

    // Not a claim about the new rule: a claim about the three that were already there. It is what makes
    // the rest of this suite worth having, and it is why the fix could not be a smaller threshold on an
    // existing check.
    @Test("the older checks are structurally unable to see it")
    func theOlderChecksCannotSeeIt() {
        let mispointed = source(reads: 20)

        #expect(mispointed.emptyStreak == 0, "no baseline was ever earned, so no streak can start")
        #expect(!SourceAttention.hasGoneQuiet(mispointed))
        #expect(!SourceAttention.hasNeverRead(mispointed, now: Date()),
                "it reads perfectly well: that is the point")
        #expect(!SourceAttention.hasFailedToReadRepeatedly(mispointed))
    }

    // MARK: the new one

    @Test("a source read many times with nothing ever on it needs a look")
    func itIsReported() {
        let s = source(reads: SourceAttention.neverListedAnythingThreshold)
        #expect(SourceAttention.hasNeverListedAnything(s))
        #expect(SourceAttention.needsALook(s))
    }

    // The half that keeps it from crying wolf. A calendar with nothing announced yet is the ordinary
    // state of a newly watched source, and an alarm on it is what #1428 and #1498 pulled back from.
    @Test("a source with only a few reads is left alone")
    func aNewSourceIsLeftAlone() {
        for reads in 0..<SourceAttention.neverListedAnythingThreshold {
            let s = source(reads: reads)
            #expect(!SourceAttention.hasNeverListedAnything(s), "fired after only \(reads) reads")
        }

        // Pinned to a NUMBER as well as to the constant, deliberately. The loop above is written in terms
        // of the threshold, so it agrees with whatever the threshold happens to be and cannot notice it
        // moving: lowering it to 1 left that loop green. Three days of quiet is the ordinary state of a
        // calendar with nothing announced yet, and calling it broken is the cry-wolf failure #1428 and
        // #1498 pulled back from, so a retune past it has to be a deliberate edit here.
        #expect(!SourceAttention.hasNeverListedAnything(source(reads: 3)),
                "three quiet reads is a quiet calendar, not a broken one")
    }

    // Any evidence that this source HAS worked disqualifies it, whichever of the three records it.
    @Test("a source that has ever listed, placed or baselined anything is not this")
    func evidenceOfLifeDisqualifiesIt() {
        let listed = source(reads: 30, everListed: true)
        #expect(!SourceAttention.hasNeverListedAnything(listed))

        let baselined = source(reads: 30, baseline: 4)
        #expect(!SourceAttention.hasNeverListedAnything(baselined))

        let placed = source(reads: 30)
        placed.lastPlacedCount = 2
        #expect(!SourceAttention.hasNeverListedAnything(placed))
    }

    // Consent outranks it, exactly as it outranks the other four. An org that asked Dan to stop must never
    // appear as work he owes anyone, because the natural end of fixing a broken source is pitching them
    // again (#800).
    @Test("a stopped source never appears as work")
    func consentOutranksIt() {
        let s = source(reads: 30)
        s.isActive = false
        s.inactiveReason = .orgRefusal
        #expect(!SourceAttention.needsALook(s))
        #expect(s.neverListedAnythingNote() == nil)
    }

    // MARK: what the row says

    @Test("the row says how many reads found nothing")
    func theRowSaysIt() throws {
        let s = source(reads: 7)
        let note = try #require(s.neverListedAnythingNote())
        #expect(note.contains("7"))
        #expect(note.contains("never listed a show"))
    }

    // Two gold lines a line apart both telling Dan to check the link is the duplicated copy this sheet
    // keeps being filed for (#843). A source that has never READ carries the stronger sentence already.
    @Test("a source that has never read at all says only the stronger thing")
    func itDoesNotDoubleUpWithNeverRead() {
        let neverRead = WatchedSource(sourceId: "n", orgName: "Never Read",
                                      listingsURL: "https://example.test/x", kind: .html)
        neverRead.addedAt = Date().addingTimeInterval(-30 * 86_400)
        neverRead.successfulCheckCount = 0
        neverRead.lastSucceededAt = nil

        #expect(SourceAttention.hasNeverRead(neverRead, now: Date()))
        #expect(neverRead.neverListedAnythingNote() == nil)
        #expect(neverRead.neverReadNote() != nil)
    }
}
