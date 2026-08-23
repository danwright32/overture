import Foundation

// #2674: a show sitting at `drafted` with nobody to send to.
//
// Measured on the live store 2026-08-13: one show, four days from its date, status `drafted`, contacts
// 0, draft body and subject both present. Dan had deleted the contacts by hand wanting to add the
// producer instead (#2629), and the draft Prep wrote for the deleted people stayed on the row.
//
// `drafted` is a promise that the next thing to do is review and send. That row cannot be sent to
// anybody, so it occupies a stage whose action is unavailable, and the stage's number counted it. After
// #2664 the badge is honest about the missing route, which makes the contradiction SHARPER rather than
// softer: the card can say there is no way in while the show sits in the stage that exists to send one
// (L67, L45).
//
// DAN'S CALL, 2026-08-23: it STAYS at drafted and the product says the stage cannot be worked. Nothing
// moves behind his back and no paid AI draft is discarded; what changes is that the row and the stage's
// own number stop pretending the work is available. The two alternatives he was offered, both of which
// move the row back to kept, are recorded here because the reason this does NOT is his and not the
// code's.
//
// IT ASKS WHERE THE ROW IS AND WHAT IT CAN DO NOW, never how it got there, which settles #2674's third
// open question. A show that never had a contact and one whose contacts were deleted are the same dead
// end, and telling them apart would need a history the row does not carry.
enum DraftedDeadEnd {

    // Only at `drafted`. A kept show with no contacts is waiting on a Prep run to find one, which is that
    // stage's ordinary state; saying it there would fire on the common case and be ignored within a day
    // (L93).
    static func hasNobodyToSendTo(_ p: Prospect) -> Bool {
        p.status == .drafted && p.recipients.isEmpty
    }

    static func count(in prospects: [Prospect]) -> Int {
        prospects.filter(hasNobodyToSendTo).count
    }
}

// What the row and the pill say about it, in one place so the two cannot drift.
enum DraftedDeadEndCopy {
    // On the card. It says what is TRUE of the row and what would change it, rather than only that
    // something is wrong: a line naming a fault with no way forward is one Dan can do nothing with (L80).
    static let line = "Drafted, and there's nobody to send it to. Add a contact and this draft is ready to go."

    // On the pill, beside the stage's own number, which still includes these rows.
    static func pillDetail(toReview: Int, deadEnds: Int) -> String {
        guard deadEnds > 0 else { return "\(toReview) to review" }
        return "\(toReview) to review, \(deadEnds) with nobody to send to"
    }
}
