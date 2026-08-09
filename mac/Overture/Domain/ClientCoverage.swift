import Foundation
import SwiftData

// #1356: which Downbeat clients is Overture failing to arm as returning clients? A returning client's
// own calendar is read a full year ahead (ClientHorizon), so a next-season date booked far out surfaces
// in time to pitch. That only happens when a watched source arms the client. NYYS, TENET and UCRI sat
// unarmed and unnoticed until a manual measurement (#1285) found them; this is the standing diagnostic
// so the next such gap is visible in the app.
//
// All logic lives here, pure and tested, NOT in the Sources sheet's SwiftUI body (#863): a listing rule
// stated in a view is a rule no test can reach, and this repo has repeatedly watched such rules drift
// under a fully green suite.

// A gap row: an unarmed client, plus the one watched source that PROBABLY is them but whose name does
// not confidently match (nil when none), so Dan can fix the name or tag it rather than think he must
// add a whole new source.
struct UnarmedClient: Equatable, Sendable {
    let client: DownbeatClient
    let nearMissSourceName: String?
}

enum ClientCoverage {
    // A source arms a client BY NAME when its org name confidently matches one of the client's names
    // (the same identity authority HistoryMatch and ClientHorizon use) AND Dan has not tagged the source
    // "Never a returning client". The "Never" tag is load-bearing: ClientHorizon.isClient lets it win in
    // both directions, so a source Dan explicitly said is not a client must not silently count as arming
    // one here, or the diagnostic would hide a real gap and disagree with the horizon it reports on.
    static func armsByName(_ source: WatchedSource, _ client: DownbeatClient) -> Bool {
        guard source.clientTagOverride != false else { return false }
        return HistoryMatch.clientNames(client).contains { GroupNameMatch.isConfident(source.orgName, $0) }
    }

    // #1358: a source arms a client BY TAG when Dan tagged it "always" AND named THIS client on the tag
    // (WatchedSource.clientTagClientId). This is the shared-venue case the name match can never catch: the
    // source org name is the venue, not the client, so armsByName is structurally false, yet Dan knows the
    // client performs there. A bare "always" tag (no named client) does not arm any specific client here.
    static func armsByTag(_ source: WatchedSource, _ client: DownbeatClient) -> Bool {
        source.clientTagOverride == true && source.clientTagClientId == client.id
    }

    static func isArmed(_ client: DownbeatClient, sources: [WatchedSource]) -> Bool {
        sources.contains { armsByName($0, client) || armsByTag($0, client) }
    }

    // A source that is PROBABLY this client but does not confidently match: not tagged "Never", not
    // already arming, and either
    //   - a single-word client name (an acronym or one-word brand, the whole point of this feature)
    //     appears verbatim as one of the source's words ("TENET" inside "TENET Vocal Artists"), or
    //   - the two names fuzzily overlap (isPossible), which covers multi-word near-misses.
    // The single-word branch exists because isPossible (Jaccard over token sets) structurally cannot fire
    // for a one-word name against a multi-word source, so it would miss exactly the cases this targets.
    // A >= 3 letter floor keeps a stray two-letter token from matching noise.
    static func nearMissSource(for client: DownbeatClient, sources: [WatchedSource]) -> WatchedSource? {
        sources.first { source in
            // #1358: a source that names a SPECIFIC client on its tag is never a mystery, so it is not
            // offered as a near-miss for any client (Dan already told Overture who it is). A bare "always"
            // tag (clientTagClientId nil) stays eligible, as does an ordinary untagged source.
            guard source.clientTagOverride != false, source.clientTagClientId == nil,
                  !armsByName(source, client) else { return false }
            let sourceTokens = Set(GroupNameMatch.tokens(source.orgName))
            return HistoryMatch.clientNames(client).contains { name in
                let nameTokens = GroupNameMatch.tokens(name)
                if nameTokens.count == 1, let only = nameTokens.first, only.count >= 3,
                   sourceTokens.contains(only) {
                    return true
                }
                return GroupNameMatch.isPossible(source.orgName, name)
            }
        }
    }

