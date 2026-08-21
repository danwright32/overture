import Foundation

// #1856: the deterministic half of the runbook's own verification bar (L27, a rule that lives only in a
// prompt is a hope).
//
// The runbook has always said a `sourceUrl` is "only ever meaningful when confidence == high": high means
// the address was read off a page naming the act, and that page is the evidence. Nothing enforced it, so a
// run could return high with no page and the app would paint it gold as a verified find.
//
// That mattered more the moment the check started pursuing acts on shows that name no producer (#1856):
// the target there is often a show TITLE, and a search for a generic title can land on an unrelated
// organisation of the same name with nothing to cite.
//
// Measured on the live store before shipping it, 2026-07-31: 33 recipients are high WITH a source page and
// 2 are high without one, so this downgrades two rows rather than repainting the queue. Deliberately
// applied to every contact rather than only to the organiser-less shows this issue is about: the rule is
// universal in the runbook's own words, and a guard that fires on one class of row leaves the same false
// claim standing everywhere else (L30, fix the class).
enum ContactConfidenceGuard {
    // A contact may keep `high` only when it names the page it was read from. Anything else falls to
    // `low`, which the card already renders honestly as "Unverified email found" (#1628). A blank or
    // whitespace-only URL is no page.
    //
    // Never upgrades: a `medium` or `low` find with a page is still whatever the run judged it to be, and
    // an absent confidence stays absent rather than being invented here.
    // #2912: and a contact the run itself called a NAME MATCH ONLY may never be high either, whatever
    // page it cites. The page is not in question there; who is on it is. Without this the card could be
    // handed a `high` beside a declared guess and would have two sources answering "how sure are we"
    // differently, with nothing saying which wins (L16). The declaration wins, because it is the more
    // specific claim and the more cautious one (L42).
    //
    // Defaulted so every existing caller keeps asking exactly the question it asked before, and so
    // `heldDown` below goes on meaning the ONE thing it was defined to mean: the citation rule fired.
    // #2895: and a NAMED PERFORMER whose run declared that the page it cited does NOT tie that person to
    // this performance may not be high either. The runbook has always said so in its own words ("only use
    // `high` if the source page corroborates that person against THIS SPECIFIC performance"), and nothing
    // enforced it, which is the same gap this guard was built to close for the citation itself.
    //
    // Performer only, because the runbook's rule is performer only. The citation rule above is universal
    // for the opposite reason, that the runbook states IT universally: this guard enforces the runbook
    // deterministically and does not invent a stricter rule than the one the run was given.
    //
    // `nil` means the run said NOTHING and changes nothing, Dan's call on 2026-08-21, the same answer
    // #2912 gave for `nameMatchOnly`. It keeps his queue as it is and lets the check work on runs that
    // declare it; what it costs is that the rule is dormant until they do, which is why
    // `PerformerCorroborationAdoption` measures adoption rather than leaving it to be discovered (L128).
    static func confidence(raw: String?, sourceURL: String?, nameMatchOnly: Bool = false,
                           provenance: String? = nil,
                           performanceCorroborated: Bool? = nil) -> String? {
        if nameMatchOnly { return raw == nil ? nil : "low" }
        guard raw == "high" else { return raw }
        return holdDown(raw: raw, sourceURL: sourceURL, nameMatchOnly: nameMatchOnly,
                        provenance: provenance,
                        performanceCorroborated: performanceCorroborated) == nil ? raw : "low"
    }

    // #2895: WHICH rule moved the answer.
    //
    // #1866 recorded THAT the guard moved it, because "Unverified email found" alone could not tell Dan
    // whether the check was unsure or whether it was sure and Overture overruled it. There are two ways to
    // be overruled now and they ask different things of him: one is an address that may be perfectly good
    // and was never cited, the other is an address cited against a page that does not establish the person.
    // One sentence cannot honestly cover both (L11), so the record says which.
    //
    // A declared name match is deliberately NOT one of these, unchanged from #2912: the card says that in
    // its own words from its own field, and folding it in would give one record two meanings (L118).
    enum HoldDown: String, CaseIterable, Equatable, Sendable {
        case namedNoPage
        case pageDoesNotCorroborate
    }

    static func holdDown(raw: String?, sourceURL: String?, nameMatchOnly: Bool = false,
                         provenance: String? = nil,
                         performanceCorroborated: Bool? = nil) -> HoldDown? {
        guard raw == "high", !nameMatchOnly else { return nil }
        let cited = (sourceURL ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if cited.isEmpty { return .namedNoPage }
        if provenance == "performer", performanceCorroborated == false { return .pageDoesNotCorroborate }
        return nil
    }

    // #1866: whether the guard actually CHANGED the answer, which is the fact the row has to record.
    //
    // The stored confidence alone cannot say it. A `low` written here and a `low` the run itself judged are
    // the same three letters, so "Unverified email found" could not tell Dan whether the check was unsure
    // or whether it was sure and Overture overruled it. Those ask different things of him, and only this
    // can tell them apart.
    //
    // Defined as "the answer moved" rather than restating the citation rule, so it can never disagree with
    // the rewrite it describes (L16: one predicate behind a claim and the thing it promises).
    static func heldDown(raw: String?, sourceURL: String?, provenance: String? = nil,
                         performanceCorroborated: Bool? = nil) -> Bool {
        holdDown(raw: raw, sourceURL: sourceURL, provenance: provenance,
                 performanceCorroborated: performanceCorroborated) != nil
    }
}
