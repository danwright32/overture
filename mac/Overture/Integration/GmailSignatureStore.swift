import Foundation

// #1144: the last-fetched styled Gmail signature (HTML), persisted so every send can attach it without a
// network round trip per email. Populated by GmailSignatureService.refresh (on connect); read by the send
// path. Persisted rather than in-memory so it survives launches and a signature-less send is the rare
// exception (fetch never succeeded), not the norm on every cold start.
enum GmailSignatureStore {
    static let key = "gmailSignatureHTML"

    static func currentHTML(defaults: UserDefaults = .standard) -> String? {
        let v = defaults.string(forKey: key)
        return (v?.isEmpty == false) ? v : nil
    }

    // Stores a non-empty signature; a nil/empty value is IGNORED (never clears a previously good one), so
    // a transient fetch failure can't wipe the signature Overture already has. Clearing is deliberate and
    // separate (clear()).
    static func store(_ html: String?, defaults: UserDefaults = .standard) {
        guard let html, !html.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        defaults.set(html, forKey: key)
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
