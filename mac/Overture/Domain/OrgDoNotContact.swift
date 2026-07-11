import Foundation

// #769: an org asked Dan to stop emailing them. Today that refusal is filed against ONE performance
// and forgotten, so when the org presents at Carnegie again next season the scout surfaces them as a
// fresh prospect with no memory of it, and nothing stands between that and a second pitch.
//
// Repeatedly emailing someone who explicitly asked you to stop is how a photographer's name gets a
// reputation in a small community, and it is the one mistake here that cannot be taken back once the
// email is gone.
//
// Deliberately NOT a new org entity, which is what the issue feared it would need. The
// do-not-contact machinery already exists and already works: HistoryMatch suppresses any org carrying
// a "dnc" history record, ProspectAssembler skips a suppressed event, and LocalHistory derives that
// history from Dan's own prospects. Marking an org only has to emit the record; the path that already
// runs every scout does the rest. A parallel mechanism would have been a second thing to get wrong.
enum OrgDoNotContact {
    // Every prospect belonging to the same org. Confident name match only, the same bar the scout's
    // own suppression uses: a merely similar name is never authoritative enough to act on, in either
    // direction.
    static func sameOrg(as name: String, in all: [Prospect]) -> [Prospect] {
        all.filter { GroupNameMatch.isConfident(name, $0.groupName) }
    }

    // Dan marks the ORG off-limits, not just this show.
    //
    // The flag goes on every prospect of the org, not only the one he was looking at, for two reasons:
    // the "dnc" history record then survives whichever show he happened to have open, and the tag is
    // visible on all of them, which is the truth (they are all off-limits now).
    //
    // Crucially this cleans up the PRESENT as well as the future. Protecting the next scout while
    // leaving three of the org's other shows drafted and ready to send in the queue would be a
    // feature that looks like it works and still sends the email.
    static func mark(orgOf prospect: Prospect, in all: [Prospect]) {
        for p in sameOrg(as: prospect.groupName, in: all) {
            p.orgDoNotContact = true

            // Nothing further goes out, on any show of theirs. Reuses the existing freeze: a contact
            // that was never emailed is simply no longer pursued, which leaves the reply/decline stats
            // honest (it records no decline that never happened).
            p.suppressUntriedRecipients(reason: .declined)

            // A show already emailed is real outreach history and stays exactly as it is. Rewriting it
            // would be lying about what happened. It just can never send again, which
            // suppressUntriedRecipients above and `isClosed` (which now reads this flag) together
            // guarantee: no fresh send, no follow-up, no reminder.
            if p.sentAt == nil && p.status != .dismissed {
                p.status = .dismissed
                p.dismissReasonRaw = DismissReason.notInterested.rawValue
            }
        }
    }

    // A mis-click must not be permanent. Releases the org so a future scout surfaces it again.
    //
    // The shows this dismissed stay dismissed, and are restored from Archive the usual way. Silently
    // resurrecting Dan's dismissals would be its own unpleasant surprise, and un-suppressing a
    // recipient he has since dealt with differently would be worse.
    static func unmark(orgOf prospect: Prospect, in all: [Prospect]) {
        for p in sameOrg(as: prospect.groupName, in: all) {
            p.orgDoNotContact = false
        }
    }
}
