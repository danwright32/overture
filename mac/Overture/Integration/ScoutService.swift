import Foundation
import SwiftData

// The in-app scout: extract the live calendar (hidden WebKit) -> classify (rules) ->
// match repeat clients -> assemble/rank -> upsert into the local store. Fully native
// and silent; no separate runner, no cloud. Upsert preserves Dan's keep/dismiss.

@MainActor
enum ScoutService {
    // #2758 / #2999: which stored row an incoming show belongs to, decided in ONE place so the refusal
    // cannot be forgotten by one arm.
    //
    // Every arm below the first WRITES the incoming key onto a stored row, and each is safe only because
    // the first arm proved nobody holds it. A key collision does not throw: measured under #2754,
    // `save()` succeeds and SwiftData MERGES the two rows, taking some fields from each, so a card's keep
    // decision, its contacts and its outreach record go with no error raised anywhere (L5).
    // #4147: WHICH read answered, carried on the decision rather than re-derived afterwards.
    //
    // The caller cannot work it out: three different arms all return `.reKey`, so "the arm that matched
    // is a fact the caller holds" was true of the insert and the in place update and false of exactly
    // the arms a rename most often comes through. Recording a rename against "reKey" would name three
    // mechanisms at once, which is the answer #4068 already had and could not use.
    //
    // A raw value, because it is written into a durable file a person reads later.
    enum MatchArm: String, Equatable, Sendable {
        case naturalKey
        case concertIdentity
        case anyRunURL
        case productionToken
        case stableSource
    }

    enum UpsertTarget: Equatable {
        case updateInPlace(Prospect)
        case reKey(Prospect, by: MatchArm)
        // #4029: a re-key that is ALSO news about a night the stored row does not have, so the nights
        // are unioned rather than replaced. Its own case rather than a flag on `.reKey`, because the
        // two differ in what they do to stored data and a caller must not be able to take one for the
        // other. Every other arm answers "this is the same run, read again", where the feed is
        // authoritative and a night it stopped listing must drop off; the token arm answers "this is
        // another night of the same production", where replacing DESTROYS a night that is still in the
        // future. Measured: joining the live Nihao Broadway pair by replacement would have discarded
        // 2026-09-11 on 2026-08-19, three weeks before it played.
        case reKeyJoiningNights(Prospect)
        // #3330: carries the key of the stored row this arrival LOOKED LIKE, or nil. The answer rides
        // the decision rather than being asked afterwards, because the read it needs is a scout read like
        // any other: a store that cannot answer must refuse the row, not silently omit the tag
        // (#3071, and `ScoutStoreReadTests` refuses a `try?` on any fetch in this file).
        case insert(ArrivalNotes)
        // The store could not answer, so nobody knows whether the key is free. Refusing costs this row
        // one run and it comes back on the next; guessing costs a card that does not come back (L105).
        case storeUnreadable

        // #4147: which read answered, for the rename ledger. Here rather than at the call site, because
        // the two arms that rewrite a stored row's title reach `apply` through one branch and a `case`
        // binding cannot name the arm on both halves of it.
        //
        // `.reKeyJoiningNights` IS the production token arm: it is the only arm that returns it
        // (`upsertTarget` above), and the case exists precisely because that arm answers a different
        // question from the rest.
        var matchedArm: MatchArm? {
            switch self {
            case .updateInPlace: return .naturalKey
            case .reKey(_, let arm): return arm
            case .reKeyJoiningNights: return .productionToken
            case .insert, .storeUnreadable: return nil
            }
        }
    }

    // #3330 and #4130: what an INSERTED row is told about the store it is landing in.
    //
    // ONE STRUCT rather than a second closure beside `lookingLike`, and one read rather than two. Both
    // answers are drawn from the same walk of the stored rows, which an inserting row already pays for
    // once; asking twice would double the fetch on the arm that runs for every genuinely new show.
    //
    // Both are POINTERS to another row's natural key, resolved at read time, and neither is ever
    // cleared: the note each draws is silent once the row it names is gone (L200).
    struct ArrivalNotes: Equatable, Sendable {
        // The stored row this arrival resembles by the launch merge's own predicate (#3330).
        var lookingLike: String? = nil
        // The stored row that was already PITCHED for this night, at this room, for this presenter
        // (#4130). Independent of the above: this pair's titles deliberately need not match at all.
        var alreadyPitched: String? = nil

        static let none = ArrivalNotes()
    }

    // The four reads the upsert makes, in the order it makes them, as closures.
    //
    // Closures rather than a ModelContext for the reason RunNightDrop's `lookup:` seam exists: a healthy
    // in-memory store never throws, so a fixture that only ever asks one proves nothing about the branch
    // this whole thing is about (L140). The order IS the rule (a concert identity beats a shared run URL
    // beats a stable source listing), so it is expressed here rather than repeated at the call site.
    static func upsertTarget(storedByKey: () throws -> Prospect?,
                             byConcert: () throws -> Prospect?,
                             byAnyRunURL: () throws -> Prospect?,
                             byProductionToken: () throws -> Prospect? = { nil },
                             byStableSource: () throws -> Prospect?,
                             // #3330, #4130: asked ONLY when every arm above has missed, so an
                             // ordinary re-ingest never pays for it. Inside the same do/catch as the
                             // arms, so a failed read refuses this row exactly as a failed arm does.
                             arrivalNotes: () throws -> ArrivalNotes = { .none }) -> UpsertTarget {
        do {
            if let existing = try storedByKey() { return .updateInPlace(existing) }
            if let match = try byConcert() { return .reKey(match, by: .concertIdentity) }
            if let match = try byAnyRunURL() { return .reKey(match, by: .anyRunURL) }
            // #4029: below the whole-URL arm on purpose. A shared WHOLE url is stronger evidence than a
            // shared token, so where both could answer, the stronger one does and the nights follow the
            // feed as they always have.
            if let match = try byProductionToken() { return .reKeyJoiningNights(match) }
            if let match = try byStableSource() { return .reKey(match, by: .stableSource) }
            return .insert(try arrivalNotes())
        } catch {
            return .storeUnreadable
        }
    }

    // #3071: a read the run makes ABOUT ITS OWN STORE that is not part of the upsert decision above.
    //
    // #2758 / #2999 fixed the one swallowed read that could DESTROY data. Four more folded "could not
    // read" into "nothing there". None of those destroys anything, which is why that fix was scoped
    // rather than swept, but each invents an emptiness that is itself a claim about Dan's data (L98, L11).
    //
    // NAMED rather than counted, because which read failed is the whole of what is wrong with the answer.
    // An unreadable watchlist means the run scanned nothing; an unreadable brand corpus means it matched
    // against less than it holds. One word covering both would say neither.
    enum StoreRead: String, Equatable, Sendable, CaseIterable {
        case repeatClientHistory
        case sourceWatchlist
        case reconcileStoredShows
        case venueBrandCorpus
        // #4056: the rows the production token discard is judged over. Its own case rather than folding
        // into `reconcileStoredShows`, because the two send Dan to different places and a sentence naming
        // the wrong one is worse than none (L11).
        case productionTokenCorpus
        // #4336 (A7): the record of which calendar results already landed. Its own case, because a
        // failure here means results may land twice, which no other read's sentence says.
        case landedRuns
        // #4332 (A3): Dan's producer corrections, the second of the two reads the brand corpus is joined from.
        // Its own case rather than folding into `venueBrandCorpus`, because a corpus missing the corrections
        // undoes what Dan said rather than judging against fewer rooms, and the sentence has to say which
        // (L530, L11).
        case producerOverrides

        // What Dan reads. Named for the thing rather than the symbol, because the sentence has to send
        // him somewhere and "venueBrands" sends him nowhere.
        var label: String {
            switch self {
            case .repeatClientHistory: return "the record of who you have shot before"
            case .sourceWatchlist: return "the list of calendars it watches"
            case .reconcileStoredShows: return "the shows it already had"
            case .venueBrandCorpus: return "the venue names it matches against"
            case .productionTokenCorpus: return "the production ids it joins a run by"
            case .landedRuns: return "the record of which calendar results already landed"
            case .producerOverrides: return "your producer and venue house corrections"
            }
        }
    }

    // A read the run cannot honestly proceed without. It THROWS, naming the read, so the run stops
    // before it spends anything and RootView's own catch reports it.
    //
    // Both uses sit at the very top of `run`, before any work: a store that cannot answer there cannot
    // answer the upsert's reads either, so stopping costs a run that was going to be wrong anyway. The
    // watchlist is the one that matters most and is the one #2999's sweep missed. An empty watchlist
    // plans zero sources, so the scout scanned nothing and reported an ordinary quiet run: a run that
    // could not read its own watchlist was indistinguishable from a night with no shows on it, which is
    // precisely the shape L98 is about.
    struct StoreReadFailure: Error, CustomStringConvertible {
        let read: StoreRead
        let underlying: Error
        // Says ONLY the new fact: which read failed. `ScoutFailure.presentation` already wraps whatever
        // reaches RootView's catch in "The scout couldn't run... Try again; if it keeps failing, something
        // is wrong with the local store", and prints this after "Details:". Restating that here put two
        // sentences on one alert each saying the run stopped and each telling him to try again, which is
        // #843's defect: correct alone, redundant where he meets them.
        var description: String { "couldn't read \(read.label). (\(underlying))" }
    }

    // #4275: the ONE whole show table read in this file and in `ScoutExtractIngest`. Every read of the
    // table a scout makes goes through this, or through a caller's injected replacement for it, so a test
    // can count them (`ScoutLandingReadsOnceTests`), and a scan refuses any other spelling of it.
    // #4332: Sendable, because the brand corpus calls it on a background context, off the main actor.
    nonisolated static let readProspectTable: ScoutLandingStore.SendableRead = { try $0.fetch(FetchDescriptor<Prospect>()) }

    // #4332 (A3): Dan's producer corrections, read the same way: injected, so a test can make it fail.
    typealias OverrideRead = @Sendable (ModelContext) throws -> ProducerOverrides
    nonisolated static let readProducerOverrides: ScoutService.OverrideRead = { try ProducerOverrideEditing.readOverrides(in: $0) }

    static func required<T>(_ read: StoreRead, _ fetch: () throws -> [T]) throws -> [T] {
        do { return try fetch() } catch { throw StoreReadFailure(read: read, underlying: error) }
    }

    // A read taken MID RUN, where throwing would discard work already done and the store's silence makes
    // the answer thinner rather than wrong.
    //
    // It answers nil for unreadable, never an empty array, which is the whole difference from
    // `(try? fetch) ?? []`: the caller is made to say what it met, and the read names itself on the run
    // so the outcome can report what it judged against less of.
    nonisolated static func readOrRecord<T>(_ read: StoreRead, into degraded: inout [StoreRead],
                                            _ fetch: () throws -> [T]) -> [T]? {
        do { return try fetch() } catch { degraded.append(read); return nil }
    }

    struct Outcome: Equatable, Sendable {
        // #4147: the titles this run overwrote, and which arm did each. Empty on almost every run.
        // Carried here as well as written to `TitleRenameLedger`, so what a run recorded can be asserted
        // without reading a file, and so a caller that wants to report it does not have to re-read one.
        var titleRenames: [TitleRenameLedger.Entry] = []
        var found: Int
        var inserted: Int
        var updated: Int
        var skipped: Int
        // #797: nights folded into a multi-night run rather than upserted on their own. Deliberately
        // NOT counted as `skipped`, which means "decided not to pursue" (a blocked date, a
        // do-not-contact org); a collapsed night was pursued, as part of its run. Kept separate so
        // every event the scout found is accounted for exactly once:
        //     found == inserted + updated + skipped + collapsedIntoRun + storeUnreadable
        // That identity is what makes a silently vanished show impossible to miss (it was the bug
        // this counter was added to catch), so it is asserted directly in the tests.
        var collapsedIntoRun: Int = 0

        // #2758 / #2999: shows this run refused to touch because the store could not answer whether
        // their key was free. A fifth term in the identity above rather than a fold into `skipped`,
        // which means Dan's rules decided against the show: this one nobody decided anything about, and
        // it comes back on the next run. Naming it is the whole point, because a run that quietly drops
        // shows is indistinguishable from a run that found none (L98, L11).
        var storeUnreadable: Int = 0
        var storeUnreadableKeys: [String] = []

        // #3071: the reads above that could not answer this run. Not a count of shows: nothing was
        // dropped, the run simply judged against less than the store really holds, and the point is that
        // it SAYS so instead of reporting an ordinary run (L98, L11).
        var degradedReads: [StoreRead] = []
        // Set when the Downbeat past-client export was missing, unreadable, or stale, so
        // warm/repeat matching ran degraded and Dan should be told (#22/#23).
        var clientListWarning: String? = nil
        // #499: set when a context.save() failed during this run, so some or all of what the
        // scout found or reconciled may not have persisted.
        var saveFailed: Bool = false

        // #802: what happened to each watched source this run. A run is no longer one number, and it
        // must never report a total that silently omits half of what it was supposed to check.
        var sources: [SourceResult] = []

        // #857: results that came back under a sourceId we never queued. The run rebuilt a key instead of
        // echoing it, so its work resolves to nothing and cannot be landed on the right row. Recorded so
        // it vanishes LOUDLY: the queued source it should have belonged to shows up separately as
        // never-read (the shell guard fills it), but only this names WHY (the id was rewritten).
        var unqueuedResultIds: [String] = []

        // #802, Dan's 3rd decision: the orgs that asked him to stop whose shows still turned up on a
        // calendar he watches. The #769 guard suppressed them, silently, and silent is the problem: on
        // the one mistake that cannot be taken back he would rather SEE the guard working than trust it.
        // This is a receipt, not a warning: nothing is wrong and nothing needs doing.
        var suppressedOrgs: [SuppressedOrg] = []

        // #802: the run found changed pages and could not hand them off to be read (the runner is not
        // configured, or a previous run is still going). NOT a per-source failure: those calendars are
        // healthy and it is the app that cannot read them. Marking them failing would send Dan to debug
        // twelve working websites.
        var extractLaunchFailure: String? = nil

        // #4330 (A13): an ingest that waited for the store past its deadline and was refused, in the sentence
        // that says why and that nothing was lost (`LandingWaitCopy`). Nothing from it landed; its results
        // are kept and offered again (`PendingScoutIngests`).
        var notLandedYet: String? = nil

        // #4336 (A7): these results were refused because they had already landed, at this time (the FIRST
        // landing's). Nothing from them was applied. Its own outcome, never a landing that found nothing.
        var alreadyLandedAt: Date? = nil
        // #4334 (A5): why this landing stopped before landing every source, or never started (`LandingStop`).
        // nil for a landing that reached every source it was given, including one where a source level
        // failure put one source back and the rest landed.
        var landingStop: LandingStop? = nil
        // #4334: how `apply`'s own save failed, classified once (`LandingSaveFailure`). Read by the landing
        // that called it, to decide whether to carry on; nil when the save succeeded or nothing saved.
        var saveFailureScope: LandingSaveFailure.Scope? = nil

        // #4330: the sources this run set aside because a later run had already landed them.
        var supersededSources: [SourceResult] { sources.filter { $0.state == .superseded } }

        // #4334: the sources a stopped landing never reached.
        var notAttemptedSources: [SourceResult] { sources.filter { $0.state == .notAttempted } }

        // #4338 (A10): a save failed and the recovery WILL try again, because the landing's journal is kept and
        // its record has attempts left (`LandingRecovery.willRetry`). Written by the two landings that keep a
        // journal, at their end; read by the save failure's sentence, so "will be retried" is said only when
        // it is true (L703). False on every outcome whose save did not fail.
        var retriedByRecovery: Bool = false

        // #4334: the stop, in Dan's words, with what it left behind. nil when nothing stopped, and for a store
        // that refused a save, whose sentence is `ScoutWarningCopy.saveFailed` itself, unless sources after it
        // went unlanded, which is then said.
        var landingStopWarning: String? {
            var parts: [String] = []
            switch landingStop {
            case .recentEditsUnsaved(let rows)?: parts.append(ScoutWarningCopy.recentEditsUnsaved(rows))
            case .notReverted(let source, _)?: parts.append(ScoutWarningCopy.notReverted(source))
            case .journalNotWritten(let why)?: parts.append(ScoutWarningCopy.journalNotWritten(why))
            case .resultsNotKept(let why)?: parts.append(ScoutWarningCopy.resultsNotKept(why))
            case .storeRefusedASave?, nil: break
            }
            let unreached = notAttemptedSources.count
            if unreached > 0, let landingStop, !landingStop.refusedBeforeAnything {
                parts.append(ScoutWarningCopy.notAttempted(unreached))
            }
            return parts.isEmpty ? nil : parts.joined(separator: " ")
        }

        // #888 part B: what THIS source swept, carried home so the caller can reconcile every source it
        // landed in ONE pass. Nil when this apply had no feed to report on (the lead path), which is
        // what keeps a pasted lead structurally unable to mark anything gone (#826).
        var report: FeedReconcile.SourceReport? = nil

        // Every source's report from a merged run. `merge` collects them (see below), so a caller that
        // landed six sources can hand all six to one reconcile and finally satisfy "every owner was
        // asked", which a single-report reconcile never could.
        var reports: [FeedReconcile.SourceReport] = []

        var allReports: [FeedReconcile.SourceReport] { reports + [report].compactMap { $0 } }

        var failedSources: [SourceResult] { sources.filter { $0.state.isFailure } }

        // The single warning to show after a run, if any. A save failure takes precedence over
        // everything else: the run may have found and processed events that never persisted, the
        // most actionable problem (#499).
        //
        // #802: `found == 0` STOPS being a global warning. Under a watchlist, zero is the NORMAL
        // off-season answer (5 of the 7 sites in the #770 spike, in July) and is also exactly what a
        // fully hash-skipped run legitimately returns. Firing "the feed's data format may have changed"
        // on every quiet week would train Dan to ignore the one warning that matters. It now fires only
        // for a source that HAS a healthy baseline and still came back with nothing, which for
        // Carnegie's 90-day window is the same unusual event it always was (#27, #126).
        var warning: String? {
            // #4330 (L94): `notLandedYet` rides with both early returns rather than being hidden behind them:
            // "kept, will be offered again" is true of the run whatever else went wrong with it.
            if saveFailed {
                return [ScoutWarningCopy.saveFailed(retried: retriedByRecovery), landingStopWarning, notLandedYet]
                    .compactMap { $0 }.joined(separator: "\n\n")
            }
            // The run found new listings and could not read them. It outranks a per-source failure
            // because it is the app that is broken, not a calendar, and because it has a one-step fix.
            if let extractLaunchFailure {
                return [extractLaunchFailure, notLandedYet].compactMap { $0 }.joined(separator: "\n\n")
            }
            // A source that could not be checked is the most actionable thing after that, and it is
            // named, every run, for as long as it keeps failing. A dead source and a quiet season must
            // never look alike. #857: a run that rebuilt an id (returned work under a source we never
            // queued) is shown alongside, not masked by, the failures, because both can happen in one run.
            // #3071: alongside the two above rather than instead of either, because all three can
            // happen in one run and each names a different thing that went wrong.
            let parts = [landingStopWarning, notLandedYet, failureWarning, unqueuedWarning, degradedReadWarning,
                         supersededWarning].compactMap { $0 }
            if !parts.isEmpty { return parts.joined(separator: "\n\n") }
            if !silentlyEmptySources.isEmpty {
                return ScoutWarningCopy.silentlyEmptyFeed(sources: silentlyEmptySources.map { ($0.orgName, $0.droppedRowCount) })
            }
            return clientListWarning
        }

        // #857: the run rebuilt one or more sourceIds, so its work for them cannot be landed. Named, so
        // the drop is loud rather than silent. The id itself is what the run wrote, and is the actionable
        // clue for whoever debugs why a source keeps coming back never-read.
        private var unqueuedWarning: String? {
            guard !unqueuedResultIds.isEmpty else { return nil }
            return ScoutWarningCopy.unqueued(ids: unqueuedResultIds)
        }

        // #4330: the reader of `.superseded`, so a set aside reading is said rather than left looking like a
        // source that was never checked.
        private var supersededWarning: String? {
            let set = supersededSources
            guard !set.isEmpty else { return nil }
            return ScoutWarningCopy.superseded(set.map(\.orgName))
        }

        // #3071: the reads that could not answer, in Dan's words. This is the READER that stops
        // `degradedReads` being a field written and never read (L46).
        private var degradedReadWarning: String? {
            guard !degradedReads.isEmpty else { return nil }
            return ScoutWarningCopy.degradedReads(degradedReads.map(\.label))
        }

        private var failureWarning: String? {
            let failed = failedSources
            guard !failed.isEmpty else { return nil }
            let lines = failed.map { "\($0.orgName): \($0.state.failureMessage ?? "couldn't be checked")" }
            return failed.count == 1
                ? "One source couldn't be checked. \(lines[0])"
                : "\(failed.count) sources couldn't be checked.\n\n" + lines.joined(separator: "\n")
        }

        // The sources that have succeeded before (so they have a baseline to be judged against) and came
        // back empty anyway. A brand-new source with no history has nothing unusual about an empty first
        // check, and a quiet off-season is not a defect.
        // #1027: internal, not private, so the structured ScoutWarnings can read the SAME rule the old
        // single-string warning used rather than restating it and eventually disagreeing with it.
        // #1531: the SOURCES, no longer a bare Bool. The rule is unchanged; what changed is that the
        // answer keeps the one fact Dan can act on, which of them went quiet, instead of discarding it
        // and leaving the warning to say "the calendar feed" about any of 62 sources.
        var silentlyEmptySources: [SourceResult] {
            sources.filter { $0.state == .ingested(found: 0) && $0.hadBaseline }
        }

        // Folds one source's ingest into the run's totals. The counts stay additive so the #797 identity
        // (found == inserted + updated + skipped + collapsedIntoRun + storeUnreadable) still holds across
        // the whole run, which is what makes a silently vanished show impossible to miss.
        mutating func merge(_ other: Outcome) {
            found += other.found
            inserted += other.inserted
            updated += other.updated
            skipped += other.skipped
            collapsedIntoRun += other.collapsedIntoRun
            storeUnreadable += other.storeUnreadable
            storeUnreadableKeys.append(contentsOf: other.storeUnreadableKeys)
            degradedReads.append(contentsOf: other.degradedReads)
            // #4338: retried only while every failed save merged in is; one that will not be is the one to say.
            let wasFailed = saveFailed
            saveFailed = saveFailed || other.saveFailed
            retriedByRecovery = saveFailed && (!wasFailed || retriedByRecovery)
                && (!other.saveFailed || other.retriedByRecovery)
            sources.append(contentsOf: other.sources)
            unqueuedResultIds.append(contentsOf: other.unqueuedResultIds)
            suppressedOrgs.append(contentsOf: other.suppressedOrgs)
            // #4147's renames, which this used to drop, so a run built by merging one Outcome per source
            // reported none however many it made (`ScoutReadsLandTogetherTests`).
            titleRenames.append(contentsOf: other.titleRenames)
            notLandedYet = notLandedYet ?? other.notLandedYet
            alreadyLandedAt = alreadyLandedAt ?? other.alreadyLandedAt
            // #4334: the first stop wins; nothing after it was attempted, so there is no second.
            landingStop = landingStop ?? other.landingStop
            // #888 part B: reports ACCUMULATE across a merge rather than the last one winning. That is
            // the whole point: a caller that landed six sources must be able to hand all six to one
            // reconcile, or "every owner was asked" can never be true of a co-listed show.
            reports.append(contentsOf: other.allReports)
        }
    }

