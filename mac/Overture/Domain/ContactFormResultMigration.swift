import Foundation
import SwiftData

// #1626: upgrade the rows already stamped "no email found" that are actually reachable through a form
// on the act's own site.
//
// The stored verdict is what the badge reads (#1596 Phase 3), so without this pass every show already
// checked before `contactFormOnly` existed keeps reading as a dead end until Dan pays to check it a
// second time. On the live store that is the six shows from the 2026-07-27 run, three of which carry a
// usable form (jakebergmagic.com/contact, shop.copeland.band, marcribler.com/contact).
//
// Deliberately narrow, in one direction only: `no_email_found` becomes `contact_form_only`, and nothing
// else is touched. A blanket re-derive would also move a badge whose venue warning Dan has since
// dismissed, and he decided on 2026-07-27 that dismissing a warning makes the address sendable but does
// NOT move the badge until a re-check. This pass must not quietly overturn that.
//
// Idempotent, guarded by the stored value itself, so a second pass is a no-op. Returns how many it
// changed.
enum ContactFormResultMigration {
    @discardableResult
    static func run(in context: ModelContext) -> Int {
        let prospects = (try? context.fetch(FetchDescriptor<Prospect>())) ?? []
        var changed = 0
        for p in prospects where p.reachabilityResult == .noEmailFound {
            guard p.reachabilityResultFromRecipients == .contactFormOnly else { continue }
            p.reachabilityResult = .contactFormOnly
            changed += 1
        }
        return changed
    }
}
