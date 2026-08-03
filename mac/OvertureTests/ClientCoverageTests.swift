import Testing
import Foundation
import SwiftData

// #1356: the coverage diagnostic's pure logic. A Downbeat client is "armed" when some watched source
// arms it as a returning client; the diagnostic lists the clients NOTHING arms, so a returning client
// booked a year out can never silently sit on the short horizon (the NYYS/TENET/UCRI blind spot). Kept
// out of the view (#863) so every rule below is tested rather than stated in a SwiftUI body.
@Suite("Client coverage diagnostic (#1356)")
struct ClientCoverageTests {
    private func client(_ name: String, id: String? = nil, short: String? = nil) -> DownbeatClient {
        DownbeatClient(id: id ?? name, displayName: name, shortName: short, email: "", contractEmail: "",
                       phoneNumber: nil, isTaxExempt: nil, hasLeftReview: false, specialBehaviors: [],
                       notes: nil, hostingSite: "")
    }

    private func source(_ org: String, tag: Bool? = nil, clientId: String? = nil) -> WatchedSource {
        let s = WatchedSource(sourceId: org, orgName: org, listingsURL: "https://\(org).example/e", kind: .html)
        s.clientTagOverride = tag
        s.clientTagClientId = clientId
        return s
    }

    private func unarmedNames(_ sources: [WatchedSource], _ clients: [DownbeatClient],
                              _ dismissed: Set<String> = []) -> [String] {
        ClientCoverage.unarmed(sources: sources, clients: clients, dismissedIds: dismissed)
            .map { $0.client.displayName }
    }

    // MARK: arming

    @Test func aClientAnExactSourceMatchesIsNotUnarmed() {
        let clients = [client("Brooklyn Youth Chorus"), client("Opera Praktikos")]
        let sources = [source("Brooklyn Youth Chorus")]
        #expect(unarmedNames(sources, clients) == ["Opera Praktikos"])
    }

    // #1351 integration: an acronym client armed by its spelled-out source is covered.
    @Test func anAcronymClientIsArmedByItsSpelledOutSource() {
        let clients = [client("NYYS")]
        #expect(unarmedNames([source("New York Youth Symphony")], clients).isEmpty)
    }

    @Test func aClientNoSourceMatchesIsUnarmed() {
        #expect(unarmedNames([source("Carnegie Hall")], [client("UCRI")]) == ["UCRI"])
    }

    // The serious red-team catch: a source Dan tagged "Never a returning client" must NOT arm a client,
    // even when its name matches, so the gap is still surfaced. This is the authority ClientHorizon uses.
    @Test func aSourceTaggedNeverDoesNotArmEvenWhenItsNameMatches() {
        let clients = [client("Brooklyn Youth Chorus")]
        #expect(unarmedNames([source("Brooklyn Youth Chorus", tag: false)], clients) == ["Brooklyn Youth Chorus"])
    }

    @Test func aSourceTaggedAlwaysStillArmsAMatchingClient() {
        let clients = [client("Brooklyn Youth Chorus")]
        #expect(unarmedNames([source("Brooklyn Youth Chorus", tag: true)], clients).isEmpty)
    }

    // MARK: arming by a tag that NAMES a client (#1358)

    // The shared-venue case this feature exists for: the source is a venue whose name does not match the
    // client at all (Merkin Concert Hall vs Brooklyn Youth Chorus), but Dan tagged it "always" and named
    // WHICH Downbeat client performs there. That client is armed for real, not merely silenceable by hiding.
    @Test func aTagThatNamesAClientArmsItWithoutANameMatch() {
        let clients = [client("Brooklyn Youth Chorus", id: "byc-id")]
        let sources = [source("Merkin Concert Hall", tag: true, clientId: "byc-id")]
        #expect(unarmedNames(sources, clients).isEmpty)
    }

    // A bare "always" tag (no named client) does NOT arm an unmatched client: naming is what arms a
    // specific client in the diagnostic, so the bare tag keeps its old name-only behavior and the gap
    // stays visible.
    @Test func aBareAlwaysTagDoesNotArmAnUnmatchedClient() {
        let clients = [client("Brooklyn Youth Chorus", id: "byc-id")]
        let sources = [source("Merkin Concert Hall", tag: true)]
        #expect(unarmedNames(sources, clients) == ["Brooklyn Youth Chorus"])
    }

    // A source that names a specific client is not offered as a near-miss for a DIFFERENT unarmed client,
    // even when their names fuzzily overlap: Dan already told Overture who that source is.
    @Test func aSourceThatNamesAClientIsNotANearMissForAnother() {
        let clients = [client("Manhattan Chamber Players", id: "mcp-id"),
                       client("Some Other Client", id: "other-id")]
        let sources = [source("Manhattan Chamber Orchestra", tag: true, clientId: "other-id")]
        let result = ClientCoverage.unarmed(sources: sources, clients: clients, dismissedIds: [])
        #expect(result.map(\.client.displayName) == ["Manhattan Chamber Players"])
        #expect(result.first?.nearMissSourceName == nil)
    }