    // An org Dan told Overture to stop contacting, whose shows a watched calendar is still listing.
    struct SuppressedOrg: Equatable, Sendable {
        var orgName: String
        var showCount: Int
    }

    // What one watched source did this run. Every source that was supposed to be checked appears here,
    // including the ones that were not checked, because "not checked today" reporting as silence is the
    // failure this whole feature exists to prevent.
    struct SourceResult: Equatable, Sendable {
        var sourceId: String
        var orgName: String
        var state: State
        // Whether this source had a feed history before this run, which is what makes an empty result
        // from it unusual rather than merely quiet.
        var hadBaseline: Bool = false
        // #1055: the page this result is about. The end-of-scout popup shows (and opens) it beside a
        // couldn't-be-checked failure, so Dan can judge whether it is the wrong page without leaving the
        // popup for the Sources sheet. nil only for Carnegie's native feed, which has no page to correct.
        var listingsURL: String? = nil
        // #1539: how many rows this run READ and then dropped. Zero when the page listed nothing at all.
        //
        // It is the difference between the only two ways a source with a history comes back empty, and
        // the warning was explaining both as the first: "Its page format may have changed" was shown for
        // The Players Theatre on 2026-07-26, whose page had been read fine and listed 149 shows, every
        // one dropped for having no venue (#1529). Nothing about the format had changed, and the
        // suggested cause sent Dan to inspect a page that was correct.
        var droppedRowCount: Int = 0

        enum State: Equatable, Sendable {
            case ingested(found: Int)     // ran natively and its shows are in the store (Carnegie)
            case unchanged               // its page has not changed since we last read it: nothing to do
            case queuedForReading        // its page changed and Dan started this run: it is being read
            case changedNotRead          // its page changed, but this was the free daily run
            case deferred                // over this run's budget. NOT checked. Not fine, not failing.
            case failed(SourceFailure)   // named, recorded on the row, and never fatal to the source
            // #1027: a no_dated_content page Dan CONFIRMED as right-but-empty, read again at the same
            // bytes. NOT a failure (it does not nag) and NOT `.unchanged` (that means never re-read;
            // this page WAS read and its emptiness accepted). Its own case so a future count of one can
            // never be quietly mistaken for the other.
            case confirmedEmpty
            // #4330 (A13): a later run read this source after this run did and landed it first
            // (`WatchedSource.lastTouchedSequence`), so this run's older reading was set aside unlanded. Not a
            // failure (the later run's reading is in the store) and not `.unchanged` (the page may well
            // have changed): its own case, so the report says what happened.
            case superseded
            // #4334 (A5): this source's shows were applied and its save failed, so they were PUT BACK
            // (`ScoutLandingStore.revertFailedSave`): nothing it wrote is in the store or left pending, its
            // page hash is not promoted and its unread flag stays set, so the next scout reads it again.
            // Never `.ingested`, which is what this path used to say (#499).
            case saveFailed
            // #4334: a landing stopped before this source (`Outcome.landingStop`), so nothing of this run's
            // reading of it was applied. Its page keeps its unread state, so the next scout reads it again.
            case notAttempted

            var isFailure: Bool { if case .failed = self { return true }; return false }

            var failureMessage: String? {
                if case .failed(let f) = self { return f.message }
                return nil
            }
        }
    }

    // #802: the loop. `runScout` walks every ACTIVE watched source rather than opening with one
    // hardcoded call to Carnegie.
    //
    // Two rules govern it, and both are the opposite of what the old single-source version did:
    //
    // 1. ONE SOURCE'S FAILURE NEVER KILLS THE RUN. It used to throw on the first fetch error, which was
    //    correct when there was exactly one source and its failure meant the run had nothing to do. With
    //    a watchlist, throwing means source 9 being down silently costs Dan sources 10 through 20. Every
    //    per-source failure is now caught, typed, written onto that source's row, counted into the
    //    outcome, and reported by name. The run continues.
    // 2. THE RUN NEVER REPORTS A NUMBER THAT OMITS HALF OF ITSELF. Every source appears in
    //    `outcome.sources`, including the ones that were deferred or that failed, because "not checked
    //    today" quietly reporting as silence is the exact failure this feature exists to prevent.
    //
    // `depth` carries Dan's 4th decision: the automatic daily run WATCHES (fetch, hash, health) and
    // spends nothing, and only a scout he started READS the pages that changed. Carnegie ingests fully
    // on both, because its Algolia path is native and free.
    //
    // Everything is injected (the extractor, the fetch, the defaults) so the whole loop is a real unit
    // test with no network: under the test host `UserDefaults.standard` is the LIVE app's own preference
    // domain, so a test that used the real one would scribble on Dan's app.
    static func runScout(into context: ModelContext,
                         depth: ScoutDepth = .readChanged,
                         // Dan pointed at one source and asked for it. Absent means the ordinary run.
                         only: Set<String>? = nil,
                         extractor: any SourceExtractor = CarnegieExtractor(),
                         // #1237: which native extractor reads each source. The default registry owns the
                         // two host-routed feed adapters (OPERA, VenueTix) and returns nil for everything
                         // else, so the loop below falls back to the injected `extractor` (Carnegie, or a
                         // test stub) exactly as before for Carnegie and any non-native row. Injected so a
                         // dispatch test can hand each source a no-network stub.
                         extractorRegistry: (WatchedSource?) -> (any SourceExtractor)? = SourceExtractorRegistry.extractor(for:),
                         // #1127: the source's orgName rides along (2nd arg) so a feed adapter that cannot
                         // learn the venue name from the feed itself (VenueTix) can attribute the shows.
                         // #1175: the source's venueLocation rides along (3rd arg) so a single-venue feed with
                         // no city in its own data still places in-region.
                         // #1210: unless a test injects its own, the fetch pages FORWARD on a site's own
                         // month links, reading the shared four-month horizon instead of the one month it
                         // used to (CalendarMonthIndex.defaultHorizon). A month-paginated calendar (Kaufman)
                         // now surfaces its later, more pitchable months; a non-paginated page is still
                         // fetched exactly once. Safe on this reconciling path because a short stitched read
                         // downgrades to incompleteExtraction and can mark nothing gone (SweepCoverage #897,
                         // wired end to end in StitchedSweepIngestWiringTests). Built in the body (below),
                         // not as a default here, because a default argument cannot reference the `session`
                         // and horizon it needs; `session` is injected so a test can drive the real
                         // paginating fetch against a stub without the network.
                         fetch fetchOverride: ((URL, String?, String?) async throws -> FetchedPage)? = nil,
                         session: URLSession = .shared,
                         // Injected for the same reason the fetch is: pinning writes a file to the
                         // handoff directory and launching starts a real Claude run, so a test that used
                         // the real ones would litter Dan's store and spend his tokens.
                         pin: (FetchedPage, String) throws -> URL = { try ScoutPagePin.write($0, forSourceId: $1) },
                         launch: ([ScoutExtractQueueItem]) throws -> Void = {
                             _ = try ScoutExtractService.startExtract(items: $0, now: Date())
                         },
                         budget: Int = SourceSchedule.unlimitedBudget,
                         now: Date = Date(),
                         defaults: UserDefaults = .standard,
                         // #1034: the native "Scouting" phase heartbeat for the takeover modal. Called
                         // after each source in the fetch/hash loop below with (orgName, 1-based
                         // position, total), so the modal can name the source it is checking and count
                         // "3 of 9" instead of a bare spinner. Default no-op, matching the fetch/pin/
                         // launch injection style above, so every other caller runs unchanged.
                         onNativeProgress: (String, Int, Int) -> Void = { _, _, _ in },
                         // #2203: the SAME phase's heartbeat after the counted part is over. The fetch
                         // loop above is only the first half of Scouting; everything from the read
                         // hand-off to the final save happens with the count pinned at its total, so the
                         // screen looked frozen and the sweep's only evidence of life expired. Each tail
                         // step names itself here. Default no-op, like the callback above.
                         onNativeStep: (ScoutSweepStep) -> Void = { _ in },
                         // #1037: Dan's cooperative cancel, checked between sources in the fetch loop.
                         // When it flips true the sweep stops cleanly and, because the run was abandoned,
                         // NO detached read is launched. Default never-cancelled, so every existing
                         // caller sweeps and hands off exactly as before.
                         isCancelled: () -> Bool = { false },
                         // #1498: asked ONCE, after the free sweep, when more pages need reading than
                         // ScoutReadBudget's threshold. It is handed the true count and returns what Dan
                         // chose. Defaulting to `.all` keeps every existing caller and every test reading
                         // exactly what it read before, and means a caller that cannot ask (a headless or
                         // scheduled path) never blocks on a question nobody is there to answer, which is
                         // the failure that lost twenty shows in the detached runner.
                         askReadBudget: (Int) async -> ScoutReadBudget.Choice = { _ in .all },
                         // #4275: how the whole show table is read. Every such read in this run goes through
                         // it (the history, the brand corpus, and the landing's working set), so a test can
                         // count them; nothing else in this file fetches the table.
                         // #4332 (A3): Sendable, because the brand corpus calls it off the main actor.
                         readProspectTable: @escaping ScoutLandingStore.SendableRead = ScoutService.readProspectTable,
                         // #4332: Dan's producer corrections, the corpus's other read, injected likewise.
                         readProducerOverrides: @escaping ScoutService.OverrideRead = ScoutService.readProducerOverrides,
                         // #4330 (A13): the one queue every landing waits its turn in. The sweep runs WITHOUT
                         // it; only the landing block and the tail take a token. Injected so a test can hold
                         // the store across a suspension without making every other test's landing wait.
                         landings: LandingSingleFlight = .shared,
                         // A run Dan pressed is a Dan action, and waits ahead of every scout landing; the
                         // scheduled run is a scout landing.
                         landingPriority: LandingSingleFlight.Priority = .scout,
                         // The floor the run's landing sequence is minted above, besides the store's own:
                         // the pending ingest copies, which can hold a number no landing ever saved.
                         sequenceFloor: () -> Int = { PendingScoutIngests.live.highestSequence },
                         // #4329 (A12): the Squarespace collection probe (#1503), injected so a test can drive
                         // the promotion without the network. Answers the collection's JSON body, or nil.
                         squarespaceProbe: @escaping (URL) async -> Data? = ScoutService.probeSquarespaceCollection,
                         // #4329: the landing's closing save (save one), injected so a test can make it fail
                         // (`saveLanding`), as the ingest's is.
                         saveClosing: (ModelContext) throws -> Void = { try $0.save() },
                         // #4329: handed each source's captured read-phase writes as the landing applies them,
                         // so a test can prove every branch that writes was driven. nil, which every shipping
                         // caller passes, reports nothing.
                         onApplyCaptured: ((SourceWrites) -> Void)? = nil,
                         // #4334 (A5): each landing source's own save, the entry flush's, and how a failed save
                         // is classified, injected so a test can fail one source's save and not the next (a real
                         // refusal fails every save the container makes).
                         saveSource: @escaping (ModelContext) throws -> Void = { try $0.save() },
                         saveEntry: (ModelContext) throws -> Void = { try $0.save() },
                         classifySaveFailure: @escaping (Error) -> LandingSaveFailure.Scope = LandingSaveFailure.classify,
                         // #4335 (A6): where this run keeps its landing journal (`LandingJournal`). RootView passes
                         // `.live`, and `EveryProductLandingKeepsAJournalTests` fails when a product caller does
                         // not. nil keeps none, for a test whose subject is not the journal.
                         journals: LandingJournals? = nil,
                         // #4335 (RC6): where each landed source's feed movement line is appended, after its save.
                         movementLog: any FeedMovementLog.Sink = FeedMovementLog.file,
                         // #4582: Downbeat's export and the imported booking history, the two files the run reads
                         // its clients, bookings, blocked days and history from, as the lead paste takes them
                         // (#4558). The app passes neither, so it reads the real files; every test names its own,
                         // and `TestsNameTheirLandingInputFilesTests` fails one that does not, because the default
                         // under test is one folder every test process on the Mac shares (#2097).
                         exportURL: URL = DownbeatBridge.defaultURL,
                         importedHistory: URL = LocalHistory.importedURL)
                         async throws -> Outcome {
        // History the matcher sees = any one-time legacy import + Overture's own activity,
        // so repeat-client recognition stays current as Dan sends and books (#19).
        // #3071: REQUIRED, not swallowed. An empty answer here means a repeat client is not recognised
        // as one, so a show Dan has already shot reads as cold and gets pitched as a stranger.
        // #4339 (A11): read OFF the main thread whenever nothing is pending: measured on a live store clone the
        // table read and the history built from it were 204.5 and 40.0 ms of this first hold at 1,372 shows, 812.8
        // and 203.1 at 4x. Still REQUIRED: an unreadable table refuses the run here.
        // #4558: with Downbeat's export and the blocked calendar, through `LandingInputs`, the one builder every
        // landing reads its inputs through, by its refusing read; this used to build the export read and the
        // calendar itself beside it.
        let loaded: LandingInputs.Inputs
        switch await LandingInputs.readRefusingUnreadableShowTable(exportURL: exportURL, historyURL: importedHistory,
                                                                   now: now, readProspectTable: readProspectTable,
                                                                   into: context) {
        case .success(let read): loaded = read
        case .failure(let unreadable): throw StoreReadFailure(read: .repeatClientHistory, underlying: unreadable)
        }
        let history = loaded.history
        let blocked = loaded.blocked

        // #3071: the one that matters most. An empty watchlist plans zero sources, so the scout scans
        // nothing and reports an ordinary quiet run (L98).
        let watchlist = try required(.sourceWatchlist) { try context.fetch(FetchDescriptor<WatchedSource>()) }
        let plan = SourceSchedule.plan(sources: watchlist, depth: depth, only: only, budget: budget, now: now)

        // #4330 (A13): this run's landing sequence, minted as its read phase starts, which writes nothing to
        // the store and so needs no token. Every source the landing block below lands or settles is
        // stamped with it, and a source a LATER run has already stamped higher is set aside (see there).
        // #4335: and above every landing record and every journal NAME, pending or set aside as unreadable, so
        // the number of a landing a crash interrupted before its first save is never handed out again.
        let sequence = landings.mintSequence(
            above: max(sequenceFloor(), watchlist.map(\.lastTouchedSequence).max() ?? 0,
                       (try? LandingRun.highestSequence(in: context)) ?? 0, journals?.highestSequence ?? 0))
        // #4335 (A6): this run's identity (L186), recorded in its journal before any source applies and on every
        // source it lands. A sweep has no results file to hash, so it is an id of its own, minted once here.
        let sweepID = "sweep-" + UUID().uuidString

        // The real paginating fetch, built PER SOURCE, unless a test injected its own. A known client's own
        // calendar (or a source Dan tagged as a client's) is read a full year forward to catch a returning
        // client's far-future dates (#1209); every other source keeps the shared four-month horizon
        // (#1210). Built here, not as a default argument, because a default cannot reference the `session`,
        // `now`, clients, and per-source horizon it needs. An injected fetch bypasses all of this.
        func fetchFor(_ source: WatchedSource) -> (URL, String?, String?) async throws -> FetchedPage {
            if let fetchOverride { return fetchOverride }
            let horizon = ClientHorizon.months(for: source, clients: loaded.clients)
            return { url, name, location in
                try await SourceFetcher.fetch(url, session: session, monthHorizon: horizon,
                                              now: now, sourceName: name, sourceLocation: location)
            }
        }

        var outcome = Outcome(found: 0, inserted: 0, updated: 0, skipped: 0)

        // The native sources (Carnegie, and only Carnegie). Free, synchronous, and fully ingested on
        // every run including the automatic one, so today's behavior is preserved exactly.
        //
        // A store whose #800 backfill has not run yet has no rows at all. It still scouts Carnegie, from
        // the injected extractor, so the app is never dead in the window between upgrading and the first
        // launch migration.
        let nativeSources: [WatchedSource?] = plan.native.isEmpty && watchlist.isEmpty ? [nil] : plan.native

        // #4102: every free source is READ first and LANDED together, after the html loop below, in one
        // synchronous block. Reading awaits (the network, and the classify pass off the actor), and the
        // window draws at every await, so a source landed as soon as it was read reached the screen as a
        // change of its own: the queue re-derived the whole store once per source, then again for each
        // notification that follows a save (measured in `AScoutRunDerivesTheQueueOnceTests`: four sources,
        // sixteen whole-store derivations, against four for one source). Landed together, a run is one
        // change however long Dan's watchlist grows.
        //
        // `reports` keeps the order each source was CHECKED in, so a read that lands later still sits in
        // the report where it was checked rather than at the end.
        // #4329 (A12): a checked source carries the writes its check decided, applied by the landing block.
        enum ReportSlot { case read(Int), checked(SourceResult, WatchedSource, SourceWrites) }
        var reads: [NativeRead] = []
        var reports: [ReportSlot] = []
        // Read at the first free source rather than per source, and not at all on a run that has none.
        //
        // #4334 (A5): a slot a stopped landing never reached, reported as such so it is not silence.
        var notAttempted: Set<String> = []
        func reportNotAttempted(_ slot: ReportSlot) {
            switch slot {
            case .checked(_, let source, _):
                notAttempted.insert(source.sourceId)
                outcome.sources.append(SourceResult(sourceId: source.sourceId, orgName: source.orgName,
                                                    state: .notAttempted, listingsURL: source.listingsURL))
            case .read(let i):
                let native = reads[i]
                notAttempted.insert(native.sourceId)
                outcome.sources.append(SourceResult(sourceId: native.sourceId, orgName: native.orgName,
                                                    state: .notAttempted, listingsURL: native.source?.listingsURL))
            }
        }
        // #4332 (A3): read OFF the main actor, through a background context, which reads only what is SAVED. So
        // the entry flush (`flushBeforeLanding`, A5's, the one implementation) runs first, here as well as under
        // the token below: this one so the background read sees what Dan sees, that one so no source applies
        // over an edit made while the sweep was reading. nil means the flush could not save, so the run is
        // refused by name before anything is read or applied: every source is reported not attempted, and
        // since the read phase writes nothing (A12), nothing needs undoing and the next scout reads them again.
        var corpusRead: CorpusRead?
        // #4338 (A10): how many of this landing's entry flushes saved pending edits, for its record.
        var entryFlushSaves = 0
        func corpus() async -> CorpusRead? {
            if let corpusRead { return corpusRead }
            let flush = flushBeforeLanding(context, save: saveEntry)
            if flush == .saved { entryFlushSaves += 1 }
            if let refused = flush.refusal {
                outcome.landingStop = refused
                for slot in reports { reportNotAttempted(slot) }
                for source in nativeSources.compactMap({ $0 }) + plan.fetch
                where !notAttempted.contains(source.sourceId) {
                    notAttempted.insert(source.sourceId)
                    outcome.sources.append(SourceResult(sourceId: source.sourceId, orgName: source.orgName,
                                                        state: .notAttempted, listingsURL: source.listingsURL))
                }
                outcome.clientListWarning = DownbeatBridge.warningText(for: loaded.exportHealth)
                return nil
            }
            let read = await venueBrandCorpusOffMain(container: context.container, read: readProspectTable,
                                                     readOverrides: readProducerOverrides)
            corpusRead = read
            return read
        }
        for source in nativeSources {
            // #1237: each native source reads through its own extractor (OPERA/VenueTix via the registry),
            // falling back to the injected one for Carnegie and any row the registry does not own.
            let resolved = extractorRegistry(source) ?? extractor
            guard let brands = await corpus() else { return outcome }
            reports.append(.read(reads.count))
            reads.append(await readNative(source, extractor: resolved, clients: loaded.clients,
                                          history: history, corpus: brands, now: now))
        }

        // The html sources: fetch, hash, and decide. Nothing is READ here: this loop is free, and it runs
        // identically on the daily automatic scout and on one Dan started.
        var toRead: [(source: WatchedSource, page: FetchedPage)] = []
        for (index, source) in plan.fetch.enumerated() {
            // #1037: Dan's cancel, checked between sources. The sweep stops cleanly here rather than mid-
            // fetch (an await cannot be interrupted anyway), and the launch guard below then hands off no
            // read, so a cancelled run leaves nothing behind for a detached process to finish.
            if isCancelled() { break }
            let (result, page, checkWrites) = await check(source, fetch: fetchFor(source), probe: squarespaceProbe,
                                                          depth: depth, now: now)
            // #1189: advance the manual scout's OWN fairness clock, but ONLY on a run Dan started. The
            // free daily watch-only run leaves it untouched (it advances only the shared lastCheckedAt,
            // inside SourceCheck.decide), so unlike lastCheckedAt it is not flattened every morning and a
            // source that did not get its turn is genuinely first in line on the next press.
            //
            // #1498: stamped where the source is actually READ, not here where it is merely fetched. The
            // fetch is now uncapped, so stamping on a fetch would put an identical timestamp on all 62
            // sources every press and flatten this clock into one big tie, which is precisely the coverage
            // loss #1189 fixed for lastCheckedAt. Keyed to the read, it also finally matches its own name.
            // #1295 / #1529: the fetched page carries the structure it was built from (a TicketTailor
            // widget's embedded JSON, or the ticketing feed body a hop landed on), so it is parsed NATIVELY
            // here, for free, instead of paying a detached read to look at a document Overture wrote itself.
            // readNative gives either one the SAME usable-event guard and #887 cancellation tolerance every
            // native feed gets, so this can never falsely mark shows gone.
            if let page, let inlineExtractor = inlineNativeExtractor(for: page, source: source, now: now) {
                // The pending hash/months belong to the detached ingest, which a native parse never runs,
                // so clear them either way, or the reattach path would believe a read is still owed. Mark
                // the bytes INGESTED (lastContentHash) only on a successful parse, the same state the
                // detached ingest sets on success, so the next run skips an unchanged page; a drift/parse
                // failure leaves lastContentHash on the old bytes so the next run re-reads and it stays
                // visibly failing until fixed.
                //
                // #4329 (A12): captured with the check's own writes and applied by the landing block.
                var inline: [SourceWrites.Step] = [.pendingRead(hash: nil, months: [])]
                // #1529: remember that this row's shows come from a ticketing feed, so the Sources sheet can
                // ask for the room on THIS row (TicketingFeedRead.needsVenueName) instead of on all of them.
                if let feed = page.ticketingFeedURL, page.followedTicketLinkFrom != nil {
                    inline.append(.ticketingFeed(feed))
                }
                guard let brands = await corpus() else { return outcome }
                reports.append(.read(reads.count))
                reads.append(await readNative(source, extractor: inlineExtractor, clients: loaded.clients,
                                              history: history, corpus: brands, now: now,
                                              // #1529: a feed parse follows no per-event detail page, so a
                                              // row the feed named no venue for is the feed's own gap, never
                                              // a page Overture failed to read (#1472's rule, applied to the
                                              // READ that happened rather than to the kind on the row: these
                                              // two paths ingest natively while the row still says .html).
                                              venueGapsAreStructural: true,
                                              // Marked read only once its shows have landed (#4102).
                                              markReadAs: page.contentHash,
                                              writes: checkWrites.appending(SourceWrites(.readInline, inline))))
            } else {
                reports.append(.checked(result, source, checkWrites))
                if let page { toRead.append((source, page)) }
            }
            // #1034: the native-phase heartbeat. Fired for every fetched source, changed or not, so the
            // takeover modal's count advances through the whole sweep rather than stalling on the ones
            // that happened not to be re-read.
            onNativeProgress(source.orgName, index + 1, plan.fetch.count)
        }

        // #4102: every read lands HERE, in one block with no await in it, in the order the sources were
        // checked. Each still saves and reconciles on its own exactly as before, so a source whose save
        // fails carries no report and marks nothing gone (#499, #888), and a source whose read failed
        // lands nothing at all: it was recorded on its row and reported when it was read.
        //
        // #4275: and every source judges against ONE read of the stored shows, built here, after the last
        // await, and kept current as each source lands (`ScoutLandingStore`). It used to be two whole table
        // fetches per source plus one per source's reconcile.
        //
        // #4330 (A13): the store is taken HERE, after the last await of the read phase, and released
        // straight after this block's save, so the sweep above and the read budget question below never
        // hold it. A refusal at the deadline throws before anything below is applied; the pages this run
        // read keep their unread state, so the next scout reads them again.
        let landingToken = try await landings.begin(
            entryPoint: .runScoutLanding, priority: landingPriority,
            deadline: LandingSingleFlight.Deadline.runScoutLanding,
            onWait: { onNativeStep(.waitingForTheLandingInProgress) })
        defer { landingToken.end() }
        // The first thing done under the token: re-validation. A source whose `lastTouchedSequence` is now
        // above this run's was landed by a later run after this one read it, so this run's reading of it is
        // the older one. It is set aside whole: its captured writes are dropped (its fetch health, its failure
        // streak, its pending hash), its shows are not applied, its page hash is not promoted and its page is
        // not handed to the reader, so the row stays exactly as the later run left it and the next scout reads
        // the page again. #4329 (A12): the read phase above wrote NOTHING, which is what makes "set aside
        // whole" true; every write it decided is applied here, after this check, or not at all.
        func supersededSinceRead(_ source: WatchedSource?) -> Bool {
            (source?.lastTouchedSequence ?? 0) > sequence
        }
        var setAside: Set<ObjectIdentifier> = []
        func setAsideAndReport(_ source: WatchedSource) {
            setAside.insert(ObjectIdentifier(source))
            outcome.sources.append(SourceResult(sourceId: source.sourceId, orgName: source.orgName,
                                                state: .superseded, listingsURL: source.listingsURL))
        }
        func landCaptured(_ writes: SourceWrites, on source: WatchedSource) {
            source.lastTouchedSequence = sequence
            source.applyCaptured(writes)
            onApplyCaptured?(writes)
        }
        // Sources this run leaves waiting to be read, reported as `.deferred`: the one word for that fact,
        // whether the budget, Dan's answer or a failed save one is why (see the tail).
        func reportWaiting(_ sources: [WatchedSource]) {
            for source in sources {
                outcome.sources.append(SourceResult(sourceId: source.sourceId, orgName: source.orgName,
                                                    state: .deferred, listingsURL: source.listingsURL))
            }
        }
        // #4334 (A5): the ENTRY FLUSH, the first thing done holding the store. A failed source's save is put
        // back to its COMMITTED values, which are the values from just before this landing only if nothing it
        // can touch was pending when the landing began, so anything pending is saved first. A flush that
        // cannot save REFUSES the landing by name before anything is applied (L667): the edits stay exactly
        // as they were for Dan's own save path, and every page keeps its unread state for the next scout.
        let entryFlush = flushBeforeLanding(context, save: saveEntry)
        if entryFlush == .saved { entryFlushSaves += 1 }
        if let refused = entryFlush.refusal {
            outcome.landingStop = refused
            for slot in reports { reportNotAttempted(slot) }
            outcome.clientListWarning = DownbeatBridge.warningText(for: loaded.exportHealth)
            return outcome
        }
        // #4335 (A6): the landing's record of itself, written before anything is applied, after the last await
        // of the read phase. A journal that cannot be written refuses the landing by name (L258); every page
        // keeps its unread state for the next scout, as the entry flush's refusal leaves it.
        let journal = LandingJournal(
            runIdentity: sweepID, sequence: sequence, entryPoint: .runScoutLanding,
            sources: reports.map { slot -> LandingJournal.Source in
                switch slot {
                case .checked(_, let source, _): return .init(sourceId: source.sourceId, pageHash: nil)
                case .read(let i): return .init(sourceId: reads[i].sourceId, pageHash: reads[i].markReadAs)
                }
            },
            now: now)
        if let journals {
            do {
                try journals.start(journal)
            } catch {
                outcome.landingStop = .journalNotWritten(why: HandoffDecodeFailure.describe(error))
                for slot in reports { reportNotAttempted(slot) }
                outcome.clientListWarning = DownbeatBridge.warningText(for: loaded.exportHealth)
                return outcome
            }
        }
        let landing = ScoutLandingStore(context: context, read: readProspectTable, saveSource: saveSource,
                                        classify: classifySaveFailure)
        // The landing record, inserted at the start of the synchronous landing block (the 2026-09-29 L55
        // decision) and carried by its first save; a settled row to the revert, so a source whose save fails
        // is put back without taking it.
        let run = LandingRun.begin(runIdentity: sweepID, sequence: sequence, entryPoint: .runScoutLanding,
                                   startedAt: now, in: context)
        // #4338: always set, so a record this build wrote carries a count (0 included) and one it did not carries
        // none; and added to, so a record an earlier attempt of the same run saved keeps its count.
        run.entryFlushSaves = (run.entryFlushSaves ?? 0) + entryFlushSaves
        // #4338: read now, while the record is certainly in the context, for whether a failed save is retried.
        let attemptsBefore = run.attemptCount
        landing.noteSettled(run)
        for slot in reports {
            // #4334: a landing a failed save stopped lands nothing after it (decision 3).
            if outcome.landingStop != nil {
                reportNotAttempted(slot)
                continue
            }
            switch slot {
            case .checked(let result, let source, let writes):
                if supersededSinceRead(source) {
                    setAsideAndReport(source)
                    continue
                }
                landCaptured(writes, on: source)
                // #4334: a settled source's writes are not the next source's turn, so that source's failed
                // save leaves them pending for the save after it.
                landing.noteSettled(source)
                outcome.sources.append(result)
            case .read(let i):
                let native = reads[i]
                if supersededSinceRead(native.source), let source = native.source {
                    setAsideAndReport(source)
                    continue
                }
                if let source = native.source {
                    landCaptured(native.writes, on: source)
                    // A read that failed lands nothing, so its writes are settled ones, like a checked slot's.
                    switch native.read {
                    case .failed: landing.noteSettled(source)
                    case .listed:
                        // #4335: which run landed this source, in the same save as its shows, so the store says
                        // which sources an interrupted landing finished. A failed save puts these back with them.
                        source.lastLandedRunID = sweepID
                        source.lastLandedSequence = sequence
                    }
                }
                // #4335: marks a natively read page read itself, in the same save as its shows.
                let landed = landNative(native, clients: loaded.clients, history: history, blocked: blocked,
                                        now: now, landing: landing, movementLog: movementLog, into: context)
                outcome.merge(landed)
            }
        }
        // A page set aside above is not handed to the reader either: its pending hash was never recorded, so
        // an ingest of it would have nothing to promote, and the later run that overtook it owns that page.
        toRead.removeAll { setAside.contains(ObjectIdentifier($0.source)) }

        // #4325: the last source's reconcile, and its feed health, saved here rather than left to autosave.
        //
        // #4329 (A12): SAVE ONE, straight after the landing loop and BEFORE the read budget question, which can
        // wait on Dan for as long as he leaves it open. It carries every landing source and every settled
        // source's captured writes, so nothing sits unsaved across that question (ScopeMemo serves a refetch
        // only while the main context holds nothing unsaved, and Phase C's clean-at-every-yield invariant needs
        // it there too). A failed save one STOPS the landing: it is recorded as "could not be saved" and nothing
        // below runs, so no read is handed off on a pending hash the store never took. Putting the unsaved
        // writes back first is A5's revert, which is not built yet; until it is, they stay pending exactly as a
        // failed per source save leaves them (#499).
        //
        // What it does NOT stop is the report. This run's findings are still true and still Dan's to see: the
        // per source results above, the sources still waiting to be read, and the past client list's health.
        // The pages queued for reading were never handed over, so they are reported as waiting rather than as
        // being read. Everything the tail WRITES (the handoff, the fairness clock, the booking reconcile, the
        // blocked town retirement, the completed scout timestamp) stays stopped, since it would build on
        // writes the store never took.
        //
        // #4334 (A5): a landing a failed source save STOPPED takes the same way out, after saving what the
        // sources before the failure left pending (a store that refused one save will usually refuse this
        // one too, and then it is put back like any failed closing save). A landing that stopped because a
        // source could NOT be put back makes no further save at all, so nothing it could not restore is saved.
        let stop = outcome.landingStop
        let notReverted: Bool = { if case .notReverted? = stop { return true }; return false }()
        // #4335: the landing record is stamped landed in save one, when every source's save went through; a
        // failed save one puts the stamp back with everything else it carried.
        let landedEverySource = stop == nil && !outcome.saveFailed
        if landedEverySource { run.landedAt = now }
        if notReverted || !saveLanding(landing, into: context, save: saveClosing) || stop != nil {
            outcome.saveFailed = true
            // #4338 (A10): retried only when the recovery really will: the journal is kept and attempts are left.
            outcome.retriedByRecovery = LandingRecovery.willRetry(journalKept: journals != nil,
                                                                  attempts: attemptsBefore)
            let neverHandedOver = Set(toRead.map { $0.source.sourceId })
            outcome.sources.removeAll { $0.state == .queuedForReading && neverHandedOver.contains($0.sourceId) }
            reportWaiting(SourceSchedule.waitingToRead(deferred: plan.deferred)
                          + toRead.map(\.source).filter { !notAttempted.contains($0.sourceId) })
            outcome.clientListWarning = DownbeatBridge.warningText(for: loaded.exportHealth)
            return outcome      // save one failed: the landing stops here
        }
        // #4330: released here, before the read budget question.
        landingToken.end()

        // ONE batched detached run for every page that changed, never N subprocesses: one hung source
        // must not be able to block the marker guard or leave a bare indefinite spinner. Only reachable
        // at `.readChanged`, because `check` only ever hands back a page to read on a run Dan started.
        //
        // A failure to LAUNCH is not swallowed, and it is deliberately NOT recorded as a failure of the
        // sources. The runner not being configured is the first thing Dan will hit, and those twelve
        // calendars are perfectly healthy: it is the app that cannot read them. Marking them "failing"
        // would send him to debug twelve working websites. It is a run-level problem, named as one, and
        // every source keeps its pending hash and its unread flag so the next run reads them all once
        // the runner is fixed. What must never happen is silence: a watchlist that quietly never reads
        // anything is indistinguishable from one where every calendar happens to be quiet.
        // #1037: a cancelled run launches no read. Whatever pages the sweep pinned before Dan stopped it
        // are simply not handed off, so no detached process starts to be cancelled a moment later. The
        // sources keep their pending hash and unread flag, exactly as an un-launched run does, so the
        // next scout reads them.
        // #1498: the one point in the run where money is about to be spent, and so the one place worth
        // asking about. Everything above was free (fetch, hash, health), which is why the count handed to
        // the question is the TRUE number of pages that need reading rather than a guess from last night's
        // hashes. At or under the threshold nothing is asked and the run just goes, exactly as before.
        //
        // A run Dan did NOT start can never reach here: `check` only ever hands back a page to read at
        // .readChanged, so toRead is empty on the free daily watch and the ask is unreachable from it.
        // A scoped "read this one" run cannot reach it either, being a single source.
        var declined: [WatchedSource] = []
        // #4339 (A11): whether anything could have landed between this run's landing block and its tail. Only
        // when nothing could does the tail take its rows from the landing's working set; otherwise it fetches.
        var tailMayHaveBeenInterleaved = false
        if case .ask(let pending) = ScoutReadBudget.decide(pending: toRead.count), !isCancelled() {
            tailMayHaveBeenInterleaved = true
            let chosen = ScoutReadBudget.pagesToRead(toRead, choice: await askReadBudget(pending))
            // Whatever he did not take keeps its unread flag and its older fairness clock, so it is not
            // lost: it is reported as waiting below and sorts to the front of the next press. Backing out
            // entirely is a real answer and lands here with everything declined.
            declined = toRead.dropFirst(chosen.count).map(\.source)
            toRead = chosen
        }

        // #4330 (A13): the tail touches the store (the fairness clock, the booking reconcile, the blocked
        // town retirement), so it holds a second, short token of its own, taken after the read budget
        // answer and released after its own save below. A refusal here throws before the handoff: the
        // shows above are already saved, and the pages keep their unread state for the next scout.
        let tailToken = try await landings.begin(
            entryPoint: .runScoutTail, priority: landingPriority,
            deadline: LandingSingleFlight.Deadline.runScoutTail,
            onWait: {
                tailMayHaveBeenInterleaved = true
                onNativeStep(.waitingForTheLandingInProgress)
            })
        defer { tailToken.end() }
        // #4339 (A11): the tail's two whole table fetches (the booking reconcile's, the town retirement's) were
        // 200 and 216 ms on the main thread at 1,372 shows, 801 and 866 at 5,500, measured inside the run by
        // `LandingFirstHoldProbeTests`. The landing's working set already holds every show as it now stands,
        // so with no await between the landing block and here that could have let another landing in, both are
        // handed it instead. With one (the read budget question, or a wait for the tail's token), the table is
        // read afresh, ONCE for both, so a show another landing added meanwhile is still judged. A read that
        // fails is recorded on the run and judges nothing, where each pass used to read it as an empty store
        // on its own (`(try? fetch) ?? []`, L215).
        let tailRows: [Prospect]
        do {
            tailRows = tailMayHaveBeenInterleaved ? try readProspectTable(context) : try landing.rows()
        } catch {
            tailRows = []
            if !outcome.degradedReads.contains(.reconcileStoredShows) {
                outcome.degradedReads.append(.reconcileStoredShows)
            }
        }

        if !toRead.isEmpty && !isCancelled() {
            onNativeStep(.handingPagesToTheReader)
            do {
                try queueForReading(toRead, pin: pin, launch: launch)
                // #1498: the fairness clock moves for the sources this run actually READ, and only those.
                // See the fetch loop above for why it can no longer be stamped there.
                for (source, _) in toRead { source.lastManualReadAt = now }
            } catch {
                outcome.extractLaunchFailure = extractLaunchMessage(error)
            }
        }

        // Deferred is a visible state, never silence, but only for a source that actually has something
        // unread waiting. A source over budget with NOTHING new to read is fully covered: the free daily
        // watch-only run fetches and hashes it every night regardless of budget, so it can never go
        // unchecked for weeks. Surfacing the unchanged ones too made "N venues still waiting" a fixed
        // total-minus-budget that never converged however many times Dan pressed Run again
        // (SourceSchedule.waitingToRead).
        //
        // #1498: `declined` joins them, and is the same state for the same reason. A page Dan chose not to
        // read this press is waiting exactly as an over-budget one was, so it is reported through the one
        // path that already exists rather than gaining a second word for the same fact. It is NOT filtered
        // by waitingToRead: that filter exists to drop UNCHANGED sources a budget skipped, and every source
        // here reached toRead, which means it has something to read by definition.
        reportWaiting(SourceSchedule.waitingToRead(deferred: plan.deferred) + declined)

        outcome.clientListWarning = DownbeatBridge.warningText(for: loaded.exportHealth)

        // Reconcile bookings from Downbeat: a contacted prospect that's now a Downbeat
        // client gets outcome booked automatically (#41).
        // #1434/#1435: one generic reconcile pass over prospects AND inquiries (suggestion-only, but
        // claiming a booking to win the tie-break). `try?` yields none on a container predating Inquiry.
        // #1960: built inside the call, so an unhealthy export refuses before the store is swept.
        onNativeStep(.checkingBookings)
        // #4329 (A12): the booking reconcile and the blocked town retirement each used to save on their own;
        // both fold into the tail's one save below (save two), which carries them with the fairness clock.
        _ = DownbeatBooking.reconcileBooked(entities: DownbeatBooking.bookingEntities(prospects: tailRows, in: context),
                                            clients: loaded.clients, bookings: loaded.bookings,
                                            health: loaded.exportHealth, now: Date())
        // #1238: retire any show a blocked town this run may have (re-)surfaced, so blocking a town keeps
        // future scouts out too, not just the shows present when Dan blocked it. Idempotent.
        onNativeStep(.clearingBlockedTowns)
        _ = ExcludedTownRetirement.run(rows: tailRows, in: context)
        onNativeStep(.saving)
        // #4330 / #4329: SAVE TWO, the tail's own, so the fairness clock, the booking reconcile (#41) and the
        // retirement are on disk before its token is released, rather than left to autosave. Its own save,
        // so a failure here never touches save one, which is already in the store. #499: a failure is
        // recorded as `saveFailed`, and #4334 (A5): the tail's writes are put back first, so the next scout
        // does them once rather than on top of a pending copy.
        if context.hasChanges {
            do {
                try saveClosing(context)
            } catch {
                landing.revertFailedSave(closing: true)
                outcome.saveFailed = true
            }
        }
        // #4338: decided once, from the outcome the landing ends with, as the ingest decides it: a failed tail, and a
        // source level failure the landing carried on from, both keep the journal for the recovery, and the second
        // was never seen by a flag set only where a save failed (the review of 29db676).
        outcome.retriedByRecovery = outcome.saveFailed
            && LandingRecovery.willRetry(journalKept: journals != nil, attempts: attemptsBefore)
        // #4335: the run's journal is spent only once the tail's writes are in the store too, so a run stopped
        // in the tail keeps it for the recovery, which then finds every source landed and only the tail left.
        if landedEverySource && !outcome.saveFailed { journals?.retire(journal) }
        tailToken.end()
        // Record that a scout completed, so the masthead can show freshness (#35).
        recordScout(at: Date(), in: defaults)
        return outcome
    }

