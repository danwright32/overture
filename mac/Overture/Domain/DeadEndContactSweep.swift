import Foundation
import SwiftData

// #2421: the dead-end contacts already in the store.
//
// Stopping the importer creating them only decides what a FUTURE run does. Measured on the live store
// 2026-08-10: 45 contacts have no address and nothing but a social profile, spread across 33 shows. They
// would sit on those cards forever, counted as people found, drafted to, and struck by hand one at a time.
//
// It DELETES a row, so what it refuses to touch matters more than what it removes:
//
//   - Never one that was WRITTEN TO. `Recipient.wasWrittenTo` is the one declared answer to that (#1845,
//     and #2009's guard is what keeps it complete), so a contact Dan pitched by hand through a DM, or one
//     carrying any other record of outreach, is left exactly where it is. Measured before shipping: 0 of
//     the 45 carried any such record, so this refusal costs nothing today and is what makes the pass safe
//     the day one of them does.
//   - Never a manual one (#388: Dan typed it in himself).
//   - Never one that has a usable route. The rule is `DeadEndContact.hasNoUsableRoute`, the same one the
//     importer now applies, so the sweep and the ingest cannot disagree about what a dead end is.
enum DeadEndContactSweep {

    // How many rows were removed, reported rather than silent so a launch that cleaned something can say
    // so and a test can tell "nothing to do" from "did nothing".
    @discardableResult
    static func run(in context: ModelContext) -> Int {
        let prospects = (try? context.fetch(FetchDescriptor<Prospect>())) ?? []
        var removed = 0
        for p in prospects { removed += sweep(p, in: context) }
        if removed > 0 { try? context.save() }
        return removed
    }

    @discardableResult
    static func sweep(_ p: Prospect, in context: ModelContext) -> Int {
        let doomed = p.recipients.filter { isRemovable($0) }
        guard !doomed.isEmpty else { return 0 }
        for r in doomed {
            p.recipients.removeAll { $0 === r }
            context.delete(r)
        }
        return doomed.count
    }

    // Split out and internal so the refusals above are testable one at a time, rather than only ever
    // observed through a pass that happened not to delete anything.
    static func isRemovable(_ r: Recipient) -> Bool {
        guard r.provenance != .manual else { return false }
        guard !r.wasWrittenTo else { return false }
        return DeadEndContact.hasNoUsableRoute(email: r.email, formURL: r.contactFormURL)
    }
}
