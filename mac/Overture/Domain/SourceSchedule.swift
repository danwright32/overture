import Foundation

// #802: what one scout run does to each watched source, decided BEFORE anything touches the network.
//
// Kept pure and separate from the loop that executes it, because everything that governs Dan's token
// spend and the safety of his queue lives here: which sources are checked at all, in what order, which
// are deferred, and whether this run is even allowed to read a page. A rule buried inside an async loop
// with a URLSession call in it is a rule nobody can test.

// Whether this run may spend tokens reading a page that changed.
//
// Dan's 4th decision (2026-07-12), and the reason the two exist separately: the expensive half of a
// scout is ONLY the AI extraction, and extraction only ever touches a page whose content actually
// changed. Fetching and hashing is free. So watching and spending do not have to be the same event, and
// splitting them means the watchlist's core promise (nothing you asked to watch is ever quietly
// dropped) can be kept automatically, every day, for nothing, while the token spend stays Dan's.
enum ScoutDepth: Equatable, Sendable {
    // The daily automatic run. Fetch, hash, record health and any typed failure, and flag a source whose
    // listings have changed. NEVER launches a claude -p run. A dead source is noticed within a day
    // rather than whenever Dan next scouts by hand.
    case watchOnly
    // A scout Dan started. Everything above, and then it reads the pages whose hash actually changed.
    case readChanged
}

// @MainActor because it reads and orders @Model rows, which are not Sendable under Swift 6. The Plan it
// returns holds those rows, so it cannot be Sendable either, and it does not need to be: it is created
// and consumed inside one run on the main actor.
@MainActor
enum SourceSchedule {
    // The cap on how many sources a run Dan STARTED will read. A backstop, not the cost model: the
    // content hash is the cost model, and it means a steady-state run reads almost nothing. This exists
    // for the day Dan adds fifty sources and immediately presses Scout.
    static let defaultBudget = 20

    struct Plan: Equatable {
        // Sources with their own native extractor (Carnegie's Algolia index). They never enter the
        // fetch path and are never budgeted: no HTTP GET can retrieve a POST search API, and their
        // extraction is free, so there is nothing to ration.
        var native: [WatchedSource]
        // Sources whose listings page this run will fetch and hash.
        var fetch: [WatchedSource]
        // Over budget: NOT checked this run. A real, visible state, and neither of the other two. It is
        // not "fine" and it is not "failing", it is "not checked today", and their lastCheckedAt is
        // deliberately left alone so they are first in line next run.
        var deferred: [WatchedSource]
        var depth: ScoutDepth

        var maySpendTokens: Bool { depth == .readChanged }
    }

    // `only` scopes a read to named sources: Dan pointed at one and asked for it. Absent means the
    // ordinary run.
    //
    // It exists because "read THIS source" is otherwise impossible to express. Every source shares a
    // lastCheckedAt (the daily run checks them in one pass), so oldest-first is a tie across the whole
    // list and the budget then picks arbitrarily among them. Capping a run to 3 does not read the 3 you
    // meant, it reads 3 drawn by lot.
    static func plan(sources: [WatchedSource], depth: ScoutDepth, only: Set<String>? = nil,
                     budget: Int = defaultBudget, now: Date) -> Plan {
        // An org that asked Dan to stop, or a dead source he removed, is not checked at all. Not
        // fetched, not hashed, not read. Re-checking an org that asked to be left alone is the one
        // mistake in this feature that cannot be taken back.
        // ABOVE the scoping, deliberately. Naming a source cannot override an org's refusal: that is
        // the one mistake in this feature that cannot be taken back, so it is not a filter Dan can
        // reach past by pointing at a row.
        let watched = sources.filter(\.isActive)

        let native = watched.filter(\.usesNativeExtractor)
        // Oldest first, so a budget staggers rather than starves: a source pushed to the back this run
        // is at the front of the next one, because a deferred source's lastCheckedAt never moved. A
        // source never checked at all has been waiting since Dan added it, so it is the oldest thing
        // there is.
        let fetchable = watched
            .filter(\.isGenericallyFetchable)
            .sorted { ($0.lastCheckedAt ?? .distantPast) < ($1.lastCheckedAt ?? .distantPast) }

        switch depth {
        case .watchOnly:
            // Nothing to ration: this run spends nothing whatever it checks. Capping it would mean
            // silently not watching a source Dan asked us to watch, which is the one thing the
            // watchlist promises never to do.
            return Plan(native: native, fetch: fetchable, deferred: [], depth: depth)
        case .readChanged:
            // Dan named the sources, so the budget does not apply: it is a backstop against reading
            // fifty by accident, and an explicit request is not an accident. Nothing is deferred
            // either, because the rest were never asked for and are not waiting on anything. An id
            // that matches nothing reads nothing, rather than falling back to reading everything: a
            // typo must not launch twenty runs.
            if let only {
                return Plan(native: native.filter { only.contains($0.sourceId) },
                            fetch: fetchable.filter { only.contains($0.sourceId) },
                            deferred: [], depth: depth)
            }
            let cap = max(0, budget)
            return Plan(native: native,
                        fetch: Array(fetchable.prefix(cap)),
                        deferred: Array(fetchable.dropFirst(cap)),
                        depth: depth)
        }
    }
}

