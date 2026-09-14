import Foundation
import SwiftData

// #3651 (milestone #80, Phase 1): the identity of a row on the Reached out list, and the one place that
// finds the model behind a press on it.
//
// WHY A SNAPSHOT AT ALL. `RenderData.reachedOut` held live `Prospect` and `Recipient` references across
// a render snapshot, and deletes run on the MAIN context with a window open: `LaunchMigrations` sweeps at
// launch, and `DuplicateContactMerge`, `SameNightTitleVariantMerge`, `DriftedRunMerge` and
// `ContactRefusal` all call `context.delete`. Reading a property off a deleted model is a crash, not a
// stale row.
//
// WHY NOT THE NATURAL KEY, which is the obvious answer and the dangerous one. `Prospect.naturalKey` is
// `@Attribute(.unique)` and MUTABLE, reassigned at five sites, and one of them is a survivor adopting the
// key of the loser it just deleted (`SameNightTitleVariantMerge:187`; the others are
// `NaturalKeyVenueMigration:76` and `:154`, `RunNightDrop:271` and `:313`, and `ScoutService:1282`).
// Because the column is unique, `first(where:)` on a key finds EXACTLY ONE row and returns it with
// nothing to report, so a press meant for a merged-away show resolves silently onto the survivor and
// lands on a different show. That is L145 (re-keying onto an identity another record holds), L75
// (identification falling back to a nearby candidate) and L15 (keying on a mutable string) at once, and
// this milestone's hard constraint 2 says a wrong-row write is worse than the crash it replaces.
//
// SO: `persistentModelID` is the IDENTITY and the natural key is a WITNESS. The resolver refuses whenever
// the two disagree, rather than preferring either.
//
// `persistentModelID` is only stable for a SAVED row, so `isResolvable` asserts the snapshot was taken of
// one. Every row reaching here came out of a `@Query` and is saved by construction; the assertion is
// there because "by construction" is the kind of premise that stops being true without anything saying so.
struct ReachedOutSnapshot: Equatable, Identifiable, Sendable {
    let showID: PersistentIdentifier
    let contactID: PersistentIdentifier
    // The WITNESS, never the identity. If this disagrees with the row `showID` finds, the row is not the
    // one the list drew and the press is refused.
    let naturalKey: String
    let contactId: String
    let org: String
    let next: Date

    var id: String { "\(naturalKey)#\(contactId)" }

    init(show: Prospect, contact: Recipient, next: Date) {
        self.showID = show.persistentModelID
        self.contactID = contact.persistentModelID
        self.naturalKey = show.naturalKey
        self.contactId = contact.id
        self.org = show.groupName
        self.next = next
    }

    // WHAT THE RESOLVER FOUND. Three refusals, three causes, three sentences, because two outcomes given
    // the same message are one outcome in practice and only one of these is "the show is gone" (L11, L260).
    enum Outcome: Equatable, CustomStringConvertible {
        case found(Prospect, Recipient)
        /// The row is not in the live list. It was deleted, or merged away.
        case gone
        /// The row is alive and its own key has moved, so it is not the show the list drew.
        case reKeyed
        /// The show is alive and unchanged; the contact is not there any more.
        case contactGone

        var description: String {
            switch self {
            case .found: return "found"
            case .gone: return "gone"
            case .reKeyed: return "reKeyed"
            case .contactGone: return "contactGone"
            }
        }

        // Said in Dan's own words, one sentence each. `gone` reuses the wording already shipped for this
        // case so the product does not grow a second way of saying one thing.
        // COLD READ, 2026-09-07, each branch rendered and read in the order Dan meets it: he presses a
        // control, the row does not change, and this appears (#843).
        //
        // EACH BRANCH IS A WHOLE SENTENCE rather than one sentence with a name spliced into it. Written
        // the obvious way, with a `name` local falling back to "That show", the copy inventory records
        // the FRAGMENTS ("That show", "that show") as entries of their own, and the cold read the
        // inventory exists for cannot be done on a clause (#2570, #2548). `couldNotFindShow` beside it
        // already does it this way.
        //
        // WHAT THE READER IS TOLD TO DO, which is the half a refusal usually gets wrong. Nothing here
        // asks Dan to fix anything, because there is nothing for him to fix: the save that moved the row
        // has already rebuilt the queue, so by the time he reads this the list is correct. So each one
        // says what happened, that nothing was changed, and that the row in front of him is now right.
        func sentence(org: String?) -> String {
            switch self {
            case .found: return ""
            case .gone: return ActionAck.couldNotFindShow(org: org)
            case .reKeyed:
                guard let org, !org.isEmpty else {
                    return "That show was merged, or moved to a different night, after this row was "
                        + "drawn. Nothing was changed. The list has caught up, so press it again"
                }
                return "\(org) was merged, or moved to a different night, after this row was drawn. "
                    + "Nothing was changed. The list has caught up, so press it again"
            case .contactGone:
                guard let org, !org.isEmpty else {
                    return "That contact is no longer on the show, so nothing was changed. It was "
                        + "merged into another contact, or struck off"
                }
                return "That contact is no longer on \(org), so nothing was changed. It was merged "
                    + "into another contact, or struck off"
            }
        }
    }

    // ONE definition of "find the row behind this press", so a second call site cannot grow a second
    // answer (L263, L370).
    //
    // `prospects` is the VIEW's own live query, never the pass's captured scope. Resolving against a
    // captured array walks model references the pass took minutes ago and faults a property on each one,
    // which is the same invalidated-model crash moved one level out and paid on every press rather than
    // only a Reached out one. `RenderData`'s own comment already states that rule.
    static func resolve(_ snapshot: ReachedOutSnapshot, in prospects: [Prospect]) -> Outcome {
        guard let show = prospects.first(where: { $0.persistentModelID == snapshot.showID }) else {
            return .gone
        }
        guard show.naturalKey == snapshot.naturalKey else { return .reKeyed }
        guard let contact = show.recipients.first(where: {
            $0.persistentModelID == snapshot.contactID && $0.id == snapshot.contactId
        }) else { return .contactGone }
        return .found(show, contact)
    }
}
