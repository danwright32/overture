import Foundation

// Keeps repeat-client recognition current without a stale CSV re-import (#19). The
// matching history is derived live from Overture's own activity: a booked outcome is
// "booked", a reply is "warm", a scheduling dismissal is "declined", a lost outcome is
// "lost_soft"/"lost_hard", and a plain send is a neutral "contacted". Merged with
// Downbeat and any one-time legacy import, so every action Dan takes feeds the next
// scout's prior-relationship signal automatically.
enum LocalHistory {
    // Reasons Dan skips a prospect because HE couldn't take it (a scheduling miss), not because they
    // are a bad fit. What that BUYS the org is that the miss is never mistaken for a fit judgement: it
    // is recorded as "declined", which `Ranker.priorPoints` weights 0, exactly like a cold lead.
    //
    // #1820: this used to claim the opposite, that a scheduling miss kept an org hot and earned it a
    // multiplier. That stopped being true at #1362 and was wrong for a year, and the multiplier it named
    // existed in no line of code anywhere in the domain. (The old wording is deliberately not quoted
    // here: the guard on this file matches TEXT, and cannot tell a line that makes the claim from one
    // explaining the claim was retired, L103.) #1362's decision is explicit at
    // `Ranker.priorPoints`: a past decline is usually just an old date conflict, irrelevant to a
    // future pitch, so it neither floats a declined show to the top nor auto-corrects a warm lead.
    //
    // It mattered more than an ordinary stale comment because of WHERE it sits: this is the line a
    // reader meets while deciding what a dismiss reason MEANS before choosing one, and on 2026-07-30
    // it produced a wrong answer to Dan about which reason to pick when clearing the other shows on a
    // night he had committed (#1819). He was told "Date conflict" would keep those orgs hot with a
    // boost; it leaves them exactly where "Not a fit" leaves them.
    // #1821: `pitchingOtherShows` belongs here for exactly the same reason. Dan wanted the show and lost
    // it to the night's capacity, not to anything about the org, so it stays a hot future lead and scores
    // identically to a date conflict ("declined", which Ranker.priorPoints weights 0 by #1362's decision).
    // #2394: `hadPaidWork` is the rename of `alreadyBooked`, the same fact under the word that does not
    // collide with a client having hired Dan.
    private static let schedulingDismissals: Set<ShowOutcome> = [.dateConflict, .hadPaidWork,
                                                                 .pitchingOtherShows]

