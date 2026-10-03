import Foundation
import SwiftData

// #802 slice 3: what the app does with what the extract run read.
//
// This is where the watchlist finally writes to Dan's store, and it is where the feature's two most
// dangerous mistakes live:
//
//   Stamping a content hash for a page we did not actually ingest. The source would then report as
//   healthy and unchanged forever, having never once been read, and Dan would have no way to know that
//   a calendar he is counting on stopped being looked at months ago.
//
//   Letting a broken page read as a quiet one. A calendar drawn by JavaScript returns exactly what a
//   healthy off-season returns: nothing. Only the verdict tells them apart, and telling them apart is
//   the single thing Dan said must never fail.
@MainActor
enum ScoutExtractIngest {
    // Reads the results file the detached run wrote, and lands it, source by source.
    //
    // Each source is independent: a run that died at source nine keeps sources one through eight, and
    // a source it never reached keeps its pending hash and its unread flag so the next run picks it up
    // again rather than skipping it forever.
    // #3905: ASYNC, so the per event classify and match loop can leave the main actor.
    //
    // #3884 did this for the scout's own sweep and named this path as the one it did not convert. It is
    // the worse of the two: on 2026-09-13 an ingest froze the app for 34.2 s, with two 10 s samples
    // putting 8,485 of 8,498 main thread samples under this function and `ScoutService.apply`. #3887
    // stopped it re-importing a STALE results file; it never stopped a legitimate import blocking the
    // window for as long as it takes.
    //
    // ONE implementation, made async, rather than a second `ingestOffTheActor` beside it. The loop below
    // is long and carries the source resolution, the health state and the reconcile; a second copy of it
    // is how the two would come to disagree about what an ingest does (L263).
    // #4102: one source's result, read and classified, waiting to land with the rest of the file.
    private struct Pending {
        let source: WatchedSource
        let events: [ExtractedEvent]
        let rejection: RejectionCounts
        let health: FeedReconcile.FeedHealthState
        let effectiveVerdict: PageVerdict
        let preClassified: ScoutService.PreClassified
        // #4329 (A12): the run's note for this source, applied with the rest of its landing.
        let writes: SourceWrites
    }

    // #4330: a settled slot carries its source (nil for an id nobody queued) so the landing block can
    // stamp it with this run's sequence. #4329 (A12): and what reading it decided to write on the row (its
    // note, its failure, its confirmed quiet page), applied there after the re-validation, or dropped whole.
    private enum Slot {
        case settled(ScoutService.Outcome, WatchedSource?, SourceWrites)
        case pending(Pending)
    }

