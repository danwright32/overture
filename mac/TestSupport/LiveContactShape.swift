import Foundation

// #3650 (milestone #80, Phase 0): the live store's CONTACT shape, in one place, because two cost
// fixtures in two different targets need it and a rule's data shared while the code applying it is
// copied is not consolidation (L370).
//
// WHY IT MATTERS. Almost everything expensive about building a queue card is per CONTACT:
// `SendGroup.CardGroups`, `RecipientSnapshot`, and `Recipient.draftLintBlockers`, which reaches
// `DraftCheck` only through a non-empty effective body. A fixture with no recipients short-circuits
// every one of those on its first line, so it measures a path the app never takes.
//
// THAT IS NOT HYPOTHETICAL, and it is why this type exists rather than a comment. #2048 found the
// unhosted cost fixture holding 1,139 prospects and NOT ONE recipient. It was fixed there. The HOSTED
// fixture, `FeltWaitCostTests`, which measures the wait Dan actually FEELS, still held zero on
// 2026-09-07, and nothing reported it: `scripts/check-fixture-corpus-drift.sh` scanned only
// `mac/OvertureTests`, so an entire test target was exempt from the check written to catch exactly this
// (L96, L247). The scan root is widened in the same change.
//
// THE SPREAD IS THE LOAD-BEARING PART, not the totals. 962 of the 1,224 rows have no contact at all, so
// the per-contact work short-circuits on the overwhelming majority. A fixture giving every row a contact
// would measure a path the live store does not take and argue for a fix aimed at the wrong half.
//
// THE VALUES ARE INVENTED and only the SHAPE is real. A distribution is not anybody's data, which is
// what makes deriving the shape from the live store and inventing every name and address the right
// design here (L48, L155, and the privacy rule both fixtures state in their own headers).
//
// Measured 2026-09-07 on a WAL-inclusive read-only copy of the live store.
enum LiveContactShape {

    // LIVE-SHAPE: recipients
    static let recipients = 387
    // LIVE-SHAPE: prospectsWithAContact
    static let prospectsWithAContact = 262
    // LIVE-SHAPE: pendingRecipients
    static let pendingRecipients = 359
    // LIVE-SHAPE: prospectsWithADraftBody
    static let prospectsWithADraftBody = 65
    // The INTERSECTION, which is what the draft lint actually scales with and what no other dimension
    // here can see: the lint is reached only through a non-empty effective body, and `QueueItem.init`
    // asks that of the PENDING recipients (#3506).
    // LIVE-SHAPE: recipientsOnDraftBodyRows
    static let recipientsOnDraftBodyRows = 69
    // LIVE-SHAPE: pendingRecipientsWithADraftBody
    static let pendingRecipientsWithADraftBody = 41

    // A body clean of everything `DraftCheck` blocks, so the lint does its whole pass rather than bailing
    // at its first finding. Invented text, never a real draft.
    static let draftBody = "Hello there,\n\nI photograph performances in New York and would love to "
        + "cover this one. My work is at the link below.\n\nBest,\nDan"

    // Whether row `n` of a corpus carries a draft body. The first `prospectsWithADraftBody` rows do,
    // which is the convention both fixtures follow and the one `attachRecipients` assumes.
    static func carriesADraftBody(_ n: Int) -> Bool { n < prospectsWithADraftBody }

    // WHERE THE RECIPIENT ITSELF IS BUILT, and why it is not built here. `mac/TestSupport` is compiled
    // into BOTH test targets, and they reach the app differently: the unhosted target compiles the app's
    // sources in, the hosted one imports the built module. So a shared file cannot name `Prospect` or
    // `Recipient` at all, which is why `LiveDateClustering` beside it returns plain strings.
    //
    // What is shared is therefore the DECISION, which is the part that was worth sharing: which row gets
    // how many contacts, and which of them are pending. Each fixture turns that into its own objects in
    // six lines. Sharing the constants while copying the loop that applies them would not be
    // consolidation (L370); sharing the loop and leaving the constants apart would be the same defect
    // pointing the other way.

    /// One entry per recipient the live shape calls for: which row it hangs on, and whether it is pending.
    struct Placement: Equatable {
        let row: Int
        let pending: Bool
    }

    // Body rows first, because the intersection is the constraint that cannot be satisfied afterwards:
    // 64 of the 65 body-carrying rows also carry a contact, holding 69 between them, so five of them
    // carry two, and 41 of those are pending. Everything else with a contact is pending, which is what
    // the remaining totals require. That is consistent with how the store gets this way: a row gets a
    // draft when it is prepped, and its contacts are sent from there.
    //
    // A corpus too small to hold the shape gets NOTHING rather than a squeezed version of it, because a
    // partial shape is a fixture claiming a spread it does not have, and every count taken from it would
    // be wrong in a way nothing reports (L48, L98). The small-corpus fixtures that use this assert the
    // mechanism rather than the cost, and say so.
    static func placements(rowCount: Int) -> [Placement] {
        guard rowCount >= prospectsWithAContact + 1 else { return [] }
        var out: [Placement] = []
        var pendingMade = 0

        let bodyRowsWithAContact = prospectsWithADraftBody - 1
        for n in 0..<bodyRowsWithAContact {
            let howMany = n < (recipientsOnDraftBodyRows - bodyRowsWithAContact) ? 2 : 1
            for _ in 0..<howMany {
                let pending = pendingMade < pendingRecipientsWithADraftBody
                out.append(Placement(row: n, pending: pending))
                if pending { pendingMade += 1 }
            }
        }

        var n = prospectsWithADraftBody
        while out.count < recipients && n < prospectsWithAContact + 1 {
            let left = recipients - out.count
            let rowsLeft = prospectsWithAContact + 1 - n
            let howMany = left > rowsLeft ? 2 : 1
            for _ in 0..<howMany where out.count < recipients {
                out.append(Placement(row: n, pending: true))
            }
            n += 1
        }
        return out
    }
}