    // #1295 / #1529: an html source whose fetched page came back carrying the structure behind it reads
    // natively, for free, rather than paying to have an AI read a document Overture synthesized. Returns the
    // extractor for such a page, or nil for the ordinary page (which goes on to the paid read as before).
    // One place, so the two shapes cannot drift apart on how they are ingested and counted.
    private static func inlineNativeExtractor(for page: FetchedPage, source: WatchedSource,
                                              now: Date) -> (any SourceExtractor)? {
        if let widgetHTML = page.ticketTailorWidgetHTML {
            return TicketTailorExtractor(
                fetchEvents: {
                    try TicketTailorCalendar.upcoming(
                        TicketTailorCalendar.parseWidget(widgetHTML), now: now)
                },
                venueName: source.orgName, location: source.venueLocation)
        }
        return TicketingFeedRead.extractor(for: page, source: source, now: now)
    }

    // #4102: one free source, READ but not yet landed. What `readNative` hands to `landNative`.
    //
    // The two halves travel as one value because they are one source's read: the events, what the guard
    // made of them, the feed health they are judged against and the classify pass run over them. Handed
    // over as loose parameters, a caller could land one source's pass with another's health.
    struct NativeRead {
        enum Read {
            // The extractor threw. Already recorded on the row and already a finished report, because a
            // source that could not be read has nothing to land.
            case failed(Outcome)
            case listed(Listed)
        }
        struct Listed {
            let usable: [ExtractedEvent]
            let rejection: RejectionCounts
            let health: FeedReconcile.FeedHealthState
            let preClassified: PreClassified
        }
        let source: WatchedSource?
        let sourceId: String
        let orgName: String
        let read: Read
        // #1295 / #1529: an html page read natively is marked READ (its hash stamped as ingested) only once
        // its shows have landed, so the stamp can never describe bytes whose shows never reached the store.
        let markReadAs: String?
        // #4329 (A12): what reading this source decided to write on its row (the check's own writes for an
        // inline page, and the failure when the extractor threw), applied by the landing block.
        let writes: SourceWrites
    }

    // One native source, READ: extract and classify, both awaited, and NOTHING written to the store. Its
    // failure is captured and reported, never thrown, so a source that is down cannot cost Dan the rest of
    // his watchlist. #4329 (A12): the row's own failure is a captured write too, applied by the landing block.
    //
    // #4102: this used to be `runNative`, which also UPSERTED, one source at a time between the awaits of
    // the sweep, so every source reached the screen as its own change and the queue re-derived the whole
    // store for each one (measured: four sources, sixteen derivations, against four for one source). The
    // writes now happen in `landNative`, for every source at once, at the end of the sweep.
    private static func readNative(_ source: WatchedSource?, extractor: any SourceExtractor,
                                   clients: [DownbeatClient], history: [HistoryRecord],
                                   corpus: (brands: ProducerGate.VenueBrands, degradedReads: [StoreRead]),
                                   now: Date,
                                   // #1529: overrides the row's own answer for a read that ingested natively
                                   // while the row still says .html. nil keeps the kind's rule (SourceKind
                                   // .venueGapsAreStructural), which is right for every other caller.
                                   venueGapsAreStructural: Bool? = nil,
                                   markReadAs: String? = nil,
                                   writes: SourceWrites = .none) async -> NativeRead {
        let sourceId = source?.sourceId ?? WatchedSource.carnegieId
        let orgName = source?.orgName ?? "Carnegie Hall"

        let events: [ExtractedEvent]
        do {
            events = try await extractor.extract().events
        } catch {
            // Typed, named, on the row, and the loop carries on. `ScoutFailure` used to present this as
            // the death of the whole scout, because with one source it was.
            let failure = SourceFailure.fetch(fetchError(from: error))
            // #1759: through the one shared recorder, so a native feed that has been throwing for a week
            // carries the same history a failing html page does. The row is optional here, and a run
            // handed no row still records nothing at all, exactly as it already did.
            let failed = source == nil ? writes
                : writes.appending(SourceWrites(.nativeReadFailed, [.failedRead(failure, at: now)]))
            var outcome = Outcome(found: 0, inserted: 0, updated: 0, skipped: 0)
            outcome.sources = [SourceResult(sourceId: sourceId, orgName: orgName, state: .failed(failure),
                                            listingsURL: source?.listingsURL)]
            return NativeRead(source: source, sourceId: sourceId, orgName: orgName, read: .failed(outcome),
                              markReadAs: markReadAs, writes: failed)
        }

        // #801: this source's feed health lives on its own row, seeded from the three old global keys by
        // WatchedSourceBackfill. A merged baseline could never tell one source's dead scraper from
        // another's big season.
        let health = FeedReconcile.FeedHealthState(
            baseline: source?.baselineFeedCount ?? 0,
            degradedStreak: source?.degradedStreak ?? 0,
            lastDegradedCount: source?.lastDegradedCount ?? 0)

        // #987: the SAME usable-event rule the agent path applies at its boundary. This path used to hand
        // the raw feed straight to applySweep and never see the guard, so the same show got a different
        // verdict depending on which door it came through, and nobody chose that.
        //
        // LIVE-STORE-CLAIM verified=2026-07-18 measure="live rows with a missing, placeholder, or numeric-id venue"
        // A no-op on today's data (0 of 313 live rows have a missing, placeholder, or numeric-id venue,
        // because Carnegie always names a hall), and that is the point: it is insurance, and it means
        // #979's place-aware venue rule can be written ONCE instead of forked across two paths. The
        // guard's argument does not care which door an event used: a prospect with no venue puts the
        // wrong place in Dan's email, and nothing downstream can catch it. A structured feed that stops
        // naming a facility produces exactly that, silently.
        let usable = events.map(ExtractedEventGuard.placed)   // #1214: carry a rescued outdoor venue on
            // #1766: and drain a presenter that is really the room, BEFORE the row becomes a prospect.
            // Runbook rule 3d asks for it; this is the boundary that does not merely ask.
            .map(ExtractedEventGuard.presenterThatIsNotTheRoom)
            .filter(ExtractedEventGuard.isUsable)
        // #1032: the drops split by family (venue vs title), the SAME helper the agent door counts
        // through, so the two paths can never disagree. `unreadTotal` is the tolerance-gate count; the title
        // share travels on so the Sources note names a titleless drop correctly rather than "no venue".
        //
        // #1472: this path's venue gaps are the SOURCE'S OWN blank fields, not pages Overture failed to read.
        // A native feed parses structured rows and never hops to a per-event detail page, so there is no page
        // that could have failed (SourceKind.venueGapsAreStructural is where that is decided, once). Those rows
        // are counted apart from `unreadTotal` and their listing links travel to the reconcile below as still
        // listed, which is what keeps a stored show safe when its own row goes blank.
        let kind = source?.kind ?? .algolia
        let rejection = ExtractedEventGuard.rejectionCounts(
            for: events, venueGapsAreStructural: venueGapsAreStructural ?? kind.venueGapsAreStructural)

        // #3884: the per event classify and match loop is pure over values, so it is awaited OFF the main
        // actor; only the upserts in `landNative` need the context. `applySweep` is `@MainActor` and
        // synchronous, so one source's whole match pass used to be one uninterrupted block of main thread
        // work with the window unable to draw: measured over the 127 second scout window of 2026-09-13
        // 22:25:05 EDT, 97.4 seconds of recorded main thread stall inside it, the longest 27.2 seconds.
        //
        // The corpus it classifies against is read ONCE per run by the caller (#4102), rather than once per
        // source: a whole table fetch, measured at 158.8 ms over 1,238 rows, per source, on the main thread.
        // It is the store as it stood before this run landed anything, because nothing lands until every
        // source has been read. Before #4102 a later source saw an earlier source's new shows in it; the
        // difference is one run's new shows, and the next run's corpus holds them.
        let classifiedPass = await ScoutClassify.offTheCallersActor(
            events: usable, clients: clients, history: history,
            venueBrands: corpus.brands, sourceIds: [sourceId])
        return NativeRead(source: source, sourceId: sourceId, orgName: orgName,
                          read: .listed(.init(usable: usable, rejection: rejection, health: health,
                                              preClassified: PreClassified(result: classifiedPass,
                                                                           degradedReads: corpus.degradedReads))),
                          markReadAs: markReadAs, writes: writes)
    }