    @discardableResult
    static func ingest(_ results: ScoutExtractResults,
                       clients: [DownbeatClient], history: [HistoryRecord], blocked: BlockedCalendar,
                       today: String = QueueModel.easternToday(),
                       now: Date = Date(),
                       // #4275: how the whole show table is read, injected so a test can count the reads.
                       // Every read of it this ingest makes goes through here.
                       // #4332 (A3): Sendable, because the brand corpus calls it off the main actor.
                       readProspectTable: @escaping ScoutLandingStore.SendableRead = ScoutService.readProspectTable,
                       // #4332: Dan's producer corrections, the corpus's other read, injected likewise.
                       readProducerOverrides: @escaping ScoutService.OverrideRead = ScoutService.readProducerOverrides,
                       // #4330 (A13): the queue the landing block waits its turn in, and at what priority.
                       landings: LandingSingleFlight = .shared,
                       priority: LandingSingleFlight.Priority = .scout,
                       // #4336 (A7): the identity of the results being landed and the check to judge it by.
                       // `ScoutExtractLanding` always passes one, being the only caller holding the bytes the
                       // identity is the hash of (AlreadyLandedBypassIsTestOnlyTests holds the app to that).
                       // nil, for a test landing decoded results with no file behind them, checks and records
                       // nothing.
                       identity: LandedResultsIdentity? = nil,
                       // The run's landing sequence. nil mints one as the read phase starts; a pending copy
                       // offered again passes the sequence it was minted with (`PendingScoutIngests`), so it
                       // is judged as the run it really is.
                       sequence givenSequence: Int? = nil,
                       sequenceFloor: () -> Int = { PendingScoutIngests.live.highestSequence },
                       // Called with the run's sequence only when the landing has to WAIT for the store,
                       // before it starts to: where the caller keeps a copy of what it is holding (L665).
                       onWait: (Int) -> Void = { _ in },
                       // The closing save, injected so a test can make it fail (`ScoutService.saveLanding`).
                       saveClosing: (ModelContext) throws -> Void = { try $0.save() },
                       // #4327 step 0.7: handed the working set after each LANDED source (labelled with its source
                       // id) and once more after the reconcile's read (labelled `Counters.afterReconcile`, and only
                       // when a reconcile ran, so a landing that reconciled nothing never reports a reconcile), so a
                       // probe can say what each source cost from its cumulative counters, and #4333's tests can
                       // compare its batch tables with a rebuild after every source. nil, which every shipping
                       // caller passes, reports nothing.
                       onLandingStep: ((String, ScoutLandingStore) -> Void)? = nil,
                       // #4329 (A12): handed each source's captured read-phase writes as the landing applies
                       // them, so a test can prove every branch that writes was driven. nil reports nothing.
                       onApplyCaptured: ((SourceWrites) -> Void)? = nil,
                       // #4334 (A5): each landing source's own save, the entry flush's, and how a failed save is
                       // classified, injected so a test can fail one source's save and not the next.
                       saveSource: @escaping (ModelContext) throws -> Void = { try $0.save() },
                       saveEntry: (ModelContext) throws -> Void = { try $0.save() },
                       classifySaveFailure: @escaping (Error) -> LandingSaveFailure.Scope = LandingSaveFailure.classify,
                       // #4334: called with the run's sequence when the entry flush refuses the landing, where
                       // the caller keeps a copy of the results to land once the edits are saved (L371, L665).
                       onRefused: (Int) -> Void = { _ in },
                       // #4335 (A6): where this landing keeps its journal, the record of what it set out to do
                       // (`LandingJournal`). The product call sites pass `.live`, resolved there once, and
                       // `EveryProductLandingKeepsAJournalTests` fails when one does not. nil keeps none, for a
                       // test whose subject is not the journal; a test that is passes its own sandbox (L433).
                       journals: LandingJournals? = nil,
                       // #4331 (A2): how the landing stamps `ingestedAt`. Only the merge survivor probe passes
                       // anything but the rule, to measure the rule against the one it replaced.
                       stampRule: IngestedAtStamp.Rule = .whenChanged,
                       into context: ModelContext) async -> ScoutService.Outcome {
        var outcome = ScoutService.Outcome(found: 0, inserted: 0, updated: 0, skipped: 0)
        // #4335: minted above every sequence the store recorded (on a source, or on a landing record) and
        // every sequence a journal's NAME carries, pending or set aside as unreadable, so a landing a crash
        // interrupted before its first save can never have its number handed out again (L186, L371).
        let sequence = givenSequence ?? landings.mintSequence(
            above: max(sequenceFloor(), highestStoredSequence(in: context), journals?.highestSequence ?? 0))

        // #4329 (A12): the read loop below writes NOTHING to the store. Every write it decides for a source (the
        // run's note, a failure, a confirmed quiet page) is captured in that source's slot and applied by the
        // landing block, after the re-validation, so the context is clean across the classify await and a
        // reading a later run overtook leaves the row exactly as that later run left it.
        //
        // #4102: every source is READ first (its checks, and its classify pass awaited off the actor) and
        // every source's shows LAND afterwards, together, in one block with no await in it. Landed as each
        // one was classified, every source reached the screen as its own change and the queue re-derived
        // the whole store once per source, then again for each notification that follows a save: the
        // shape `AScoutRunDerivesTheQueueOnceTests` measured on the sweep, where four sources cost sixteen
        // whole-store derivations. `slots` keeps the results in the order the file lists them, so a source
        // settled while reading still sits in the report where it was read.
        var slots: [Slot] = []
        // The brand corpus, read at the first source that needs it rather than once per source: a whole
        // table fetch, measured at 158.8 ms over 1,238 rows. Nothing lands until every source is read,
        // so a per source read would return the same store every time.
        var corpusRead: ScoutService.CorpusRead?
        // #4334 (A5): a slot a stopped landing never reached, reported as such so it is not silence. A result
        // under an id nobody queued is a report rather than a write, so it is still said.
        func reportNotAttempted(_ slot: Slot) {
            switch slot {
            case .settled(let settled, nil, _):
                outcome.merge(settled)
            case .settled(_, let source?, _):
                outcome.sources.append(ScoutService.SourceResult(
                    sourceId: source.sourceId, orgName: source.orgName, state: .notAttempted,
                    listingsURL: source.listingsURL))
            case .pending(let pending):
                outcome.sources.append(ScoutService.SourceResult(
                    sourceId: pending.source.sourceId, orgName: pending.source.orgName, state: .notAttempted,
                    listingsURL: pending.source.listingsURL))
            }
        }
        // #4332 (A3): the entry flush refused BEFORE the background corpus read. Nothing is read or applied
        // after it: every source already read, and every one not yet reached, is reported not attempted, and
        // the caller keeps the results to land once the edits are saved, as it does for a refusal under the
        // token below.
        func refuseBeforeTheRead(_ stop: LandingStop,
                                 unread: ArraySlice<ScoutExtractResult>) -> ScoutService.Outcome {
            outcome.landingStop = stop
            for slot in slots { reportNotAttempted(slot) }
            for result in unread {
                if let source = row(for: result.sourceId, in: context) {
                    reportNotAttempted(.settled(ScoutService.Outcome(found: 0, inserted: 0, updated: 0, skipped: 0),
                                                source, .none))
                } else {
                    outcome.unqueuedResultIds.append(result.sourceId)
                }
            }
            onRefused(sequence)
            return outcome
        }

        for (index, result) in results.results.enumerated() {
            // What this source settled while being read (a failure, a confirmed quiet page, an id nobody
            // queued), reported in its own slot so the order holds.
            var settled = ScoutService.Outcome(found: 0, inserted: 0, updated: 0, skipped: 0)
            // A source id the app never queued resolves to NOTHING. The results file is written by a
            // Claude run, and if it ever rebuilt an id instead of echoing it verbatim, the work must
            // vanish loudly rather than land on some other org's row. A silent mismatch has to read as
            // absence, never as the wrong show. #857: recorded, so "loudly" is true: the drop is
            // surfaced in the run's warning rather than being a bare `continue` nobody ever sees.
            guard let source = row(for: result.sourceId, in: context) else {
                settled.unqueuedResultIds.append(result.sourceId)
                slots.append(.settled(settled, nil, .none))
                continue
            }

            // #875: the run's own explanation, kept rather than discarded. Written for EVERY result, on
            // the failure path and the healthy one alike, and overwritten each run so it always describes
            // the LAST thing that happened rather than accumulating a history nobody asked for. A source
            // that recovers must stop explaining a failure it no longer has.
            let note = SourceWrites(.runNote, [.notes(result.note)])

            // #857: the run's own results are untrusted input. A verdict that disagrees with the events
            // it returned (it claimed the page was empty or unreadable and still handed back shows, or
            // claimed it found upcoming listings and handed back none) is the run ignoring its own
            // instructions, and its silence about a show is worth nothing. Its events are NOT ingested;
            // it is a named failure so the next scout reads the page again.
            //
            // Checked BEFORE the verdict branch below on purpose: a `no_dated_content`/`unreadable`
            // result that still carries events already fails there, but with the generic wrong-page
            // message; catching it here names the real problem (the run disagreed with itself) on the WHY
            // line Dan reads, and also catches the two contradictions that verdict branch cannot see
            // (`all_past` with events, which it would otherwise INGEST, and `upcoming_listings` with none,
            // which it would otherwise stamp as a healthy quiet read).
            if let reason = ScoutResultAudit.contradiction(in: result) {
                let failed = fail(source, as: .inconsistentResult, now: now, outcome: &settled)
                slots.append(.settled(settled, source,
                                      note.appending(SourceWrites(.runNote, [.notes(reason)])).appending(failed)))
                continue
            }

            // A page we could not read is a FAILURE, and its hash is not stamped. Stamping it would mean
            // never looking at this source again: it would report as unchanged forever, having never
            // once been read. `SourceFailure(verdict:)` is what decides which verdicts mean broken, and
            // a quiet off-season is deliberately not one of them.
            if let failure = SourceFailure(verdict: result.verdict) {
                // #1027: a page Dan confirmed as right-but-empty, read again at the same bytes, is not a
                // failure and does not nag. Checked with the hash just read (pendingContentHash), so the
                // instant the page changes it fails here as before. Only no_dated_content is ever
                // confirmable (isConfirmedQuiet gates on the verdict), so this cannot swallow a broken
                // fetch or a JS page.
                if SourceConfirmation.isConfirmedQuiet(verdict: result.verdict,
                                                       readHash: source.pendingContentHash,
                                                       confirmedEmptyHash: source.confirmedEmptyHash) {
                    let quiet = recordConfirmedEmpty(on: source, now: now, outcome: &settled)
                    slots.append(.settled(settled, source, note.appending(quiet)))
                    continue
                }
                let failed = fail(source, as: failure, now: now, outcome: &settled)
                slots.append(.settled(settled, source, note.appending(failed)))
                continue
            }

            // #897: a stitched multi-month page (#858) is a trustworthy feed for reconcile ONLY once the
            // run read every month the app stitched into it. A run that covered fewer months read a SHORTER
            // page than the app fetched and hashed, and treating its silence about a show as evidence that
            // show was cancelled is the exact data loss #858 shipped pagination OFF to avoid. When the
            // sweep is short we DOWNGRADE the run's own verdict to incomplete_extraction: the shows it did
            // find still land as adds and updates, but the page is not marked finished (its hash is not
            // stamped, so the next scout re-reads it) and no feed health is recorded, exactly as a
            // partially read page already behaves (#1012). absenceIsEvidence can never fire for
            // incomplete_extraction, so a short sweep can never mark a live show gone.
            //
            // Inert on the single-month watchlist default (pendingPageMonths has 0 or 1 entry), so this
            // changes nothing until pagination is raised above one month on a reconciling path.
            let sweepComplete = SweepCoverage.isComplete(stitchedMonths: source.pendingPageMonths,
                                                         monthsCovered: result.monthsCovered)
            let effectiveVerdict = sweepComplete ? result.verdict : PageVerdict.incompleteExtraction

            // We read the page. It may have had nothing upcoming on it, which is the NORMAL state (5 of
            // the 7 sites in the #770 spike, in July) and is not a failure: we know what that page says,
            // and re-reading it daily until the season starts would be paying to be told so again.
            // #1236: for a source flagged to merge its per-conductor listings (DCINY), stamp a synthetic
            // same-date+venue seriesId here, where the WatchedSource is in hand, so the existing RunGrouping
            // collapse in ScoutService fuses the rows into one prospect. Kept in Swift, not the untrusted
            // shell runner. Inert (no-op) for every ordinary source, whose flag is false.
            // #1291: hand the source's own listings URL to the boundary so a stripped signup-form link
            // (DCINY's /opportunities/ getfeedback rows) falls back to the listings page, not to no link.
            let rawEvents = results.events(for: result.sourceId, today: today,
                                           listingsURL: source.listingsURL)
            let events = source.mergeSameDateVenue ? SameDateVenueMerge.stamped(rawEvents) : rawEvents
            // #1032: the drops this run threw away, split by family (venue vs title), computed once and
            // used for BOTH the #887 tolerance gate (its total) and the Sources note (its title share).
            let rejection = results.rejectionCounts(for: result.sourceId)
            let health = FeedReconcile.FeedHealthState(
                baseline: source.baselineFeedCount,
                degradedStreak: source.degradedStreak,
                lastDegradedCount: source.lastDegradedCount)

            // The SAME pipeline every other show goes through. That is load-bearing, not tidiness: it is
            // what makes the blocked-date skip, the #769 do-not-contact suppression and the #798
            // upcoming-only guard apply to a watched source exactly as they do to everything else. A
            // watchlist that could smuggle a refused org back in by a side door would be worse than no
            // watchlist at all.
            // #3905: the corpus is read HERE, the loop over this source's events is awaited off the main actor,
            // and the upserts in `land` run on it again. #4332 (A3): the corpus is read off the main actor too,
            // through a background context, behind the entry flush (`ScoutService.flushBeforeLanding`): a
            // background context reads only what is SAVED, so anything pending is saved first, or the landing
            // is refused by name before anything is read.
            // The same three steps the scout's own sweep takes (`ScoutService.readNative` and
            // `landNative`), and the same shared pieces, so the two paths cannot drift about what a
            // classify pass is.
            let corpus: ScoutService.CorpusRead
            if let corpusRead {
                corpus = corpusRead
            } else {
                if let refused = ScoutService.flushBeforeLanding(context, save: saveEntry) {
                    return refuseBeforeTheRead(refused, unread: results.results[index...])
                }
                corpus = await ScoutService.venueBrandCorpusOffMain(container: context.container,
                                                                    read: readProspectTable,
                                                                    readOverrides: readProducerOverrides)
                corpusRead = corpus
            }
            let classifiedPass = await ScoutClassify.offTheCallersActor(
                events: events, clients: clients, history: history,
                venueBrands: corpus.brands, sourceIds: [source.sourceId])
            slots.append(.pending(Pending(source: source, events: events, rejection: rejection, health: health,
                                          effectiveVerdict: effectiveVerdict,
                                          preClassified: ScoutService.PreClassified(
                                              result: classifiedPass, degradedReads: corpus.degradedReads),
                                          writes: note)))
        }

        // #4102: every source lands here, in the order it was read, with no await between them.
        //
        // #4275: judged against ONE read of the stored shows, built here after the last await and kept
        // current as each source lands, rather than two whole table fetches per source and one more for
        // each event reaching the run URL arm (`ScoutLandingStore`).
        //
        // #4330 (A13): the store is taken HERE, after the last classify await, and released after the
        // closing save below. A refusal at the deadline lands nothing and says so; the caller keeps the
        // results to offer again (`ScoutExtractLanding`), so nothing is lost.
        let token: LandingSingleFlight.Token
        do {
            token = try await landings.begin(entryPoint: .scoutExtractIngest, priority: priority,
                                             deadline: LandingSingleFlight.Deadline.scoutExtractIngest,
                                             onWait: { onWait(sequence) })
        } catch is CancellationError {
            outcome.notLandedYet = LandingWaitCopy.ingestCancelled
            return outcome
        } catch {
            outcome.notLandedYet = String(describing: error)
            return outcome
        }
        defer { token.end() }
        // #4336 (A7): asked again now the store is held, because the caller's asking was formed before it
        // was (L157), and two landings of the same bytes can both have passed it while they waited. Refused
        // before anything is applied, as its own outcome with the first landing's time (L100, L11). A
        // record that cannot be read refuses nothing (refusing would lose a run to a read nothing else
        // needed) and is said as a degraded read, never read as "never landed" (L215).
        if let identity {
            do {
                if let landedAt = try identity.check.landedAt(identity.contentHash, context) {
                    outcome.alreadyLandedAt = landedAt
                    return outcome
                }
            } catch {
                outcome.degradedReads.append(.landedRuns)
            }
        }
        // #4334 (A5): the ENTRY FLUSH, the first WRITE done holding the store (`ScoutService.flushBeforeLanding`),
        // after #4336's refusal above, which only reads: results that already landed are refused whatever is
        // pending, so that answer must not wait on a save, nor be said as "your edits could not be saved".
        // A flush that cannot save refuses the landing by name before anything is applied (L667): the edits
        // stay exactly as they were, and the caller keeps the results to land once they are saved.
        if let refused = ScoutService.flushBeforeLanding(context, save: saveEntry) {
            outcome.landingStop = refused
            for slot in slots { reportNotAttempted(slot) }
            onRefused(sequence)
            return outcome
        }
        // #4335 (A6): the landing's record of itself, written before anything is applied and after the last
        // await. Its run identity is the results' content hash; decoded results with no file behind them (a
        // test's) are given one of their own, so every landing is recorded.
        let runIdentity = identity?.contentHash ?? "decoded-" + UUID().uuidString
        let journal = LandingJournal(
            runIdentity: runIdentity, sequence: sequence, entryPoint: .scoutExtractIngest,
            sources: slots.compactMap { slot -> LandingJournal.Source? in
                switch slot {
                case .settled(_, let source?, _): return .init(sourceId: source.sourceId, pageHash: nil)
                case .settled(_, nil, _): return nil
                case .pending(let pending):
                    return .init(sourceId: pending.source.sourceId, pageHash: pending.source.pendingContentHash)
                }
            },
            now: now)
        // A journal that cannot be written refuses the landing by name before any apply (L258), exactly as the
        // entry flush's refusal does: the caller keeps the results to land once it can.
        if let journals {
            do {
                try journals.start(journal)
            } catch {
                outcome.landingStop = .journalNotWritten(why: HandoffDecodeFailure.describe(error))
                for slot in slots { reportNotAttempted(slot) }
                onRefused(sequence)
                return outcome
            }
        }
        let landing = ScoutLandingStore(context: context, read: readProspectTable, saveSource: saveSource,
                                        classify: classifySaveFailure, stampRule: stampRule)
        // The landing record, inserted here, at the start of the synchronous landing block (the 2026-09-29 L55
        // decision), so the read phase above stays clean, and carried to disk by the landing's first save. It
        // is a SETTLED row to the revert: a source whose save fails is put back without taking it, so the
        // record of a landing that started survives that source.
        let run = LandingRun.begin(runIdentity: runIdentity, sequence: sequence, entryPoint: .scoutExtractIngest,
                                   startedAt: now, in: context)
        landing.noteSettled(run)
        // #4330: the re-validation. A later run landed this source after this one read it, so this reading is
        // the older one and is set aside whole: nothing applied (#4329: not even its note, its failure or its
        // failure streak, which the read loop no longer writes), and the page hash not promoted, so the next
        // scout reads the page again.
        func setAsideIfSuperseded(_ source: WatchedSource) -> Bool {
            guard source.lastTouchedSequence > sequence else { return false }
            outcome.sources.append(ScoutService.SourceResult(
                sourceId: source.sourceId, orgName: source.orgName, state: .superseded,
                listingsURL: source.listingsURL))
            return true
        }
        func landCaptured(_ writes: SourceWrites, on source: WatchedSource) {
            source.lastTouchedSequence = sequence
            source.applyCaptured(writes)
            onApplyCaptured?(writes)
        }
        func land(_ pending: Pending) {
            let source = pending.source
            if setAsideIfSuperseded(source) { return }
            landCaptured(pending.writes, on: source)
            // #4335: which run landed this source, in the same save as its shows (`apply`'s), so the store says
            // which sources an interrupted landing finished. A failed save puts these back with the shows.
            source.lastLandedRunID = runIdentity
            source.lastLandedSequence = sequence
            let events = pending.events
            let rejection = pending.rejection
            let health = pending.health
            let effectiveVerdict = pending.effectiveVerdict
            let applied = ScoutService.apply(
                events: events, clients: clients, history: history, blocked: blocked,
                // #887: the events this run THREW AWAY are handed over with the ones it kept. They were
                // rejected for having no venue, which almost always means their own detail page was never
                // read, so this run does not know what else it failed to reach. It may add and update; it
                // may not conclude that anything was cancelled. Available here all along
                // (rejectedEvents(for:) existed for exactly this) and consumed only by the lead sheet,
                // which is why the scout could quietly mark Dan's live shows gone.
                feed: ScoutService.FeedCheck(sourceId: source.sourceId,
                                             baseline: health.baseline,
                                             successfulCheckCount: source.successfulCheckCount,
                                             verdict: effectiveVerdict,
                                             // #1472/#1469: `unreadTotal` is the drops that are still suspected
                                             // reading failures. An .html source IS read page by page, so a
                                             // venue-less row stays one of those UNLESS the run itself marked
                                             // the row as one the page publishes no venue for.
                                             rejectedCount: rejection.unreadTotal,
                                             // #1469: those flagged rows travel to the reconcile as still
                                             // listed, by link where they have one and by night where they do
                                             // not (a placeholder row links nowhere), so no stored show is
                                             // struck for a row that is on the page right now.
                                             structuralGapURLs: rejection.structuralGapURLs,
                                             structuralGapDates: rejection.structuralGapDates),
                // #4331 (A2): this ingest's own `now`, which every row the landing changes is stamped from.
                today: today, now: now, sourceIds: [source.sourceId],
                preClassified: pending.preClassified,
                landing: landing,
                into: context)

            if applied.saveFailed {
                // #499: everything above was classified and upserted in memory and never persisted. The
                // hash stays UNSTAMPED and the unread flag stays set, so the next run reads this page
                // again. Stamp it here instead and the source would fetch fine, report fine, and have
                // silently ingested nothing since the day the save failed.
                //
                // #4334 (A5): and it is PUT BACK, with this source's captured writes, so nothing it wrote is
                // left pending for a later save to carry, or to fail on again, or for an offer of the same
                // results to apply a second time. Reported as `.saveFailed`, never `.ingested`, and its counts
                // are not merged: none of its shows is in the store.
                outcome.saveFailed = true
                outcome.degradedReads.append(contentsOf: applied.degradedReads)
                outcome.landingStop = outcome.landingStop ?? ScoutService.isolateFailedSave(
                    of: source.orgName, scope: applied.saveFailureScope, landing: landing)
                outcome.sources.append(ScoutService.SourceResult(
                    sourceId: source.sourceId, orgName: source.orgName,
                    state: .saveFailed, hadBaseline: health.baseline > 0, listingsURL: source.listingsURL))
                return
            }
            outcome.merge(applied)

            // #986: how many of the shows this run KEPT said where they are, by the SAME rule the native
            // path uses (SourcePlacement.placedCount), so the two ingest doors can never disagree on it.
            let placedCount = SourcePlacement.placedCount(locations: events.map(\.location))

            if effectiveVerdict == .incompleteExtraction {
                // #1012: real events, so they land, but the run only read PART of this page. Stamping the
                // hash or clearing the unread flag here would mean never going back for the rest of it:
                // the source would report healthy and unchanged forever, having been read exactly once.
                recordPartialCheck(on: source, events: events.count, now: now,
                                   unreadable: rejection.unreadTotal, titleUnreadable: rejection.titleRelated,
                                   structuralGaps: rejection.structuralGapCount,
                                   droppedShows: rejection.droppedShows, placed: placedCount)
            } else {
                recordSuccess(on: source, events: events.count, health: health, now: now,
                              // #891: recorded on the SAME branch as the run's success, so the count can
                              // never describe a run other than the one that produced it. A source that
                              // recovers overwrites this with a zero and stops complaining, which it must:
                              // a warning that never clears becomes furniture, and this is the one line
                              // Dan must not skim.
                              // #1032: the title share rides alongside the total, so the note names a
                              // titleless drop correctly instead of calling it "no venue".
                              unreadable: rejection.unreadTotal, titleUnreadable: rejection.titleRelated,
                              // #1469: rows the PAGE publishes no venue for, disclosed on the row as a plain
                              // fact rather than counted as pages the run failed to open.
                              structuralGaps: rejection.structuralGapCount,
                              // #1471: and WHICH shows they were, so the sheet names the row rather than
                              // leaving Dan to find it in the raw results file.
                              droppedShows: rejection.droppedShows, placed: placedCount)
            }
            outcome.sources.append(ScoutService.SourceResult(
                sourceId: source.sourceId, orgName: source.orgName,
                state: .ingested(found: events.count), hadBaseline: health.baseline > 0,
                listingsURL: source.listingsURL,
                // #1539: the same two counts recorded on the row just above, so the end-of-scout warning
                // can tell a page that listed nothing from a page whose every row was dropped. Both are
                // drops: a row rejected outright and a row the page published no venue for are equally
                // "read, and not usable", and neither is a page format that changed.
                droppedRowCount: rejection.unreadTotal + rejection.structuralGapCount))
        }
        for slot in slots {
            // #4334: a landing a failed save stopped lands nothing after it (decision 3).
            if outcome.landingStop != nil {
                reportNotAttempted(slot)
                continue
            }
            switch slot {
            case .settled(let settled, let source, let writes):
                guard let source else {
                    outcome.merge(settled)
                    continue
                }
                if setAsideIfSuperseded(source) { continue }
                landCaptured(writes, on: source)
                // #4334: not the next source's turn, so that source's failed save leaves these pending.
                landing.noteSettled(source)
                outcome.merge(settled)
            case .pending(let pending):
                land(pending)
                onLandingStep?(pending.source.sourceId, landing)
            }
        }

        // #888 part B: ONE reconcile, with EVERY source this run landed.
        //
        // This used to happen inside `apply`, once per source, with a single-element report list. So
        // `believable` was never larger than one source, and a show co-listed by two could never satisfy
        // "every owner was asked and none has it" on any run, whatever either source said. The careful,
        // conservative half of FeedReconcile was dead code that read as working.
        //
        // Batched here, so a show that both Kaufman and Merkin have dropped can finally be seen as gone,
        // while a show whose second owner was NOT in this run stays untouched, because that source might
        // still be listing it and nobody asked.
        //
        // Deliberately AFTER the whole loop and not inside it: a partial batch would arm exactly the
        // half-informed conclusion this rule exists to prevent.
        //
        // KNOWN LIMIT, stated rather than hidden: the native (Carnegie) sweep reconciles separately, in
        // runScout, minutes before this file even exists. So a show co-listed by Carnegie AND a watched
        // HTML calendar is still never marked gone. That is the SAFE direction and no worse than before,
        // but it is not the whole rule, and somebody should know that before assuming it is.
        // #4334: a stopped landing reconciles nothing, since not every source it was given was asked.
        let reports = outcome.allReports
        if !reports.isEmpty && outcome.landingStop == nil {
            // The working set, which is the store as it now stands. A read that fails reconciles nothing,
            // which is what the empty answer this used to fall back to did.
            let allStored = (try? landing.rows()) ?? []
            landing.noteReconcile(FeedReconcile.reconcile(stored: allStored, reports: reports, today: today))
            onLandingStep?(ScoutLandingStore.Counters.afterReconcile, landing)
        }
        // #4325: the reconcile's writes, and every source's bookkeeping above, saved before the landing
        // returns, through the one closing save the native sweep uses. Nothing saved them before this.
        // #4336 (A7): the stamp that these results landed rides the closing save, so it reaches disk with the
        // landing or not at all. Only a landing nothing failed to save is stamped: a failed save leaves the
        // results to be offered again, and a stamp would refuse them (L5). A stamp whose save failed is put
        // back by the closing save's revert (#4334), to the unlanded record the first save carried, or with
        // the record itself when no save carried it. #4335: the record is the one inserted at landing start.
        let landed = !outcome.saveFailed && outcome.landingStop == nil
        if landed { run.landedAt = now }
        // #4334 (A5): a landing that stopped because a source could NOT be put back makes no further save, so
        // nothing it could not restore is saved; any other stop still saves what the sources before it left.
        if case .notReverted? = outcome.landingStop {
            outcome.saveFailed = true
        } else if !ScoutService.saveLanding(landing, into: context, save: saveClosing) {
            outcome.saveFailed = true
        }
        // #4335: a landing whose every save went through has spent its journal. Any other keeps it, for the
        // recovery to read against what the store says landed.
        if landed && !outcome.saveFailed { journals?.retire(journal) }
        token.end()

        return outcome
    }

