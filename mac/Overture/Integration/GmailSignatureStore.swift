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

    // The signature to attach to an outgoing email: the stored HTML when present, otherwise the plain-text
    // fallback (so a send is never left signature-less silently).
    static func currentSignature(defaults: UserDefaults = .standard) -> OutboundSignature {
        if let html = currentHTML(defaults: defaults) {
            return OutboundSignature(html: html, plainText: OutboundSignature.plainFallback.plainText)
        }
        return .plainFallback
    }
}