    // The gap list: clients nothing arms and Dan has not dismissed, each with its near-miss source, sorted
    // by name so the view holds no ordering rule of its own.
    static func unarmed(sources: [WatchedSource], clients: [DownbeatClient],
                        dismissedIds: Set<String>) -> [UnarmedClient] {
        clients
            .filter { !dismissedIds.contains($0.id) && !isArmed($0, sources: sources) }
            .map { UnarmedClient(client: $0, nearMissSourceName: nearMissSource(for: $0, sources: sources)?.orgName) }
            .sorted { $0.client.displayName.localizedCaseInsensitiveCompare($1.client.displayName) == .orderedAscending }
    }

    // The "N ignored" list: dismissed clients that are STILL a gap (dismissed AND unarmed). A dismissed
    // client that later gains a matching source drops out silently (it is covered, nothing to manage), so
    // the count the disclosure shows always equals the rows it can name and restore (the #863 promise).
    static func ignored(sources: [WatchedSource], clients: [DownbeatClient],
                        dismissedIds: Set<String>) -> [DownbeatClient] {
        clients
            .filter { dismissedIds.contains($0.id) && !isArmed($0, sources: sources) }
            .sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
    }

    // MARK: memoization (perf)
    //
    // The Sources sheet used to call `unarmed` + `ignored` INLINE in its SwiftUI body, so this
    // O(clients x sources) fuzzy match ran twice on the main thread on EVERY body render: every keystroke
    // in the add fields, every scroll tick (the sheet binds its scroll position to state). That per-frame
    // work made typing lag, froze the sheet on a long scroll, and let a "Not one I scout" tap go
    // unregistered long enough to queue, so a single click dismissed several clients in a row. The compute
    // stays here (pure, tested); the view now CACHES `result` keyed on `signature` and recomputes only when
    // an input the match reads actually changes.

    struct Result: Equatable, Sendable {
        let gaps: [UnarmedClient]
        let ignored: [DownbeatClient]
        static let empty = Result(gaps: [], ignored: [])
    }

    static func result(sources: [WatchedSource], clients: [DownbeatClient],
                       dismissedIds: Set<String>) -> Result {
        Result(gaps: unarmed(sources: sources, clients: clients, dismissedIds: dismissedIds),
               ignored: ignored(sources: sources, clients: clients, dismissedIds: dismissedIds))
    }

    // A value snapshot of EXACTLY the fields the match reads: per source its org name and the two
    // client-tag fields (all `armsByName` / `armsByTag` / `nearMissSource` look at), per client its id and
    // the names `HistoryMatch.clientNames` derives (displayName + shortName), and the dismissed set.
    // Equatable by those values (not SwiftData model identity) and order-independent, so it changes iff the
    // gap list could change and stays equal across a keystroke or scroll that touched none of them. Missing
    // a field here would leave a STALE gap list on screen; an unused one would only cost a needless recompute.
    struct Signature: Equatable, Sendable {
        struct SourceFacet: Equatable, Sendable, Comparable {
            let id: String
            let orgName: String
            let clientTag: Bool?
            let clientTagClientId: String?
            static func < (l: SourceFacet, r: SourceFacet) -> Bool { l.id < r.id }
        }
        struct ClientFacet: Equatable, Sendable, Comparable {
            let id: String
            let displayName: String
            let shortName: String?
            static func < (l: ClientFacet, r: ClientFacet) -> Bool { l.id < r.id }
        }
        let sources: [SourceFacet]
        let clients: [ClientFacet]
        let dismissed: [String]
    }

    static func signature(sources: [WatchedSource], clients: [DownbeatClient],
                          dismissedIds: Set<String>) -> Signature {
        Signature(
            sources: sources.map {
                Signature.SourceFacet(id: $0.sourceId, orgName: $0.orgName,
                                      clientTag: $0.clientTagOverride, clientTagClientId: $0.clientTagClientId)
            }.sorted(),
            clients: clients.map {
                Signature.ClientFacet(id: $0.id, displayName: $0.displayName, shortName: $0.shortName)
            }.sorted(),
            dismissed: dismissedIds.sorted()
        )
    }
}

