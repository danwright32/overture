import Foundation

// #1144: fetches Dan's real styled signature from Gmail settings (users/me/settings/sendAs), so every
// outgoing email carries the same signature he has set in Gmail (teal name, he/they, linked site, social
// icons) and it never drifts. Any failure returns nil and logs loudly; the caller then falls back to the
// plain-text sign-off rather than sending a signature-less email silently.
enum GmailSignatureService {
    // The primary sendAs's HTML signature from a sendAs.list response, or the first non-empty one. Pure,
    // so the JSON shape is pinned by a test without the network.
    static func primarySignature(fromListJSON data: Data) -> String? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let list = root["sendAs"] as? [[String: Any]] else { return nil }
        let candidates = [list.first { ($0["isPrimary"] as? Bool) == true }].compactMap { $0 } + list
        for entry in candidates {
            if let sig = (entry["signature"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
               !sig.isEmpty {
                return sig
            }
        }
        return nil
    }

    // Fetches the signature HTML. Returns nil on any non-2xx, network error, or empty/absent signature, so
    // the caller always has a definite yes/no and never blocks a send on this.
    static func fetchSignatureHTML(
        token: String,
        fetch: @Sendable (URLRequest) async throws -> (Data, URLResponse)
    ) async -> String? {
        var req = URLRequest(url: URL(string: "https://gmail.googleapis.com/gmail/v1/users/me/settings/sendAs")!)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        do {
            let (data, resp) = try await fetch(req)
            guard let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                // copy-inventory:ignore-start  developer diagnostic log, not the app's own voice (#915)
                NSLog("[Overture] Gmail signature fetch returned a non-success status; keeping any stored signature.")
                // copy-inventory:ignore-end
                return nil
            }
            return primarySignature(fromListJSON: data)
        } catch {
            // copy-inventory:ignore-start  developer diagnostic log, not the app's own voice (#915)
            NSLog("[Overture] Gmail signature fetch failed: \(error.localizedDescription); keeping any stored signature.")
            // copy-inventory:ignore-end
            return nil
        }
    }

    // Best-effort refresh: fetch with the current access token and store on success. On any failure it
    // leaves the stored signature untouched (a transient error must not wipe a good one). Safe to call on
    // connect and on launch.
    @MainActor
    static func refresh(
        token: (@Sendable () async throws -> String)? = nil,
        fetch: (@Sendable (URLRequest) async throws -> (Data, URLResponse))? = nil,
        store: @Sendable (String?) -> Void = { GmailSignatureStore.store($0) }
    ) async {
        let resolveToken = token ?? { try await GmailAuthManager.shared.validAccessToken() }
        guard let accessToken = try? await resolveToken() else { return }
        let html = await fetchSignatureHTML(token: accessToken,
                                            fetch: fetch ?? { try await GmailNetworking.session.data(for: $0) })
        store(html)
    }
}