    // #4102: one source's read, LANDED: upsert, reconcile, and fold the run into the row's feed health.
    // Synchronous on purpose, and the caller lands every source of a sweep in one go, with no await
    // between them, so the screen sees the whole run as ONE change rather than one per source.
    private static func landNative(_ native: NativeRead, clients: [DownbeatClient], history: [HistoryRecord],
                                   blocked: BlockedCalendar, now: Date, landing: ScoutLandingStore,
                                   movementLog: any FeedMovementLog.Sink,
                                   into context: ModelContext) -> Outcome {
        let listed: NativeRead.Listed
        switch native.read {
        case .failed(let outcome): return outcome
        case .listed(let read): listed = read
        }
        let source = native.source
        let usable = listed.usable
        let rejection = listed.rejection
        let health = listed.health
        let rejectedCount = rejection.unreadTotal

        // The report is judged against what the source stood at BEFORE this run's bookkeeping below.
        let feed = FeedCheck(sourceId: native.sourceId,
                             baseline: health.baseline,
                             // No row yet means no history, so it is treated as still in its warmup: it
                             // can find and rank shows but cannot mark any of them gone, which is exactly
                             // what "we have no feed history to judge an absence against" should mean.
                             successfulCheckCount: source?.successfulCheckCount ?? 0,
                             // #987/#887: guarding this path without this line would have SHIPPED the bug
                             // it was meant to prevent. A dropped event is absent from the feed the
                             // reconcile reads, so a run that threw events away is indistinguishable from
                             // one whose shows were cancelled (#897/#917's live bug class). Handing the
                             // count over lets #887's tolerance gate forbid this run from concluding that
                             // anything is gone. It may still add and update.
                             rejectedCount: rejectedCount,
                             // #1472: the blank-venue rows this run saw, so the reconcile treats their shows as
                             // still listed. Without this the exemption above would be the #887 bug it was
                             // meant to prevent: a Met production whose venue field goes blank between runs
                             // would look exactly like one that was cancelled.
                             structuralGapURLs: rejection.structuralGapURLs,
                             structuralGapDates: rejection.structuralGapDates)

        // Fold this run into the source's own feed-health state: a full feed re-baselines immediately,
        // and a feed that stays degraded at a stable smaller level across selfHealThreshold scouts
        // re-baselines too, so a genuine sustained calendar shrink self-heals without one bad fetch
        // ratcheting the baseline down (#150/#152).
        //
        // #987: the USABLE count, matching the agent path, which baselines on what came out of its guard
        // rather than what went in. Baselining on the raw feed while ingesting the usable subset would
        // make every guarded run look like a shrinking calendar.
        //
        // #4335 (A6): written BEFORE `applySweep`'s save, with the page's hash marked read, so that one save
        // carries this source's shows AND its bookkeeping, or (failed, and put back by A5's revert below) none
        // of them, exactly as the ingest's `land` does. They used to follow the save and ride the next source's,
        // and its feed movement line was appended before the save that carried it. The line is appended once
        // that save has succeeded (RC6).
        let movement = recordCheck(on: source, events: usable.count, health: health, now: now,
                    // #891/#987: so a native feed that stopped naming venues says so on the Sources
                    // sheet, exactly as an unreadable HTML source does, instead of going quiet.
                    unreadable: rejectedCount,
                    // #1032: the title share, so the note never calls a titleless drop "no venue".
                    titleUnreadable: rejection.titleRelated,
                    // #1472: the source's own blank-venue rows, disclosed on the row as a plain fact rather
                    // than counted as a reading failure that would cost it its cancelling.
                    structuralGaps: rejection.structuralGapCount,
                    // #1471: WHICH shows those were, so the sheet can name them instead of leaving Dan to
                    // find the offending row in the raw feed himself.
                    droppedShows: rejection.droppedShows,
                    // #986/#1005: how many kept shows named WHERE they are, by the SAME rule the agent
                    // path uses. Wired here so this path feeds the placement detector too. (#1029 removed
                    // the Dan-facing line the count fed; the count still records for #970's drift check.)
                    placed: SourcePlacement.placedCount(locations: usable.map(\.location)))
        // #1295 / #1529: an html page read natively is marked READ only together with its shows: here, in the
        // same save, so the stamp can never describe bytes whose shows never reached the store.
        if let hash = native.markReadAs, let source {
            source.lastContentHash = hash
            source.hasUnreadChanges = false
        }

        // #888 part B: applySweep, because this IS a single-source sweep and it must still reconcile its
        // own report. `apply` alone no longer reconciles, and using it here would make Carnegie silently
        // stop marking anything gone: nothing would fail, shows would just quietly linger forever.
        // #3884: handed the pass `readNative` already ran off the actor, so only the upserts run here.
        var outcome = applySweep(
            events: usable, clients: clients, history: history, blocked: blocked, feed: feed,
            // #1302: derive applySweep's upcoming-only 'today' from THIS run's now, not the wall clock.
            // Without it a scout given an injected now (a test, or any non-real clock) had its events pass
            // the extractor's own now-relative upcoming filter only to be dropped again by applySweep
            // against the real day, so a native-feed run was never fully time-controllable.
            today: QueueModel.easternToday(now),
            // #4331: and the stamp of every row it changes, from the same instant.
            now: now,
            sourceIds: [native.sourceId], preClassified: listed.preClassified, landing: landing,
            into: context)

        // #4334 (A5): the #499 rule, which this path broke. A source whose save failed is PUT BACK, with the
        // writes its read captured and (#4335) its bookkeeping and its read mark, and it is reported
        // `.saveFailed`, never `.ingested`, so its page keeps its unread state. Its counts are not carried: none
        // of its shows is in the store. No movement line is appended for it.
        if outcome.saveFailed {
            var failed = Outcome(found: 0, inserted: 0, updated: 0, skipped: 0)
            failed.saveFailed = true
            failed.degradedReads = outcome.degradedReads
            failed.landingStop = isolateFailedSave(of: native.orgName, scope: outcome.saveFailureScope,
                                                   landing: landing)
            failed.sources = [SourceResult(sourceId: native.sourceId, orgName: native.orgName, state: .saveFailed,
                                           hadBaseline: health.baseline > 0, listingsURL: source?.listingsURL)]
            return failed
        }
        if let movement { movementLog.append(movement) }

        outcome.sources = [SourceResult(sourceId: native.sourceId, orgName: native.orgName,
                                        state: .ingested(found: usable.count),
                                        hadBaseline: health.baseline > 0,
                                        listingsURL: source?.listingsURL)]
        return outcome
    }

    // #1503: whether this source should be promoted to the native Squarespace feed. Only an .html source is
    // a candidate (the others already ingest natively), and the cheap marker check runs first so no request
    // is spent on a page that is obviously not Squarespace. A probe that fails for any reason simply leaves
    // the source exactly as it was, on the path that already works. #4329 (A12): it only ANSWERS; the
    // promotion itself is a captured write the landing block applies (`check`).
    private static func shouldPromoteToSquarespace(_ source: WatchedSource, page: FetchedPage,
                                                   probe: (URL) async -> Data?) async -> Bool {
        // The cheap half first, so no request is spent on a page that is obviously not Squarespace.
        guard source.kind == .html,
              SquarespaceCalendar.looksLikeSquarespace(page.normalizedHTML),
              let listings = source.listingsURL, let url = URL(string: listings) else { return false }
        // A probe that fails for ANY reason yields nil, which shouldPromote reads as "leave it alone".
        let jsonBody = await probe(SquarespaceCalendar.jsonURL(for: url))
        return SquarespaceCalendar.shouldPromote(kind: source.kind, pageHTML: page.normalizedHTML,
                                                 jsonBody: jsonBody)
    }

    // The live probe: the collection's JSON body when it answers 2xx, nil for anything else.
    static func probeSquarespaceCollection(_ url: URL) async -> Data? {
        guard let (data, response) = try? await URLSession.shared.data(from: url),
              let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else { return nil }
        return data
    }

    // One html source: fetch it, hash it, and decide. Never throws. Returns the page ONLY when this run
    // is going to read it, so the caller cannot accidentally spend a token on a run Dan did not start.
    //
    // #4329 (A12): and writes NOTHING. What the check decided for the row comes back as `SourceWrites`, which
    // the landing block applies after its re-validation, or drops whole when a later run overtook this one.
    private static func check(_ source: WatchedSource,
                              fetch: (URL, String?, String?) async throws -> FetchedPage,
                              probe: (URL) async -> Data?,
                              depth: ScoutDepth, now: Date) async -> (SourceResult, FetchedPage?, SourceWrites) {
        func result(_ state: SourceResult.State) -> SourceResult {
            SourceResult(sourceId: source.sourceId, orgName: source.orgName, state: state,
                         hadBaseline: source.baselineFeedCount > 0,
                         listingsURL: source.listingsURL)
        }

        guard let listings = source.listingsURL, let url = URL(string: listings) else {
            // A watched source with no usable address cannot be checked, and saying so is the whole
            // point: silence here would be a source Dan believes is being watched and is not.
            let failure = SourceFailure.verdict(.unreadable)
            // #1759: through the one shared recorder. This run came away without reading the source, and
            // it will do so on every run until the address is corrected, which is precisely the state the
            // streak exists to make visible.
            return (result(.failed(failure)), nil,
                    SourceWrites(.noUsableAddress, [.failedRead(failure, at: now)]))
        }

        let fetched: Result<FetchedPage, SourceFetchError>
        do {
            fetched = .success(try await fetch(url, source.orgName, source.venueLocation))
        } catch {
            fetched = .failure(fetchError(from: error))
        }

        // #1503: a Squarespace EVENTS collection publishes its whole schedule as data, so it never needs
        // a paid read. Detection has to be by CONTENT (Squarespace serves arbitrary domains, so nothing
        // in the URL says so), and it rides the fetch that just happened rather than a launch migration,
        // which would have meant a network probe per source at startup. Promoted here, the source ingests
        // natively from the NEXT run on, and this run does not read it, so the last paid read is saved
        // too. Covers the 7 already on the watchlist and every Squarespace org Dan adds later, through
        // one mechanism instead of two.
        if case .success(let page) = fetched,
           await shouldPromoteToSquarespace(source, page: page, probe: probe) {
            return (result(.unchanged), nil, SourceWrites(.promotedToSquarespace, [.kind(.squarespaceFeed)]))
        }

        let (decision, writes) = SourceCheck.decide(source: source, result: fetched, depth: depth, now: now)
        switch decision {
        case .unchanged:
            return (result(.unchanged), nil, writes)
        case .changedButNotRead:
            return (result(.changedNotRead), nil, writes)
        case .failed(let f):
            return (result(.failed(f)), nil, writes)
        case .read(let page):
            // Remember the hash of the bytes we are about to hand to the run. It cannot be recomputed at
            // ingest: that happens minutes later in another process, by which time the live page may have
            // moved on, and re-hashing would stamp a hash for bytes nobody ever read.
            // #897: and which months this pin actually stitched together, so ingest can tell a run that read
            // all of them from one that skimmed some. Empty on the single-month default, where SweepCoverage
            // is inert. Held like the hash, and cleared on the same success branch.
            return (result(.queuedForReading), page, writes.appending(SourceWrites(
                .queuedForReading, [.pendingRead(hash: page.contentHash, months: page.monthsRead)])))
        }
    }

    // Pin each changed page to disk and hand the batch to ONE detached run.
    //
    // The app fetched and hashed these bytes itself, and the run is pointed at exactly those bytes on
    // disk. That is what keeps the listing SET (which shows exist, which are gone: the thing that
    // re-keys prospects and drives the reconcile) determined by what the app hashed, rather than by
    // whatever a website happened to serve an agent a second later.
    private static func queueForReading(_ pages: [(source: WatchedSource, page: FetchedPage)],
                                        pin: (FetchedPage, String) throws -> URL,
                                        launch: ([ScoutExtractQueueItem]) throws -> Void) throws {
        let items: [ScoutExtractQueueItem] = try pages.map { source, page in
            let pinned = try pin(page, source.sourceId)
            return ScoutExtractQueueItem(sourceId: source.sourceId,
                                         orgName: source.orgName,
                                         listingsURL: source.listingsURL,
                                         pagePath: pinned.path)
        }
        try launch(items)
    }

    // Named, actionable, and never a stack trace. "Runner not configured" is the first thing Dan will
    // hit and it has a one-step fix, so it must not surface as a Swift error description.
    private static func extractLaunchMessage(_ error: Error) -> String {
        switch error {
        case ScoutExtractService.ExtractLaunchError.runnerUnavailable:
            return "The reader that pulls listings off a page isn't set up yet, so the pages that changed couldn't be read. See docs/scout-extract-runbook.md. Nothing was lost: they'll be read on the next scout once it's configured."
        case ScoutExtractService.ExtractLaunchError.alreadyRunning:
            // #2208: the run is refused before it starts now, so reaching this means a read began DURING
            // the sweep. Nothing is lost (every changed page keeps its unread flag), and the sentence
            // names the next step rather than leaving Dan to infer it.
            return "A previous run was still reading pages, so the pages this run found were not handed over. Nothing was lost: press Run scout again once the reading finishes and they will be read."
        default:
            return "The pages that changed couldn't be handed off to be read (\(error)). They'll be tried again on the next scout."
        }
    }

    // Anything a source's extractor or fetcher throws that is not already typed is a connectivity
    // problem as far as the row is concerned. Named, not swallowed.
    //
    // #1543: and named as precisely as the error allows. This is the path a FEED ADAPTER's untyped throw
    // takes (none of them catch their own session errors), so routing it through the same reader the plain
    // fetch uses is what stops a broken handshake on a feed host reading as a dead link while the identical
    // failure on an html source reads honestly.
    private static func fetchError(from error: Error) -> SourceFetchError {
        (error as? SourceFetchError) ?? .transport(error)
    }

    // Records that this source was checked, and folds the run into its own feed-health history. Not
    // saved here: since #4335 the caller writes this just BEFORE `applySweep`, whose save carries it with the
    // source's shows, or puts both back when it fails.
    //
    // #1001: the shared bookkeeping (the health fold, the #891 readable/unreadable counts, the #986
    // placement detector, the #801 warmup counter) lives on WatchedSource.recordSuccessfulRead, the ONE
    // copy the agent path also calls. This native path adds only the piece that is genuinely its own: it
    // no-ops when there is no row (Carnegie can scout on a store whose #800 backfill has not run yet, and
    // there is nothing to record onto), where the agent path always has a real row.
    // #4335 (RC6): returns the read's feed movement line for the caller to append once the save carrying it has
    // succeeded; nil when there is no row to record onto.
    private static func recordCheck(on source: WatchedSource?, events: Int,
                                    health: FeedReconcile.FeedHealthState, now: Date,
                                    unreadable: Int = 0, titleUnreadable: Int = 0,
                                    structuralGaps: Int = 0, droppedShows: [DroppedShow] = [],
                                    placed: Int = 0) -> String? {
        guard let source else { return nil }
        return source.recordSuccessfulRead(events: events, unreadable: unreadable,
                                    titleUnreadable: titleUnreadable, structuralGaps: structuralGaps,
                                    droppedShows: droppedShows, placed: placed, feedHealth: health, now: now)
    }

    // #800: the accessors below are `nonisolated`. They touch nothing but UserDefaults, which is
    // thread-safe, and they were main-actor-isolated only by inheritance from this enum. The launch-time
    // WatchedSourceBackfill has to read this state to seed it onto Carnegie's row, and it runs outside
    // the main actor like every other migration in LaunchMigrations. Reading these keys through their
    // own accessors is the point: the alternative is the backfill hardcoding the same key strings, which
    // is exactly how two copies of a name drift apart.
    //
    // #801: the scout no longer WRITES the three feed-health keys; Carnegie's row owns that state now.
    // They are kept, read-only, for exactly one reason: WatchedSourceBackfill reads them to seed the row
    // on a store that has not migrated yet, and a store can migrate at any future launch. Deleting them
    // would silently reset Carnegie's tuned #150/#152 history to zero for anyone who upgrades late.

    nonisolated static let lastScoutKey = "scoutLastRunAt"
    // Store/read injectable so the persistence is testable without polluting the global
    // defaults (test side effects stay in a transient suite).
    nonisolated static func recordScout(at date: Date, in defaults: UserDefaults = .standard) {
        defaults.set(date, forKey: lastScoutKey)
    }
    nonisolated static func lastScoutedAt(in defaults: UserDefaults = .standard) -> Date? {
        defaults.object(forKey: lastScoutKey) as? Date
    }

    // The baseline a later run is judged against to spot a degraded/partial feed (#150), the
    // `baseline` field of the persisted feed-health state. runScout updates it through
    // recordFeedHealthState (a degraded run can't ratchet it down, but a sustained shrink re-baselines
    // it, #152). These two accessors remain for direct baseline reads/writes and tests. Injectable
    // defaults keep test side effects contained.
    nonisolated static let lastHealthyFeedCountKey = "scoutLastHealthyFeedCount"
    nonisolated static func recordHealthyFeedCount(_ count: Int, in defaults: UserDefaults = .standard) {
        defaults.set(count, forKey: lastHealthyFeedCountKey)
    }
    nonisolated static func lastHealthyFeedCount(in defaults: UserDefaults = .standard) -> Int {
        defaults.integer(forKey: lastHealthyFeedCountKey)   // 0 when unset = no baseline yet
    }

    // The degraded-streak half of the feed-health state (#152): how many consecutive degraded feeds
    // have held at a stable smaller level, and the size of the most recent one. Stored beside the
    // baseline (which keeps reusing lastHealthyFeedCountKey) so the self-heal decision survives
    // between scouts. Injectable defaults keep test side effects contained.
    nonisolated static let degradedStreakKey = "scoutDegradedStreakCount"
    nonisolated static let lastDegradedFeedCountKey = "scoutLastDegradedFeedCount"

    nonisolated static func feedHealthState(in defaults: UserDefaults = .standard) -> FeedReconcile.FeedHealthState {
        FeedReconcile.FeedHealthState(
            baseline: defaults.integer(forKey: lastHealthyFeedCountKey),
            degradedStreak: defaults.integer(forKey: degradedStreakKey),
            lastDegradedCount: defaults.integer(forKey: lastDegradedFeedCountKey))
    }

    nonisolated static func recordFeedHealthState(_ state: FeedReconcile.FeedHealthState, in defaults: UserDefaults = .standard) {
        defaults.set(state.baseline, forKey: lastHealthyFeedCountKey)
        defaults.set(state.degradedStreak, forKey: degradedStreakKey)
        defaults.set(state.lastDegradedCount, forKey: lastDegradedFeedCountKey)
    }

    // What the source whose events these are knows about its OWN feed, which is the only thing that
    // licenses the reconcile to read a stored show's absence as a cancellation (#801).
    //
    // nil means "these events are not a sweep of anybody's feed": a hand-added lead (#799) reports on
    // the one page Dan pasted and says nothing whatever about what Carnegie is still listing. With no
    // feed check there are no reports, so nothing can be marked gone. That makes #826 (two leads in a
    // row marking Dan's live Carnegie shows as disappeared) structurally impossible rather than
    // guarded by a flag a future caller could forget.
    struct FeedCheck: Equatable, Sendable {
        var sourceId: String
        var baseline: Int
        var successfulCheckCount: Int
        var verdict: PageVerdict = .upcomingListings
        // #887: events this run threw away (no venue, so their detail page was never read). A run that
        // dropped shows may still ADD and UPDATE, but its silence about a show is not evidence the show
        // was cancelled. Defaulted to a clean sweep, so a caller that does not know cannot accidentally
        // claim one.
        //
        // #1472: this is now the UNREAD drops only (RejectionCounts.unreadTotal). A row the SOURCE published
        // with no venue is not a page that failed, and is handed over below instead.
        var rejectedCount: Int = 0
        // #1472: the listing links of rows this run SAW but could not import because the source published no
        // venue for them. They go into the report's `seenSourceURLs`, so a stored show whose row went blank
        // between runs is still counted as listed and can never be marked gone for it.
        //
        // This is the half that makes exempting those rows from `rejectedCount` safe rather than merely
        // quieter, and it is why a row with no link of its own is never exempted (ExtractedEventGuard): with
        // nothing to hand over there is nothing to protect the stored show with.
        var structuralGapURLs: Set<String> = []
        // #1469: the nights of those rows that carry no link (a placeholder row links nowhere), so the show
        // behind one can still be held. Source-scoped by the reconcile, never pooled: see SourceReport.
        var structuralGapDates: Set<String> = []
    }

