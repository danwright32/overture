import Foundation

// #3373: dropping the night a kept row was kept for sends it back to Scout.
//
// Dan's call, 2026-09-18: "always back to scout. if prepped, delete the prep so we don't risk a bad email
// going out". A keep is a decision about a specific night as often as about the run. Before this, a
// one-night dismiss re-keyed a kept row onto the run's next night and left `status` alone, so the card sat
// in Prep on a date Dan never chose, and a draft already written went on naming the night he had just
// dropped, one Approve away from being sent.
//
// So when the drop MOVES the row (the run plays on), a row that had been kept, drafted or approved returns
// to `.new` on its new night, and its draft goes in the same write. Deleting the draft is also what makes
// the next Keep prep the show again: `PrepQueueBuilder.needsPrep` only takes a kept show with no draft.
//
// Two cases are outside the rule, deliberately:
//
// - A row anything has been SENT for is a live conversation, not a kept row (the implementer's reading on
//   the issue, 2026-09-18). Resetting it would hide an email that already went out.
// - The night dropped is not the one the row is filed under. Today that cannot happen, because a run card
//   only renders under its opening night, but the per-night work (#3325) adds drops of other nights, and a
//   keep is about the night on the card, so only dropping THAT night retracts it.
enum KeptNightDrop {

    // The stages a keep puts a row in, and the two it moves through before anything is sent.
    static let keptStatuses: Set<ReviewStatus> = [.queued, .drafted, .approved]

    static func returnsToScout(priorStatus: ReviewStatus, droppedNight: String, filedUnder: String?,
                               anythingSent: Bool) -> Bool {
        keptStatuses.contains(priorStatus) && droppedNight == filedUnder && !anythingSent
    }

    // Every field the reset clears, held so an undo can put each one back (L574: an undo restoring fewer
    // fields than the action changed is not its inverse). The reset and the restore both read THIS list,
    // so a field added to one cannot be forgotten by the other.
    struct Draft: Equatable, Sendable {
        let subject: String?
        let body: String?
        let variant: String?
        let model: String?
        let editedByDan: Bool
        let writtenByDan: Bool
        let originalSubject: String?
        let originalBody: String?
    }
}

extension Prospect {
    // Whether anything has gone out for this show, on the show or on any one of its contacts. The same two
    // facts `hasEnteredSendHalf` reads for a send, without its status arm: an approved row has entered the
    // send half and has still sent nothing, and it is exactly the row this rule is for.
    var anythingSent: Bool {
        sentAt != nil || recipients.contains { $0.sendState == .sent }
    }

    var keptNightDraft: KeptNightDrop.Draft {
        KeptNightDrop.Draft(subject: draftSubject, body: draftBody, variant: draftVariant, model: draftModel,
                            editedByDan: draftEditedByDan, writtenByDan: draftWrittenByDan,
                            originalSubject: originalDraftSubject, originalBody: originalDraftBody)
    }

    func restoreKeptNightDraft(_ d: KeptNightDrop.Draft) {
        draftSubject = d.subject
        draftBody = d.body
        draftVariant = d.variant
        draftModel = d.model
        draftEditedByDan = d.editedByDan
        draftWrittenByDan = d.writtenByDan
        originalDraftSubject = d.originalSubject
        originalDraftBody = d.originalBody
    }

    // Applies the rule after a drop that MOVED the row, and answers the draft it deleted so the caller's
    // undo entry can carry it. Nil when the row was not returned to Scout, which is also the undo's cue to
    // leave the draft fields exactly as they are.
    //
    // `priorStatus` and `filedUnder` are read by the caller BEFORE the drop, because the drop rewrites
    // `performanceDate` and the rule is about the night the row was kept for, not the one it moved to.
    @discardableResult
    func returnToScoutIfKept(priorStatus: ReviewStatus, droppedNight: String,
                             filedUnder: String?) -> KeptNightDrop.Draft? {
        guard KeptNightDrop.returnsToScout(priorStatus: priorStatus, droppedNight: droppedNight,
                                           filedUnder: filedUnder, anythingSent: anythingSent) else {
            return nil
        }
        let deleted = keptNightDraft
        restoreKeptNightDraft(KeptNightDrop.Draft(subject: nil, body: nil, variant: nil, model: nil,
                                                  editedByDan: false, writtenByDan: false,
                                                  originalSubject: nil, originalBody: nil))
        status = .new
        return deleted
    }
}
