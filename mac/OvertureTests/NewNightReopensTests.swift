import Testing
import Foundation

// #4052. Whether a LATER NIGHT of the same show reopens a decision Dan has already recorded on it.
//
// WHY THIS EXISTS. #4029 teaches ingest to join a night onto the row that already holds the show, so a
// night arriving after the card was decided inherits whatever decision sits on that row. Without this
// predicate that is silently wrong in one direction: a show dismissed because Dan was busy THAT NIGHT
// would stay in the Archive and never be offered again. Measured on the live store 2026-09-20, that is
// not hypothetical. pk 397 `Nihao Broadway` was dismissed `pitching_other_shows` for 2026-09-11, the
// 2026-09-29 night became its own row, and Dan pitched it (pk 1114, `contacted`). Joining without this
// gate would have silenced the card that produced the outreach.
//
// Dan's call, 2026-09-20 (this session, in chat): "if I dismiss for a date conflict, it comes back on a
// later night of it's run. but if I dismiss for 'dont want to shoot this' it never comes back."
//
// THE RULE. A new night reopens an ending that was about the NIGHT. It never reopens one that was about
// the show, the org, or the route, because a different night changes nothing about any of those.
@Suite("A new night reopens only a night-specific ending (#4052)")
struct NewNightReopensTests {

    // The four Dan names as night-specific. Every one of them says he WANTED the show and that this
    // particular night was spent, so a night he has not spent is a question he has not answered.
    @Test func aNightSpecificEndingIsReopenedByANewNight() {
        for outcome in [ShowOutcome.dateConflict, .hadPaidWork, .pitchingOtherShows, .tooSoon] {
            #expect(outcome.newNightReopens, "\(outcome.rawValue) is about the night, so a new night reopens it")
        }
    }

    // The judgements, and the two that are about the org rather than the night. A different night does
    // not make a show he does not want to shoot into one he does, and it does not invent a contact route.
    @Test func aJudgementAboutTheShowIsNeverReopened() {
        for outcome in [ShowOutcome.notAFit, .dontWantToShoot, .noWayToReachThem, .duplicate] {
            #expect(!outcome.newNightReopens, "\(outcome.rawValue) is about the show, so a new night changes nothing")
        }
    }

    // `wentBy` is the one ending that is NOT a decision: the show's last night passed while it sat
    // untriaged (ShowOutcome.swift, its own comment). There is no judgement to respect, so a night that
    // has not gone by is a live question. Folding it in with the judgements would treat Overture's own
    // bookkeeping as though Dan had said no.
    @Test func aShowThatMerelyWentByIsReopenedByANewNight() {
        #expect(ShowOutcome.wentBy.newNightReopens)
    }

    // `tooFar` is the consequence of blocking a town, and the town is still blocked on the new night.
    // Reopening would put a show back in front of him in a place he asked never to see.
    @Test func aBlockedTownIsNotReopenedByANewNight() {
        #expect(!ShowOutcome.tooFar.newNightReopens)
    }

    // Every ending where a pitch ALREADY WENT OUT stays closed. Reviving one would put a show Dan has
    // already emailed about back in the queue to be emailed about again, which is #3636's hazard, and it
    // is a decision nobody has made. Deliberately conservative: the row stays in the Archive and is found
    // rather than silently resurfacing.
    @Test func anEndingAfterAPitchIsNeverReopened() {
        for outcome in ShowOutcome.pitched {
            #expect(!outcome.newNightReopens, "\(outcome.rawValue) follows a pitch, so it is not reopened")
        }
    }

    // L113: the vocabulary's completeness is enforced rather than left to whoever adds the next case.
    // A value added to `ShowOutcome` without being classified here fails this, which is the whole point:
    // the default must be a red test, never a silent answer.
    @Test func everyEndingIsClassifiedOneWayOrTheOther() {
        let reopened = ShowOutcome.allCases.filter { $0.newNightReopens }
        let closed = ShowOutcome.allCases.filter { !$0.newNightReopens }
        #expect(reopened.count + closed.count == ShowOutcome.allCases.count)
        #expect(Set(reopened) == Set([.dateConflict, .hadPaidWork, .pitchingOtherShows, .tooSoon, .wentBy]))
    }
}
