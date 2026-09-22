import Foundation
import SwiftData

// #726: a narrow safety net for #369's grouping, the SAME real-world performance somehow still
// producing two separate Prospect rows (grouping's title/venue/date matching didn't merge them).
// Fires only when contact, venue, AND date all agree, deliberately narrower than "this contact is
// pitched elsewhere soon": a shared contact at a genuinely DIFFERENT venue (e.g. a touring act's
// shared booking-agency inbox pitching two different upcoming shows) is legitimate and never
// flagged. Unlike VenueContactGuard/PressContactGuard (pure functions), this needs a ModelContext
// since it looks across OTHER prospects, not just this recipient's own fields.
enum DuplicateContactGuard {
    private static let gapDays = 3  // mirrors RunGrouping's own window (#369)

    // #4042: WHICH row it matched, not merely that it matched one.
    //
    // The warning this feeds BLOCKS a send and used to say only that the address is "already pitched for
    // a show at this venue", which left Dan to find the collision himself on a screen that does not show
    // the other card. A message naming a specific record owes him the way to act on it (L80), and that
    // needs the matched row to survive the journey from prep to review, which a stored Bool cannot do.
    //
    // The KEY rather than a snapshot of the row's title and night: the row can change or be merged away
    // between prep and review, and a key resolved at render draws the CURRENT title or nothing at all,
    // where a snapshot would quietly describe a row that no longer reads that way (L200).
    struct Match: Equatable, Sendable {
        let prospectKey: String
    }

    // #Predicate cannot call .lowercased() inside its closure, so the email/venue comparison is
    // done in plain Swift after an unfiltered fetch, not via a predicate.
    // #3636: `groupName` is NOT defaulted, so every call site has to answer it. A default of nil would
    // silently give a forgetful caller the old three day behaviour, which is the case this exists to
    // fix, and nothing would say so (L168, L621).
    //
    // It is OPTIONAL in type because a row legitimately may not carry one, and nil means the same-show
    // question could not be asked rather than answered no: the three day arm still applies and the
    // wider arm does not. That is the safe direction, since the wide arm only ever ADDS a warning.
    static func duplicate(email: String?, venue: String?, performanceDate: String?,
                          groupName: String?,
                          excludingProspectKey: String, in context: ModelContext) -> Match? {
        guard let email, !email.isEmpty, let venue, !venue.isEmpty, let performanceDate else { return nil }
        let targetEmail = canon(email)
        let targetVenue = canon(venue)
        guard let allRecipients = try? context.fetch(FetchDescriptor<Recipient>()) else { return nil }
        let hit = allRecipients.first { r in
            guard let rEmail = r.email, canon(rEmail) == targetEmail,
                  let p = r.prospect, p.naturalKey != excludingProspectKey, !p.isClosed,
                  let pVenue = p.venue, canon(pVenue) == targetVenue,
                  let otherDate = p.performanceDate,
                  let gap = EasternDate.daysUntil(from: otherDate, to: performanceDate)
            else { return false }
            if abs(gap) <= gapDays { return true }
            // #3636: the SAME SHOW, weeks apart, which the three day arm cannot reach.
            //
            // Dan asked, 2026-09-07: "if a show happens over multiple weekends from now until November
            // and I pitch it once, what happens to the future recurrences in the scout queue? Does it
            // come back?" For a source with no production id it comes back as a second card, and this
            // guard was the only thing that could have said so on the way out. Every fragment of a
            // multi-weekend run sits weeks apart, so it never fired on one.
            //
            // BOTH RECORDED DECISIONS WERE READ BEFORE THIS WAS WRITTEN (L542), and they do not
            // conflict; they answer different questions and one of them answers this one.
            // `RunGrouping.gapDays` is "mirrored by DuplicateContactGuard to pace how often Dan may
            // contact one org. Deliberately NOT widened by #1558: those are different questions, and
            // nobody asked them." So the 3 stays, untouched, for that question. `sameShowGapDays` is
            // "Dan's number, 2026-07-26 ... he pitches a run ONCE ('I'm not going to send them an email
            // every week pitching the show'), not once a week", which is a statement about EMAILING,
            // and this is the guard that paces emailing.
            //
            // Bounded by that same constant rather than "any gap", because `RunGrouping`'s record says a
            // silence longer than it is a separate engagement that earns its own card, and a fresh pitch
            // for a genuinely separate engagement is correct.
            //
            // `isSameShowTitle` (#3917) rather than raw equality, because these fragments differ by a
            // subtitle, which is the whole shape of the defect.
            guard let groupName, !groupName.isEmpty else { return false }
            return abs(gap) <= RunGrouping.sameShowGapDays
                && GroupNameMatch.isSameShowTitle(p.groupName, groupName)
        }
        // The prospect is read from the recipient that matched, which is the row the sentence will name.
        // A recipient with no prospect cannot satisfy the predicate above, so this cannot be nil where a
        // hit exists; it is written as a guard rather than a force unwrap because a crash on the send
        // screen is the worst possible answer to a warning (L42).
        guard let key = hit?.prospect?.naturalKey else { return nil }
        return Match(prospectKey: key)
    }

    private static func canon(_ s: String) -> String {
        s.lowercased().trimmingCharacters(in: .whitespaces)
    }
}
