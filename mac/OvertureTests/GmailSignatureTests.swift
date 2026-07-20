import Testing
import Foundation
@testable import Overture

// #1144: Overture attaches Dan's real styled Gmail signature to every outgoing email, fetched from Gmail
// settings and cached. These pin the parsing, the cache's don't-clobber-on-failure rule, and the
// fallback that guarantees a send is never left signature-less silently.
@Suite("Gmail signature fetch and cache (#1144)")
struct GmailSignatureTests {
    private func freshDefaults() -> UserDefaults {
        let d = UserDefaults(suiteName: "gmail-sig-test-\(UUID().uuidString)")!
        d.removePersistentDomain(forName: "gmail-sig-test")
        return d
    }

    // MARK: - Store

    @Test func storeKeepsANonEmptySignature() {
        let d = freshDefaults()
        GmailSignatureStore.store("<div>sig</div>", defaults: d)
        #expect(GmailSignatureStore.currentHTML(defaults: d) == "<div>sig</div>")
    }

    // A nil or blank fetch result must NOT wipe a signature already stored (a transient failure can't
    // downgrade Dan to plain text once he has a good one).
    @Test func storeIgnoresNilOrBlankSoATransientFailureCannotClobber() {
        let d = freshDefaults()
        GmailSignatureStore.store("<div>good</div>", defaults: d)
        GmailSignatureStore.store(nil, defaults: d)
        GmailSignatureStore.store("   ", defaults: d)
        #expect(GmailSignatureStore.currentHTML(defaults: d) == "<div>good</div>")
    }

    @Test func currentSignatureUsesStoredHtmlElseThePlainFallback() {
        let d = freshDefaults()
        #expect(GmailSignatureStore.currentSignature(defaults: d) == OutboundSignature.plainFallback)

        GmailSignatureStore.store("<div>sig</div>", defaults: d)
        let sig = GmailSignatureStore.currentSignature(defaults: d)
        #expect(sig.html == "<div>sig</div>")
        #expect(sig.plainText == OutboundSignature.plainFallback.plainText)
    }

    // MARK: - Corruption (#1253): fail loud, never silently attach a broken signature to a real send.

    // The concrete corruption that shipped 2026-07-20: a stale signature carrying literal octal escapes
    // like \240 (a broken non-breaking space) that Gmail's sendAs returned. Valid signature HTML never
    // carries a literal backslash-octal run.
    private let corruptSignature = "<div>Dan Wright\\240he/they\\240\\240</div>"

    @Test func corruptionReasonFlagsLiteralOctalEscapes() {
        #expect(GmailSignatureHealth.corruptionReason(corruptSignature) != nil)
    }

    @Test func corruptionReasonPassesACleanStyledSignature() {
        let clean = "<div style=\"color:#0aa\">Dan Wright</div><div>he/they</div>" +
                    "<a href=\"https://danwrightphotography.com\">Portfolio</a>&nbsp;"
        #expect(GmailSignatureHealth.corruptionReason(clean) == nil)
    }

    // Fail loud on STORE: an obviously-corrupt fetch is refused, not silently cached, and a prior good
    // signature is left intact.
    @Test func storeRefusesAnObviouslyCorruptSignature() {
        let d = freshDefaults()
        GmailSignatureStore.store("<div>good</div>", defaults: d)
        GmailSignatureStore.store(corruptSignature, defaults: d)
        #expect(GmailSignatureStore.currentHTML(defaults: d) == "<div>good</div>")
    }

    // Fail loud on READ: even if a corrupt signature already sits in the cache (cached before this guard),
    // it is treated as absent so a real send falls back to plain text rather than shipping the garbage, and
    // the corruption is a surfaceable fact rather than a silent bad send.
    @Test func aCorruptCachedSignatureNeverShipsAndFallsBackToPlain() {
        let d = freshDefaults()
        d.set(corruptSignature, forKey: GmailSignatureStore.key)   // simulate a pre-guard corrupt cache
        #expect(GmailSignatureStore.currentHTML(defaults: d) == nil)
        #expect(GmailSignatureStore.currentSignature(defaults: d) == OutboundSignature.plainFallback)
        #expect(GmailSignatureStore.currentSignatureIssue(defaults: d) != nil)
    }

    // MARK: - Parsing

    @Test func primarySignaturePicksThePrimarySendAs() {
        let json = """
        {"sendAs":[
          {"sendAsEmail":"alias@x.org","isPrimary":false,"signature":"<i>alias</i>"},
          {"sendAsEmail":"dan@x.org","isPrimary":true,"signature":"<b>Dan Wright</b>"}
        ]}
        """
        #expect(GmailSignatureService.primarySignature(fromListJSON: Data(json.utf8)) == "<b>Dan Wright</b>")
    }

    @Test func primarySignatureFallsBackToTheFirstNonEmptyWhenNoPrimaryHasOne() {
        let json = """
        {"sendAs":[
          {"sendAsEmail":"a@x.org","isPrimary":true,"signature":""},
          {"sendAsEmail":"b@x.org","isPrimary":false,"signature":"<i>b</i>"}
        ]}
        """
        #expect(GmailSignatureService.primarySignature(fromListJSON: Data(json.utf8)) == "<i>b</i>")
    }

