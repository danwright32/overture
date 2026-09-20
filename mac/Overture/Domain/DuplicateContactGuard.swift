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

    // #Predicate cannot call .lowercased() inside its closure, so the email/venue comparison is
    // done in plain Swift after an unfiltered fetch, not via a predicate.
    // #3636: `groupName` is NOT defaulted, so every call site has to answer it. A default of nil would
    // silently give a forgetful caller the old three day behaviour, which is the case this exists to
    // fix, and nothing would say so (L168, L621).
    //
    // It is OPTIONAL in type because a row legitimately may not carry one, and nil means the same-show
    // question could not be asked rather than answered no: the three day arm still applies and the
    // wider arm does not. That is the safe direction, since the wide arm only ever ADDS a warning.
    static func looksLikeDuplicate(email: String?, venue: String?, performanceDate: String?,
                                   groupName: String?,
                                   excludingProspectKey: String, in context: ModelContext) -> Bool {
        guard let email, !email.isEmpty, let venue, !venue.isEmpty, let performanceDate else { return false }
        let targetEmail = canon(email)
        let targetVenue = canon(venue)
        guard let allRecipients = try? context.fetch(FetchDescriptor<Recipient>()) else { return false }
        return allRecipients.contains { r in
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
    }

    private static func canon(_ s: String) -> String {
        s.lowercased().trimmingCharacters(in: .whitespaces)
    }
}
