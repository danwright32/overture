import Foundation
import SwiftData

// #2422: the duplicates already in the store, reconciled by the SAME rule that stops new ones arriving.
//
// The importer fix (PrepImporter.matchSamePerson) only decides what a FUTURE run does. Six pairs were
// sitting on Dan's live store when this was written, across two shows, plus the pair he struck by hand
// that morning, and nothing was ever going to reconcile them: a re-prep would keep finding both handles
// and keep them both. That card reads as a 17 person show when 5 of the 17 are duplicates of another 5.
//
// It DELETES a row, so the rules below are written to fail towards keeping one:
//
//   - Only within one show, and only among still-pending, non-manual recipients. A sent recipient's
//     address is locked (#408) and a manual one is Dan's own (#388); a group containing either is left
//     entirely alone rather than partly merged.
//   - Only where exactly two or more rows fold to ONE person and every one of them is safe to touch.
//   - Nothing the loser knew is lost. Every field is carried across where the winner has none, which is
//     the case the store actually held: Ben Cameron's form-only row carried no role while his address row
//     carried "Creator & Host, Broadway Sessions", and Cydney's Instagram row carried a role her booking
//     page row did not (L5: a blank must never beat real data in a merge).
enum DuplicateContactMerge {

    // How many rows were merged away. Reported rather than silent so a launch that reconciled something
    // can say so, and so a test can tell "nothing to do" from "did nothing".
    @discardableResult
    static func run(in context: ModelContext) -> Int {
        let prospects = (try? context.fetch(FetchDescriptor<Prospect>())) ?? []
        var merged = 0
        for p in prospects {
            merged += reconcile(p, in: context)
        }
        if merged > 0 { try? context.save() }
        return merged
    }

    // One show. Split out so a test can drive it without a store full of other prospects, and because
    // this is the unit the rule is actually about: two rows are the same person only within one show.
    @discardableResult
    static func reconcile(_ p: Prospect, in context: ModelContext) -> Int {
        var byPerson: [String: [Recipient]] = [:]
        for r in p.recipients {
            guard let key = ContactIdentity.personKey(r.name) else { continue }
            byPerson[key, default: []].append(r)
        }

        var merged = 0
        for (_, rows) in byPerson where rows.count > 1 {
            // Any row that must not be touched takes the whole group out of scope. Merging the other two
            // while a sent row sits beside them would leave the card still showing one person twice, and
            // this pass is not the place to decide what a sent duplicate means.
            guard rows.allSatisfy({ $0.provenance != .manual && $0.sendState == .pending }) else { continue }
            // Two rows holding DIFFERENT addresses are not one person found twice. They are either two
            // people who share a name or two real routes to one, and either way the loser's address is
            // destroyed by this pass: `carryAcross` only ever FILLS a gap, so a winner that already has
            // an address simply drops the other one.
            //
            // The importer refuses the matching case for the same reason (a batch carrying one name twice
            // is not evidence), and this pass had no equivalent because there is no batch here to look at.
            // Measured on the live store 2026-08-10: 0 groups match, so this costs nothing today and is
            // what stops the day it does from costing an address silently.
            let addresses = Set(rows.compactMap { r -> String? in
                let address = (r.email ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                return address.isEmpty ? nil : address
            })
            guard addresses.count <= 1 else { continue }
            guard let winner = preferredRow(rows) else { continue }

            for loser in rows where loser !== winner {
                carryAcross(from: loser, to: winner)
                p.recipients.removeAll { $0 === loser }
                context.delete(loser)
                merged += 1
            }
            if let id = Recipient.makeId(email: winner.email, formURL: winner.contactFormURL) {
                winner.id = id
            }
        }
        return merged
    }

    // The better way in, by the same order the card already uses to decide what it will offer Dan: an
    // address beats a form, and a form on the act's own site beats a social profile (#1626), which is a
    // dead end he will not use.
    //
    // A stable tie-break on the id, so two equally good rows always resolve the same way rather than
    // depending on fetch order, which would make this pass produce different stores on different runs.
    static func preferredRow(_ rows: [Recipient]) -> Recipient? {
        rows.min { lhs, rhs in
            let l = rank(lhs), r = rank(rhs)
            return l == r ? lhs.id < rhs.id : l < r
        }
    }

    private static func rank(_ r: Recipient) -> Int {
        if !(r.email ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return 0 }
        if let form = r.contactFormURL, !form.isEmpty, !Reachability.isSocialOnly(form) { return 1 }
        if let form = r.contactFormURL, !form.isEmpty { return 2 }
        return 3
    }

    // Everything the loser knew that the winner does not. Only ever fills a gap: the winner was chosen
    // for its handle, and a merge that let the loser's blank overwrite the winner's value would destroy
    // the thing the choice was made on.
    private static func carryAcross(from loser: Recipient, to winner: Recipient) {
        if (winner.email ?? "").isEmpty { winner.email = loser.email }
        if (winner.name ?? "").isEmpty { winner.name = loser.name }
        if (winner.role ?? "").isEmpty { winner.role = loser.role }
        if (winner.contactSourceURL ?? "").isEmpty { winner.contactSourceURL = loser.contactSourceURL }
        if (winner.contactMethodRaw ?? "").isEmpty { winner.contactMethodRaw = loser.contactMethodRaw }
        if (winner.contactConfidenceRaw ?? "").isEmpty {
            winner.contactConfidenceRaw = loser.contactConfidenceRaw
        }
        if (winner.overrideBody ?? "").isEmpty { winner.overrideBody = loser.overrideBody }
        // The form follows the same better-of-the-two rule the importer uses, so a winner chosen for its
        // ADDRESS still inherits the loser's usable booking page rather than dropping it.
        winner.contactFormURL = ContactIdentity.preferredFormURL(existing: winner.contactFormURL,
                                                                 incoming: loser.contactFormURL)
        // A dismissal is Dan's own answer about this person, so it survives whichever row he gave it on.
        // Never the reverse: a guard's opinion is re-derived on the next ingest, but his answer is not.
        winner.looksLikeVenueDismissed = winner.looksLikeVenueDismissed || loser.looksLikeVenueDismissed
        winner.looksLikePressContactDismissed =
            winner.looksLikePressContactDismissed || loser.looksLikePressContactDismissed
        winner.looksLikeDuplicateContactDismissed =
            winner.looksLikeDuplicateContactDismissed || loser.looksLikeDuplicateContactDismissed
    }
}
