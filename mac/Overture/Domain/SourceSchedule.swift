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
    // #1498: how many sources a run Dan started FETCHES. Unlimited, because fetching and hashing costs
    // nothing and the content hash is the real cost model: only a page that actually changed is ever
    // handed to the paid read. This used to be 20, a backstop against "the day Dan adds fifty sources and
    // immediately presses Scout", but it guarded the wrong half: it rationed free work, left 42 of 62
    // sources unfetched every press, and did not bound the spend at all. That guard now sits on the READ,
    // where the money is (ScoutReadBudget), and asks Dan with the true count.
    //
    // Still a real parameter rather than a deleted one: a caller passing a number smaller than the
    // watchlist gets the old deferred behaviour, so that path stays live and tested.
    static let unlimitedBudget = Int.max

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
    // It exists because "read THIS source" is otherwise impossible to express. The daily run checks every
    // source in one pass, so the ordinary read plan cannot know which source Dan cares about right now;
    // capping a run to 3 reads the 3 the fairness order happens to surface, not the 3 he meant.
    static func plan(sources: [WatchedSource], depth: ScoutDepth, only: Set<String>? = nil,
                     budget: Int = unlimitedBudget, now: Date) -> Plan {
        // An org that asked Dan to stop, or a dead source he removed, is not checked at all. Not
        // fetched, not hashed, not read. Re-checking an org that asked to be left alone is the one
        // mistake in this feature that cannot be taken back.
        // ABOVE the scoping, deliberately. Naming a source cannot override an org's refusal: that is
        // the one mistake in this feature that cannot be taken back, so it is not a filter Dan can
        // reach past by pointing at a row.
        let watched = sources.filter(\.isActive)

        let native = watched.filter(\.usesNativeExtractor)
        let fetchable = watched.filter(\.isGenericallyFetchable)

        switch depth {
        case .watchOnly:
            // The free daily run reads nothing and defers nothing, so its order is immaterial: it checks
            // every fetchable source whatever the budget. Kept oldest-first by the shared fetch clock only
            // so the "checking 3 of 9" heartbeat advances through them in a sensible order. Nothing to
            // ration: capping this run would mean silently not watching a source Dan asked us to watch,
            // which is the one thing the watchlist promises never to do.
            let ordered = fetchable.sorted {
                ($0.lastCheckedAt ?? .distantPast) < ($1.lastCheckedAt ?? .distantPast)
            }
            return Plan(native: native, fetch: ordered, deferred: [], depth: depth)
        case .readChanged:
            // #1189: a run Dan started reads CHANGED venues first, then oldest by the manual scout's OWN
            // fairness clock, then by sourceId as a stable final tie-break (see manualReadOrder). This is
            // the whole fix for the coverage loss the daily run created: the uncapped overnight watch-only
            // run stamps an identical lastCheckedAt on every fetchable source, flattening the old oldest-
            // lastCheckedAt-first order into one big tie, so "the first 20" was the same 20 every press and
            // the same ~17-source tail was deferred forever. Changed-first means a changed calendar is
            // never starved behind unchanged ones (an unchanged one has nothing to read), and the manual
            // clock (which the daily run never touches) keeps a deferred source genuinely next in line.
            let ordered = fetchable.sorted(by: manualReadOrder)
            // Dan named the sources, so the budget does not apply: it is a backstop against reading fifty
            // by accident, and an explicit request is not an accident. Nothing is deferred either, because
            // the rest were never asked for and are not waiting on anything. An id that matches nothing
            // reads nothing, rather than falling back to reading everything: a typo must not launch twenty
            // runs.
            if let only {
                return Plan(native: native.filter { only.contains($0.sourceId) },
                            fetch: ordered.filter { only.contains($0.sourceId) },
                            deferred: [], depth: depth)
            }
            // #1498: the budget no longer rations the FETCH by default. Fetching and hashing is free, and
            // only a page whose content actually changed is ever handed to the paid read, so capping here
            // rationed the free half of the run: a 62-source watchlist checked 20 a press and left 42
            // untouched, which is how a source with something to say ended up three presses back through
            // no fault of its own (#1498's Finding B looked stuck for exactly that reason). The question
            // moved to the paid read, where the money is, and is asked with the true count once everything
            // has been fetched (ScoutReadBudget). Nothing is deferred here any more, because nothing is
            // skipped.
            //
            // `budget` stays in the signature and is honoured as a hard ceiling when a caller passes one
            // BELOW the number of sources, so a test can still pin the deferred shape and a future runaway
            // guard has a lever. The default is unlimited.
            let cap = max(0, budget)
            guard cap < ordered.count else {
                return Plan(native: native, fetch: ordered, deferred: [], depth: depth)
            }
            return Plan(native: native,
                        fetch: Array(ordered.prefix(cap)),
                        deferred: Array(ordered.dropFirst(cap)),
                        depth: depth)
        }
    }

    // Of the sources a run deferred (over budget, not fetched this press), the ones genuinely WAITING to
    // be read: those carrying unread listings. An UNCHANGED deferred source has nothing to read. The free
    // daily watch-only run fetches and hashes every source regardless of budget, so a deferred-but-
    // unchanged source is fully covered, not neglected, and re-checked for free every night.
    //
    // Surfacing every deferred source as "waiting" (changed or not) is what made the end-of-scout popup's
    // "N venues still waiting to be checked" a fixed total-minus-budget that never fell however many times
    // Dan pressed Run again: with 42 fetchable sources and a budget of 20 it read "22 waiting" on every
    // press, forever, because a different 22 unchanged sources are always over the cap. Filtered to the
    // changed ones, the number is the real backlog of unread pages and it converges: each press reads up
    // to the budget of changed venues (changed-first, see manualReadOrder), and their unread flag clears
    // on a successful ingest, so repeated presses drain it to zero.
    //
    // #1546: and NOT a source whose flag is only an owed retry. `ScoutExtractIngest.fail()` sets the same
    // flag on every failed read, and for a no_dated_content page nothing ever clears it, so that source is
    // unread by this definition on every run forever and could hold the count off zero however many times
    // Dan pressed Run again. It is not waiting to be read: reading it again reproduces the same failure.
    // It is still reported, loudly, as a FAILING source, which is where a broken page belongs.
    //
    // Worth stating plainly for whoever reads this next: since #1498 removed the default fetch budget,
    // `plan.deferred` is empty on every run the app actually makes, so this filter currently decides
    // nothing on screen. It is kept correct rather than deleted because the budget is still honoured when a
    // caller passes one, and a rule that is wrong while dormant is a bug waiting for the day it wakes up.
    static func waitingToRead(deferred: [WatchedSource]) -> [WatchedSource] {
        deferred.filter(\.isCarryingUnreadListings)
    }

    // #1189: the order a run Dan started reads its fetchable sources in. Three keys, in strict order:
    //
    //   1. Changed-first, in THREE ranks rather than two (#1546). A changed venue is never starved behind
    //      an unchanged one, which has nothing to read anyway. This alone converges coverage: each press
    //      clears up to the cap of changed venues, and their flag clears on successful ingest, so the next
    //      press reads the next batch. The middle rank is the fix: a source whose unread flag is only an
    //      owed retry (its last read failed and its bytes have not moved since) used to sort on the same
    //      key as a genuine change and so led every press, forever, because that flag can never clear
    //      itself. It is demoted, not dropped: #1217 still re-reads a still broken source on a run Dan
    //      started, on the assumption he fixed the cause between presses, and it still outranks a quiet
    //      source with nothing to read. What it no longer does is take the first slot of the batch Dan
    //      agreed to pay for (ScoutReadBudget slices exactly this order) away from a venue that genuinely
    //      posted a new season.
    //   2. Oldest by the manual scout's own fairness clock (lastManualReadAt, nil sorting oldest). The
    //      daily watch-only run never advances this clock, so unlike lastCheckedAt it is not flattened
    //      every morning: a source the last press deferred stays genuinely next in line across days. This
    //      is what fairly distributes reads when MORE than the cap have changed at once (a big batch).
    //   3. sourceId, a deterministic final tie-break, so the order is stable rather than dependent on the
    //      store's internal (unsorted) FetchDescriptor row order.
    private static func manualReadOrder(_ a: WatchedSource, _ b: WatchedSource) -> Bool {
        if readRank(a) != readRank(b) { return readRank(a) < readRank(b) }
        let aClock = a.lastManualReadAt ?? .distantPast
        let bClock = b.lastManualReadAt ?? .distantPast
        if aClock != bClock { return aClock < bClock }
        return a.sourceId < b.sourceId
    }

    // #1546: the first key's three ranks, lowest read first. Kept as a named function rather than inlined
    // so the order it encodes is legible: real unread listings, then a retry we owe on a page that has not
    // moved, then a source with nothing to read at all.
    private static func readRank(_ source: WatchedSource) -> Int {
        guard source.hasUnreadChanges else { return 2 }
        return source.unreadIsOnlyAnOwedRetry ? 1 : 0
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
        // #1217: captured BEFORE the success branch below resets health and lastFailure, so a source that
        // did not cleanly succeed last time can still be recognized after it fetches fine this time.
        let retryStillBroken = source.lastCheckWasNotCleanSuccess
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
                // #1217: a scout Dan started re-reads a source that did NOT cleanly succeed last time,
                // even when the page is byte-for-byte unchanged, on the assumption he fixed the
                // underlying cause (a code fix, a runbook fix, a corrected URL) between scouts. The free
                // daily watch-only run never does this: it costs a token, which only Dan's run may spend.
                if depth == .readChanged && retryStillBroken {
                    return .read(page)
                }
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
