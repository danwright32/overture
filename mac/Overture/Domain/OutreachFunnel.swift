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
// Measured on the live store 2026-08-11 while building this: 877 scouted, 81 holding a contact, 13
// drafted, 6 sent. Of the 81, 49 were still upcoming with a contact already found and no draft, and 16
// had passed their date with a contact and no send, 11 of those after a PAID reachability check. So the
// answer was the second explanation, not a broken send path, and the cost of it is measurable: paid
// lookups spent on shows that then expired unpitched.
//
// These are STANDING counts, not a flow over a window. The flow version needs a stamp per stage
// transition and most stages do not carry one; the standing shape is what Dan can act on tonight, and the
// two expiry counts already carry the time dimension that matters. #2510 holds the window version.
//
// Every number here is COUNTED from the rows, never written down: a hand-written count in a doc or a
// comment is stale the day after it is measured (L32), and this report exists precisely because the
// numbers move.
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

    // The sentences live here rather than in the view, matching `OutcomePatterns` (#885): what is left in
    // the view is layout, and every sentence Overture can say lands in `docs/copy-inventory.md` where a
    // wording change shows up in the words Dan will read.

    /// The shape of the funnel. Always shown when there is anything at all to report.
    static func stageLine(_ c: Counts) -> String {
        "\(c.scouted) scouted, \(c.contactFound) with a contact, \(c.drafted) drafted, \(c.sent) sent."
    }

    /// The chances still open. Nil when there are none, so the section says nothing rather than
    /// announcing a zero: an absent line here reads as "nothing waiting", which is what it means.
    static func waitingLine(_ c: Counts) -> String? {
        guard c.waitingWithAContact > 0 else { return nil }
        let shows = c.waitingWithAContact == 1 ? "1 upcoming show has" : "\(c.waitingWithAContact) upcoming shows have"
        return "\(shows) a contact and no draft."
    }

    /// The chances that ran out, with the paid ones named apart, because that is the number with a cost
    /// attached and Dan can only weigh the spend if he can see it.
    static func expiredLine(_ c: Counts) -> String? {
        guard c.expiredWithAContact > 0 else { return nil }
        let shows = c.expiredWithAContact == 1 ? "1 show" : "\(c.expiredWithAContact) shows"
        guard c.expiredAfterAPaidCheck > 0 else {
            return "\(shows) ran out of time holding a contact."
        }
        return "\(shows) ran out of time holding a contact, \(c.expiredAfterAPaidCheck) of them after a paid check."
    }
}