    // #4330: the highest sequence any landing has stamped on a source, the store's half of the floor a new
    // sequence is minted above. One sorted fetch of one row. A fetch that fails leaves the floor to this
    // process's own mints; the same store then fails every `row(for:)` below, so nothing lands on it.
    // #4335: and the highest a landing RECORD carries, which a landing whose sources were all set aside or
    // put back still saved.
    private static func highestStoredSequence(in context: ModelContext) -> Int {
        var top = FetchDescriptor<WatchedSource>(sortBy: [SortDescriptor(\.lastTouchedSequence, order: .reverse)])
        top.fetchLimit = 1
        let touched = (try? context.fetch(top))?.first?.lastTouchedSequence ?? 0
        return max(touched, (try? LandingRun.highestSequence(in: context)) ?? 0)
    }

    // The shared bookkeeping for a source that failed this run, whichever way it failed (a broken verdict
    // or a run that contradicted itself, #857). The hash is NOT stamped and the unread flag stays set, so
    // the next scout reads the page again rather than skipping it forever on the strength of a bad run.
    //
    // #4329 (A12): reported here, written by the landing block. The writes come back captured.
    private static func fail(_ source: WatchedSource, as failure: SourceFailure, now: Date,
                             outcome: inout ScoutService.Outcome) -> SourceWrites {
        outcome.sources.append(ScoutService.SourceResult(
            sourceId: source.sourceId, orgName: source.orgName, state: .failed(failure),
            listingsURL: source.listingsURL))
        // #1759: through the one shared recorder, which also counts this as another run that came away
        // without reading the page. Counted rather than merely stamped, because "The next scout will try
        // it again" is a promise, and on the tenth run in a row it is one the app has broken ten times
        // while saying exactly what it said the first time.
        return SourceWrites(.readFailed, [.failedRead(failure, at: now), .unreadChanges(true)])
    }