    // MARK: near-miss hint (the precise word-containment rule, not fuzzy Jaccard)

    @Test func aSingleWordClientNameContainedInASourceSurfacesAsANearMiss() {
        // The pre-data-fix TENET case: client "TENET", source "TENET Vocal Artists" does not confidently
        // match, but the source clearly IS them, so the hint names it.
        let result = ClientCoverage.unarmed(sources: [source("TENET Vocal Artists")],
                                            clients: [client("TENET")], dismissedIds: [])
        #expect(result.count == 1)
        #expect(result.first?.nearMissSourceName == "TENET Vocal Artists")
    }

    @Test func aFuzzilyOverlappingMultiWordSourceIsANearMiss() {
        let result = ClientCoverage.unarmed(sources: [source("Manhattan Chamber Orchestra")],
                                            clients: [client("Manhattan Chamber Players")], dismissedIds: [])
        #expect(result.first?.nearMissSourceName == "Manhattan Chamber Orchestra")
    }

    @Test func anUnrelatedSourceIsNotANearMiss() {
        let result = ClientCoverage.unarmed(sources: [source("Carnegie Hall")],
                                            clients: [client("UCRI")], dismissedIds: [])
        #expect(result.first?.nearMissSourceName == nil)
    }

    // A source tagged "Never" is not offered as a near-miss either: Dan already said it is not them.
    @Test func aSourceTaggedNeverIsNotANearMiss() {
        let result = ClientCoverage.unarmed(sources: [source("TENET Vocal Artists", tag: false)],
                                            clients: [client("TENET")], dismissedIds: [])
        #expect(result.first?.nearMissSourceName == nil)
    }

    // MARK: dismissal

    @Test func aDismissedClientIsExcludedFromTheGapList() {
        let clients = [client("UCRI", id: "ucri-id"), client("Opera Praktikos", id: "op-id")]
        let sources = [source("Carnegie Hall")]
        #expect(unarmedNames(sources, clients, ["ucri-id"]) == ["Opera Praktikos"])
    }

    // The "N ignored" list shows dismissed clients that are STILL a gap, and never one now armed (so its
    // count always matches the rows it can name and restore).
    @Test func ignoredListsDismissedClientsThatAreStillUnarmed() {
        let clients = [client("UCRI", id: "ucri-id")]
        let ignored = ClientCoverage.ignored(sources: [source("Carnegie Hall")], clients: clients,
                                             dismissedIds: ["ucri-id"])
        #expect(ignored.map(\.displayName) == ["UCRI"])
    }

    @Test func aDismissedClientThatBecameArmedDropsOutOfIgnored() {
        let clients = [client("Brooklyn Youth Chorus", id: "byc-id")]
        let ignored = ClientCoverage.ignored(sources: [source("Brooklyn Youth Chorus")], clients: clients,
                                             dismissedIds: ["byc-id"])
        #expect(ignored.isEmpty)
    }

    @Test func theGapListIsSortedByName() {
        let clients = [client("Zed Ensemble"), client("Alpha Choir"), client("Mecca Winds")]
        #expect(unarmedNames([source("Carnegie Hall")], clients) == ["Alpha Choir", "Mecca Winds", "Zed Ensemble"])
    }

    // MARK: memoization signature (perf)

    // The Sources sheet used to recompute this O(clients x sources) match INLINE in its SwiftUI body, so it
    // re-ran on every keystroke and every scroll tick, not only when the data changed. That main-thread lag
    // let a click go unregistered and queue, so one "Not one I scout" tap dismissed several clients in a row.
    // The fix lets the view CACHE the result keyed on `signature`, recomputing only when an input the match
    // actually reads changes. These tests pin what the signature must and must not react to: a missed
    // dependency would leave a STALE gap list on screen, which is worse than the slowness it replaces.

    @Test func signatureIsStableAcrossIdenticalInputs() {
        let clients = [client("UCRI", id: "ucri")]
        let sources = [source("Carnegie Hall")]
        let a = ClientCoverage.signature(sources: sources, clients: clients, dismissedIds: [])
        let b = ClientCoverage.signature(sources: sources, clients: clients, dismissedIds: [])
        #expect(a == b)
    }

    // The load-bearing correctness test: touching a source field the coverage match never reads
    // (lastCheckedAt, hasUnreadChanges, isActive) must NOT invalidate the cache, or every scout tick would
    // needlessly re-run the whole match, which is the lag we are removing.
    @Test func signatureIgnoresSourceFieldsTheMatchDoesNotRead() {
        let clients = [client("UCRI", id: "ucri")]
        let s = source("Carnegie Hall")
        let before = ClientCoverage.signature(sources: [s], clients: clients, dismissedIds: [])
        s.lastCheckedAt = Date(timeIntervalSince1970: 1)
        s.hasUnreadChanges = true
        s.isActive = false
        let after = ClientCoverage.signature(sources: [s], clients: clients, dismissedIds: [])
        #expect(before == after)
    }

