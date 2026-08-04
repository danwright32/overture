import Foundation

// #1144: the last-fetched styled Gmail signature (HTML), persisted so every send can attach it without a
// network round trip per email. Populated by GmailSignatureService.refresh (on connect); read by the send
// path. Persisted rather than in-memory so it survives launches and a signature-less send is the rare
// exception (fetch never succeeded), not the norm on every cold start.
enum GmailSignatureStore {
    static let key = "gmailSignatureHTML"

    static func currentHTML(defaults: UserDefaults = .standard) -> String? {
        guard let v = defaults.string(forKey: key), !v.isEmpty else { return nil }
        // #1253: never hand out an obviously-corrupt cached signature (one cached before the store guard,
        // say). Treated as absent so the send path falls back to plain text rather than shipping garbage.
        if GmailSignatureHealth.corruptionReason(v) != nil { return nil }
        return v
    }

    // Stores a non-empty signature; a nil/empty value is IGNORED (never clears a previously good one), so
    // a transient fetch failure can't wipe the signature Overture already has. Clearing is deliberate and
    // separate (clear()).
    static func store(_ html: String?, defaults: UserDefaults = .standard) {
        guard let html, !html.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        // #1253: fail loud, not silent. An obviously-corrupt fetch (Gmail's sendAs returned a signature
        // with literal \240 octal escapes on 2026-07-20) is REFUSED, not cached, so it can never ship on a
        // real pitch; any prior good signature is left intact.
        if let reason = GmailSignatureHealth.corruptionReason(html) {
            // copy-inventory:ignore-start  developer diagnostic log, not the app's own voice (#915)
            // #1689: a PROBLEM. The refusal is correct, but something upstream handed back a signature
            // that does not look like one, and the next real send is the surface it shows up on.
            AgentLog.problem("[Overture] Refusing to cache an obviously-corrupt Gmail signature (\(reason)); keeping any stored one.")
            // copy-inventory:ignore-end
            return
        }
        defaults.set(html, forKey: key)
    }

    // #1253: the reason the currently cached signature looks corrupt, or nil when it looks fine. For a
    // warning surface (relates to #1242), so a corrupt cache is a visible, actionable fact rather than a
    // silent bad send. Reads the RAW stored value (not currentHTML, which hides a corrupt one).
    static func currentSignatureIssue(defaults: UserDefaults = .standard) -> String? {
        guard let v = defaults.string(forKey: key), !v.isEmpty else { return nil }
        return GmailSignatureHealth.corruptionReason(v)
    }

    // #2087: the reason the currently cached signature will look wrong to a dark-mode reader, or nil when
    // it looks fine everywhere. Deliberately its OWN answer rather than another value folded into
    // currentSignatureIssue above: these are two independent checks with two different consequences (that
    // one refuses a signature, this one only warns about it), and a single shared status field lets a pass
    // from one erase the other's finding (L53).
    //
    // Reads the RAW stored value, like currentSignatureIssue, so a signature the corruption guard is
    // already hiding still answers for itself here.
    static func currentDarkBackgroundIssue(defaults: UserDefaults = .standard) -> String? {
        guard let v = defaults.string(forKey: key), !v.isEmpty else { return nil }
        return GmailSignatureHealth.darkBackgroundReason(v)
    }

    static func clear(defaults: UserDefaults = .standard) { defaults.removeObject(forKey: key) }

    // #1158: when the periodic refresh last ATTEMPTED a fetch. GmailSignatureService.refreshIfDue uses it
    // to fetch at most once per interval so the resident app stays current without hammering Gmail. Stored
    // as a Unix time; nil (0) means never attempted, which reads as due.
    static let lastRefreshKey = "gmailSignatureLastRefreshAt"

    static func lastRefreshAttemptAt(defaults: UserDefaults = .standard) -> Date? {
        let t = defaults.double(forKey: lastRefreshKey)
        return t > 0 ? Date(timeIntervalSince1970: t) : nil
    }

    static func setLastRefreshAttemptAt(_ date: Date, defaults: UserDefaults = .standard) {
        defaults.set(date.timeIntervalSince1970, forKey: lastRefreshKey)
    }

    // The signature to attach to an outgoing email: the stored HTML when present, otherwise the plain-text
    // fallback (so a send is never left signature-less silently).
    static func currentSignature(defaults: UserDefaults = .standard) -> OutboundSignature {
        if let html = currentHTML(defaults: defaults) {
            return OutboundSignature(html: html, plainText: OutboundSignature.plainFallback.plainText)
        }
        return .plainFallback
    }
}