    // #888 part B: one source sweeping its own feed, applied AND reconciled.
    //
    // `apply` is an UPSERT: it lands events and hands back what this source swept. Reconciling is a
    // whole-run decision, because "every owner of this show was asked and none has it" cannot be judged
    // one source at a time (that is the bug: with a single-element report list, `believable` was never
    // larger than one source, so a co-listed show could never be marked gone by anybody).
    //
    // A caller with SEVERAL sources (ScoutExtractIngest) therefore applies each, then reconciles once
    // with all their reports. A caller with exactly ONE (the native Carnegie sweep) uses this, so the
    // pairing lives in production code rather than being re-assembled by every call site, where it could
    // drift or simply be forgotten. Forgetting it is silent: shows would just quietly stop being marked
    // gone, and nothing would fail.
    @discardableResult
    static func applySweep(
        events: [ExtractedEvent],
        clients: [DownbeatClient],
        history: [HistoryRecord],
        blocked: BlockedCalendar,
        feed: FeedCheck,
        today: String = QueueModel.easternToday(),
        // #4331: passed straight through to `apply`, which stamps a changed row from it.
        now: Date = Date(),
        sourceIds: [String] = [],
        // #3884: passed straight through to `apply`. See `readNative`, which runs it off the actor.
        preClassified: PreClassified? = nil,
        // #4275: the landing's working set, shared with `apply`. nil reads the store for this sweep alone.
        landing: ScoutLandingStore? = nil,
        into context: ModelContext
    ) -> Outcome {
        let landing = landing ?? ScoutLandingStore(context: context)
        var outcome = apply(events: events, clients: clients, history: history, blocked: blocked,
                            feed: feed, today: today, now: now, sourceIds: sourceIds,
                            preClassified: preClassified, landing: landing, into: context)
        if let report = outcome.report {
            reconcileLanded([report], on: landing, today: today, degraded: &outcome.degradedReads)
        }
        return outcome
    }

    // #4474: the reconcile a landing notes, ONE implementation for both landing paths (this one per source, and
    // the extract ingest's once per landing), so the two cannot come to treat a failed read differently.
    // #3071: a reconcile handed an invented empty marks nothing gone and says nothing about it, so a run that
    // could not read its own shows looks exactly like one where none had dropped out. It is skipped and NAMED
    // instead. #4325: what it writes is noted on the landing, whose closing save carries it (`saveLanding`).
    static func reconcileLanded(_ reports: [FeedReconcile.SourceReport], on landing: ScoutLandingStore,
                                today: String, degraded: inout [StoreRead]) {
        // #4475: only the rows these reports could change, never every stored row: runScout reconciles once a
        // SOURCE, so the whole store was walked once per source landed (`ScoutLandingStore.rows(reconciledBy:)`).
        guard let touchable = readOrRecord(.reconcileStoredShows, into: &degraded,
                                           { try landing.rows(reconciledBy: reports) }) else {
            return
        }
        landing.noteReconcile(FeedReconcile.reconcile(stored: touchable, reports: reports, today: today))
    }

    // #4325: the closing save of a scout landing, ONE implementation for both paths (`runScout`'s native
    // sweep and `ScoutExtractIngest.ingest`). Each source's upserts are saved as it lands, but the reconcile
    // after the last one (and, in the ingest, the only one) was left to autosave or the next unrelated save,
    // so a quit or a crash first lost a feed miss (L12), and a probe round read the last round's writes as
    // its own (#4327 step 0.5).
    //
    // A failed save is the per source save's failure (`Outcome.saveFailed`, #499), never `try?`. And it
    // PUTS BACK everything it could not carry (#4334, A5: the failure path revert, over the whole closing
    // write set): `missedScoutCount += 1` is not idempotent, so a miss left pending would be counted again by
    // the retry and both would land on the next save, and the same is true of every source's bookkeeping the
    // closing save was carrying. Returns whether the landing's writes are in the store.
    static func saveLanding(_ landing: ScoutLandingStore, into context: ModelContext,
                            save: (ModelContext) throws -> Void = { try $0.save() }) -> Bool {
        guard context.hasChanges else { return true }
        do {
            try save(context)
            landing.reconcileWritesSaved()
            return true
        } catch {
            landing.revertFailedSave(closing: true)
            return false
        }
    }

    // #4334 (A5): one source's save failed. ONE implementation for both landing paths. The source is put back
    // (`ScoutLandingStore.revertFailedSave`), and the answer is whether the landing may go on: nil when the
    // failure was confined to this source's rows (`LandingSaveFailure`, source level), a stop otherwise, and
    // a stop BY NAME when what the source wrote could not all be put back.
    static func isolateFailedSave(of orgName: String, scope: LandingSaveFailure.Scope?,
                                  landing: ScoutLandingStore) -> LandingStop? {
        let report = landing.revertFailedSave(closing: false)
        if !report.notRestorable.isEmpty { return .notReverted(source: orgName, why: report.notRestorable) }
        return scope == .source ? nil : .storeRefusedASave(source: orgName)
    }

    // #4334 (A5): the ENTRY FLUSH, shared by both landing paths. Anything pending in the main context when a
    // landing takes the store is saved first, so the failure path revert, which restores COMMITTED values,
    // can never put back an edit made before the landing. The whole context, not a chosen set of types: a
    // type left out is a type whose pending edit a revert could silently discard, and saving what is pending
    // is what autosave would do anyway. Cheap when nothing is pending, which after #4329 is the normal case.
    // A flush that cannot save refuses the landing, naming the rows it was carrying, and leaves them exactly
    // as they were.
    // #4338 (A10): says which of three things it did, so the landing can count a flush that SAVED on its record
    // (`LandingRun.entryFlushSaves`), and records each refusal and each success on `record`, whose two refusals
    // in a row are the standing state on the landing line (`EntryFlushRecord`).
    static func flushBeforeLanding(_ context: ModelContext, save: (ModelContext) throws -> Void,
                                   record: EntryFlushRecord = .shared) -> EntryFlush {
        guard context.hasChanges else {
            record.saveSucceeded()
            return .nothingPending
        }
        let rows = pendingRowNames(in: context)
        do {
            try save(context)
            record.saveSucceeded()
            return .saved
        } catch {
            record.refused(rows: rows)
            return .refused(.recentEditsUnsaved(rows: rows))
        }
    }

    // What is waiting to be saved, in the words Dan knows each row by: a show by its title, a calendar by its
    // organisation, a contact by their address, and anything else as one more record, never a type name.
    static func pendingRowNames(in context: ModelContext) -> [String] {
        let models = context.changedModelsArray + context.insertedModelsArray + context.deletedModelsArray
        return Array(Set(models.map(rowName(of:)))).sorted()
    }

    // #4338: one row's name in those words, shared with the discard confirmation (`UnsavedEditsDiscard`) so the
    // refusal and the confirmation name a row the same way.
    static func rowName(of model: any PersistentModel) -> String {
        switch model {
        case let p as Prospect: return p.groupName
        case let w as WatchedSource: return w.orgName
        case let r as Recipient: return r.email ?? r.name ?? "a contact"
        default: return "another record"
        }
    }

    // Application of already-extracted events with injected data, so the full
    // classify -> match -> assemble -> upsert chain is testable without network/WebKit.
    //
    // #888 part B: this UPSERTS and hands back what the source swept (`Outcome.report`). It does NOT
    // reconcile: see applySweep above for why that is now the caller's decision.
    // #3884: a classify pass run elsewhere, with the store reads it had to make to run it.
    //
    // The two travel TOGETHER rather than as two parameters, because they are one fact: this pass, and
    // whether the corpus behind it was readable. Handed in separately, a caller could supply the result
    // and forget the reads, and the run would report a clean corpus it never read (L544).
    struct PreClassified: Equatable, Sendable {
        var result: ScoutClassify.Result
        var degradedReads: [StoreRead]
    }

    // #1702/#1719: which presenter names read as their building's own brand, judged over the store as it
    // stands, plus Dan's own corrections. ONE implementation, because `apply` reads it when it classifies
    // for itself and `runScout` reads it (once per run, #4102) before `readNative` hands a pass in, and two readings of the
    // same corpus is how the two would come to judge different brands (L263).
    //
    // #3071: a corpus built from an invented empty is a THINNER brand list, so a hall's own brand can
    // raise a fuzzy match it should not. The run still proceeds, because the answer is degraded rather
    // than wrong, but the failed read travels with it.
    typealias CorpusRead = (brands: ProducerGate.VenueBrands, degradedReads: [StoreRead])

    // On the context the caller holds, on the caller's actor: what `apply` reads when it classifies for itself
    // (the lead paste, until A11 moves it, and every test that lands a batch directly).
    static func venueBrandCorpus(in context: ModelContext,
                                 read: ScoutLandingStore.Read = ScoutService.readProspectTable) -> CorpusRead {
        buildBrandCorpus(shows: { try read(context) },
                         overrides: { try ProducerOverrideEditing.readOverrides(in: context) })
    }

    // #4332 (A3): the same corpus, read through a context of its own, OFF the main actor. Built from Sendable
    // values only (`ProducerGate.VenueBrands`), and the context never saves, so nothing it fetched crosses
    // back. A background context reads what is SAVED, which is why every entry point calls this only after the
    // entry flush (`flushBeforeLanding`) has saved whatever was pending.
    //
    // `Task.detached` rather than relying on a nonisolated async function leaving the caller's actor: a
    // language mode in which such a function inherits its caller's actor would put the read straight back on
    // the main thread while reading as though it had moved (the reason `ScoutClassify.offTheCallersActor`
    // gives).
    nonisolated static func venueBrandCorpusOffMain(container: ModelContainer,
                                                    read: @escaping ScoutLandingStore.SendableRead,
                                                    readOverrides: @escaping ScoutService.OverrideRead) async -> CorpusRead {
        await Task.detached(priority: .userInitiated) {
            let context = ModelContext(container)
            return buildBrandCorpus(shows: { try read(context) }, overrides: { try readOverrides(context) })
        }.value
    }

    // ONE implementation of the corpus, whichever context it is read through (L263). Both joined reads are
    // gated (L530, L215): a failure is recorded under its own name, and the corpus is built from what could be
    // read, so the landing proceeds degraded rather than wrong.
    nonisolated static func buildBrandCorpus(shows: () throws -> [Prospect],
                                             overrides: () throws -> ProducerOverrides) -> CorpusRead {
        var degraded: [StoreRead] = []
        let brandShows = readOrRecord(.venueBrandCorpus, into: &degraded, shows) ?? []
        let corrections: ProducerOverrides
        do { corrections = try overrides() } catch {
            degraded.append(.producerOverrides)
            corrections = .none
        }
        // Through the one projection of a stored show onto the fields the brand judgement reads, shared with
        // the queue's producer tables (#4357 slice B), so the two corpora cannot come to read different fields.
        return (ProducerGate.VenueBrands(shows: brandShows.map(ProducerGate.Show.init), overrides: corrections),
                degraded)
    }

