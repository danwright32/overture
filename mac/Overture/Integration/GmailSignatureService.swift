import Foundation

// #1144: fetches Dan's real styled signature from Gmail settings (users/me/settings/sendAs), so every
// outgoing email carries the same signature he has set in Gmail (teal name, he/they, linked site, social
// icons) and it never drifts. Any failure returns nil and logs loudly; the caller then falls back to the
// plain-text sign-off rather than sending a signature-less email silently.
enum GmailSignatureService {
    // The primary sendAs's HTML signature from a sendAs.list response, or the first non-empty one. Pure,
    // so the JSON shape is pinned by a test without the network.
    static func primarySignature(fromListJSON data: Data) -> String? {
        guard let root = ResponseBody.json(data, from: "gmail.settings.sendAs.list").value,
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
        // copy-inventory:ignore-start  the HTTP Authorization header Google reads, not a sentence
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        // copy-inventory:ignore-end
        do {
            let (data, resp) = try await fetch(req)
            guard let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                // copy-inventory:ignore-start  developer diagnostic log, not the app's own voice (#915)
                // #1689: a PROBLEM. Gmail answered, and not with the signature.
                AgentLog.problem("[Overture] Gmail signature fetch returned a non-success status; keeping any stored signature.")
                // copy-inventory:ignore-end
                return nil
            }
            return primarySignature(fromListJSON: data)
        } catch {
            // copy-inventory:ignore-start  developer diagnostic log, not the app's own voice (#915)
            // #1689: a PROBLEM. Same reason as above; this is the throwing half of it.
            AgentLog.problem("[Overture] Gmail signature fetch failed: \(error.localizedDescription); keeping any stored signature.")
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

    // #1158: opportunistic refresh so the cached signature stays current WITHOUT a manual reconnect and
    // WITHOUT hammering the network. Ridden along the safe-reconcile tick (launch + periodic + export-
    // change), it actually fetches at most once per `minimumInterval`: it no-ops when Gmail isn't
    // connected, and when the last attempt was more recent than the interval. The attempt time is
    // recorded before the fetch, so a persistent failure retries on the NEXT interval rather than on
    // every tick. A failed fetch still cannot clobber a good stored signature: that is refresh()'s (and
    // GmailSignatureStore.store's) guarantee, which this reuses rather than duplicating.
    @MainActor
    static func refreshIfDue(
        minimumInterval: TimeInterval = 24 * 60 * 60,
        now: Date = Date(),
        isConnected: () -> Bool = { GmailAuthManager.shared.isConnected },
        lastAttemptAt: () -> Date? = { GmailSignatureStore.lastRefreshAttemptAt() },
        recordAttemptAt: (Date) -> Void = { GmailSignatureStore.setLastRefreshAttemptAt($0) },
        performRefresh: () async -> Void = { await GmailSignatureService.refresh() }
    ) async {
        guard isConnected() else { return }
        if let last = lastAttemptAt(), now.timeIntervalSince(last) < minimumInterval { return }
        recordAttemptAt(now)
        await performRefresh()
    }

    // #1208: the signature matters most at the exact moment an email goes out. The daily refreshIfDue can
    // leave the cached signature up to 24h stale, so Dan editing his Gmail signature and sending right
    // after would carry the old one. Called at the start of a send, this reuses refreshIfDue with a SHORT
    // window instead of the 24h one, so a send refreshes even when the daily tick fetched hours ago, while
    // still self-throttling across a quick multi-recipient burst (it does not fetch once per email) and
    // inheriting refresh()'s don't-clobber-on-failure guarantee. It never blocks the send: a failed or
    // disconnected refresh just leaves the stored signature as-is.
    static let sendRefreshInterval: TimeInterval = 60

    @MainActor
    static func refreshBeforeSend(
        now: Date = Date(),
        isConnected: () -> Bool = { GmailAuthManager.shared.isConnected },
        lastAttemptAt: () -> Date? = { GmailSignatureStore.lastRefreshAttemptAt() },
        recordAttemptAt: (Date) -> Void = { GmailSignatureStore.setLastRefreshAttemptAt($0) },
        performRefresh: () async -> Void = { await GmailSignatureService.refresh() }
    ) async {
        await refreshIfDue(minimumInterval: sendRefreshInterval, now: now,
                           isConnected: isConnected, lastAttemptAt: lastAttemptAt,
                           recordAttemptAt: recordAttemptAt, performRefresh: performRefresh)
    }
}
