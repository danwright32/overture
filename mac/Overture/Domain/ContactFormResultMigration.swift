import Foundation
import SwiftData

// #1626: upgrade the rows already stamped "no email found" that are actually reachable through a form
// on the act's own site.
//
// The stored verdict is what the badge reads (#1596 Phase 3), so without this pass every show already
// checked before `contactFormOnly` existed keeps reading as a dead end until Dan pays to check it a
// LIVE-STORE-CLAIM verified=2026-07-27 measure="rows from the 2026-07-27 probe run stamped no_email_found, and how many hold a usable contact form on the act's own site"
// second time. On the live store that is the six shows from the 2026-07-27 run, three of which carry a
// usable form (sorrelmanemagic.com/contact, shop.copeland.band, marcribler.com/contact).
//
// Deliberately narrow, in one direction only: `no_email_found` becomes `contact_form_only`, and nothing
// else is touched. A blanket re-derive would also move a badge whose venue warning Dan has since
// dismissed, and he decided on 2026-07-27 that dismissing a warning makes the address sendable but does
// NOT move the badge until a re-check. This pass must not quietly overturn that.
//
// Milestone 61 Phase 0.3, 2026-08-31: `ReachabilityVerdictRefresh` now runs directly AFTER this pass,
// once per Mac, and refreshes every unsent show's stored verdict to what the show holds. So the
// 2026-07-27 decision quoted above was overturned ONCE, deliberately, by Dan's call of 2026-08-31 ("why
// wouldn't we refresh all 690 of them? Shouldn't it be accurate?"), on being shown that some shows
// would move down and why.
//
// The ONGOING rule is unchanged and this pass is NOT dead. Dan confirmed in the same session that he
// meant a one time repair rather than a rule change, so after that single sweep a dismissed warning
// still does not move the badge until a re-check, and this narrow pass is still what upgrades a row
// that acquires a form URL afterwards. The plan's revision 3 assumed a blanket re-derive and said this
// file would become dead code; that assumption did not survive asking him which he meant.
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