    @discardableResult
    static func apply(
        events: [ExtractedEvent],
        clients: [DownbeatClient],
        history: [HistoryRecord],
        blocked: BlockedCalendar,
        feed: FeedCheck? = nil,
        // #798: injected so the upcoming-only guard below is testable against a pinned day instead of
        // the wall clock. The reconcile already needed today's date; now one value serves both.
        today: String = QueueModel.easternToday(),
        // #4331 (A2): the instant this landing stamps a row it changed or inserted, plus the row's apply ordinal
        // (`ScoutLandingStore.nextStamp`). Never `scoutNow` below, which is Eastern midnight: a row stamped from it
        // would read as older than one written by hand earlier the same day. Every shipping caller passes its
        // own landing's `now` (ingest, `runScout`, the lead paste); the default serves a test landing one batch.
        now: Date = Date(),
        // #771: the source(s) this run's events came from, stamped onto every prospect it inserts and
        // UNIONED onto every one it updates. Empty means "we did not record it", which is what every
        // prospect predating #800 carries, and what a Prep-created one carries. An empty list can never
        // satisfy the reconcile's "every source that owns this show was asked", so it never accrues a
        // miss. That is exactly today's behavior for a non-Carnegie URL.
        sourceIds: [String] = [],
        // #3884: a classify pass the caller already ran OFF the main actor, or nil to run it here. See
        // Phase 1 below for why nil is an instruction and not an absent input.
        preClassified: PreClassified? = nil,
        // #4275: the stored shows this sweep judges against, shared across every source of one landing and
        // kept current as each lands (`ScoutLandingStore`). nil builds one for this sweep alone, which is
        // what a caller landing a single batch (a lead, a test) wants: one read, not one per question.
        landing: ScoutLandingStore? = nil,
        into context: ModelContext
    ) -> Outcome {
        let landing = landing ?? ScoutLandingStore(context: context)
        // #1648: the instant this run scores against, derived from the day it was already given rather
        // than from a second clock, so pinning `today` in a test pins this too (LESSONS L39). Used only
        // to decide whether a row's contact answer has aged past its 90 day expiry, where a day's
        // precision is ample. Falls back to the real clock only if `today` is unparseable, which would
        // already have broken the upcoming-only guard above it.
        let scoutNow = EasternDate.date(from: today) ?? Date()
        var inserted = 0, updated = 0, skipped = 0, collapsedIntoRun = 0
        // #4147: every title this run overwrote, with the arm that did it. Carried on the Outcome as
        // well as written to the ledger, so a test can assert what a run recorded without reading a file.
        var titleRenames: [TitleRenameLedger.Entry] = []
        // #2758: rows this run refused to touch because the store could not answer whether their key was
        // free. Kept apart from `skipped`, which means "decided not to pursue": this one was pursued and
        // could not be settled, and the two need different words on the summary.
        var unreadableStore = 0
        var unreadableKeys: [String] = []
        var suppressedShows: [String] = []      // #802: by org name, folded into one line each below
        // #1702: which presenter names read as their building's own brand, judged over the store as it
        // stands and computed ONCE per sweep rather than per event. Read here rather than passed in, so
        // every caller (the scout, a test, a future one) judges against the real corpus and none of them
        // can forget to supply it. A brand every show in a hall shares must not be able to raise a fuzzy
        // "possible match", or one past record asks the same question on every show in the building.
        // #1719: and Dan's own corrections alongside the corpus, read here for the same reason the
        // corpus is: so no caller can forget to supply them.
        // #3071: a corpus built from an invented empty is a THINNER brand list, so a hall's own brand
        // can raise a fuzzy match it should not. The run still proceeds (the answer is degraded, not
        // wrong, and throwing here would discard the classify work already done), but it says so.
        var degradedReads: [StoreRead] = []
        // Natural keys actually present in this run's feed, so the post-upsert reconcile can
        // tell which stored prospects dropped out (#133).
        var seenKeys = Set<String>()

        // Phase 1: classify each event and collect prospect decisions (no upserts yet).
        //
        // #3884 MOVED THE LOOP ITSELF into `ScoutClassify`, which is pure and can run off the main actor.
        // The store reads that FEED it (the whole table fetch behind `venueBrands`, and the producer
        // overrides beside it) stay above this line, on the main actor, because a `ModelContext` cannot
        // leave it. `preClassified` is how the scout hands in a pass it has already run off the actor;
        // nil means "classify it here", which is what every other caller does and what this function has
        // always done. Nil is a real instruction rather than a missing value, and there is no input it
        // stands in for (L168).
        // The corpus read is LAZY, and that is not a tidy-up. `venueBrands` feeds this loop and nothing
        // else in this function, so on the pre-classified path the caller has already read it and doing
        // it again here would add a whole table fetch, measured at 158.8 ms over 1,238 rows, to the very
        // main thread block this change exists to shorten.
        // `classifiedPass`, not the obvious `classified`. The test-only-reachable scan matches on the
        // bare IDENTIFIER, and `RunNightDrop` declares one called `classified` that only its tests name,
        // so a local of that name here made that declaration read as reached by app code and turned its
        // baseline entry stale. Seen: `everyBaselineEntryIsStillAFinding` went red on a file this change
        // does not touch.
        let classifiedPass: ScoutClassify.Result
        if let preClassified {
            classifiedPass = preClassified.result
            // The caller's read, carried through, so a corpus it could not read still reaches Dan. Without
            // this the pre-classified path would report a clean run over a degraded corpus (#3071, L98).
            degradedReads.append(contentsOf: preClassified.degradedReads)
        } else {
            let corpus = venueBrandCorpus(in: context)
            degradedReads.append(contentsOf: corpus.degradedReads)
            classifiedPass = ScoutClassify.run(events: events, clients: clients, history: history,
                                               venueBrands: corpus.brands, sourceIds: sourceIds)
        }
        let prospects = classifiedPass.prospects
        skipped += classifiedPass.skipped
        suppressedShows.append(contentsOf: classifiedPass.suppressedOrgs)

        // Phase 2: collapse multi-night runs so only the representative night is upserted. Each row
        // carries its INDEX into `prospects` as its identity (#797), which is how a grouped run finds
        // its way back to the prospect it came from.
        let rows = prospects.enumerated().map { i, p in
            RunGrouping.RunRow(
                id: i,
                groupName: p.groupName,
                venue: p.venue,
                performanceDate: p.performanceDate,
                sourceListingURL: p.sourceListingURL,
                seriesId: p.seriesId          // #1174: carry the production id into run grouping
            )
        }
        let grouped = RunGrouping.group(rows)

        // Phase 3: upsert one prospect per grouped run. Every prospect is in exactly one run
        // (RunGrouping emits a group for every row, dated or not), so identity resolves all of them
        // and there is no leftover case to handle separately.
        //
        // #797: this used to resolve through a [sourceListingURL: AssembledProspect] dictionary, and
        // lost shows two ways. A listing URL is not unique, so an org publishing its whole season on
        // ONE page collapsed into a single prospect, last write wins, the rest gone and not even
        // counted. And a run whose representative row had no URL (representativeRow picks the
        // SHORTEST title, which can be the unlinked night) failed the URL guard and the whole run was
        // dropped, member nights included.
        // #4056: the production token poison set, computed ONCE for the whole sweep.
        //
        // It used to be rebuilt inside `matchByProductionToken`, per incoming listing, over the stored
        // rows plus THAT ONE listing. Two things were wrong with that, and only the first was filed.
        //
        // The cost: `ShowLink.foldedTitle` and `foldedVenue` walk and rewrite a string on every call and
        // are not memoised, so a venue publishing dozens of listings re-folded all 1,275 stored rows once
        // per listing.
        //
        // The ANSWER, which the issue said was fine: a listing that would poison the token is invisible
        // while an earlier one is being judged, so the verdict depended on the order the venue happened
        // to list its nights in. Measured 2026-09-21 (`BatchWidePoisonMapTests`): with the poisoning
        // listing arriving second, a season token joined two rows it must not; with the same three shows
        // presented the other way round, it correctly refused. Same store, same rule, different answer.
        //
        // Over the whole batch it does not depend on ordering at all, and it sees strictly more than the
        // per listing map could: a token two INCOMING listings disagree about is caught on the sweep that
        // brings them, rather than on whichever later sweep happens to store one of them first.
        let batchRows = grouped.compactMap {
            prospects.indices.contains($0.row.id) ? prospects[$0.row.id] : nil
        }
        // A read that could not answer refuses EVERY token this sweep carries, rather than refusing none.
        // The two directions are not symmetric: a refusal costs a duplicate card Dan can see and merge,
        // and a wrong join carries a stored row's dismissal, its recipients and its thread id onto another
        // show, silently (#797). So the unreadable case takes the side that can be undone, and says so
        // rather than looking like a clean sweep (L42, L11).
        let batchPoisonedTokens: Set<String>
        do {
            // #4333 (A4): the stored rows' half from the landing's tables, so this source walks its own batch
            // and the rows written since the source before it, not every stored row again.
            batchPoisonedTokens = try landing.poisonedTokens(adding: batchRows)
        } catch {
            degradedReads.append(.productionTokenCorpus)
            batchPoisonedTokens = Set(batchRows.flatMap {
                (($0.sourceListingURL.map { [$0] } ?? []) + $0.runSourceURLs)
                    .compactMap(ProductionToken.inURL)
            })
        }

        // #1848 and #4098 both ask a question of every stored row. Each used to fetch the whole store for
        // itself, then (#4275) walk the landing's working set once per source; since #4333 (A4) both answers
        // come from the landing's tables, built once per landing and kept current as each source lands, so
        // nothing here reads or walks the store.
        //
        // The two want OPPOSITE things from a read that fails, and that is deliberate rather than an
        // inconsistency: the spelling lock can only ever REPLACE a spelling with one the source itself
        // published, so having none simply leaves today's reading alone, while the ambiguity discard
        // exists to REFUSE joins, so an empty set would license every join it is there to prevent (L42,
        // L215). Fail open for the first, fail closed for the second.
        let storedSpellings: ScoutLandingStore.VenueSpellings?
        do {
            storedSpellings = try landing.venueSpellings()
        } catch {
            degradedReads.append(.reconcileStoredShows)
            storedSpellings = nil
        }

        // #4098: how ambiguous each URL this sweep carries is, for the two URL matching arms.
        let batchAmbiguousURLs: AmbiguousURLs
        if storedSpellings != nil,
           let measured = try? landing.ambiguousURLs(adding: batchRows) {
            batchAmbiguousURLs = measured
        } else {
            let everyURL = Set(batchRows.flatMap {
                ListingURL.foldedSet(($0.sourceListingURL.map { [$0] } ?? []) + $0.runSourceURLs)
            })
            batchAmbiguousURLs = AmbiguousURLs(atAVenue: everyURL, anywhere: everyURL)
        }

        for gr in grouped {
            guard prospects.indices.contains(gr.row.id) else { continue }
            let p = prospects[gr.row.id]

            // #798: the upcoming-only guard, and it lives HERE, at the run, on purpose.
            //
            // Carnegie's feed only ever returned a forward 90-day window, so nothing ever needed
            // this. An arbitrary org's page is the opposite: the #770 spike found 5 of 7 real sites
            // still displaying LAST season's dates, and one listing 11 concerts under a "Previous
            // Concerts This Season" heading. Without this, the first check of a new source floods the
            // queue with shows that already happened.
            //
            // Judged on the run's LAST night (`runEndDate ?? performanceDate`), so a run already
            // underway survives. Putting the same rule at the EVENT (inside ProspectAssembler.decide)
            // would look equivalent and would corrupt the store: past nights would be dropped BEFORE
            // grouping, so a live run would lose its opening night, its natural key would shift to
            // the next remaining night on every scout, and each run would re-key or duplicate the
            // same show. Dan's call (2026-07-11): a run underway keeps its OPENING-night date; the
            // queue already renders it as a run ("Jul 9 to 12"), so it reads as still running.
            //
            // An undated listing cannot be judged past, and "date to be confirmed" is a normal state
            // on an org's season page, so it is kept rather than silently dropped.
            let lastNight = EasternDate.runLastNight(runEndDate: gr.runEndDate,
                                                     performanceDate: gr.row.performanceDate)
            if EasternDate.runHasPassed(lastNight: lastNight, today: today) {
                skipped += gr.memberIds.count      // every night accounted for, none silently vanished
                continue
            }

            // Every night of the run beyond the one being upserted is folded into it, not lost:
            // counted so `found` always reconciles against what actually happened to each event.
            collapsedIntoRun += max(0, gr.memberIds.count - 1)

            // Fold run metadata onto the assembled prospect.
            var enriched = p
            enriched.runEndDate = gr.runEndDate
            enriched.partOfRelatedRun = gr.partOfRelatedRun
            enriched.runSourceURLs = gr.runSourceURLs
            enriched.runNights = gr.memberDates    // #1523: the nights it plays, for the clash check

            // #1699: what this ONE card may claim about curtain time, decided from EVERY night of the
            // run rather than read off the representative one. A run collapses to a single card showing a
            // date range, so a time printed beside that range is a claim about all of its nights.
            //
            // Dan's rule (2026-08-02): nights that agree state their shared time; nights that differ say
            // "Times vary"; a run nobody published a time for says nothing and reads exactly like today's
            // card. The member rows are gone after this point (the same reason runNights above is stored
            // rather than derived), so this is the only moment the comparison can be made.
            let nightTimes = gr.memberIds.compactMap {
                prospects.indices.contains($0) ? prospects[$0].startTimes : nil
            }
            switch RunStartTimes.across(nightTimes) {
            case .none:
                enriched.startTimes = []
                enriched.startTimesVary = false
            case .same(let times):
                enriched.startTimes = times
                enriched.startTimesVary = false
            case .varies:
                // No SHARED time alongside the flag: a card holding one night's time AND a note saying
                // the nights differ would contradict itself on the same line. The per-night schedule is
                // kept regardless, for the hover.
                enriched.startTimes = []
                enriched.startTimesVary = true
            }

            // #1699: every night's own times, as self-describing "yyyy-MM-dd HH:mm" entries, so the hover
            // behind "Times vary" shows the real schedule. Dan's call (2026-08-02) once the measurement
            // showed varying runs are the MAJORITY of timed cards rather than the rare case this feature
            // was designed around, which made "Times vary" alone the most common thing a timed card said
            // while answering nothing he needed.
            enriched.nightStartTimes = gr.memberIds.flatMap { id -> [String] in
                guard prospects.indices.contains(id),
                      let night = prospects[id].performanceDate else { return [] }
                return prospects[id].startTimes.map { "\(night) \($0)" }
            }

            // #1236: a synthetic same-date+venue merge (DCINY) collapsed several per-conductor rows into
            // this one. RunGrouping keeps only the representative row's title, so rebuild the name from
            // EVERY member title (the conductor list is the name), and drop the span: it is one date, not a
            // multi-night run. Keyed off the synthetic id, so an ordinary run (a real feed id, or none) is
            // untouched and keeps its representative title. Set before the natural key is computed below.
            if SameDateVenueMerge.isMerged(p.seriesId) {
                let memberTitles = gr.memberIds.compactMap {
                    prospects.indices.contains($0) ? prospects[$0].groupName : nil
                }
                enriched.groupName = SameDateVenueMerge.combinedName(from: memberTitles)
                if enriched.runEndDate == enriched.performanceDate { enriched.runEndDate = nil }
            }

            // #901: the date conflict, and it lives HERE, at the run, for the same reason the guard above
            // does. `runEndDate` does not exist until the nights have been grouped, so a check on the
            // event (where the old blocked-date drop lived) can only ever see opening night: a four-night
            // run whose third night sits on a booked shoot passed clean, and Dan would have pitched a
            // show he could not finish.
            //
            // It FLAGS, it does not drop (Dan's call, 2026-07-13). A dropped show is a decision the app
            // made for him, silently, and he would rather see the clash and decide himself.
            enriched.conflictKey = blocked.conflict(performanceDate: enriched.performanceDate,
                                                    runEndDate: enriched.runEndDate,
                                                    nights: enriched.runNights)?.key

            // #1848: the room, spelled the way this source has already spelled it. BEFORE the key, which
            // is the whole point: the venue is one of the key's three fields, so a second spelling is a
            // second key, a second card and a second paid contact check. Nothing is invented here; the
            // only value this can produce is one the same source has already published.
            enriched.venue = VenueSpellingLock.locked(
                enriched.venue,
                // #1848: how THIS run's sources have already spelled their own rooms, as the stored rows
                // stood when this source began.
                spellingsUsedBySource: storedSpellings?.used(by: enriched.sourceIds) ?? [])
            let key = Prospect.makeNaturalKey(groupName: enriched.groupName, performanceDate: enriched.performanceDate, venue: enriched.venue)
            seenKeys.insert(key)
            // #2758 / #2999: ONE decision, taken before anything is written, so a store that cannot answer
            // refuses this row instead of falling through to an arm that would re-key or insert onto a key
            // somebody else may hold. The comments on each arm are below, at the point it is acted on.
            let target = upsertTarget(
                storedByKey: { try landing.stored(key: key) },
                byConcert: { try matchByConcertIdentity(enriched.seriesId, groupName: enriched.groupName,
                                                        openingNight: enriched.performanceDate,
                                                        runEndDate: enriched.runEndDate,
                                                        venue: enriched.venue, landing: landing) },
                byAnyRunURL: { try matchByAnyRunURL(enriched.runSourceURLs, groupName: enriched.groupName,
                                                    venue: enriched.venue,
                                                    ambiguous: batchAmbiguousURLs.anywhere,
                                                    landing: landing) },
                byProductionToken: {
                    try matchByProductionToken((enriched.sourceListingURL.map { [$0] } ?? [])
                                                 + enriched.runSourceURLs,
                                               groupName: enriched.groupName,
                                               venue: enriched.venue,
                                               poisoned: batchPoisonedTokens, landing: landing)
                },
                byStableSource: { try matchByStableSource(url: enriched.sourceListingURL,
                                                          date: enriched.performanceDate,
                                                          venue: enriched.venue,
                                                          groupName: enriched.groupName,
                                                          ambiguous: batchAmbiguousURLs.atAVenue,
                                                          landing: landing) },
                arrivalNotes: {
                    // ONE fetch, both answers. Two separate closures would walk the store twice for
                    // every genuinely new show, and this arm already runs only when every match arm
                    // above has missed.
                    // #4460: both scans match only a row on this show's own NIGHT, so they are handed the
                    // rows on that night rather than every stored row. An empty night is on no row, and both
                    // scans answer nil for one before they look; the lookup still reads the store, so an
                    // unreadable one refuses this show exactly as the walk did.
                    let stored = try landing.rows(.night(enriched.performanceDate ?? ""))
                    return ArrivalNotes(
                        lookingLike: LookalikeOnArrival.amongStored(
                            stored.map {
                                (key: $0.naturalKey, groupName: $0.groupName,
                                 performanceDate: $0.performanceDate, venue: $0.venue)
                            },
                            groupName: enriched.groupName, performanceDate: enriched.performanceDate,
                            venue: enriched.venue, excludingKey: key),
                        alreadyPitched: AlreadyPitchedNight.amongStored(
                            stored.map {
                                AlreadyPitchedNight.Stored(key: $0.naturalKey, presenter: $0.presenter,
                                                           performanceDate: $0.performanceDate,
                                                           venue: $0.venue, sentAt: $0.sentAt)
                            },
                            presenter: enriched.presenter, performanceDate: enriched.performanceDate,
                            venue: enriched.venue, excludingKey: key))
                }
            )
            switch target {
            case .updateInPlace(let existing):
                // Exact natural-key match: update in place.
                // #4147: the title as it stood BEFORE the write, because `apply` overwrites it in place
                // and nothing afterwards can say what it was (this is the whole of why #4068 could not
                // be answered).
                let titleBefore = existing.groupName
                // #4331 (A2): whether the row held unsaved writes BEFORE this apply, so a change can be told
                // from the state the row reaches rather than from a list of the writes that reach it (L247).
                let wasDirty = existing.hasChanges
                apply(enriched, to: existing, now: scoutNow,
                      storedByKey: landing.stored(key:))
                landing.stampTouched(existing, changed: wasDirty || existing.hasChanges, at: now)
                recordRename(of: existing, from: titleBefore, by: target.matchedArm, at: scoutNow,
                             into: &titleRenames)
                updated += 1
            case .reKey(let match, _), .reKeyJoiningNights(let match):
                // #4331 (A2): before ANY write this arm makes, the reopening and the re-key included, so both
                // count as the change they are.
                let wasDirty = match.hasChanges
                // #4029: the token arm alone answers "this is ANOTHER NIGHT of the production this row
                // holds", so its nights are added to the row's rather than replacing them, and a decision
                // Dan made about a night he has already spent is reconsidered. Every other arm below says
                // "this is the same run, read again", where the feed is authoritative and neither applies.
                if case .reKeyJoiningNights = target {
                    let newNights = Set(enriched.runNights).subtracting(match.runNights)
                    let union = Set(enriched.runNights).union(match.runNights).sorted()
                    enriched.runNights = union
                    enriched.performanceDate = union.first ?? enriched.performanceDate
                    enriched.runEndDate = union.count > 1 ? union.last : nil

                    // #4052, and it is the reason this arm is allowed to join at all. The row carries
                    // whatever ending Dan recorded, so without this a dismissal he made about ONE night
                    // silently decides every later one. Measured on the live store 2026-09-20: pk 397
                    // Nihao Broadway was dismissed `pitchingOtherShows` for 2026-09-11, the 2026-09-29
                    // night became a row of its own, and he PITCHED it. Joining without reopening would
                    // have silenced the card that produced the outreach.
                    //
                    // Only on a night the row does not already hold, so a re-read of the same nights can
                    // never undo a decision (L92: a removal recorded against nothing recurs, and this is
                    // its mirror, a decision undone by an event that did not happen).
                    if !newNights.isEmpty, let ending = match.showOutcome, ending.newNightReopens {
                        // The same reverse the Archive's restore and the blocked-town undo take, rather
                        // than clearing the fields here, so a show reopened by a new night is in exactly
                        // the state a show reopened by hand is (#28, #1238).
                        match.clearDismissal()
                    }
                }
                // No exact key match, but a stored row is this same show under a key that has moved. Three
                // reads can say so, and they are asked in `upsertTarget` in this order:
                //
                //   #1260 Phase 2, a merged prospect carrying the SAME synthetic concert id
                //   (samedatevenue:DATE|VENUE), whose name and representative URL both shifted because the
                //   scout re-listed the per-conductor rows in a new order or with refreshed links. The two
                //   URL arms would miss and INSERT A DUPLICATE, stranding Dan's keep/dismiss.
                //
                //   #4040 REWROTE what makes this safe, because what stood here was false. It read: "the
                //   synthetic id is minted only for a mergeSameDateVenue source, so it can NEVER fuse two
                //   genuinely different shows". That is a claim about every WRITER, and the gate was a bare
                //   prefix test that asks nothing about who wrote the string. The extract runbook (3b) tells
                //   the run to copy a page's series marker VERBATIM into `seriesId`, so a page could hand
                //   Overture a value carrying the prefix and switch off both corroborations below.
                //
                //   What makes it safe NOW is that the gate is ANCHORED: the id must name this row's own
                //   date and folded venue (`SameDateVenueMerge.isMerged(_:naming:venue:)`), so it can only
                //   ever join rows that genuinely share what it names, whoever wrote it. A normal
                //   matinee/evening still gets no id to match.
                //
                //   What is NOT settled, so nobody reads the above as more than it is: a source flagged
                //   `mergeSameDateVenue` that genuinely runs two different shows in one room on one night
                //   still fuses them, because date plus venue is the whole of the id and no title is
                //   checked. That rests on a human decision on the watchlist. Measured 2026-09-20: 1 of 74
                //   sources carries the flag, 9 rows carry a synthetic id, and every one of them agrees with
                //   the date and venue its own id encodes.
                //
                //   #132, a stored record sharing one of this run's member URLs, so the keep/dismiss
                //   decision survives a run-window shift.
                //
                //   #29, the same source listing and date, where the venue tweaked the title between runs.
                //
                // All three do the same thing here: re-key to the new key and update in place. Safe only
                // because the exact-key read above proved nobody holds it, which is why a read that could
                // not answer refuses the row below rather than arriving here (#2758).
                //
                // #3324 (plan 2.11): the key stored is the key of the night the row LANDS on, which is the
                // opening `apply` is about to assign, not the feed's. They differ whenever Dan dropped the
                // opening night: the feed still lists it, `apply` keeps it dropped, and storing the feed's
                // key beside the kept date left 19 of 1,260 rows (measured 2026-09-17) whose key named a
                // night their card does not play, repaired at every launch by an unrelated venue pass and
                // re-created by the next scout. ONE function answers the opening for both writes now.
                let openingNight = Self.scoutOpening(fed: enriched.performanceDate,
                                                     fedNights: enriched.runNights, existing: match,
                                                     lookup: landing.stored(key:))
                let anchored = Prospect.makeNaturalKey(groupName: enriched.groupName,
                                                       performanceDate: openingNight, venue: enriched.venue)
                if anchored != key {
                    // The feed's key was proven free above; the landing key was not, so it is asked here,
                    // before any write, with the row itself counting as free.
                    // #4275: from the landing's key index, like every keyed read on this path.
                    switch match.keyAvailability(anchored, lookup: landing.stored(key:)) {
                    case .free:
                        break
                    case .unreadable:
                        unreadableStore += 1
                        unreadableKeys.append(anchored)
                        continue
                    case .taken:
                        // Another card holds the night this row would land on. Moving onto it would merge
                        // two cards (the #2754 measurement), and storing the feed's key would re-create the
                        // drift this arm exists to stop. So the row is left exactly as it was this run and
                        // the reason is logged; the next scout asks again.
                        // copy-inventory:ignore-start  developer diagnostic log, not the app's own voice
                        AgentLog.problem("#3324 ScoutService re-key: \(match.naturalKey) would land on \(anchored), which another card holds; left untouched this run.")
                        // copy-inventory:ignore-end
                        continue
                    }
                }
                // #4106 Phase 1a: written only where it differs, as every write reached from a re-land is.
                match.assign(\.naturalKey, anchored)
                // Seen under the key it now holds, so the feed reconcile below reads it as present.
                seenKeys.insert(anchored)
                // #4147: as above, and this is the arm the harm class actually travels on: a re-key onto
                // a stored row carries Dan's dismissal, his sent record and his thread id with it.
                let titleBefore = match.groupName
                apply(enriched, to: match, now: scoutNow,
                      storedByKey: landing.stored(key:))
                landing.stampTouched(match, changed: wasDirty || match.hasChanges, at: now)
                recordRename(of: match, from: titleBefore, by: target.matchedArm, at: scoutNow,
                             into: &titleRenames)
                updated += 1
            case .insert(let notes):
                let fresh = make(enriched, key: key, stampedAt: landing.nextStamp(at: now))
                // #3330: before it goes in, ask whether a stored row on this night at this room is the
                // same show by the merge's own predicate. The upsert has already decided to INSERT, so
                // this changes nothing about whether the row is written; it records which row the
                // arrival looked like, so the pairing is on the card now rather than after the next
                // launch. Dan's call, 2026-09-21: tag, never refuse.
                //
                // The answer came WITH the decision, computed inside `upsertTarget`'s own do/catch, so a
                // store that could not answer refused this row rather than inserting it untagged. The
                // first draft read the store here with `try?`, which `ScoutStoreReadTests` refused and
                // was right to: folding "could not read" into "nothing like it" invents an emptiness that
                // is itself a claim about Dan's data (#3071, L98, L215).
                fresh.arrivedLookingLike = notes.lookingLike
                // #4130: and whether a pitch has already gone out for this presenter, on this night, in
                // this room. Nothing about the titles is asked, deliberately: the pair this exists for
                // is one every title rule in the app refuses, and what makes it a duplicate pitch is the
                // presenter rather than the billing.
                fresh.arrivedOnAPitchedNight = notes.alreadyPitched
                context.insert(fresh)
                // #4275: into the working set too, so the next event of this source, and every later
                // source of this landing, sees it exactly as a fresh fetch would.
                landing.inserted(fresh)
                inserted += 1
            case .storeUnreadable:
                // The store could not answer whether this key is free, so this row is left alone entirely.
                // A show missing from one run comes back on the next; a merged card does not come back at
                // all (L105). Counted, and named on the summary, because a run that quietly drops shows is
                // indistinguishable from a run that found none (L98).
                unreadableStore += 1
                unreadableKeys.append(key)
            }
        }

        // Reconcile stored prospects against this run's feed: mark ones that dropped out (#133).
        //
        // #801: this now happens only when a SOURCE swept its own feed and said so (`feed`). A
        // hand-added lead (#799) comes through this same function on purpose, so that blocked dates,
        // the #769 do-not-contact suppression and the #798 upcoming-only guard all apply to it exactly
        // as they do to a scouted show. But it sweeps nobody's feed, so it produces no report, and with
        // no report nothing can be marked gone. That is what makes #826 impossible rather than merely
        // guarded: there is no flag left for a future caller to forget to set.
        //
        // Every remaining judgement (is this feed big enough to be believed, is this source past its
        // warmup, does a verdict of "quiet off-season" count as evidence) lives in SourceReport, judged
        // against THIS source's own baseline.
        // #888 part B: the report is RETURNED, and the caller reconciles. It used to be reconciled right
        // here, one source at a time, with a single-element list. So `believable` was never larger than
        // one source, and a show owned by TWO could never satisfy the rule's "every owner was asked",
        // whatever either source said. The careful, conservative half of this design was dead code that
        // read as working.
        //
        // A caller that has several sources' reports (ScoutExtractIngest, which lands a whole batched
        // extract run) now reconciles ONCE with all of them, so a co-listed show can finally be judged.
        //
        // A caller with NO feed (the lead path, #799) gets no report and so cannot reconcile at all.
        // That is still what makes #826 structurally impossible rather than guarded by a flag somebody
        // could forget: there is nothing to forget, because there is nothing to pass.
        let report: FeedReconcile.SourceReport? = feed.map { feed in
            FeedReconcile.SourceReport(
                sourceId: feed.sourceId,
                seenKeys: seenKeys,
                // Presence is judged against the RAW feed's listing URLs, not just what we upserted, so
                // a show we filtered out this run (newly blocked date, do-not-contact) isn't mistaken
                // for one the venue cancelled (#133).
                // #1472: plus the rows this run saw and could not import because the source published no
                // venue for them. A blank venue field is not a cancellation, and the show is right there on
                // the calendar, so it counts as listed even though nothing was upserted from it.
                seenSourceURLs: Set(events.compactMap { $0.sourceUrl }).union(feed.structuralGapURLs),
                structuralGapDates: feed.structuralGapDates,
                feedCount: events.count,
                baseline: feed.baseline,
                successfulCheckCount: feed.successfulCheckCount,
                verdict: feed.verdict,
                rejectedCount: feed.rejectedCount)
        }
        // Several shows by the same org become ONE line with a count. Four separate lines saying the
        // same thing is how a report becomes wallpaper.
        let suppressed = Dictionary(grouping: suppressedShows, by: { $0 })
            .map { SuppressedOrg(orgName: $0.key, showCount: $0.value.count) }
            .sorted { ($0.showCount, $1.orgName) > ($1.showCount, $0.orgName) }

        // #4331 (A2): a row this landing left unstamped because it had no twin when touched is stamped now if a
        // write since (this source's or an earlier one's) has given it one, before the save that carries it.
        landing.stampRowsGivenATwin()

        do {
            // #4334 (A5): through the landing, so a test can fail one source's save and not the next.
            try landing.saveSource(context)
        } catch {
            // #499: everything above was classified/upserted in memory but never persisted.
            //
            // #888 part B: and so it carries NO report. A run whose writes did not land has not swept
            // anything, and letting it reconcile would judge a show absent from a feed that was never
            // actually recorded. Deliberately not merely "safe": there is nothing to reconcile against.
            // #4147: NOTHING is recorded on this path, and that is the rule rather than an omission. The
            // save failed, so the titles in memory are not the titles on disk, and a ledger saying a row
            // was renamed when the store still holds the old name is worse than no ledger at all (L12).
            var outcome = Outcome(found: events.count, inserted: inserted, updated: updated,
                                  skipped: skipped,
                                  collapsedIntoRun: collapsedIntoRun, saveFailed: true)
            outcome.suppressedOrgs = suppressed
            // #3071: carried even onto a run that failed to save. The brand corpus was read (or not)
            // before any of this, and a save failure does not make that read any more readable.
            outcome.degradedReads = degradedReads
            // #4334: classified once, here where the error is, for the landing that decides what comes next.
            outcome.saveFailureScope = landing.classify(error)
            return outcome
        }
        // #4147: AFTER the save and never before, so the ledger records what the store actually holds.
        //
        // A ledger write that fails must not fail the run: the scout's work has already landed, and this
        // is a diagnostic record beside it. It is LOGGED rather than swallowed, because a ledger that
        // silently stopped being written is exactly the state #4068 was in (L11, L98).
        TitleRenameLedger.recordOrLog(titleRenames, now: scoutNow)
        var outcome = Outcome(found: events.count, inserted: inserted, updated: updated, skipped: skipped,
                              collapsedIntoRun: collapsedIntoRun)
        outcome.titleRenames = titleRenames
        outcome.storeUnreadable = unreadableStore
        outcome.storeUnreadableKeys = unreadableKeys
        outcome.suppressedOrgs = suppressed
        outcome.degradedReads = degradedReads
        outcome.report = report
        return outcome
    }

    // Matches an existing prospect that shares ANY of the given run member URLs, checking
    // both the stored sourceListingURL and the stored runSourceURLs (#132). Used when the
    // run's opening night has shifted between scouts so no exact natural key matches: the caller
    // then RE-KEYS that stored record, which is why this must be certain it is the same show.
    //
    // #797: a shared URL alone is not that certainty. An org that publishes its whole season on ONE
    // page gives every show the same listing URL, so URL-only matching handed back an UNRELATED act
    // and the caller re-keyed it, mutating one stored row over and over: twenty shows in, one row
    // out, and Dan's keep/dismiss on it silently transplanted onto a different act.
    //
    // The act and the venue must agree too. That is exactly what a genuine #132 run-window shift
    // preserves (the same act, at the same venue, on moved dates), so the case this exists for still
    // matches, while a season page full of strangers no longer does.
    // #2758: throws, for the reason above.
    private static func matchByAnyRunURL(_ urls: [String], groupName: String, venue: String?,
                                         ambiguous: Set<String> = [],
                                         landing: ScoutLandingStore) throws -> Prospect? {
        // #4116: folded on BOTH sides, so one member addressed with and without its trailing slash is
        // one member. The fold is `ListingURL`'s, shared with `matchByStableSource` below rather than
        // spelled again here (L370).
        let candidates = ListingURL.foldedSet(urls)
        guard !candidates.isEmpty else { return nil }
        // #4275: the landing's working set and its cached folds, rather than a whole table fetch and a
        // fresh fold of every row for each event that reaches this arm.
        // #4460: and only the rows carrying one of these URLs, in the landing's order, rather than every row.
        let all = try landing.rows(.sharingURL(candidates))
        let room = venueKey(venue)
        return all.first { p in
            let folded = landing.fold(of: p)
            let sharesURL = (folded.listingFold.map { candidates.contains($0) } ?? false)
                || !folded.runFolds.isDisjoint(with: candidates)
            guard sharesURL else { return false }
            // #3917: `isSameShowTitle`, not `isConfident`, and the shared URL above is what licenses it.
            // A source that drops or adds a parenthetical keeps publishing the same link, and
            // `isConfident` refuses a one word title outright and anything under 0.6 containment below
            // that, so the arm missed exactly the drift it exists to catch. Measured over the live store
            // before it was changed (`SubtitleVariantMatchTests`): 3 pairs are newly joined here and all
            // three are one show, including Dan's own Jalopy open mic pair from #1590.
            // #4098: on a URL that carries MORE THAN ONE SHOW, the title test is the strict one.
            //
            // The shared URL is what licenses the loose predicate, and on an organisation level page
            // ("metopera.org", a season page, a ticketing host's event index) it licenses nothing: every
            // show in the building shares it. Measured on the live store 2026-09-22, 27 of 1,208 distinct
            // listing URLs carry more than one title, and this arm has no venue test at all, so those are
            // exactly the pages where a subtitle or a billing difference could join two strangers.
            //
            // IT DOES NOT REFUSE OUTRIGHT, which was the other option the issue named. This arm exists
            // for #132, a run whose opening night MOVED, and on a season page a blanket discard would
            // cost that case for every show the venue lists there. Demanding a shared night would cost it
            // too, since a moved opening is the whole shape. So the arm keeps working and asks the
            // question repeat client detection asks, which refuses a one word title and anything under
            // 0.6 containment (L93: name what the fallback gives up rather than leaving it to be found).
            let sharedAmbiguousURL = !candidates.isDisjoint(with: ambiguous)
            guard folded.venueKey == room else { return false }
            return sharedAmbiguousURL
                ? titleIsTheKeySOwn(p.groupName, groupName)
                : GroupNameMatch.isSameShowTitle(p.groupName, groupName)
        }
    }