    @Test func signatureChangesWhenASourceOrgNameChanges() {
        let clients = [client("Brooklyn Youth Chorus", id: "byc")]
        let s = source("Carnegie Hall")
        let before = ClientCoverage.signature(sources: [s], clients: clients, dismissedIds: [])
        s.orgName = "Brooklyn Youth Chorus"
        let after = ClientCoverage.signature(sources: [s], clients: clients, dismissedIds: [])
        #expect(before != after)
    }

    @Test func signatureChangesWhenAClientTagChanges() {
        let clients = [client("Brooklyn Youth Chorus", id: "byc")]
        let s = source("Merkin Concert Hall")
        let before = ClientCoverage.signature(sources: [s], clients: clients, dismissedIds: [])
        s.clientTagOverride = true
        s.clientTagClientId = "byc"
        let after = ClientCoverage.signature(sources: [s], clients: clients, dismissedIds: [])
        #expect(before != after)
    }

    @Test func signatureChangesWhenTheDismissedSetChanges() {
        let clients = [client("UCRI", id: "ucri")]
        let sources = [source("Carnegie Hall")]
        let before = ClientCoverage.signature(sources: sources, clients: clients, dismissedIds: [])
        let after = ClientCoverage.signature(sources: sources, clients: clients, dismissedIds: ["ucri"])
        #expect(before != after)
    }

    @Test func signatureChangesWhenAClientNameChanges() {
        let sources = [source("Carnegie Hall")]
        let before = ClientCoverage.signature(sources: sources, clients: [client("UCRI", id: "ucri")], dismissedIds: [])
        let after = ClientCoverage.signature(sources: sources, clients: [client("UCRI Chamber", id: "ucri")], dismissedIds: [])
        #expect(before != after)
    }

    @Test func signatureChangesWhenAClientIsAddedOrRemoved() {
        let sources = [source("Carnegie Hall")]
        let one = ClientCoverage.signature(sources: sources, clients: [client("UCRI", id: "ucri")], dismissedIds: [])
        let two = ClientCoverage.signature(sources: sources,
                                           clients: [client("UCRI", id: "ucri"), client("Opera Praktikos", id: "op")],
                                           dismissedIds: [])
        #expect(one != two)
    }

    // Source order must not matter: the @Query feeding this is sorted, but a reorder that leaves every
    // field identical should not thrash the cache (the output does not depend on order either).
    @Test func signatureIsIndependentOfSourceOrder() {
        let clients = [client("UCRI", id: "ucri")]
        let a = source("Alpha Hall"); let b = source("Beta Hall")
        #expect(ClientCoverage.signature(sources: [a, b], clients: clients, dismissedIds: [])
                == ClientCoverage.signature(sources: [b, a], clients: clients, dismissedIds: []))
    }

    // Caching must change performance, not output: the cached result equals computing the two lists directly.
    @Test func resultMatchesUnarmedAndIgnoredComposed() {
        let clients = [client("UCRI", id: "ucri"), client("Opera Praktikos", id: "op")]
        let sources = [source("Carnegie Hall")]
        let r = ClientCoverage.result(sources: sources, clients: clients, dismissedIds: ["op"])
        #expect(r.gaps == ClientCoverage.unarmed(sources: sources, clients: clients, dismissedIds: ["op"]))
        #expect(r.ignored == ClientCoverage.ignored(sources: sources, clients: clients, dismissedIds: ["op"]))
    }
}

// #1356: dismiss/restore persistence, mirroring ExcludedTownEditing. In-app only, keyed by the stable
// Downbeat client UUID, reversible (the never-a-dead-end rule).
@Suite("Coverage dismissal persistence (#1356)")
@MainActor
struct CoverageDismissEditingTests {
    private func context() throws -> ModelContext {
        let c = try ModelContainer(for: Schema([DismissedCoverageClient.self]),
                                   configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        return ModelContext(c)
    }

    @Test func dismissThenRestoreRoundTrips() throws {
        let ctx = try context()
        CoverageDismissEditing.dismiss(clientId: "abc", into: ctx)
        #expect(CoverageDismissEditing.dismissedIds(in: ctx) == ["abc"])
        CoverageDismissEditing.restore(clientId: "abc", in: ctx)
        #expect(CoverageDismissEditing.dismissedIds(in: ctx).isEmpty)
    }

    @Test func dismissIsIdempotent() throws {
        let ctx = try context()
        CoverageDismissEditing.dismiss(clientId: "abc", into: ctx)
        CoverageDismissEditing.dismiss(clientId: "abc", into: ctx)
        #expect(CoverageDismissEditing.rows(in: ctx).count == 1)
    }
}