    @Test func primarySignatureIsNilWhenThereIsNone() {
        #expect(GmailSignatureService.primarySignature(fromListJSON: Data(#"{"sendAs":[]}"#.utf8)) == nil)
        #expect(GmailSignatureService.primarySignature(fromListJSON: Data("not json".utf8)) == nil)
    }

    // MARK: - Fetch (failure paths return nil so the caller falls back, never blocks a send)

    private func fetch(_ status: Int, _ body: String) -> @Sendable (URLRequest) async throws -> (Data, URLResponse) {
        { _ in (Data(body.utf8), HTTPURLResponse(url: URL(string: "https://gmail.googleapis.com")!,
                                                 statusCode: status, httpVersion: nil, headerFields: nil)!) }
    }

    @Test func fetchReturnsTheSignatureOn200() async {
        let html = await GmailSignatureService.fetchSignatureHTML(
            token: "tok", fetch: fetch(200, #"{"sendAs":[{"isPrimary":true,"signature":"<b>Dan</b>"}]}"#))
        #expect(html == "<b>Dan</b>")
    }

    @Test func fetchReturnsNilOnNonSuccessStatus() async {
        let html = await GmailSignatureService.fetchSignatureHTML(token: "tok", fetch: fetch(403, "forbidden"))
        #expect(html == nil)
    }

    @Test func fetchReturnsNilWhenTheRequestThrows() async {
        let html = await GmailSignatureService.fetchSignatureHTML(token: "tok", fetch: { @Sendable _ in
            throw URLError(.notConnectedToInternet)
        })
        #expect(html == nil)
    }

    // MARK: - Scope + refresh

    // The settings-read scope must be requested, or the live signature fetch would always 403. Dan
    // re-authorizes once to grant it (he approved that trade-off).
    @Test func gmailScopesRequestTheSettingsReadScope() {
        #expect(OAuthConfig.gmailScopes.contains("https://www.googleapis.com/auth/gmail.settings.basic"))
    }

    private final class Box: @unchecked Sendable { var value: String?; var called = false }

    // refresh() (called on connect) fetches with the current token and stores the result on success.
    @MainActor
    @Test func refreshStoresTheFetchedSignature() async {
        let box = Box()
        await GmailSignatureService.refresh(
            token: { "tok" },
            fetch: fetch(200, #"{"sendAs":[{"isPrimary":true,"signature":"<b>Dan</b>"}]}"#),
            store: { box.value = $0; box.called = true })
        #expect(box.called)
        #expect(box.value == "<b>Dan</b>")
    }

    // If the token can't be obtained, refresh stores nothing (it never wipes a stored signature over a
    // transient auth hiccup).
    @MainActor
    @Test func refreshStoresNothingWhenTheTokenIsUnavailable() async {
        let box = Box()
        await GmailSignatureService.refresh(
            token: { throw URLError(.userAuthenticationRequired) },
            fetch: fetch(200, "{}"),
            store: { _ in box.called = true })
        #expect(!box.called)
    }

    // MARK: - Opportunistic periodic refresh (#1158)

    // THE KEY INVARIANT, exercised end-to-end through refresh(): a FAILED fetch (a network error) must
    // leave a previously stored good signature EXACTLY as it was. The periodic refresh must never be able
    // to downgrade Dan to the plain fallback because a fetch happened to fail.
    // UserDefaults is thread-safe but not Sendable; refresh()'s store closure is @Sendable, so route the
    // ephemeral test suite through this holder rather than capturing it directly.
    private final class DefaultsBox: @unchecked Sendable {
        let defaults: UserDefaults
        init(_ d: UserDefaults) { self.defaults = d }
    }

    @MainActor
    @Test func aFailedRefreshNeverClobbersTheStoredSignature() async {
        let box = DefaultsBox(freshDefaults())
        GmailSignatureStore.store("<div>good</div>", defaults: box.defaults)
        await GmailSignatureService.refresh(
            token: { "tok" },
            fetch: { @Sendable _ in throw URLError(.notConnectedToInternet) },
            store: { GmailSignatureStore.store($0, defaults: box.defaults) })
        #expect(GmailSignatureStore.currentHTML(defaults: box.defaults) == "<div>good</div>")
    }

    // A non-2xx (a 403 on the settings scope, say) is also a failure and must not clobber either.
    @MainActor
    @Test func aNon2xxRefreshNeverClobbersTheStoredSignature() async {
        let box = DefaultsBox(freshDefaults())
        GmailSignatureStore.store("<div>good</div>", defaults: box.defaults)
        await GmailSignatureService.refresh(
            token: { "tok" },
            fetch: fetch(403, "forbidden"),
            store: { GmailSignatureStore.store($0, defaults: box.defaults) })
        #expect(GmailSignatureStore.currentHTML(defaults: box.defaults) == "<div>good</div>")
    }

    // The attempt-time clock round-trips (a typo in the key would silently defeat the cadence gate).
    @Test func lastRefreshAttemptTimeRoundTrips() {
        let d = freshDefaults()
        #expect(GmailSignatureStore.lastRefreshAttemptAt(defaults: d) == nil)
        let t = Date(timeIntervalSince1970: 1_000_000)
        GmailSignatureStore.setLastRefreshAttemptAt(t, defaults: d)
        #expect(GmailSignatureStore.lastRefreshAttemptAt(defaults: d) == t)
    }

    private final class RanBox: @unchecked Sendable { var called = false; var recordedAt: Date? }

    // (a) The opportunistic refresh actually RUNS when appropriate (not only on connect): connected, and
    // never refreshed before. This is the behaviour that keeps the signature current without a reconnect.
    @MainActor
    @Test func refreshIfDueRefreshesWhenConnectedAndNeverRefreshedBefore() async {
        let box = RanBox()
        await GmailSignatureService.refreshIfDue(
            minimumInterval: 24 * 60 * 60, now: Date(),
            isConnected: { true },
            lastAttemptAt: { nil },
            recordAttemptAt: { box.recordedAt = $0 },
            performRefresh: { box.called = true })
        #expect(box.called)
        #expect(box.recordedAt != nil)
    }

    // It also runs once the last attempt is older than the interval (the resident-app cadence).
    @MainActor
    @Test func refreshIfDueRefreshesWhenTheLastAttemptIsOlderThanTheInterval() async {
        let box = RanBox()
        let now = Date()
        await GmailSignatureService.refreshIfDue(
            minimumInterval: 24 * 60 * 60, now: now,
            isConnected: { true },
            lastAttemptAt: { now.addingTimeInterval(-48 * 60 * 60) },
            recordAttemptAt: { _ in },
            performRefresh: { box.called = true })
        #expect(box.called)
    }

    // It self-throttles: a recent attempt means no fetch, so the periodic tick can't hammer the network.
    @MainActor
    @Test func refreshIfDueSkipsWhenAttemptedRecently() async {
        let box = RanBox()
        let now = Date()
        await GmailSignatureService.refreshIfDue(
            minimumInterval: 24 * 60 * 60, now: now,
            isConnected: { true },
            lastAttemptAt: { now.addingTimeInterval(-60) },
            recordAttemptAt: { _ in },
            performRefresh: { box.called = true })
        #expect(!box.called)
    }

    // And it no-ops entirely when Gmail isn't connected.
    @MainActor
    @Test func refreshIfDueSkipsWhenNotConnected() async {
        let box = RanBox()
        await GmailSignatureService.refreshIfDue(
            minimumInterval: 24 * 60 * 60, now: Date(),
            isConnected: { false },
            lastAttemptAt: { nil },
            recordAttemptAt: { _ in box.recordedAt = Date() },
            performRefresh: { box.called = true })
        #expect(!box.called)
        #expect(box.recordedAt == nil)
    }

    // MARK: - #1208: refresh right before a send, closing the 24h window for the case that matters most

    // The signature is most important to be current at the moment an email goes out. refreshBeforeSend
    // refreshes even when the daily refreshIfDue would skip: here the last attempt was 5 minutes ago (well
    // within the 24h opportunistic interval, so refreshIfDue(24h) would NOT fetch), yet the send path
    // still fetches, so a signature Dan edited since the daily tick is current on the outgoing email.
    @MainActor
    @Test func refreshBeforeSendRefreshesEvenWhenTheDailyRefreshWouldSkip() async {
        let box = RanBox()
        let now = Date()
        await GmailSignatureService.refreshBeforeSend(
            now: now,
            isConnected: { true },
            lastAttemptAt: { now.addingTimeInterval(-5 * 60) },   // 5 min ago: within 24h, outside the send window
            recordAttemptAt: { _ in },
            performRefresh: { box.called = true })
        #expect(box.called)
    }

    // Within a single send burst (a multi-recipient show sent in quick succession) it self-throttles, so
    // it does not fetch once per email: a send moments after the last attempt does not re-fetch.
    @MainActor
    @Test func refreshBeforeSendSelfThrottlesWithinABurst() async {
        let box = RanBox()
        let now = Date()
        await GmailSignatureService.refreshBeforeSend(
            now: now,
            isConnected: { true },
            lastAttemptAt: { now.addingTimeInterval(-5) },   // 5s ago: inside the send window
            recordAttemptAt: { _ in },
            performRefresh: { box.called = true })
        #expect(!box.called)
    }

    // And, like every other refresh path, it no-ops when Gmail isn't connected, so it can never block or
    // delay a send that has no signature to fetch.
    @MainActor
    @Test func refreshBeforeSendNoOpsWhenNotConnected() async {
        let box = RanBox()
        await GmailSignatureService.refreshBeforeSend(
            now: Date(),
            isConnected: { false },
            lastAttemptAt: { nil },
            recordAttemptAt: { _ in },
            performRefresh: { box.called = true })
        #expect(!box.called)
    }
}
