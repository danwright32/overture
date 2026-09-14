import Foundation
import SwiftData

// #2408: putting a struck address back, from the one surface that lists them.
//
// THROUGH `ContactRefusal.allow`, never a bare delete of the row, which is what the issue asks for and
// the reason is not stylistic: a strike can be recorded at BOTH scopes for one address, and `allow` is
// documented to clear the pair so an organisation-level refusal is never left standing behind a contact
// now sitting on a card.
//
// IT CLEARS EVERY ROW FOR THAT ADDRESS, not only the one the entry was listed under, and that is the
// difference between this and the obvious version. Handing `allow` only the scope of the row Dan pressed
// leaves the other one refusing, so the address comes back on some cards and not others, and he has no
// way to tell which. Found by a test driven against a real store: the obvious version passed a source
// guard that could see `allow` was CALLED and not what it was handed (L178).
@MainActor
enum StruckAddressMutations {

    static func putBack(_ entry: StruckAddressListing.Entry,
                        rows: [StruckAddressListing.Row],
                        context: ModelContext, feedback: ActionFeedback) {
        // The handle as the store keyed it, split back into the two arguments `allow` takes. Rebuilt from
        // the stored key rather than from what is on screen, because the screen strips the `form:` prefix
        // for reading and `allow` is keyed on the whole handle.
        let isLink = entry.handleKey.hasPrefix(Recipient.formHandlePrefix)
        let email = isLink ? nil : entry.handleKey
        let formURL = isLink
            ? String(entry.handleKey.dropFirst(Recipient.formHandlePrefix.count))
            : nil

        // Every scope this address is struck under, in one pass. `allow` clears at most one show and one
        // organisation per call, so a handle struck on two shows needs two calls; asking it once per row
        // is what makes "put it back" mean the same thing however many strikes are behind it.
        for row in rows where row.handleKey == entry.handleKey {
            let isShow = row.scopeRaw == ContactRefusal.Scope.showRaw
            ContactRefusal.allow(email: email, formURL: formURL,
                                 showKey: isShow ? row.scopeId : nil,
                                 orgKey: isShow ? nil : row.scopeId,
                                 in: context)
        }
        guard context.saveOrWarn(org: entry.scopeName, feedback: feedback) else { return }
        feedback.acknowledge(ActionAck.struckAddressPutBack(entry.handle))
    }
}