// #1356: a client Dan has marked "not one I scout", so the gap list converges to real gaps instead of
// nagging with the ~15 out-of-area or non-venue clients that will never have a source. SwiftData-only,
// keyed by the stable Downbeat client UUID, reversible. Mirrors ExcludedTown's shape.
@Model
final class DismissedCoverageClient {
    // Not `id`: PersistentModel already refines Identifiable through persistentModelID (the same
    // convention as WatchedSource.sourceId / ExcludedTown.town).
    @Attribute(.unique) var clientId: String
    var dismissedAt: Date

    init(clientId: String, dismissedAt: Date = Date()) {
        self.clientId = clientId
        self.dismissedAt = dismissedAt
    }
}

// Dismiss/restore, kept OUT of the view for the same reason ExcludedTownEditing is (#863). Idempotent by
// construction; reversible by design (the never-a-dead-end rule, #845).
@MainActor
enum CoverageDismissEditing {
    static func dismiss(clientId: String, into context: ModelContext) {
        guard !dismissedIds(in: context).contains(clientId) else { return }
        context.insert(DismissedCoverageClient(clientId: clientId))
        try? context.save()
    }

    static func restore(clientId: String, in context: ModelContext) {
        guard let row = rows(in: context).first(where: { $0.clientId == clientId }) else { return }
        context.delete(row)
        try? context.save()
    }

    static func rows(in context: ModelContext) -> [DismissedCoverageClient] {
        (try? context.fetch(FetchDescriptor<DismissedCoverageClient>(sortBy: [SortDescriptor(\.dismissedAt)]))) ?? []
    }

    static func dismissedIds(in context: ModelContext) -> Set<String> {
        Set(rows(in: context).map(\.clientId))
    }
}

// #1356: the diagnostic's wording, kept out of the view (#863) and harvested into docs/copy-inventory.md
// like ClientTagCopy. No dashes as punctuation (the style rule); colons and separate sentences instead.
enum CoverageCopy {
    static let sectionTitle = "Returning clients not covered"
    // #1547: the box explains itself in EVERY state, not only when there are gaps in it.
    //
    // With zero gaps and some clients set aside, the sheet rendered the heading "Returning clients not
    // covered" directly above a bare collapsed count and nothing else, which reads as N uncovered clients
    // when it means the opposite. Dan asked what the section meant on 2026-07-26, which is the evidence.
    // The sentence existed; it was inside the has-gaps branch, so it was compiled out in exactly the
    // state he was in.
    static func sectionExplanation(hasGaps: Bool) -> String {
        hasGaps
            ? "Downbeat clients no watched source treats as a returning client, so their next season would not surface a year ahead. Add a source for them, or tag an existing one below."
            : "Every returning client is covered by a watched source, or set aside below."
    }
    // #1548: ONE verb and ONE noun for this state, everywhere it appears.
    //
    // It was named three ways on one screen: the button that creates it said "Not one I scout", the
    // collapsed count called them "N ignored clients", and the way back said "Stop ignoring this". The
    // noun in the count was the one word Dan never clicked, and "ignored" also collided with the
    // unrelated Removed sources section above it.
    //
    // "Set aside" is the verb, so the count is the same words as the button he pressed, and it does not
    // borrow a word another section already owns.
    static let dismissLabel = "Set aside"
    static let restoreLabel = "Put back"

    // Shown under a gap row when a watched source is probably this client but the name does not match.
    static func nearMiss(sourceName: String) -> String {
        "A source \"\(sourceName)\" may be them: check its name, or tag it a returning client."
    }

    // The collapsed disclosure. Singular/plural so it never reads "1 clients", and the same words as
    // the button that put them there (#1548).
    static func ignoredDisclosure(count: Int) -> String {
        count == 1 ? "1 client set aside" : "\(count) clients set aside"
    }

    // The banner shown the moment a client is dismissed, so the row does not just silently vanish. The
    // disclosure below is the durable way back; this Undo is the immediate one (the #845 pairing).
    static func dismissedAck(name: String) -> String {
        "Set aside \(name). It will not show as a coverage gap."
    }

    // Fail loud: when the Downbeat export is missing, stale or unreadable, an empty gap list would look
    // exactly like "every client is covered". Say instead that coverage cannot be checked.
    static let coverageUnavailable =
        "Coverage cannot be checked right now: the Downbeat client export is missing or could not be read. Refresh it from Downbeat."
}