    // #4029: the venue's OWN opaque production token, read out of a URL both rows already carry.
    //
    // `ShowLink` reads this token and groups on it for DISPLAY, because it was measured to be stable
    // across every night of a run and to carry none of the title. No arm read it, so the app told Dan
    // two rows were one show while still minting the second. Both the reader and the discard rule come
    // from `ShowLink`, never a second copy here (L370).
    //
    // WHY IT MAY RE-KEY, measured on the live store 2026-09-20 over a WAL inclusive clone of 1,275 rows.
    // 230 rows carry a venuetix token and 228 tokens are distinct, so exactly TWO pairs share one while
    // holding disjoint URL sets, and both pairs are one production under an identical folded title at an
    // identical folded venue. `ShowLink.poisonedTokens` discards NOTHING over that whole store. At ingest
    // a wrong join costs a row rather than a re-render, which is why the would-have-matched report was
    // taken before this was allowed to write anything.
    //
    // NOT corroborated by a run overlap, unlike `matchByConcertIdentity`. That arm demands one so a
    // production remounted next season becomes a new card rather than inheriting an old dismissal, and
    // that is right for a SPAN. It is wrong here: both live pairs are single nights 18 and 70 days apart,
    // so an overlap test refuses both and the arm would fire on nothing. What stands in for it is that
    // the token is the VENUE'S own identifier for one production, plus the folded title, plus the
    // poisoned-token discard. What protects Dan's decision is `ShowOutcome.newNightReopens` at the join,
    // not a refusal to join at all.
    // #2758: throws, for the reason the arms above give.
    // #4056: every token this sweep must refuse, over the stored rows AND every row the sweep carries.
    //
    // ONE walk for the whole batch. The discard is asked over every stored row rather than over the
    // candidates, for the reason `ShowLink`'s own comment gives: a venue stamping one token across its
    // season reveals itself through rows that sit alone under their own titles, so narrowing the question
    // to candidates cannot see it. The incoming rows join that population for the same reason, and
    // because a sweep that brings two disagreeing listings should not have to wait for a later one to
    // notice (L487 is the same shape: a single moment cannot see what moved across time).
    // THROWS rather than answering with an empty store, which #3071 and `ScoutStoreReadTests` both
    // forbid and which this got wrong first time round. An empty poison set means NOTHING IS REFUSED, so
    // a read that failed would license every join this rule exists to prevent, in the one situation where
    // the code knows least (L215, L105: an empty collection returned on a throw is indistinguishable from
    // a correct read of an empty one, and here the two have opposite consequences).
    // #4098: the two URL arms' own discard, computed over the SAME walk as the token one above: every
    // stored row plus every incoming row, once per batch rather than once per row.
    //
    // TWO SETS because the two arms ask different questions, and each is named where it is used rather
    // than one set being reused for tidiness (L370).
    struct AmbiguousURLs: Equatable, Sendable {
        // For `matchByStableSource`, which tests the venue: a URL carrying more than one show AT ONE
        // VENUE.
        var atAVenue: Set<String> = []
        // For `matchByAnyRunURL`, which does not: a URL carrying more than one show anywhere.
        var anywhere: Set<String> = []

        static let none = AmbiguousURLs()
    }

    // #4098: the title test the two URL arms fall back to on a page carrying more than one show, in ONE
    // place so the two arms cannot drift apart on the question (L370).
    //
    // IT IS THE NATURAL KEY'S OWN FOLD, and `GroupNameMatch.isConfident` is NOT, which is the correction
    // this branch needed. That function strips a trailing subtitle after a colon (`stripProgramSubtitle`,
    // #105, so a booking sheet's "Presenter: Program" matches a venue's "Presenter"), so on a season page
    // "Back to Shakespeare" and "Back to Shakespeare: An Evening of Sonnets and Songs" are CONFIDENT: the
    // strict fallback joined exactly the pair it was added to refuse, and the first ingest fixture written
    // against it proved it did.
    //
    // WHAT REMAINS JOINABLE on such a page, which is the reason this is not a blanket refusal: a title
    // that folds to the same key. #132 is a run whose OPENING NIGHT moved, where the title is unchanged
    // and the date is not, and that is still recognised here. What is given up is a genuine subtitle
    // drift on an ambiguous page: it mints a second row, which is visible on the queue and reversible,
    // rather than re-keying a stored row, which carries Dan's dismissal onto a show he never saw (L93).
    private static func titleIsTheKeySOwn(_ a: String, _ b: String) -> Bool {
        ShowLink.foldedTitle(a) == ShowLink.foldedTitle(b)
    }

    static func ambiguousURLsForBatch(_ incoming: [AssembledProspect],
                                      storedRows: () throws -> [Prospect]) throws -> AmbiguousURLs {
        let stored = try storedRows().flatMap { ambiguityEntries(of: ScoutLandingStore.Fold($0)) }
        let seen = stored + ambiguityEntries(of: incoming)
        return AmbiguousURLs(atAVenue: ShowLink.ambiguousURLs(seen, scopedByVenue: true),
                             anywhere: ShowLink.ambiguousURLs(seen, scopedByVenue: false))
    }

    // What one stored row contributes to the ambiguity walk: each folded URL it carries, with its title as
    // written and its folded room. ONE builder for both halves of the walk, so the stored rows and the
    // incoming ones cannot come to be entered differently (L370).
    nonisolated static func ambiguityEntries(of folded: ScoutLandingStore.Fold)
        -> [(url: String, title: String, venue: String)] {
        folded.allURLFolds.map { (url: $0, title: folded.groupName, venue: folded.foldedVenue) }
    }

    nonisolated static func ambiguityEntries(of incoming: [AssembledProspect])
        -> [(url: String, title: String, venue: String)] {
        incoming.flatMap { p -> [(url: String, title: String, venue: String)] in
            let room = ShowLink.foldedVenue(p.venue)
            return ListingURL.foldedSet((p.sourceListingURL.map { [$0] } ?? []) + p.runSourceURLs)
                .map { (url: $0, title: p.groupName, venue: room) }
        }
    }

    // The store is the reader on every shipping path. The seam exists so the FAILED read can be
    // exercised at all: a healthy in-memory store never throws, so a test that only ever hands it a
    // working one proves nothing about the branch that matters most, which is the one that decides
    // whether an unreadable store refuses every token or none (L140). Same reasoning, and the same
    // shape, as `Prospect.keyAvailability(_:lookup:)`.
    // #4333: the FROM-SCRATCH walk, every stored row freshly folded. The landing answers from its tables
    // (`ScoutLandingStore.poisonedTokens(adding:)`); this is what `.everyRead` and the tests compare against.
    static func poisonedTokensForBatch(_ incoming: [AssembledProspect],
                                       storedRows: () throws -> [Prospect]) throws -> Set<String> {
        let stored = try storedRows()
        return ShowLink.poisonedTokens(stored.flatMap { poisonEntries(of: ScoutLandingStore.Fold($0)) }
                                       + poisonEntries(of: incoming))
    }

    // What one stored row, and what a batch, contribute to the token walk. ONE builder for each half, shared
    // by the walk above and by the landing's tables (`ScoutLandingStore`), so the two cannot come to enter a
    // row differently (L370).
    nonisolated static func poisonEntries(of folded: ScoutLandingStore.Fold)
        -> [(token: String, title: String, venue: String)] {
        folded.tokens.map { (token: $0, title: folded.foldedTitle, venue: folded.foldedVenue) }
    }

    nonisolated static func poisonEntries(of incoming: [AssembledProspect])
        -> [(token: String, title: String, venue: String)] {
        incoming.flatMap { p -> [(token: String, title: String, venue: String)] in
            let urls = (p.sourceListingURL.map { [$0] } ?? []) + p.runSourceURLs
            let theirTitle = ShowLink.foldedTitle(p.groupName)
            let theirRoom = ShowLink.foldedVenue(p.venue)
            return urls.compactMap(ProductionToken.inURL).map { (token: $0, title: theirTitle, venue: theirRoom) }
        }
    }

    private static func matchByProductionToken(_ urls: [String], groupName: String, venue: String?,
                                               poisoned: Set<String>,
                                               landing: ScoutLandingStore) throws -> Prospect? {
        let incoming = Set(urls.compactMap(ProductionToken.inURL))
        guard !incoming.isEmpty else { return nil }
        let usable = incoming.subtracting(poisoned)
        guard !usable.isEmpty else { return nil }
        // #4460: only the rows carrying a usable token, in the landing's order.
        let all = try landing.rows(.sharingToken(usable))
        let title = ShowLink.foldedTitle(groupName)
        let room = venueKey(venue)

        return all.first { p in
            let folded = landing.fold(of: p)
            guard !Set(folded.tokens).isDisjoint(with: usable) else { return false }
            // The natural key's OWN fold on both sides, which is what makes this a canonical function
            // rather than a similarity judgement and is why it can join with no human in the loop. It is
            // also what lets "Nihao Broadway" and "Nihao Broadway!" through, since the fold removes the
            // trailing mark, while refusing two different shows that merely share a room.
            return folded.foldedTitle == title && folded.venueKey == room
        }
    }

    // Venue equality for the re-key guards: a missing venue on both sides still counts as "the same
    // venue" (it is the same absence of information, which is the pre-#797 behavior for that case).
    //
    // #1686: compared through the SAME fold the natural key uses, not a raw lowercase. These guards exist
    // for the case where a title has drifted and the show must be recognised by its listing, its date and
    // its room instead, which is precisely when the room is also liable to be respelled by the same
    // extract run. A raw compare meant one variance defeated the guard designed for the other: three of
    // the four YNYC pairs on the live store carry the IDENTICAL season-page URL on both rows, so this
    // should have caught every one of them and instead inserted a second card.
    //
    // #4275: written as the ONE SIDE of that comparison, so a stored row's half is folded once per
    // landing (`ScoutLandingStore.Fold.venueKey`) rather than once per event per row, and every arm
    // compares `venueKey(a) == venueKey(b)`.
    nonisolated static func venueKey(_ raw: String?) -> String {
        guard let raw, !raw.trimmingCharacters(in: .whitespaces).isEmpty else { return "" }
        return VenueNormalization.normalizeForKey(raw)
    }

    // #1260 Phase 2: a merged prospect identified by its persisted synthetic concert id, so a re-scout
    // recognizes the SAME merged concert even when its name and every recruiting URL changed (a reorder or
    // refreshed links). Only ever fires for a merged cluster (isMerged gate), and the id already encodes
    // date+venue, so the venue test is belt-and-braces against a hash-collision, never load-bearing. Fetch-all
    // + filter, like matchByStableSource; the store is small.
    //
    // #1528: and a REAL feed production id now matches too, which is the whole fix for a run whose opening
    // night moves. OvationTix and VenueTix tag every night of one show with a shared id and pass
    // `sourceUrl: nil`, so when the first night plays and leaves the feed, the key drifts, both URL arms
    // find nothing, and this arm's `isMerged` gate refused the one piece of identity actually on the row.
    // A new prospect appeared every day and Dan re-triaged a show he had dismissed.
    //
    // NOT simply "any non-empty seriesId", because the field is not reliably a production id. The extract
    // runbook (§3b) tells the paid AI to copy any "Series:" marker off a page verbatim, and a page reading
    // "Series: Broadway Sessions" is a SEASON spanning different productions. Matching on that would
    // re-key a stored prospect onto a different show while keeping its dismissal, sent record and thread
    // id, which is precisely the #797 failure. So a real id carries identity only with two corroborations
    // a season marker cannot fake: the titles must be the same act, and the two RUNS must overlap in time.
    //
    // The overlap test is also what makes a remount safe, with no arbitrary window constant. A run whose
    // opening night creeps forward (or backward: a feed can GAIN an earlier night, which is how Jena
    // Friedman drifted) still overlaps its own stored dates. The same production remounted next season
    // does not, so it correctly becomes a new card Dan is asked about rather than silently inheriting an
    // old dismissal and vanishing.
    // #2758: THROWS rather than swallowing. A swallowed fetch here, answering an empty array, answers "no
    // match" for a store that could not answer, which sends the chain to the final insert, the most
    // destructive of the five arms: it puts a new row on a key another row may already hold.
    private static func matchByConcertIdentity(_ seriesId: String?, groupName: String,
                                               openingNight: String?, runEndDate: String?, venue: String?,
                                               landing: ScoutLandingStore) throws -> Prospect? {
        guard let seriesId, !seriesId.isEmpty else { return nil }
        // #4460: only the rows holding this series id, in the landing's order.
        let all = try landing.rows(.series(seriesId))
        let room = venueKey(venue)
        let sharing = all.filter { $0.seriesId == seriesId && landing.fold(of: $0).venueKey == room }

        // A synthetic same-date id already encodes date and venue and is minted only for a
        // mergeSameDateVenue source, so it needs no corroboration: recognizing a concert whose NAME
        // changed is that path's entire purpose (#1260) and a title check would defeat it.
        // #4040: ANCHORED to the row asking. The bare prefix test this used to read asks only whether a
        // string starts with a namespace this app reserves, never who wrote it, and the extract run copies
        // a page's series marker verbatim into this field. So the corroboration skipped below rested on a
        // claim about MINTING that an arriving value could defeat. A synthetic id is its own date and
        // folded venue, so requiring it to NAME them takes nothing from the #1260 path and removes every
        // case where the id says something the row does not.
        if SameDateVenueMerge.isMerged(seriesId, naming: openingNight, venue: venue) {
            // #4040: DETERMINISTIC, by the same rule and for the same reason as the branch below, which
            // this one contradicted two lines above it. It returned `sharing.first` over an unordered
            // fetch while its sibling's comment said in as many words: "never `first` on an unordered
            // fetch... an arbitrary pick would land Dan's dismissal on a different row each sweep."
            //
            // Reproduced through the real `apply` before this changed (`MergedIdArbitraryPickTests`):
            // two stored rows sharing one synthetic id, one of them dismissed, and the incoming show
            // came out DISMISSED with that row inserted first and LIVE with it inserted second. That is
            // Dan's refusal of one act landing on a show he never saw, which is the #797 failure, and
            // the suite was intermittently red across repeated runs because the pick really is
            // arbitrary rather than merely unspecified.
            //
            // The corroboration question this branch deliberately skips is NOT settled by this and is
            // still #4040's: the id is date plus venue, so a source flagged `mergeSameDateVenue` that
            // genuinely runs two different shows a night fuses them with no title test. Measured
            // 2026-09-20: 1 of 74 watched sources carries that flag, 9 rows carry a synthetic id and no
            // id is held by more than one row, so that half is inert today and rests on a human
            // decision on the watchlist rather than on a property of the code.
            return theOnlyRowThisMayReKey(sharing)
        }

        let corroborated = sharing.filter {
            GroupNameMatch.isConfident($0.groupName, groupName)
                && runsOverlap(storedStart: $0.performanceDate, storedEnd: $0.runEndDate,
                               incomingStart: openingNight, incomingEnd: runEndDate)
        }
        // Deterministic, never `first` on an unordered fetch. Today's store already holds four rows sharing
        // one id, so an arbitrary pick would land Dan's dismissal on a different row each sweep. A row
        // carrying any history wins (it is the one holding a decision or an email); otherwise the freshest,
        // because these rows are a time series and the oldest is the most stale, typically already past
        // FeedReconcile's gone threshold and hidden from the queue.
        // #4024 recorded that this was still an arbitrary pick where TWO candidates carry history, because
        // nothing here had the refusal the merge ladders get from `mustDefer`. #4074 gives it one.
        return theOnlyRowThisMayReKey(corroborated)
    }

    // #4074: the single row this arm may re-key, or NOTHING where more than one candidate carries a
    // record of Dan's.
    //
    // Dan's call, 2026-09-20 (this session, in chat): refuse, the way the two merge ladders already do
    // through `mustDefer`. A re-key carries a stored row's dismissal, its recipients, its sent record and
    // its thread id onto whatever the incoming listing is, so picking the wrong one of two rows that both
    // hold history moves his refusal of one show onto another (#797). Declining costs a duplicate card
    // staying up until the next sweep, which he can see and merge; the re-key is silent and cannot be
    // undone from the card.
    //
    // Latent rather than live, stated so nobody reads the guard as a fix for something happening now: over
    // the live store on 2026-09-20 exactly one `seriesId` is held by more than one row (pk 139 and pk 655,
    // both `The Passion of Mr. Cardboard` at SoHo Playhouse, both dismissed under DIFFERENT reasons), and
    // both runs ended in July, so no incoming listing carries that id and this branch cannot be reached
    // for them. What the guard buys is that the day a live pair appears, the answer is already decided.
    //
    // Returning nil does not end the chain: `upsertTarget` goes on to its remaining arms and inserts if
    // none of them match, which is the duplicate-card outcome above rather than a lost show.
    private static func theOnlyRowThisMayReKey(_ candidates: [Prospect]) -> Prospect? {
        let withHistory = candidates.filter(NaturalKeyVenueMigration.hasOutreachHistory)
        guard withHistory.count <= 1 else {
            // copy-inventory:ignore-start  developer diagnostic log, not the app's own voice (#915)
            AgentLog.note("#4074 ScoutService: \(withHistory.count) stored rows sharing this id carry "
                          + "outreach history; leaving them for Dan rather than re-keying one.")
            // copy-inventory:ignore-end
            return nil
        }
        // Deterministic below the refusal, for the reason the sibling branch already records: these rows
        // are a time series and the oldest is the most stale, typically already past FeedReconcile's gone
        // threshold and hidden from the queue (L343, L419).
        return withHistory.first ?? candidates.max(by: { $0.ingestedAt < $1.ingestedAt })
    }

    // Do these two runs cover any of the same days? Dates are ISO `yyyy-MM-dd`, so string ordering IS date
    // ordering. A run with no end date is a single night. A run with no start cannot be compared at all and
    // is deliberately treated as no overlap: an unknown date must never authorize a re-key.
    // #3278: internal and NONISOLATED, so the contradiction rule reads the SAME overlap test the re-key
    // guard uses instead of keeping a second copy of it (L263). Nonisolated is what it always should have
    // been: it reads four strings and returns a Bool, and it inherited ScoutService's main actor isolation
    // only by sitting inside it.
    nonisolated static func runsOverlap(storedStart: String?, storedEnd: String?,
                                    incomingStart: String?, incomingEnd: String?) -> Bool {
        guard let storedStart, let incomingStart else { return false }
        let storedClose = storedEnd ?? storedStart
        let incomingClose = incomingEnd ?? incomingStart
        return incomingStart <= storedClose && storedStart <= incomingClose
    }

    // A prospect identified by its stable source listing (URL + date), used to recognize
    // the same event when its display title has drifted (#29). Fetch-all + filter is fine
    // for the local store's size and avoids optional-predicate gymnastics.
    //
    // #797: the venue must agree as well. On a season page every show shares one listing URL, so URL
    // + date alone would re-key one show onto a DIFFERENT act that happens to play the same night.
    // The title is deliberately NOT checked here: recognizing a drifted title is this matcher's
    // entire purpose, so the act name is the one thing it cannot rely on.
    // #2758: throws, for the reason above.
    private static func matchByStableSource(url: String?, date: String?, venue: String?,
                                            groupName: String,
                                            ambiguous: Set<String> = [],
                                            landing: ScoutLandingStore) throws -> Prospect? {
        guard let url, !url.isEmpty else { return nil }
        // #4098: how ambiguous the page is, asked once rather than per candidate row. Scoped BY VENUE,
        // because this arm demands the venue agrees: what matters here is whether this page carries more
        // than one show IN THIS ROOM, which is exactly the season page shape #4032 was reproduced on.
        let foldedURL = ListingURL.fold(url)
        let pageCarriesMoreThanOneShow = ambiguous.contains(foldedURL)
        // #4460: only the rows carrying this page, in the landing's order; the listing test below still
        // decides, since a row may carry it as a run URL rather than its listing.
        let all = try landing.rows(.sharingURL([foldedURL]))
        let room = venueKey(venue)
        return all.first {
            // #4116: both sides FOLDED rather than compared raw, so one page addressed with and without
            // its trailing slash is one page. (#4275: the stored side's fold is the landing's cached one,
            // `Fold.listingFold`, and a stored row with no listing URL folds to nil, which never equals
            // the incoming page, so two absent addresses still never read as one listing.) Measured on the live store 2026-09-21: four stored pairs
            // share a night and a page and differ only by that slash, and every one is a second billing
            // of one concert. The fold touches the trailing slash and nothing else; the reasoning for
            // each rule NOT adopted is recorded on `ListingURL` rather than here.
            let folded = landing.fold(of: $0)
            guard folded.listingFold == foldedURL, $0.performanceDate == date,
                  folded.venueKey == room else { return false }
            // #4032: and the two titles must be the same SHOW. The comment above says the venue is what
            // makes URL plus date safe, and on a single venue's season page that is no protection at
            // all: every show shares one URL and one room, so the predicate is satisfied by two
            // different acts playing the same night. Measured on the live store 2026-09-19, three such
            // sets exist right now and two are genuinely different shows (`Back to Shakespeare` against
            // `Marlise (A New Golden Age Musical)` at The Players Theatre, and `Hamill, TX` against
            // `SheDFW Theater Festival` at Stage West). Reproduced through the real `apply` in
            // `SeasonPageStableSourceTests`: the stored row was RENAMED onto the incoming show and its
            // dismissal went with it.
            //
            // `isSameShowTitle` rather than `isConfident`, because this arm exists to recognise a title
            // that DRIFTED (#29) and a strict test would defeat its purpose. That predicate accepts one
            // title plus a subtitle, which is what a venue tweak looks like, and refuses an unrelated
            // name (#3917, where it was measured against exactly these pairs).
            //
            // WHAT THIS GIVES UP, stated rather than left to be discovered (L93). A drift that is not a
            // subtitle, a genuine rename to an unrelated string, is no longer recognised here and mints
            // a second row. That is the right direction to fail: a duplicate row is visible on the queue
            // and can be merged, while a silent re-key carries Dan's dismissal, his sent record and his
            // thread id onto a show he never saw. Measured today the trade costs nothing: of the three
            // live sets, the only same-show pair is a subtitle pair and is still joined.
            // #4098: and on a page carrying more than one show in this room, the title test is the
            // strict one. #4032's fix made this arm ask `isSameShowTitle`, which accepts one title plus
            // a subtitle; on a season page two different shows can differ in exactly that way, and the
            // venue removes nothing because every candidate shares it. What is given up is a real
            // subtitle drift on such a page, which mints a second row rather than re-keying a stored one:
            // visible on the queue, and the direction this milestone has chosen every time (L93).
            return pageCarriesMoreThanOneShow
                ? titleIsTheKeySOwn($0.groupName, groupName)
                : GroupNameMatch.isSameShowTitle($0.groupName, groupName)
        }
    }

