import Foundation

// #2035: where the shows go between being scouted and being written to.
//
// The question came from a ratio nobody could explain: 108 contacts had produced 3 sends. That has at
// least three very different explanations (Dan is pitching from Gmail by hand, contacts are found faster
// than shows are approved, or something in the approve-to-send path is stopping shows), and only the
// third is a defect. Nothing in the app distinguished them, because the one report Dan can read
// (`OutcomePatterns`, "What converts") counts CONTACTED shows only. It describes the tail and is silent
// about everything before the send, which is exactly where the shows were going.
//
// LIVE-STORE-CLAIM verified=2026-08-11 measure="shows at each outreach stage, and those holding a contact that were never written to"
// Measured by this code against the live store 2026-08-11: 873 scouted, 66 holding a contact, 13
// drafted, 6 sent. Of the 66, 38 were still upcoming with a contact already found and no draft, and 15
// had passed their date with a contact and no send, 10 of those after a PAID reachability check. So the
// answer was the second explanation, not a broken send path, and the cost of it is measurable: paid
// lookups spent on shows that then expired unpitched.
//
// These figures replace a hand-written set (81 / 49 / 16 / 11) that was in this comment when #2035
// merged. That set came from SQL written beside this code rather than from this code, and it counted a
// show as having a contact when the contact was a web form or a DM, which cannot be written to. The
// looser count and the shipped rule disagreed by a fifth. A measurement taken by anything other than the
// rule it describes can only ever agree with itself (L70), so these come from `counts` below.
//
// These are STANDING counts, not a flow over a window. The flow version needs a stamp per stage
// transition and most stages do not carry one; the standing shape is what Dan can act on tonight, and the
// two expiry counts already carry the time dimension that matters. #2510 holds the window version.
//
// Every number here is COUNTED from the rows, never written down: a hand-written count in a doc or a
// comment is stale the day after it is measured (L32), and this report exists precisely because the
// numbers move.
// NOTHING RENDERS THIS YET, deliberately, and #16 is the issue that will. The text block these counts
// were first written for was removed on Dan's call the same day: what he wants is #16's year-end Sankey
// of the whole funnel, not three sentences at the top of the conversion sheet, and leaving the sentences
// in place would have meant shipping something to be thrown away. The COUNTS survive because they are
// the part #16 needs and they are proved by their own tests; the sentences did not, because a sentence
// nothing shows is dead code (L29). An unread value is normally a defect (L46), so this is the exception
// that names its activating issue rather than the rule (L65).
enum OutreachFunnel {

    struct Counts: Equatable, Sendable {
        /// Every show Overture holds, whatever became of it.
        var scouted = 0
        /// Shows with at least one contact carrying an address that could actually be written to. A
        /// form-or-DM-only contact is deliberately NOT counted: it is a route, not an address, and
        /// counting it here would say a show is ready to write to when nothing can be sent (L16).
        var contactFound = 0
        /// Shows carrying a drafted body.
        var drafted = 0
        /// Shows an email provably went out for.
        var sent = 0
        /// The leak this exists to show: still upcoming, not dismissed, a contact already found, and no
        /// draft. Every one of these is an opportunity Overture has already done the expensive part for.
        var waitingWithAContact = 0
        /// And the ones that ran out of time in that state: the date passed with a contact found and
        /// nothing sent.
        var expiredWithAContact = 0
        /// Of those, the ones whose contact came from a PAID reachability check. This is the number with
        /// a cost attached, which is why it is counted apart from the rest.
        var expiredAfterAPaidCheck = 0
    }

    static func counts(from prospects: [Prospect], today: String) -> Counts {
        var c = Counts()
        for p in prospects {
            c.scouted += 1

            let hasAddress = p.recipients.contains {
                !($0.email ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            }
            let wasSent = p.sentAt != nil
            let hasDraft = !(p.draftBody ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty

            if hasAddress { c.contactFound += 1 }
            if hasDraft { c.drafted += 1 }
            if wasSent { c.sent += 1 }

            guard hasAddress, !wasSent else { continue }

            // Through the shared run rule, not the performance date: a multi-night run has not passed
            // until its LAST night, and judging it on the first would call a run Dan can still pitch
            // expired (L39, one date helper).
            let lastNight = EasternDate.runLastNight(runEndDate: p.runEndDate,
                                                     performanceDate: p.performanceDate)
            if EasternDate.runHasPassed(lastNight: lastNight, today: today) {
                c.expiredWithAContact += 1
                if p.reachabilityProbedAt != nil { c.expiredAfterAPaidCheck += 1 }
            } else if p.status == .new, !hasDraft {
                c.waitingWithAContact += 1
            }
        }
        return c
    }

}
