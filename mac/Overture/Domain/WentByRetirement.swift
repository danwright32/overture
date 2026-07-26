import Foundation
import SwiftData

// #864: retire an untriaged show Dan will never work now, so `new` genuinely means "waiting on Dan".
//
// #1540 moved where that line falls: from the run's closing night to its OPENING night. Dan ruled that a
// client's need for photos is over once they have opened, so an untriaged run that has started is not a
// lead, whatever nights remain on it. Asked directly whether such a run should be archived here or merely
// hidden from the queue, he chose archived, so that "waiting on Dan", "shown in triage" and "swept up"
// stay ONE rule (Prospect.hasOpened) with no invisible class of row sitting in none of them.
//
// #861 stopped COUNTING shows that had already happened, so the Scout pill reads correctly again. But
// those shows are still in the store, still marked `new`, and always would be: nothing ever retired one
// that simply went by. #861 taught one caller to ask better. The data itself was still lying, and the
// next feature to ask "what has Overture never triaged?" would have got the same wrong answer, in a new
// place, for the same reason.
//
// Nothing is deleted. The show is dismissed with a reason of its own, `wentBy`, which is the honest
// record: its date passed while it sat undecided. That reason is deliberately NOT one of Dan's:
//
//   - Archive gives it its own bucket, so it never crowds the Dismissed list, which is where he undoes a
//     cut HE made by mistake (#28). Two dozen shows he never looked at would bury a real one.
//   - LocalHistory records nothing for it, so it never becomes a signal about the org. Retiring a show
//     Dan never saw must not teach the next scout that he passed on it.
//   - The row offers no Restore: the date has passed, so there is nothing to put it back into, and a
//     Restore would simply be undone by the next launch.
enum WentByRetirement {
    // Returns how many shows it retired, so the caller can say what it actually did rather than assume.
    @discardableResult
    static func run(in context: ModelContext, today: String = QueueModel.easternToday()) -> Int {
        let untriaged = FetchDescriptor<Prospect>(
            predicate: #Predicate { $0.statusRaw == "new" }
        )
        guard let candidates = try? context.fetch(untriaged) else { return 0 }

        // Idempotent by construction: a retired show is no longer `new`, so a second pass cannot see it.
        let opened = candidates.filter { $0.hasOpened(today: today) }
        for p in opened {
            p.markDismissed(reason: .wentBy)
        }
        return opened.count
    }
}
