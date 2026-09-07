import Foundation

// #2408. The addresses Dan has struck, in a form he can read and act on.
//
// #2392 gave him a control to strike an address before the prep run, and nothing showed him what he had
// struck. One of the two scopes is effectively invisible once he leaves the card: a strike on an
// INHERITED address is recorded against the whole ORGANISATION (his call, 2026-08-09), so it removes that
// address from every show that organisation ever puts on, and weeks later such a show simply shows one
// address fewer than the check found with nothing on screen saying why.
//
// THE UNDO ALREADY EXISTED AND WAS UNREACHABLE, which is the shape of the defect. Typing the address back
// in on any of that organisation's shows reverses it, and that is deliberate (#2155). But it only works
// if he still remembers the address, and an organisation strike removes the very text he would have to
// retype.
//
// PURE, and given the rows and the shows rather than a store, so every rule here is testable and the view
// stays dumb (#863).
enum StruckAddressListing {

    // The stored row, reduced to what this reads. Mirrors `ContactRefusal.Ledger.Row` and adds the date,
    // which the ledger has no use for and this does: `RefusedContactAddress` was built auditable for
    // exactly this surface.
    struct Row: Equatable, Sendable {
        let handleKey: String
        let scopeRaw: String
        let scopeId: String
        let refusedAt: Date
    }

    // What a show contributes: its key, so a show-scoped strike can be named, and its presenter, so an
    // organisation-scoped one can be. Nothing else is read.
    struct Show: Equatable, Sendable {
        let naturalKey: String
        let groupName: String
        let presenter: String?
    }

    struct Entry: Identifiable, Equatable, Sendable {
        // The stored handle, kept as-is, because it is what `ContactRefusal.allow` is keyed on and the
        // control that puts it back has to hand back exactly this.
        let handleKey: String
        // What Dan reads: the address, or the URL without the `form:` prefix the store adds (#2438).
        let handle: String
        let isLink: Bool
        // The show or the organisation, in a spelling he would recognise, never the folded key.
        let scopeName: String
        // Whether this one removes the address from EVERY show that organisation puts on, which is the
        // half he cannot see anywhere else and the reason this surface exists.
        let appliesToEveryShowBy: Bool
        let refusedAt: Date
        // The stored scope id, kept so putting the address back can hand `ContactRefusal.allow` exactly
        // the key the strike was written under rather than one this surface re-derives. Only one of the
        // two is ever set, which is what the scope means.
        let scopeIdIfShow: String?
        let scopeIdIfOrganisation: String?
        var id: String { "\(scopeName)|\(handleKey)|\(appliesToEveryShowBy)" }
    }

    static func build(rows: [Row], shows: [Show]) -> [Entry] {
        // Built once for the whole listing rather than per row: naming an organisation walks every show
        // in the store, and doing that per strike would pay it again for each (L91).
        var orgNames: [String: String] = [:]
        var showNames: [String: String] = [:]
        for show in shows {
            showNames[show.naturalKey] = show.groupName
            if let presenter = show.presenter, let key = OrgKey.stored(for: presenter) {
                orgNames[key] = presenter
            }
        }

        return rows
            // Newest first: the strike he is most likely looking for is the one he just made. Ties break
            // on the handle, so the list is stable between reads rather than reshuffling under him.
            .sorted { $0.refusedAt == $1.refusedAt ? $0.handleKey < $1.handleKey : $0.refusedAt > $1.refusedAt }
            .map { row in
                let isShow = row.scopeRaw == ContactRefusal.Scope.showRaw
                // An organisation no show in the store names any more, and a scope this build does not
                // know, are both KEPT and marked rather than dropped or printed as a folded key. Dropping
                // one would hide a strike that is still in force, which is the very thing this surface
                // exists to make visible (L98, L11).
                let name = isShow
                    ? (showNames[row.scopeId] ?? StruckAddressCopy.unnamedShow)
                    : (orgNames[row.scopeId] ?? StruckAddressCopy.unnamedOrganisation)
                let link = row.handleKey.hasPrefix(Recipient.formHandlePrefix)
                return Entry(handleKey: row.handleKey,
                             handle: link
                                ? String(row.handleKey.dropFirst(Recipient.formHandlePrefix.count))
                                : row.handleKey,
                             isLink: link,
                             scopeName: name,
                             appliesToEveryShowBy: !isShow,
                             refusedAt: row.refusedAt,
                             scopeIdIfShow: isShow ? row.scopeId : nil,
                             scopeIdIfOrganisation: isShow ? nil : row.scopeId)
            }
    }
}

// The sheet's own words, beside the rule that produces them so they reach `docs/copy-inventory.md` and
// are read cold.
enum StruckAddressCopy {
    static let heading = "Addresses you removed"
    // "You removed" is load bearing. A strike is DAN'S OWN reversible choice, and an organisation that
    // asked not to be contacted is the one decision in this app that cannot be taken back. The Sources
    // sheet has already had exactly this defect, two states reading as one thing, so the two sentences
    // are deliberately unalike.
    static let explanation =
        "You removed these before a run, so Overture doesn't research them or write to them. Put one back and the next run can use it again."
    static let emptyState =
        "You haven't removed any addresses. Removing one on a card puts it here, so you can put it back."
    static let restoreControl = "Put back"
    static let everyShowBy = "every show by"
    static let unnamedOrganisation = "an organisation no show names any more"
    static let unnamedShow = "a show no longer in the queue"
}