// What one source's check decided, given what came back from the network, and what it wrote on the row.
//
// Pure apart from the mutations it makes to the row it is handed, so the whole of a source's health
// lifecycle (it broke, it recovered, it did not change, it changed but we are not reading it today) is
// a real test with no network in it.
@MainActor
enum SourceCheck {
    enum Decision: Equatable, Sendable {
        case unchanged                    // the hash matches what we last ingested: nothing to read
        case changedButNotRead            // it changed, but this is the free daily run
        case read(FetchedPage)            // it changed and Dan started this run: read it
        case failed(SourceFailure)        // named, recorded, and NOT fatal to the source
    }

    static func decide(source: WatchedSource, result: Result<FetchedPage, SourceFetchError>,
                       depth: ScoutDepth, now: Date) -> Decision {
        source.lastCheckedAt = now

        switch result {
        case .failure(let error):
            let failure = SourceFailure.fetch(error)
            source.health = .failing
            source.lastFailure = failure
            // NOT lastSucceededAt, and NOT successfulCheckCount. A source that has been 404ing for a
            // month must not read as "checked an hour ago, all fine", and a failed check must never
            // count toward the warmup that lets a source start marking shows as gone.
            //
            // And it stays ACTIVE. A failing source is still watched and still reported, every run,
            // forever. Nothing but an org's refusal or Dan's own removal ever takes a source off the
            // list: "broken" and "they asked us to stop" are different facts, and a source that quietly
            // deactivated itself because its site was down for a day would be the watchlist silently
            // dropping something Dan asked it to watch.
            return .failed(failure)

        case .success(let page):
            source.health = .ok
            source.lastFailure = nil        // it works again; do not carry a stale error forever

            // #1048: record what this fetch SAW, on every success branch below. This is not the ingested
            // hash (that is stamped only by a save, further down the pipeline): it is "the live page as
            // far as we know", and the free daily watch-only pass is exactly the run that updates it
            // without re-reading. The Sources confirm affordance compares it against the last read to warn
            // when a confirm would anchor to bytes the page has since moved past (WatchedSource
            // .confirmReadIsStale).
            source.lastObservedContentHash = page.contentHash

            // The hash is a CORRECTNESS mechanism, not merely a cost lever. If the page did not change,
            // the extractor never runs, so an extracted title cannot drift between runs and re-key a
            // prospect into a duplicate while the original is marked gone. Determinism by abstention.
            //
            // lastContentHash is the hash of what we last successfully INGESTED, so a source that has
            // never been ingested is changed by definition.
            guard page.contentHash != source.lastContentHash else {
                source.hasUnreadChanges = false
                return .unchanged
            }

            // There are listings here we have not read. Flagged either way, so the free daily run can
            // tell Dan what is waiting without spending anything on it.
            source.hasUnreadChanges = true

            // Note what is NOT done here: the content hash is not stamped. Only an ingest that actually
            // SAVED may stamp it. Stamp it at fetch time and a run that reads everything and then fails
            // to persist (the #499 saveFailed path) leaves the hash saying "nothing changed": the source
            // then fetches fine, reports fine, and silently ingests nothing, forever.
            return depth == .readChanged ? .read(page) : .changedButNotRead
        }
    }
}