    // #1027: a no_dated_content page Dan already confirmed as right-but-empty, read again at the same
    // bytes. It is accepted, not failed (`SourceWrites.Step.confirmedEmpty` holds what that writes). Reported
    // here; #4329 (A12): written by the landing block, with the hash the confirmation was judged against.
    private static func recordConfirmedEmpty(on source: WatchedSource, now: Date,
                                             outcome: inout ScoutService.Outcome) -> SourceWrites {
        outcome.sources.append(ScoutService.SourceResult(
            sourceId: source.sourceId, orgName: source.orgName, state: .confirmedEmpty,
            listingsURL: source.listingsURL))
        return SourceWrites(.confirmedEmpty, [.confirmedEmpty(at: now, readHash: source.pendingContentHash)])
    }

    // The page landed. Only now may its hash be promoted, and only now does this count as a check that
    // worked (the warmup that eventually lets this source mark a show as gone).
    //
    // #1001: the health fold, the #891 readable/unreadable counts and the #986 placement detector (all of
    // which the native ScoutService.recordCheck also does) live in ONE place now, on
    // WatchedSource.recordSuccessfulRead, so the two paths can never drift. That shared step writes every
    // count on this same success branch, so none can describe a run other than the one that produced it,
    // and captures the pre-run placement answer before this run overwrites it. Only the hash promotion is
    // this path's own: the native Algolia feed has no fetched page to hash.
    private static func recordSuccess(on source: WatchedSource, events: Int,
                                      health: FeedReconcile.FeedHealthState, now: Date,
                                      unreadable: Int = 0, titleUnreadable: Int = 0,
                                      structuralGaps: Int = 0, droppedShows: [DroppedShow] = [],
                                      placed: Int = 0) {
        source.recordSuccessfulRead(events: events, unreadable: unreadable,
                                    titleUnreadable: titleUnreadable, structuralGaps: structuralGaps,
                                    droppedShows: droppedShows, placed: placed, feedHealth: health, now: now)

        source.lastContentHash = source.pendingContentHash ?? source.lastContentHash
        source.pendingContentHash = nil
        // #897: the stitched-month expectation is spent once the run read the page in full. Cleared here on
        // the same success branch as the hash, so it can never carry stale months into a later comparison.
        source.pendingPageMonths = []
        source.hasUnreadChanges = false
    }