    // #4331: `stampedAt` is the landing's stamp for this row (`ScoutLandingStore.nextStamp`), so a row inserted
    // and a row updated by one landing read in the order it applied them. It is also the row's first sighting.
    private static func make(_ p: AssembledProspect, key: String, stampedAt: Date) -> Prospect {
        let prospect = Prospect(
            naturalKey: key, groupName: p.groupName, discipline: p.discipline, venue: p.venue,
            performanceDate: p.performanceDate, sourceListingURL: p.sourceListingURL,
            priorRelationship: p.priorRelationship, production: p.production, profile: p.profile,
            coverage: p.coverage, fitScore: p.fitScore, tier: p.tier, fitReason: p.fitReason,
            matchedClientName: p.matchedClientName, possibleMatchSource: p.possibleMatchSource,
            possibleMatchName: p.possibleMatchName,
            ingestedAt: stampedAt,
            runEndDate: p.runEndDate, partOfRelatedRun: p.partOfRelatedRun, runSourceURLs: p.runSourceURLs,
            runNights: p.runNights)
        // #3495: anchored on the way IN, exactly as `apply` anchors on every re-ingest. These two fields
        // are what `Prospect.scoutAnchoredNaturalKey` reads, and `NaturalKeyVenueMigration` re-keys every
        // row from that at launch, so a row minted without them is re-keyed from whatever its card ends up
        // DISPLAYING. That is the precise thing #1886 added them to prevent, and two shipped features
        // rewrite a display field on purpose (#1274 a rename, #1846 a merged card taking the watchlist's
        // room name).
        //
        // Set here rather than left to the first re-ingest, for the reason the `genreDecidedBy` stamp one
        // line down already records: a row that acquires the field only when something else happens spends
        // its whole first life unprotected, and the population that can never be reached by a
        // forward-only writer is the NEWEST rows (L389).
        prospect.scoutGroupName = p.groupName
        prospect.scoutVenue = p.venue
        prospect.setPresenter(p.presenter, from: .scout)       // #2453
        prospect.presenterWasTheRoom = p.presenterWasTheRoom   // #1788
        prospect.performanceStartTimes = p.startTimes          // #1699
        prospect.startTimesVary = p.startTimesVary             // #1699
        prospect.nightStartTimes = p.nightStartTimes           // #1699
        prospect.location = p.location
        prospect.downbeatClientId = p.downbeatClientId
        prospect.passedOnThisShow = p.passedOnThisShow
        prospect.sourceIds = p.sourceIds        // #771
        // #1663: stamp the decider on the way in, so the FIRST time a second source touches this row the
        // precedence rule already knows whose genre is sitting there. Without it every new row would spend
        // its first collision unprotected, which is the whole defect, just once per row instead of forever.
        prospect.disciplineGenreSourceKey = GenrePrecedence.sourceKey(p.sourceIds)
        prospect.producerAxisSourceKey = GenrePrecedence.sourceKey(p.sourceIds)   // #1949
        // #1954: and the presenter the two axes above are DERIVED from, stamped on the way in for the
        // same reason they are: without it every new row spends its first collision unprotected.
        prospect.presenterSourceKey = GenrePrecedence.sourceKey(p.sourceIds)
        prospect.seriesId = p.seriesId          // #1260 Phase 2: persist the merged-concert identity
        prospect.setScoutConflict(p.conflictKey)    // #901
        return prospect
    }

    // Refresh scout-owned fields; never touch status/dismissReason (Dan owns those).
    // #1648: `now` is used for ONE thing, deciding whether this row's contact answer has aged past its
    // 90 day expiry, so the shared re-score at the end reads `.unchecked` for a stale one. Derived from
    // the `today` the run already threads rather than a second clock, so a test that pins the day pins
    // this too, and day precision is ample for a 90 day window.
    // #1663: the genre decision, in one place, reached by both non-override arms of `apply`.
    //
    // Kept as a whole: discipline, production and the reason all come out of ONE EventClassifier.classify
    // call, so taking some and keeping others would leave the row describing two different shows. When the
    // stored genre stands, its reason stands with it.
    private static func takeIncomingClassification(_ p: AssembledProspect, into existing: Prospect) {
        let incomingKey = GenrePrecedence.sourceKey(p.sourceIds)

        let storedDiscipline = Discipline(rawValue: existing.discipline) ?? .other
        let incomingDiscipline = Discipline(rawValue: p.discipline) ?? .other
        let mergedDiscipline = GenrePrecedence.mergedDiscipline(
            stored: storedDiscipline, storedKey: existing.disciplineGenreSourceKey,
            incoming: incomingDiscipline, incomingKey: incomingKey)
        // Stamp whenever the value standing is the one this source brought, so "may this source correct
        // what is here" keeps answering yes for the source actually responsible for it.
        if mergedDiscipline == incomingDiscipline { existing.assign(\.disciplineGenreSourceKey, incomingKey) }
        GenreVisibility.write(mergedDiscipline, to: existing)   // #1658

        let stored = (production: Production(rawValue: existing.production) ?? .unknown,
                      profile: Profile(rawValue: existing.profile) ?? .neutral)
        let incoming = (production: Production(rawValue: p.production) ?? .unknown,
                        profile: Profile(rawValue: p.profile) ?? .neutral)
        let mergedProducer = GenrePrecedence.mergedProducer(
            stored: stored, storedKey: existing.producerAxisSourceKey,
            incoming: incoming, incomingKey: incomingKey)
        if mergedProducer == incoming { existing.assign(\.producerAxisSourceKey, incomingKey) }
        existing.assign(\.production, mergedProducer.production.rawValue)
        existing.assign(\.profile, mergedProducer.profile.rawValue)

        // #1949: recomputed, never copied from either source, because they are conclusions about the whole
        // classification and the classification may now come from two of them.
        let derived = EventClassifier.derived(discipline: mergedDiscipline,
                                              production: mergedProducer.production,
                                              profile: mergedProducer.profile,
                                              venue: existing.venue)
        existing.assign(\.coverage, derived.coverage.rawValue)
        existing.assign(\.fitReason, derived.fitReason)
    }

    // #3001: `storedByKey` is how a night RELEASED to another card is re-checked at fold time. Required
    // rather than defaulted, so a caller cannot quietly get the old subtract-forever behaviour (L168).
    // #2691 / #3324: the opening night a stored row carries after this scout. The feed's own opening,
    // UNLESS Dan dropped it, in which case the earliest night left once his drops are subtracted, and the
    // row's current date if nothing is left. One answer, read by `apply` for `performanceDate` and by the
    // `.reKey` arm for the key it stores (plan 2.11: two writes computing this separately disagreed).
    static func scoutOpening(fed: String?, fedNights: [String], existing: Prospect,
                             lookup: (String) throws -> Prospect?) -> String? {
        guard let fed, DroppedNight.all(on: existing).contains(where: { $0.night == fed }) else { return fed }
        return DroppedNight.keeping(fedNights, on: existing, lookup: lookup).min() ?? existing.performanceDate
    }

    // #4147: one rename, recorded where the title was overwritten.
    //
    // ONE function rather than the same four lines at both `apply` call sites, because the two have to
    // answer identically and a drift between them would be silent in the direction that records nothing
    // (L370). It records only a title that actually CHANGED: an ordinary re-ingest rewrites the field
    // with the same string on almost every row, and a ledger holding those would bury the handful of
    // entries anybody is looking for.
    //
    // A rename Dan made himself is invisible here by construction: `apply` refuses to write `groupName`
    // at all once `groupNameOverriddenByDan` is set, so the value cannot differ. This ledger is about
    // what the SCOUT did (L11).
    private static func recordRename(of prospect: Prospect, from before: String, by arm: MatchArm?,
                                     at now: Date, into entries: inout [TitleRenameLedger.Entry]) {
        guard prospect.groupName != before else { return }
        entries.append(TitleRenameLedger.Entry(key: prospect.naturalKey, from: before,
                                               to: prospect.groupName,
                                               // A decision that reached a write always names its arm, so
                                               // an unnamed one is a shape nobody has met. Recorded as
                                               // such rather than dropped or guessed at (L11).
                                               arm: arm?.rawValue ?? "unknown", at: now))
    }

    private static func apply(_ p: AssembledProspect, to existing: Prospect, now: Date,
                              storedByKey: (String) throws -> Prospect?) {
        // #1274: track the latest scout-emitted name always, so a "reset to scout name" restores the
        // real current name even for a show Dan renamed several scouts ago. But only write it to the
        // DISPLAY groupName when Dan has not overridden it; once he renames a show, his name stands and
        // the scout stops clobbering it. naturalKey is left as-is by the rename, so this row still
        // matched by exact key above (no duplicate).
        existing.assign(\.scoutGroupName, p.groupName)
        if !existing.groupNameOverriddenByDan {
            existing.assign(\.groupName, p.groupName)
        }
        // #2453: a BLANK may not beat real data. Both ingest doors drain a presenter that is only the
        // room's own name (`ExtractedEventGuard.presenterThatIsNotTheRoom`, applied at :546 here and at
        // ScoutExtractResults.swift:50), and a rental room bills itself that way on every listing it
        // publishes, so this line used to empty the field on every ordinary re-read of those pages. That
        // is fine while the scout is the only writer, because the same page can put its own answer back.
        // It is data loss the moment anything else writes the field: an answer from the stored-row sweep
        // (#2454), from the batched AI pass (#2456) or from Dan would live until the next run of that
        // source and leave no trace it had ever been answered, so the next batch would pay for it again.
        //
        // Narrow on purpose: this refuses an ERASURE, not an update. A re-read that actually NAMES a
        // producer still wins, because the page is what this field is about, and the stamp moves with the
        // value so the row never claims an answer came from somewhere it did not.
        if existing.presenterSurvivesAnOrdinaryReRead,
           OrganiserNaming.onlyTheActIsNamed(presenter: p.presenter) {
            // The name stands, and so must the explanation beside it: `presenterWasTheRoom` says this
            // row's BLANK presenter is a name Overture discarded, and this row's presenter is not blank.
            // Copying this listing's flag onto it would have the card assert an empty field while naming
            // an organisation (L55).
            existing.assign(\.presenterWasTheRoom, false)
        } else {
            // #1954: and WHICH SOURCE may write it, which is a different question from #2453's above.
            // That one asks whether an ordinary scout re-read may empty a name a sweep, the AI pass or
            // Dan put there. This one asks whether a DIFFERENT scout source may take a field the first
            // one filled, and until now nothing did: the presenter was last writer wins while the genre
            // and producer axes derived FROM it were not (#1663, #1949).
            //
            // A source correcting its OWN reading is untouched, which is every ordinary re-read, so this
            // changes nothing for a row one source owns.
            let incomingKey = GenrePrecedence.sourceKey(p.sourceIds)
            if GenrePrecedence.incomingPresenterStands(stored: existing.presenter,
                                                       storedKey: existing.presenterSourceKey,
                                                       incoming: p.presenter,
                                                       incomingKey: incomingKey) {
                existing.setPresenter(p.presenter, from: .scout)
                // Stamped where the value standing is the one THIS source brought, exactly as the two
                // axes are, so "may this source correct what is here" keeps answering yes for whoever is
                // actually responsible for the name.
                existing.assign(\.presenterSourceKey, incomingKey)
                // And the explanation travels with the value it explains: `presenterWasTheRoom` says why
                // THIS listing's presenter is blank, and it belongs only to a row whose presenter came
                // from this listing (L55, the same reason the branch above it states).
                existing.assign(\.presenterWasTheRoom, p.presenterWasTheRoom)   // #1788
            }
            // NOTHING is written on the losing path, not even the value the row already holds. Writing it
            // back would run through `setPresenter(_:from: .scout)`, which stamps `presenterSource`, so a
            // name a sweep, the batched AI pass or Dan put there would be recorded as the scout's on the
            // first visit by any other source, and #2453's refusal (which reads that stamp) would stop
            // protecting it. The value and the record of who wrote it are one fact (L544).
        }
        existing.assign(\.location, p.location)
        // #1886: track the listing's own spelling of the room always, the way scoutGroupName tracks the
        // scout's own name above, so the key stays anchored to what this source keeps sending even after
        // #1846's merge relabels the card with the name Dan entered on the watchlist.
        existing.assign(\.scoutVenue, p.venue)
        existing.assign(\.venue, p.venue)
        // #2691: the feed's opening night, UNLESS Dan dropped it. Assigning it back would move the card
        // to a night he explicitly said no to, which is the same silent undo the nights subtraction below
        // prevents, one field over. `keeping` answers the feed's own date whenever nothing was dropped,
        // so an ordinary show is untouched.
        //
        // #3324: asked through `scoutOpening`, the same function the `.reKey` arm stores its key from, so
        // the key and this date cannot name different nights.
        existing.assign(\.performanceDate, scoutOpening(fed: p.performanceDate, fedNights: p.runNights,
                                                         existing: existing, lookup: storedByKey))
        existing.assign(\.sourceListingURL, p.sourceListingURL)
        existing.assign(\.seriesId, p.seriesId)   // #1260 Phase 2: keep the merged-concert identity current
        // #1663/#1845: the classification block (discipline, production, profile, coverage, fitReason) all
        // moved OUT of this unconditional refresh and into the arms below. Every one of them comes out of
        // ONE EventClassifier.classify call, so refreshing some here while the arms decide the others let a
        // row keep one source's genre and take another's profile. The score is recomputed from the ROW, so
        // that mixture scored a show neither source ever described. Measured on the live store 2026-08-01:
        // the two readings of one Jalopy show sit 8 points apart, the full width of the queue.
        existing.assign(\.possibleMatchSource, p.possibleMatchSource)
        existing.assign(\.possibleMatchName, p.possibleMatchName)
        // #384: scout-owned, refreshed every run like the other scoring inputs. Read by Step B below
        // (via ClassificationOverride.rescored) and by the fresh score in p.
        existing.assign(\.passedOnThisShow, p.passedOnThisShow)
        // #901: scout-owned, and refreshed to whatever is true NOW: a vacation Dan cancelled stops
        // flagging the show, and a shoot booked over a week he was merely away re-flags it under a new
        // key, which is a fact he has not seen and so is not covered by anything he cleared.
        existing.setScoutConflict(p.conflictKey)
        // NOTE: never touch conflictClearedKey here; Dan owns that decision (#901).
        // NOTE: never touch classificationOverriddenByDan here; Dan owns that flag. #1533 retired the
        // classification-confidence pair that used to be refreshed and conditionally cleared here (#1132),
        // along with the badge whose resurfacing was the only reason either was tracked.

        // Two guards run over this prospect, and they are ORTHOGONAL: Dan can correct a prospect's
        // discipline at any time, unrelated to whether a performer match separately corrected its
        // relationship, and nothing stops both being true at once. So the two field groups resolve
        // INDEPENDENTLY, in order, rather than as nested branches. Checking classificationOverriddenByDan
        // first as an outer short-circuit would send a doubly-flagged prospect down the recompute-from-
        // the-fresh-org-match path and silently revert the performer correction, which is the exact
        // failure this guard exists to prevent, just triggered by an unrelated Dan action (#750).

        // Step A: the relationship identity. Gated only by the performer-match lock and this run's org
        // match; classificationOverriddenByDan has no say here.
        if p.orgMatchConfident {
            // A fresh, confident ORG match outranks a standing performer guess, so it wins and clears
            // the correction. The lock is a guard against silent reversion, never a permanent one-way
            // override.
            existing.assign(\.priorRelationship, p.priorRelationship)
            existing.assign(\.matchedClientName, p.matchedClientName)
            existing.assign(\.downbeatClientId, p.downbeatClientId)
            if existing.relationshipCorrectedByPerformerMatch { existing.clearPerformerMatch() }
        } else if existing.hasActivePerformerMatch {
            // The org name still matches nothing (it never did, which is why Prep had to look at the
            // performer at all). Leave Prep's correction exactly as it stands.
        } else {
            existing.assign(\.priorRelationship, p.priorRelationship)
            existing.assign(\.matchedClientName, p.matchedClientName)
            existing.assign(\.downbeatClientId, p.downbeatClientId)
        }

        // Step B: the score. Runs AFTER Step A, so `existing.priorRelationship` already holds whichever
        // value won above, and every branch below scores against the truth rather than a stale org guess.
        if existing.classificationOverriddenByDan {
            // Dan corrected the classification: keep his discipline/production values and re-score from
            // them (plus the freshly-updated profile/coverage and the Step A relationship) so fit stays
            // meaningful without reverting his correction. Because rescored() reads priorRelationship
            // straight off `existing`, this one call already reflects a protected performer match, with
            // no combined-rule branch needed. That is what makes the two guards compose.
            // Nothing to write here: the shared re-score below reads the discipline and production
            // already on the row, which is exactly what "keep Dan's values" means.
            // #1663/#1845: Dan's arm keeps taking the fresh profile, coverage and reason, exactly as it did
            // when these were refreshed unconditionally above. His correction is to the DISCIPLINE, and the
            // comment above is explicit that the re-score is meant to read his values plus the freshly
            // updated profile and coverage. Written here rather than left above so that intent is visible
            // instead of being an accident of where the line happened to sit.
            existing.assign(\.profile, p.profile)
            existing.assign(\.coverage, p.coverage)
            existing.assign(\.fitReason, p.fitReason)
        } else if existing.hasActivePerformerMatch && !p.orgMatchConfident {
            // The org match found nothing, so Step A left Prep's performer correction standing. Take the
            // scout's fresh discipline and production; the correction lives in priorRelationship, which
            // Step A already resolved on the row, so the shared re-score below picks the fresh genre up
            // WITHOUT undoing the correction by the back door.
            // #1663: subject to the same precedence as the plain arm below. The performer correction is
            // about WHO, not about genre, so it gives this arm no claim to overwrite another source's read.
            takeIncomingClassification(p, into: existing)
        } else {
            takeIncomingClassification(p, into: existing)
        }

        // #1648 Phase A1: ONE scoring expression, reached by every arm above, and it reads the ROW.
        //
        // The arms differ only in which classification fields they write; none of them writes a score.
        // Copying `p.fitScore` here (which the plain arm used to do) means the row's score is whatever
        // the assembler computed from the extracted event, and the assembler never sees the Prospect.
        // Any fact that lives only on the row is therefore invisible to it and gets stomped on the next
        // scout that re-touches the show, intermittently, because unchanged sources are hash-gated and
        // skipped. Scoring from the row instead makes the write idempotent and keeps the stored score
        // and the stored axes describing the same show.
        let refit = ClassificationOverride.rescored(existing, now: now)
        existing.assign(\.fitScore, refit.score)
        existing.assign(\.tier, refit.tier.rawValue)
        existing.assign(\.partOfRelatedRun, p.partOfRelatedRun)
        existing.assign(\.runSourceURLs, p.runSourceURLs)
        // #1523: keep the played nights current, MINUS the ones Dan dropped.
        //
        // #2691: the feed still lists a dropped night on every run, so assigning what it says would put
        // the night straight back and quietly undo his decision on the next scout. That is L92 exactly: a
        // removal recorded against nothing recurs. `DroppedNight.keeping` is the one place that
        // subtraction happens, so the queue and the scout cannot disagree about which nights this run has.
        // #3001: with a lookup, so a night released to another card comes back if that card has gone.
        let nights = DroppedNight.keeping(p.runNights, on: existing, lookup: storedByKey)
        existing.assign(\.runNights, nights)
        // And the span has to follow the nights, or a run whose opening night was dropped keeps claiming
        // to start on a date it no longer plays.
        //
        // #4106 Phase 1a: decided ONCE and assigned once. It used to be assigned the feed's end above and
        // then reassigned here, so a run with a drop wrote the field twice on every re-land, and the first
        // write was a real change even when the second put the stored value back.
        let hasDrops = !nights.isEmpty && !DroppedNight.all(on: existing).isEmpty
        existing.assign(\.runEndDate, hasDrops ? nights.max() : p.runEndDate)

        // #1699, Dan's call (2026-08-02): the NEWEST read wins, INCLUDING when it is empty. A feed that
        // stops publishing times costs the card its time, which is the cheap error; a show that gets
        // rescheduled must never keep advertising the old curtain time, which is the error that could
        // actually cost him a shoot. So this assigns rather than merging, unlike sourceIds below.
        existing.assign(\.performanceStartTimes, p.startTimes)
        existing.assign(\.startTimesVary, p.startTimesVary)
        existing.assign(\.nightStartTimes, p.nightStartTimes)

        // #771: UNION, never replace, and this is the only correct home for it. The chain above
        // deliberately merges the same show arriving from a venue's calendar and from the presenter's
        // own site into this one row. Assigning p.sourceIds here would make the row remember only
        // whichever source ran last, and Phase 3's per-source reconcile would then find the show absent
        // from the forgotten source's feed and accrue misses toward disappearedFromFeed on a live show
        // Dan may already have drafted and emailed. Sorted so the stored order is stable rather than
        // whatever the Set happened to hash to.
        existing.assign(\.sourceIds, Array(Set(existing.sourceIds).union(p.sourceIds)).sorted())

        // #4331 (A2): no `ingestedAt` here. It was the one unconditional write left (#4106 Phase 1a's named
        // residue); the caller now stamps the row from the landing's `now` only when this apply changed it, or
        // when a merge reader needs it to mean last seen (`ScoutLandingStore.stampTouched`).
    }

    // The days Dan cannot work, from BOTH sources at once (#901): Downbeat's booked shoots, and the days
    // off he types into Overture himself.
    //
    // This replaces `mergedBlockedDates`, which unioned Downbeat's exported dates with a local override
    // file, `overture-blocked-dates.json`. That file was read here and written NOWHERE: no editor, no
    // settings screen, no writer anywhere in the app, and it does not exist on Dan's Mac. Downbeat's
    // half, meanwhile, has always exported an empty list. So the guard has never once fired in the app's
    // life, and both halves of it looked exactly like a guard that worked.
    //
    // The days off now live in the store (DayOff), where the sheet that edits them and the scout that
    // reads them are looking at the same rows, instead of at a file only one of them knew about.
    // #3298: `availability` comes from the export's own health, so a file Overture could not read produces
    // a calendar that SAYS it could not measure rather than one that looks like a clear diary. The tuple
    // carries the health for that reason and nothing else.
    static func blockedCalendar(export: (bookings: [OvertureBooking], blockedDates: [String],
                                        health: DownbeatBridge.Health),
                                context: ModelContext) -> BlockedCalendar {
        BlockedCalendar.build(availability: BlockedCalendar.Availability(health: export.health),
                              bookings: export.bookings,
                              exportedBlockedDates: export.blockedDates,
                              daysOff: DayOffEditing.ranges(in: context),
                              // #2692: the shoots Dan has said are not happening. Read HERE, in the one
                              // place every surface builds its calendar through, so the sheet, the scout
                              // and the conflict sweep cannot disagree about which nights are blocked.
                              cancelledBookingIds: CancelledShootEditing.cancelledIds(in: context),
                              // #3620: Dan's weekly rules, read here for the same reason: one place every
                              // surface builds its calendar through.
                              weeklyBlocks: WeeklyDayOffEditing.blocks(in: context))
    }
}
