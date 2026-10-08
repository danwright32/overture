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
// #4357 slice I2: that rule now lives in `ShowIdentity`, lifted out of this type so every action finds its
// show the same way rather than only this list's. This holds one and calls it, and adds only what is this
// list's own: the CONTACT half.
//
// `persistentModelID` is only stable for a SAVED row. This comment used to say an assertion guarded that,
// and none existed; a row drawn before its first save is now its own refusal
// (`ShowIdentity.Refusal.drawnBeforeItsFirstSave`) rather than a premise nothing checked.
struct ReachedOutSnapshot: Equatable, Identifiable, Sendable {
    let show: ShowIdentity
    let contactID: PersistentIdentifier
    let contactId: String
    let org: String
    let next: Date

    var id: String { "\(show.naturalKey)#\(contactId)" }

    // #4358 slice E4a: over any facts conformer, so the pass takes it from a model today and from a retained
    // show after the cutover.
    init<Row: ProspectFacts>(show: Row, contact: Row.Contact, next: Date) {
        self.show = ShowIdentity(show)
        self.contactID = contact.persistentModelID
        self.contactId = contact.id
        self.org = show.groupName
        self.next = next
    }

    // WHAT THE RESOLVER FOUND. The show's own refusals are `ShowIdentity`'s, carried whole rather than
    // copied into cases of their own here, so the two lists cannot drift apart (L263). The contact going
    // is this list's own, and is a different thing from the show going (L11, L260).
    enum Outcome: Equatable, CustomStringConvertible {
        case found(Prospect, Recipient)
        /// The show itself could not be resolved, for the reason the refusal names.
        case showRefused(ShowIdentity.Refusal)
        /// The show is alive and unchanged; the contact is not there any more.
        case contactGone

        var description: String {
            switch self {
            case .found: return "found"
            case .showRefused(let refusal): return refusal.description
            case .contactGone: return "contactGone"
            }
        }

        // COLD READ, 2026-09-07, each branch rendered and read in the order Dan meets it: he presses a
        // control, the row does not change, and this appears (#843). The show's sentences are
        // `ShowIdentity.Refusal.sentence`, moved there unchanged; this one is the contact's.
        //
        // EACH BRANCH IS A WHOLE SENTENCE rather than one sentence with a name spliced into it, so the
        // copy inventory records sentences rather than fragments (#2570, #2548).
        func sentence(org: String?) -> String {
            switch self {
            case .found: return ""
            case .showRefused(let refusal): return refusal.sentence(org: org)
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

    // The show through the one resolver, then the contact on it.
    //
    // `shows` is the VIEW's own live query, never the pass's captured scope. Resolving against a captured
    // array walks model references the pass took minutes ago and faults a property on each one, which is
    // the same invalidated-model crash moved one level out and paid on every press rather than only a
    // Reached out one. `RenderData`'s own comment already states that rule.
    @MainActor
    static func resolve(_ snapshot: ReachedOutSnapshot, in shows: some ShowResolver) -> Outcome {
        switch snapshot.show.resolve(in: shows) {
        case .refused(let refusal):
            return .showRefused(refusal)
        case .found(let show):
            guard let contact = show.recipients.first(where: {
                $0.persistentModelID == snapshot.contactID && $0.id == snapshot.contactId
            }) else { return .contactGone }
            return .found(show, contact)
        }
    }
}
