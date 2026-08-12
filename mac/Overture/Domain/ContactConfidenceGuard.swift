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
    static func confidence(raw: String?, sourceURL: String?) -> String? {
        guard raw == "high" else { return raw }
        let cited = (sourceURL ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return cited.isEmpty ? "low" : raw
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
    static func heldDown(raw: String?, sourceURL: String?) -> Bool {
        confidence(raw: raw, sourceURL: sourceURL) != raw
    }
}