    // #1012: the run only read PART of this page, so this is neither a failure (real events came back
    // and were ingested above) nor a completed check. Deliberately does NOT do what recordSuccess does:
    //
    //   - lastContentHash / pendingContentHash / hasUnreadChanges are left untouched, so the next scout
    //     sees this source as still having unread changes and goes back for the rest of the page. Every
    //     other branch in this file that skips stamping the hash (fail(), the saveFailed path) is
    //     protecting the same invariant: only a run that read a page IN FULL may promote its hash.
    //   - baselineFeedCount / degradedStreak / successfulCheckCount are left untouched. A partial count
    //     is not this source's real size, and folding it into FeedReconcile.updatedHealth would let
    //     repeated partial reads ratchet the baseline down for no benefit: absenceIsEvidence already
    //     can never fire for this verdict (it gates on verdict == .upcomingListings), so there is nothing
    //     to protect by updating the baseline, only something to corrupt by doing so anyway.
    private static func recordPartialCheck(on source: WatchedSource, events: Int, now: Date,
                                           unreadable: Int = 0, titleUnreadable: Int = 0,
                                           structuralGaps: Int = 0, droppedShows: [DroppedShow] = [],
                                           placed: Int = 0) {
        source.lastReadableCount = events
        source.lastUnreadableCount = unreadable
        source.lastUnreadableTitleCount = titleUnreadable
        source.lastStructuralGapCount = structuralGaps
        source.lastDroppedShowLabels = droppedShows
            .compactMap { SourceReadability.showLabel(name: $0.name, date: $0.date) }
            .prefix(SourceReadability.namedShowCap)
            .map { $0 }
        source.hadPlacedBeforeLastRun = source.hasEverPlaced
        source.lastPlacedCount = placed

        source.lastCheckedAt = now
        source.health = .ok
        source.lastFailure = nil
        // #1759: a page read in PART is a page that was read. Real shows came back from it and were
        // ingested above, so this run is not one that came away with nothing, and leaving the streak
        // standing would eventually accuse a source that is working of never being readable.
        source.failedReadStreak = 0
        // Deliberately NOT lastSucceededAt and NOT successfulCheckCount: this run did not finish reading
        // the page, so it should not count as the kind of check that starts the warmup clock.
    }

    private static func row(for sourceId: String, in context: ModelContext) -> WatchedSource? {
        let descriptor = FetchDescriptor<WatchedSource>(
            predicate: #Predicate { $0.sourceId == sourceId })
        return (try? context.fetch(descriptor))?.first
    }
}