    static func records(from prospects: [Prospect]) -> [HistoryRecord] {
        prospects.compactMap { p in
            // #769: the org asked Dan to stop emailing them. Checked FIRST, and it outranks everything
            // below: even a past booking with them does not license another cold pitch after they have
            // said no. "dnc" is a status the scout's matcher already knows how to suppress on, so this
            // one line is the whole mechanism.
            if p.orgDoNotContact {
                return HistoryRecord(groupName: p.groupName, status: "dnc", origin: .overtureActivity)
            }
            if p.isBooked || p.showOutcome == .booked {
                return HistoryRecord(groupName: p.groupName, status: "booked", origin: .overtureActivity)
            }
            // #2399/#2401: read off the ONE field. This used to read `Outcome.lostHard`/`.lostSoft`, which
            // nothing in the app has ever written, so Overture could learn that an org booked Dan and could
            // never learn that one turned him down: they came back next season ranked as if nothing had
            // happened. This is the half of that defect the scout feels.
            if p.showOutcome == .theySaidNo {
                return HistoryRecord(groupName: p.groupName, status: "lost_hard", origin: .overtureActivity)
            }
            if p.showOutcome == .theySaidNotNow {
                return HistoryRecord(groupName: p.groupName, status: "lost_soft", origin: .overtureActivity)
            }
            // Deliberately NOT recorded as a loss of either kind:
            //
            // `neverHeardBack` is a silence, and a silence is not a refusal. Nobody turned Dan down, so the
            // org must not be ranked lower for never having written back. It falls through to "contacted"
            // below, which is exactly what happened.
            //
            // `turnedThemDown` is DAN'S refusal, about one show. Recording it against the org would say
            // they refused him, which is the opposite of what happened, and would then penalise an org for
            // a decision he made about a single event.
            if p.status == .dismissed,
               let reason = p.showOutcome,
               schedulingDismissals.contains(reason) {
                return HistoryRecord(groupName: p.groupName, status: "declined", origin: .overtureActivity)
            }
            // #384: Dan passed on this show on taste ("Don't want to shoot this"). Recorded WITH its
            // venue, which is the whole point: the penalty is aimed at this org at this venue, so the
            // same org anywhere else stays a perfectly ordinary lead.
            //
            // #351 recorded nothing here, precisely so a taste pass could never become an org-wide
            // black mark. The venue is what lets us keep that promise while still remembering the pass,
            // so the identical recurring show doesn't come back next season scoring just as high.
            // "Not a fit" (.notInterested) is still recorded as nothing at all: that is a judgement
            // about the show, not a standing pass Dan wants us to act on.
            if p.status == .dismissed, p.showOutcome == .dontWantToShoot {
                return HistoryRecord(groupName: p.groupName, status: "passed",
                                     origin: .overtureActivity, email: nil, venue: p.venue)
            }
            // Warm = they wrote back. Phase F: derive from a contact replying (the A3 lead rollup is
            // gone); the legacy lead outcome is kept as a fallback for un-backfilled stores.
            if p.outcome == .replied || p.recipients.contains(where: \.replied) {
                return HistoryRecord(groupName: p.groupName, status: "warm", origin: .overtureActivity)
            }
            if p.sentAt != nil {
                return HistoryRecord(groupName: p.groupName, status: "contacted", origin: .overtureActivity)
            }
            return nil
        }
    }

    // The one-time legacy booking-history import (group name + status), produced by
    // scripts/import-history.ts (pnpm import-history) from Dan's booking CSV. Absent file = no
    // history yet, which is normal, not an error.
    static var importedURL: URL {
        StoreLocation.handoffDirectory.appendingPathComponent("overture-history.json")
    }

    // ABSENT and UNREADABLE are different things (#754). Both used to return an empty array, so a
    // CORRUPT history file looked exactly like a fresh install with no import yet, and every repeat
    // client silently read as a cold lead with no symptom at all. Absent is a normal state; corrupt
    // is a fault, and the caller has to be able to say so.
    static func importedWithHealth(from url: URL = importedURL) -> (records: [HistoryRecord], unreadable: Bool) {
        guard let data = try? Data(contentsOf: url) else { return ([], false) }
        guard let history = try? JSONDecoder().decode([HistoryRecord].self, from: data) else {
            return ([], true)
        }
        // #1695: stamped explicitly rather than left to the type's default. This file IS the booking
        // import, and a record that arrives here mislabelled would be described to Dan in the wrong words
        // on a card, which is the whole defect. Saying it at the boundary means the default can be changed
        // later without silently relabelling Dan's realest business.
        return (history.map { var r = $0; r.origin = .bookingImport; return r }, false)
    }

    static func imported(from url: URL = importedURL) -> [HistoryRecord] {
        importedWithHealth(from: url).records
    }

    // The COMPLETE history any matcher should see: the legacy import plus Overture's own activity.
    // Shared (#751) so the scout and Prep match against the same records. They used to compose this
    // separately, which would have let the same performer read as a past client in one place and a
    // stranger in the other, with nothing catching the discrepancy.
    static func forMatchingWithHealth(existing: [Prospect], importedFrom url: URL = importedURL)
        -> (records: [HistoryRecord], unreadable: Bool) {
        let imported = importedWithHealth(from: url)
        return (imported.records + records(from: existing), imported.unreadable)
    }

    static func forMatching(existing: [Prospect], importedFrom url: URL = importedURL) -> [HistoryRecord] {
        forMatchingWithHealth(existing: existing, importedFrom: url).records
    }
}
