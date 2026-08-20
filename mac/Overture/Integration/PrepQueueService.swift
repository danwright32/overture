import Foundation
import SwiftData

// Phase A trigger: gather the kept-undrafted prospects into a work-list, write it,
// and launch the Prep run detached (Claude Code on Dan's Max plan). The app does NOT
// supervise the run; it writes the queue, kicks off the run, and later ingests the
// results file the run produces. Keeps the app responsive and avoids babysitting a
// long agentic process.

@MainActor
enum PrepQueueService {
    // Build the work-list from the local store: only kept (.queued) prospects that
    // have no draft yet, each carrying its EXACT stored naturalKey as an opaque token.
    //
    // #953: `includedKeys` is the per-run subset Dan chose in the Prep sheet. nil means "no subset
    // chosen", so every eligible prospect runs, exactly as before this change (every existing call site
    // relies on that). A non-nil set narrows the eligible prospects to only those keys; an empty set
    // therefore yields an empty queue, which startPrep reports as nothing to prep.
    // The kept-undrafted prospects a Prep run would actually draft: needs-prep-eligible, narrowed to the
    // per-run subset Dan chose. Shared by buildQueue (what to encode) and startPrep (what to stamp an
    // experiment arm onto), so the assigned set and the queued set can never disagree.
    static func eligibleProspects(from context: ModelContext, includedKeys: Set<String>?) -> [Prospect] {
        let all = (try? context.fetch(FetchDescriptor<Prospect>())) ?? []
        return all
            .filter(PrepQueueBuilder.needsPrepEligible)
            .filter { includedKeys?.contains($0.naturalKey) ?? true }
    }

    // #1720: the houses the run is told about, computed ONCE per queue build from the WHOLE store plus
    // Dan's own corrections. The whole store rather than the run's own items on purpose: judged against a
    // single night's selection almost nothing looks like a house, and the run would go hunting the
    // building's own inbox for want of being told (the same reasoning buildProbeQueue states for the
    // producer grouping). Read here, where the corpus is read, so neither build path can forget it.
    static func houses(from context: ModelContext) -> [ProducerGate.House] {
        let all = (try? context.fetch(FetchDescriptor<Prospect>())) ?? []
        return ProducerGate.houses(shows: all.map { ProducerGate.Show(presenter: $0.presenter,
                                                                      venue: $0.venue) },
                                   overrides: ProducerOverrideEditing.overrides(in: context))
    }

    // #2392: the addresses struck on one show, at either level, as the run is told them. One
    // implementation for both work-lists (the prep queue and the probe queue), because a rule spelled out
    // twice is how one of them comes to be missing a scope.
    //
    // The organisation half matters as much as the show half: an address Dan struck on the ledger is one
    // this show would inherit, and the run hunting the same organisation would find it again.
    private static func struckAddresses(for p: Prospect,
                                        refusals: ContactRefusal.Ledger) -> [String]? {
        guard !refusals.isEmpty else { return nil }
        let orgKey = p.presenter.flatMap { OrgKey.stored(for: $0) }
        let struck = refusals.struckAddresses(showKey: p.naturalKey, orgKey: orgKey)
        return struck.isEmpty ? nil : struck
    }

    static func buildQueue(from context: ModelContext, generatedAt: String,
                           includedKeys: Set<String>? = nil,
                           today: String = EasternDate.today(),
                           venueHistory: VenueShootHistory? = nil) -> PrepQueue {
        // #1887: read once per build, never per item (it reads two files).
        let history = venueHistory ?? VenueShootHistory.current(today: today)
        // #2392: the addresses Dan struck, read ONCE per build for the same reason.
        let refusals = ContactRefusal.ledger(in: context)
        let items: [PrepQueueItem] = eligibleProspects(from: context, includedKeys: includedKeys)
            .map { p in
                PrepQueueItem(
                    naturalKey: p.naturalKey,
                    groupName: p.groupName,
                    venue: p.venue,
                    performanceDate: p.performanceDate,
                    // #1122: the run's closing night, so a draft can pitch the whole run.
                    runEndDate: p.runEndDate,
                    discipline: p.discipline,
                    websiteURL: p.websiteURL,
                    sourceListingURL: p.sourceListingURL,
                    possibleMatchName: p.possibleMatchName,
                    // #752: NOT p.priorRelationship. An unconfirmed performer match must not reach the
                    // drafter, or a guess Dan never agreed with picks the tone of a real email. This is
                    // the only writer of this field, so this is the only place the gate belongs.
                    priorRelationship: p.priorRelationshipForDrafting,
                    production: p.production,
                    // #1308 Phase 4: draft_only when a probe already found this show's contact, so a first
                    // prep skips the expensive hunt. An explicit re-prep still wins (inside prepMode).
                    reprepMode: PrepQueueBuilder.prepMode(
                        hasDraft: p.hasDraft,
                        reprepDraftRequested: p.reprepDraftRequested,
                        reprepContactsRequested: p.reprepContactsRequested,
                        // #1666: through the shared helper, not spelled out here. The queue card has to
                        // reach the same answer, and two spellings of one rule is exactly the drift
                        // that put a Prep promise on shows Prep was refusing.
                        probedWithContact: PrepQueueBuilder.probedWithContact(
                            probedAt: p.reachabilityProbedAt,
                            contactEmails: p.recipients.map(\.email))),
                    // #1122: set only when the opening night has passed while later dates remain, so the
                    // drafter pitches only the remaining dates and never names the gone opening. Absent
                    // otherwise (single-night, or a run not yet started), so the common case is unchanged.
                    openingNightPassed: PrepQueueBuilder.openingNightPassed(
                        performanceDate: p.performanceDate, runEndDate: p.runEndDate, today: today)
                        ? true : nil,
                    // #5 v5: the assigned A/B arm, so the drafter is told which opener archetype to use.
                    // nil for a prospect with no assignment (the common case: no active experiment).
                    experimentArmInstruction: p.assignedArm,
                    // #1856: the same fact a contact check is told, on the same terms. A kept show can
                    // name no producer just as easily as an untriaged one, and the waterfall it feeds is
                    // literally the same waterfall.
                    onlyTheActIsNamed: OrganiserNaming.onlyTheActIsNamed(presenter: p.presenter),
                    // #1887: the BAND only, never the count, so the drafter has no number to state.
                    // Absent when Dan has never shot the room, when no history has been imported, and
                    // deliberately on a Carnegie show, where the tenure credential already says it.
                    venueHistory: history.band(for: p.venue)?.rawValue,
                    // #2392: addresses Dan struck on this show, so the run does not pay to research or
                    // draft to one he already refused. Absent, never an empty list, on the shows with
                    // nothing struck. Sorted so the same store always writes byte-identical JSON.
                    refusedEmails: struckAddresses(for: p, refusals: refusals),
                    // #2983: and WHO, not merely that there is a who. Through the same predicate
                    // `onlyTheActIsNamed` above uses, so the two can never disagree. A drafted pitch has
                    // the same reason to name the producing company as a check has to search for it.
                    presenterOnRecord: OrganiserNaming.namedOrganiser(presenter: p.presenter)
                )
            }
        return PrepQueueBuilder.build(from: items, generatedAt: generatedAt, houses: houses(from: context))
    }

    // #1308 Layer 2: build a reachability PROBE work-list DIRECTLY from Dan's hand-picked keys, bypassing
    // `needsPrepEligible` entirely. That gate never admits a Review-stage `.new` show (PrepQueue.needsPrep),
    // but a probe's whole point is to research contacts BEFORE keep/dismiss, so the keys Dan chose ARE the
    // authority here. Every item is contacts-only, which is what tells the runner not to draft (no new wire
    // field needed); the app tracks "this run is a probe" in its own run-type state, not in the queue JSON.
    // `needsPrep`/the prep pill are left completely untouched.
    static func buildProbeQueue(from context: ModelContext, generatedAt: String, keys: Set<String>) -> PrepQueue {
        let all = (try? context.fetch(FetchDescriptor<Prospect>())) ?? []
        // #1597 Phase 4.3: pay once per producer, not once per show. Judged against the WHOLE store, not
        // just Dan's selection, or one night's ticks would make every producer look like a single-venue
        // house and nothing would amortise. A room that rents itself out never groups (ProducerGate).
        // #1719: Dan's own corrections, read from the same store the corpus came from. Without this the
        // gate ran on its automatic arms alone and a house he had already corrected by hand was still
        // amortised across its shows.
        let refusals = ContactRefusal.ledger(in: context)
        let plan = ProbeBatch.plan(selecting: keys,
                                   among: all.map { ProbeBatch.Show(key: $0.naturalKey,
                                                                    presenter: $0.presenter,
                                                                    venue: $0.venue) },
                                   overrides: ProducerOverrideEditing.overrides(in: context))
        let running = Set(plan.keysToRun)
        var covered: [String: [String]] = [:]
        for (show, representative) in plan.coveredBy { covered[representative, default: []].append(show) }
        let items: [PrepQueueItem] = all
            .filter { running.contains($0.naturalKey) }
            .map { p in
                PrepQueueItem(
                    naturalKey: p.naturalKey,
                    groupName: p.groupName,
                    venue: p.venue,
                    performanceDate: p.performanceDate,
                    runEndDate: p.runEndDate,
                    discipline: p.discipline,
                    websiteURL: p.websiteURL,
                    sourceListingURL: p.sourceListingURL,
                    possibleMatchName: p.possibleMatchName,
                    priorRelationship: p.priorRelationshipForDrafting,
                    production: p.production,
                    // Contacts-only: find the contact, never draft. The importer's code gate enforces the
                    // no-draft rule regardless, but the runner should not spend on drafting either.
                    reprepMode: "contacts_only",
                    // Sorted so the same selection always produces byte-identical JSON: a set's iteration
                    // order is not stable, and an unstable queue file makes two identical runs look
                    // different in the diff and in any fixture comparison.
                    alsoAnswersFor: covered[p.naturalKey]?.sorted(),
                    // #1856: the run is told when this show names no producer at all, so it pursues the
                    // act itself instead of hunting an organisation that does not exist.
                    onlyTheActIsNamed: OrganiserNaming.onlyTheActIsNamed(presenter: p.presenter),
                    // #2392: a probe hunts contacts too, so it needs the same list. Left off it, a check
                    // would find and report the address Dan struck, the importer would refuse it, and he
                    // would have paid for the lookup twice over.
                    refusedEmails: struckAddresses(for: p, refusals: refusals),
                    // #2983: the name behind that flag. Without it a check on a show credited to a real
                    // company was told a producer existed and never told which one, so it hunted a
                    // nameless organisation and reported `nothing_published` about one publishing its
                    // address. This is the field that failure was missing.
                    presenterOnRecord: OrganiserNaming.namedOrganiser(presenter: p.presenter))
            }
        return PrepQueueBuilder.build(from: items, generatedAt: generatedAt, houses: houses(from: context))
    }

    // #1308 Layer 2: the probe-run side marker (which shows a live probe is researching). It carries the
    // keys the check covers, its lookup count and its settle attempts.
    //
    // #2760: still ONE file rather than one per slot, deliberately. Only one check can be alive at a time
    // (the launch refuses a second, including the upgrade case where a legacy check holds the prep slot),
    // so a second marker would be a file nothing could ever write. Its OTHER job, telling a finished prep
    // run apart from a finished check, is now needed only for the prep slot's legacy branch: the check slot
    // holds nothing but checks.
    static func probeRunURL(in support: URL) -> URL {
        support.appendingPathComponent("reachability-probe-run.json")
    }

    static var defaultProbeRunURL: URL { probeRunURL(in: StoreLocation.handoffDirectory) }

    // Launch a reachability probe over Dan's hand-picked keys. Mirrors startPrep's lock dance exactly
    // (atomic marker acquire, so a probe and a prep can never both hold the single runner slot), but builds
    // a contacts-only probe queue and records the probed keys in the probe-run marker for the completion
    // path. A probe never drafts, so it skips the voice/openers handoffs startPrep refreshes.
    @discardableResult
    static func startReachabilityProbe(keys: Set<String>, from context: ModelContext, now: Date,
                                       support: URL = StoreLocation.handoffDirectory,
                                       defaults: UserDefaults = .standard,
                                       queueURL: URL? = nil,
                                       markerURL: URL? = nil,
                                       probeRunURL: URL? = nil,
                                       cancelURL: URL? = nil,
                                       // #1856: how a show's own listing page is loaded, for the shows
                                       // where the check has no target until it reads one. Same seam and
                                       // same test-refusing default as startPrep.
                                       render: @escaping ShowListingReader.Render = ShowListingReader.liveRender,
                                       onListingProgress: @MainActor (Int, Int) -> Void = { _, _ in },
                                       announce: @MainActor () -> Void = { DetachedRunActivity.check.runStarted() },
                                       launch: @MainActor () throws -> Void = { try launchRunner(slot: .check) })
        async throws -> Int {
        // #2760: the check has its OWN slot now, so every path below is `.check`'s. An injected marker
        // decides the support directory for everything else, including the exclusion below: a guard that
        // read the live folder while the lock dance read a temp one would be asking about a different
        // machine than the one it is protecting.
        let support = markerURL?.deletingLastPathComponent() ?? support
        let queueURL = queueURL ?? RunSlot.check.queueURL(in: support)
        let markerURL = markerURL ?? RunSlot.check.markerURL(in: support)
        let cancelURL = cancelURL ?? RunSlot.check.cancelURL(in: support)
        let probeRunURL = probeRunURL ?? Self.probeRunURL(in: support)
        // #2760: the exclusion is STILL IN FORCE, and it now has to be stated rather than falling out of
        // the two runs sharing one marker. It asks about both slots, and it names which run is in the way,
        // including the upgrade case where a check started by an older build holds the PREP slot and the
        // check slot is empty (without this, that window is the one place two checks could run at once).
        if let refusal = runInFlightRefusal(now: now, support: support, checkMarkerURL: markerURL,
                                            defaults: defaults) { throw refusal }

        // #2765: reduce the SELECTION before the queue is planned, never the built queue. A check item is
        // a REPRESENTATIVE standing for N shows through `alsoAnswersFor`, so dropping a built item would
        // silently cost the other N-1 their coverage, and keeping it would violate the exclusion for the
        // held show (L66, L166). Subtracting here re-plans over what is left and picks a new
        // representative for the shows nobody holds.
        let checkSelection = selection(from: keys,
                                       excluding: try heldByOtherRun(slot: .check, now: now,
                                                                     support: support, defaults: defaults))
        if checkSelection.isEmptyBecauseHeld {
            let noun = runInFlight(slot: .prep, now: now, support: support, defaults: defaults)?.runNoun
                ?? RunKind.prep.runNoun
            throw PrepLaunchError.everyShowHeld(runNoun: noun)
        }
        let keys = checkSelection.kept

        let stamp = ISO8601DateFormatter().string(from: now)
        let queue = buildProbeQueue(from: context, generatedAt: stamp, keys: keys)
        // #1595: the probe's OWN error. This path is reached from Scout, over untriaged shows Dan has kept
        // nothing from, so the Prep wording ("No kept prospects need prepping. Keep some prospects first.")
        // describes a different feature and would send him looking for a button that is not the problem.
        guard !queue.items.isEmpty else { throw PrepLaunchError.nothingToCheck }

        // Atomic lock acquire, identical to startPrep (#480): clear a stale marker, then exclusive-create.
        try FileManager.default.createDirectory(at: markerURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? FileManager.default.removeItem(at: markerURL)
        do {
            try Data().write(to: markerURL, options: .withoutOverwriting)
        } catch {
            throw PrepLaunchError.alreadyRunning
        }
        try? FileManager.default.removeItem(at: cancelURL)

        // #3010: publish WHICH SHOWS this run holds, immediately after the lock and before the slow
        // listing read below, so the other launch can drop the overlap rather than both runs taking one
        // show. Fail-loud: a run whose coverage did not publish holds shows nobody can see, so the
        // exclusion would be silently off for the whole of it (L12). The key set is the one
        // `ReachabilityProbeMarker.write` already uses further down, derived once rather than spelled out
        // twice, because two copies of one definition drift (L107).
        //
        // Nothing CONSUMES this yet: the subtraction is #2765 and the launch serialisation is #3011. It is
        // written now so that phase has a published fact to read rather than an empty file (L90/L46), and
        // the reader it already has is `RunCoverage.read`.
        let coveredKeys = Set(queue.items.flatMap { [$0.naturalKey] + ($0.alsoAnswersFor ?? []) })
        do {
            try RunCoverage.write(keys: coveredKeys, slot: .check, in: support)
        } catch {
            try? FileManager.default.removeItem(at: markerURL)
            throw error
        }
        // #3014: a check starting is what makes the fan-out block apply at all, so the cached holdings are
        // re-read here rather than waiting for some unrelated write to rebuild the queue.
        LiveRunHoldings.refresh(support: support, now: now)

        do {
            // #1856: read the show's own page for the shows that name no producer, and ONLY those. The
            // check's target on one of them is the act, and on a title-billed show ("Broadway's Bad
            // Guys!") the act's name is nowhere but that page: 63 of the 93 live rows in this state are
            // JavaScript-drawn VenueTix pages, which the run's own tool scope forbids it from rendering.
            //
            // A show that already names its producer still spends nothing here (#1824's reasoning, which
            // held for every show while the check had a target without reading anything).
            //
            // Inside the lock and before the file is written, exactly as startPrep does: the run opens the
            // queue as it launches, so a listing read afterwards would arrive too late, and one read
            // before the lock would let two presses each pay for the same renders.
            let needingListing = queue.items.filter { $0.onlyTheActIsNamed == true }
            let listings = await ShowListingReader.readAll(for: needingListing, render: render,
                                                           onProgress: onListingProgress)
            let data = try PrepQueueBuilder.encode(PrepQueueBuilder.attaching(listings, to: queue))
            try FileManager.default.createDirectory(at: queueURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: queueURL, options: .atomic)
            // Record which shows this probe covers, so completion can mark them probed even on an empty
            // run. #1597: that is every show Dan SELECTED, which is more than the run researches: a
            // grouped item answers for the shows in its `alsoAnswersFor` too, and those must settle. The
            // intersection with what actually came back still governs (#1594), so a run that ignored the
            // grouping leaves those shows unchecked and says so in the log rather than silently marking
            // them "no email found".
            try ReachabilityProbeMarker.write(
                ReachabilityProbeMarker(
                    keys: Set(queue.items.flatMap { [$0.naturalKey] + ($0.alsoAnswersFor ?? []) }),
                    startedAt: stamp,
                    // #1616: the LOOKUPS, which is the queue's own item count. The runner chunks this list,
                    // so it is what decides how many rounds the run's wall clock covered, and the keys above
                    // are a larger number that would make every learned round look faster than it was.
                    lookups: queue.items.count),
                to: probeRunURL)
            try launch()
            recordRunStarted(slot: .check, at: now, defaults: defaults)
            // #1938: a check announces itself too. #2760: to its OWN activity, which is what makes it
            // followed and settled when it starts while a prep is live.
            announce()
        } catch {
            try? FileManager.default.removeItem(at: markerURL)   // release the lock if we never launched
            // #3010: and the coverage with it. A hold published for a run that never started would take
            // shows away from the other run for nothing, and only the marker's disappearance releases it.
            RunCoverage.clear(slot: .check, in: support)
            ReachabilityProbeMarker.clear(at: probeRunURL)
            throw error
        }
        return queue.items.count
    }

    // #1308 Layer 2: mark a probed show probed on completion, whether or not the run found a contact, so
    // the badge resolves to email-found/not-found instead of sticking on the free heuristic. Runs BEFORE
    // the probe-safe ingest overlays any found contacts.
    //
    // #1594: it stamps only the shows the run ACTUALLY ANSWERED, which is the intersection of what the run
    // was asked to do (the marker) with what came back (the results file). The marker alone is a record of
    // intent, so stamping from it labelled every show in a cancelled or crashed run "No email found" and,
    // because the badge trusts a stamp for 90 days, locked those shows out of a re-check for three months.
    // At one date that was 2 or 3 shows; after multi-date selection it is a whole week.
    //
    // The two cases that must never look alike are told apart by evidence in the file: a key PRESENT with
    // no contacts is the runner reporting "I looked, there is nobody", a real answer worth keeping; a key
    // ABSENT was never reached. Nothing about that judgment can come from the marker.
    //
    // The results file is read HERE rather than being handed in by the importer on purpose:
    // PrepImporter.consumeIfNew skips the ingest entirely when the file has already been consumed (a
    // re-settle, or a relaunch after ingest but before the marker cleared), and in that case this is the
    // only writer that runs at all.
    // Returns the keys it actually stamped, so the organisation ledger (#1598) records an answer for
    // exactly the shows this run answered and there is ONE definition of "answered" rather than two that
    // can drift.
    // #1677: `saveFailed` is an OUT parameter rather than a changed return type because the answered-key
    // set is what every caller is really asking for. The save used to be `try? context.save()`, discarding
    // the error outright: on the normal path the ingest that follows saves again so the window is narrow,
    // but on a re-settle `consumeIfNew` skips the ingest entirely and this is the ONLY writer that runs. A
    // failed save there leaves the shows unstamped, the marker cleared, and a Check button offering to pay
    // again for lookups that already happened.
    @discardableResult
    // #1623: `anIngestIsStillToCome` is whether the results file this settle is reading has yet to be
    // ingested. It decides whether the floor below is a DEFAULT or an OVERWRITE, and it is asked of the
    // same decision `consumeIfNew` makes rather than inferred from the row.
    // #1804: `queueURL` is the work-list the app itself wrote, and it is here so a show whose answer was
    // paid for under a GROUP LEAD counts as answered and is stamped. Without it those shows stay unstamped,
    // are selected and paid for again on the next check, and are counted into the shortfall sentence as
    // never answered. Optional so a caller with no queue on disk keeps the old behaviour rather than
    // failing; the real settle path always supplies it.
    static func markProbed(keys: Set<String>, answeredIn resultsURL: URL,
                           in context: ModelContext, now: Date,
                           anIngestIsStillToCome: Bool,
                           saveFailed: inout Bool,
                           queueURL: URL? = nil,
                           // #1606: injectable so a test can rehearse a rekey without touching the file.
                           remapURL: URL = NaturalKeyRemap.defaultURL) -> Set<String> {
        // #1606: BOTH ends are translated, and both is the point. A launch that rewrote natural keys
        // leaves the marker's keys AND the results file's keys stale in the same way, so translating one
        // would still intersect to nothing. A key nothing renamed answers with itself, so this is
        // unconditional rather than a branch that could be skipped.
        let remap = (try? NaturalKeyRemap.read(from: remapURL)) ?? NaturalKeyRemap(entries: [])
        let answered = Set(PrepImporter.answeredKeys(at: resultsURL, queueURL: queueURL)
                            .map(remap.current))
        let asked = Set(keys.map(remap.current))
        let toStamp = asked.intersection(answered)
        let all = (try? context.fetch(FetchDescriptor<Prospect>())) ?? []
        for p in all where toStamp.contains(p.naturalKey) {
            // #1596 Phase 3: the pre-guard default. This runs BEFORE the probe-safe ingest, so the venue
            // and press guards have not classified anything yet and this writer cannot tell a sendable
            // address from a front desk. It records the floor; the ingest upgrades it when contacts
            // landed. A run that found nothing never reaches the ingest, so this value is the answer.
            //
            // #1623: only while an ingest is still to come. On a RE-settle nothing follows this, so an
            // unconditional floor is the last word and a show that found jane@example.org last night comes
            // back reading "No email found", with that address still printed underneath it and a 90-day
            // freshness stamp locking it out of a re-check.
            if anIngestIsStillToCome {
                p.reachabilityProbedAt = now
                p.reachabilityResult = .noEmailFound
            } else {
                // Re-settling the same file changes nothing about WHEN this show was researched or what
                // was found, so both fields are filled in only where nothing is there. That is not the
                // "write the floor only when the result is nil" rule the issue warns against: on a FIRST
                // settle the branch above still overwrites, so a genuine re-check that found nothing
                // still clears an earlier positive. This branch exists for the row a first settle failed
                // to save, which would otherwise read as never checked and be paid for twice.
                if p.reachabilityProbedAt == nil { p.reachabilityProbedAt = now }
                if p.reachabilityResult == nil { p.reachabilityResult = .noEmailFound }
            }
            // #1724: this show HAS an answer now, so any record that an earlier check missed it is spent.
            // Unconditional, on both branches: a re-settle is still an answer landing, and leaving the mark
            // would put "a check missed this" on a card beside the address the check found.
            p.reachabilityUnansweredAt = nil
            // #2261: and so is any outstanding request to re-check it, for the same reason and on the same
            // terms. The question has been asked again and answered; leaving the request standing would
            // keep offering the show and let Dan pay for the same question every time he looked at it.
            p.reachabilityRecheckRequestedAt = nil
        }
        // #1724: the shows this check was given and did not answer. Written HERE rather than in
        // `settleReachabilityProbe` for two reasons, both load-bearing:
        //
        //   1. It is the same judgment. `toStamp` is the intersection of what the run was asked to do with
        //      what came back, and this is its complement, off the same two facts in the same pass. Derived
        //      anywhere else it could disagree with the shortfall sentence Dan reads, which is exactly the
        //      count-versus-rows split L16 is about.
        //   2. It is committed by the SAME save. Either the answers and the misses both land or neither
        //      does, and the #1677 marker retry that already covers a failed save covers this too. A second
        //      save of its own would be a second thing that can half-happen.
        //
        // On a re-settle (`consumeIfNew` refuses a file it has already read) this function is the only
        // writer that runs at all, which is precisely why the record has to live in it.
        // #1606: the shortfall is judged in CURRENT keys too, or a rekeyed show would read as missed by a
        // run that answered it perfectly well.
        let missed = asked.subtracting(toStamp)
        for p in all where missed.contains(p.naturalKey) {
            p.reachabilityUnansweredAt = now
            // #2261: the re-check request is deliberately NOT spent here. This run never reached this
            // show, so the question Dan asked has not been answered, and clearing it would drop his
            // re-run silently: the card would go straight back to its old frozen verdict with nothing
            // recording that the run he paid for never got to it (L47).
        }
        saveFailed = false
        do {
            try context.save()
        } catch {
            saveFailed = true
            // copy-inventory:ignore-start  a diagnostic log line, not a sentence Overture says on screen
            // #1689: a PROBLEM. The probe ran and its results did not reach the store.
            AgentLog.problem("could not stamp \(toStamp.count) probed shows: \(error.localizedDescription)")
            // copy-inventory:ignore-end
        }
        // The diagnostic copy of the shortfall, naming both counts for whoever is reading the log.
        //
        // #1769: this used to be the ONLY place a partial check was reported, described as failing loud.
        // It was not loud: an NSLog is invisible from the running app, so a check that answered 3 of 5
        // shows told nobody. `settleReachabilityProbe` now returns the same shortfall as a report the
        // caller puts on screen (ReachabilityRunSummary). This line stays as the log record, not as the
        // way Dan finds out.
        if toStamp.count < keys.count {
            // copy-inventory:ignore-start  a diagnostic log line, not a sentence Overture says on screen
            // #1689: a PROBLEM, and the line this whole issue was named for. A paid check that came
            // home short is a real thing for Dan to look at, and it carries no word like error or
            // failed, which is exactly why the kind is stated here rather than guessed from the text.
            AgentLog.problem("reachability probe settled with \(toStamp.count) of \(keys.count) shows answered; \(keys.count - toStamp.count) were never reached and stay unchecked")
            // copy-inventory:ignore-end
        }
        return toStamp
    }

    // #1308 Layer 2: settle a finished detached run. A probe and a real Prep share the runner and results
    // file, so the probe-run marker is what tells them apart. Returns a report when the finished run was a
    // probe (and was settled): every probed show is marked probed (found or not), the results are ingested
    // probe-safely (never a draft), and the marker is cleared. Returns nil when no probe marker is
    // present, so the caller ingests the run as a normal prep. Called on both producedResults and
    // finishedEmpty: a probe that found nothing is a valid "no email found" result, not a failure.
    //
    // #1769: it returns a REPORT rather than a bare yes/no because a check can come home partial. It runs
    // as up to ten concurrent claudes and a chunk that dies partway leaves the shows it never reached with
    // no answer. markProbed already knew that (it computes exactly this shortfall) and said so only to an
    // NSLog nothing surfaces, so a run that answered 69 of 77 read to Dan as a clean pass.
    //
    // #1769: the three files the ingest reads are injectable for the same reason the marker and results
    // already were. Left at their defaults a test reached Dan's LIVE prep queue and his real Downbeat
    // export, so the Outcome it examined depended on what happened to be on this Mac (L2). No caller in
    // the app passes them; they exist so a test cannot.
    //
    // #2760: `slot` is a REQUIRED first parameter and every path below follows it. It used to take six
    // URLs, each defaulted to a prep-slot path, so a check-slot caller that passed `markerURL:` and forgot
    // `resultsURL:` would compile and silently ingest the PREP run's results with `isProbe: true`, short
    // circuiting before draft handling and discarding every draft that run wrote. That is #1809 through a
    // new door, and it is the exact hazard this phase creates by putting a second run on disk.
    @discardableResult
    static func settleReachabilityProbe(slot: RunSlot,
                                        support: URL = StoreLocation.handoffDirectory,
                                        markerURL: URL? = nil,
                                        resultsURL: URL? = nil,
                                        queueURL: URL? = nil,
                                        downbeatURL: URL = DownbeatBridge.defaultURL,
                                        historyURL: URL = LocalHistory.importedURL,
                                        cancelURL: URL? = nil,
                                        into context: ModelContext, now: Date,
                                        defaults: UserDefaults = .standard) -> ReachabilityRunReport? {
        let markerURL = markerURL ?? probeRunURL(in: support)
        let resultsURL = resultsURL ?? slot.resultsURL(in: support)
        let queueURL = queueURL ?? slot.queueURL(in: support)
        let cancelURL = cancelURL ?? slot.cancelURL(in: support)
        // #3009: the probe marker is ONE file for both slots (RunSlot.swift), and it is also what decides
        // what a finished PREP was. That held only while one run could be alive, which is the premise
        // #2765 removes. A LIVE check OWNS this marker, so settling the prep slot through it reads the
        // CHECK's keys against the PREP's results, ingests with `isProbe: true`, short circuits before
        // draft handling and discards every draft the prep wrote, then clears the live check's record on
        // the way out. That is the hazard the #2760 comment above names, arriving through concurrency
        // rather than through a caller passing the wrong URL.
        //
        // Evidence, not inference: the check slot's own marker says a check is live. Run identity is
        // CARRIED, never deduced from which files happen to be lying around, which is the same rule #2980
        // applied to the runner.
        //
        // Only the PREP slot asks. A check IS settled while it is live (its only callers sit inside
        // `watchPrepRun`), so the same question asked of `.check` would refuse every real settle.
        if slot == .prep,
           isRunning(slot: .check, markerURL: RunSlot.check.markerURL(in: support), now: now) {
            // copy-inventory:ignore-start  a diagnostic log line, not a sentence Overture says on screen
            AgentLog.note("a check is live, so the shared probe marker is that check's: settling the prep slot as an ordinary prep run and leaving the marker alone (#3009).")
            // copy-inventory:ignore-end
            return nil
        }
        guard let marker = (try? ReachabilityProbeMarker.read(from: markerURL)) ?? nil else { return nil }
        var stampSaveFailed = false
        // #1623: asked BEFORE the ingest below consumes the file, because afterwards the answer is always
        // "already consumed" and the floor would never overwrite anything again.
        let ingestToCome = PrepImporter.hasUnconsumedResults(slot: slot, at: resultsURL, defaults: defaults)
        let answered = markProbed(keys: marker.keys, answeredIn: resultsURL, in: context, now: now,
                                  anIngestIsStillToCome: ingestToCome,
                                  saveFailed: &stampSaveFailed, queueURL: queueURL)
        // #1769: the ingest Outcome used to be discarded whole, so a failed save or a runaway web-call
        // count was invisible on a check as well as the shortfall. Kept, and folded into the report below.
        //
        // It is nil on a re-settle (consumeIfNew refuses a results file it has already read), which is
        // exactly why the shortfall is derived from `marker` against `answered` and never from here: those
        // two are on disk either way.
        let outcome = PrepImporter.consumeIfNew(
            slot: slot, at: resultsURL, into: context, defaults: defaults,
            ingest: { try PrepImporter.ingestFile(at: $0, into: $1, downbeatURL: downbeatURL,
                                                  historyURL: historyURL, queueURL: queueURL,
                                                  isProbe: true, now: now) })
        // #1598 Phase 5: record what this check concluded about each ANSWERED show's organisation, so a
        // sibling show never has to be paid for again. Deliberately last: only now have the venue and
        // press guards run, so a real contact can be told from a front desk, and only the shows the run
        // genuinely answered are in hand.
        // #1676: its outcome is KEPT. A failed ledger save is money already spent that Overture will spend
        // again, and it used to report only to an NSLog nothing surfaces.
        let ledger = OrgAnswerRecording.record(answeredKeys: answered, in: context, now: now)
        // #1648 Phase E: the ONE place a fresh answer moves the stored score, and it is here for exactly
        // the reason the two calls above are. markProbed writes a .noEmailFound FLOOR and saves before
        // the importer upgrades it, so hooking "wherever the result is written" would commit a demotion
        // on a verdict that was never true and strand it there if the ingest then refused or the app
        // died. Only now have the venue and press guards run, so a real contact can be told from a front
        // desk, and only the shows this run genuinely answered are in hand.
        //
        // Scoped to `answered` for the same reason OrgAnswerRecording is: a show the run never reached
        // must not be scored as though it had been.
        let answeredShows = (try? context.fetch(FetchDescriptor<Prospect>())) ?? []
        _ = ContactScoreAdjustment.settleAll(answeredShows.filter { answered.contains($0.naturalKey) },
                                             now: now)
        // #1677, Dan's call (2026-07-30): a run whose record did not save is NOT finished, so its marker
        // stays and it settles again rather than closing out as though the stamps had landed. Clearing here
        // is what would make the loss permanent and hand Dan a Check button offering to pay again.
        //
        // Bounded, his second call: the retry is idempotent (same keys, same results file), but a store that
        // will never accept a write would otherwise re-announce on every launch forever. After
        // maxSettleAttempts the marker is released and the report says it stopped trying, so the run closes
        // out having told him plainly rather than nagging indefinitely.
        var gaveUp = false
        if stampSaveFailed {
            let attempts = (marker.settleAttempts ?? 0) + 1
            if attempts >= ReachabilityProbeMarker.maxSettleAttempts {
                gaveUp = true
                ReachabilityProbeMarker.clear(at: markerURL)
            } else {
                var next = marker
                next.settleAttempts = attempts
                // If even THIS write fails the marker keeps its old count, so the worst case is a few extra
                // attempts, never a lost run.
                try? ReachabilityProbeMarker.write(next, to: markerURL)
            }
        } else {
            ReachabilityProbeMarker.clear(at: markerURL)
        }
        // #1685: was this check STOPPED, or did it simply come home short? The two need different
        // sentences, because only one of them means Dan paid for lookups that returned nothing.
        //
        // Read from the cancel sentinel, which is the same file the runner itself obeys, so the report and
        // the runner can never disagree about whether a stop was requested. It is safe to read here because
        // `startPrep` clears it before launching: its presence at settle can only have come from a cancel
        // of THIS run. Read before the marker work above is undone by a later run, and never treated as an
        // error if the file cannot be reached, since a missing sentinel is the ordinary case.
        let wasCancelled = FileManager.default.fileExists(atPath: cancelURL.path)
        return ReachabilityRunReport(requested: marker.keys.count, answered: answered.count,
                                     outcome: outcome, stampSaveFailed: stampSaveFailed,
                                     ledgerSaveFailed: ledger.saveFailed, stampSaveGaveUp: gaveUp,
                                     cancelled: wasCancelled)
    }

    // #1809: settle a check that finished while Overture was CLOSED.
    //
    // `settleReachabilityProbe` is only reachable from the run watcher, which runs only while a run is
    // live. The runner is detached and removes its own run marker on exit, so a check that finished with
    // the app shut is never settled, now or ever: its paid answers never land, and the marker it leaves
    // behind then makes the next Prep run read as a check and discard every draft it wrote.
    //
    // Returns nil when there is nothing left over, which is the normal case and must stay cheap.
    @discardableResult
    static func settleOrphanedProbe(slot: RunSlot,
                                    support: URL = StoreLocation.handoffDirectory,
                                    markerURL: URL? = nil,
                                    resultsURL: URL? = nil,
                                    queueURL: URL? = nil,
                                    downbeatURL: URL = DownbeatBridge.defaultURL,
                                    historyURL: URL = LocalHistory.importedURL,
                                    into context: ModelContext, now: Date,
                                    defaults: UserDefaults = .standard) -> ReachabilityRunReport? {
        let markerURL = markerURL ?? probeRunURL(in: support)
        guard ((try? ReachabilityProbeMarker.read(from: markerURL)) ?? nil) != nil else { return nil }
        return settleReachabilityProbe(slot: slot, support: support, markerURL: markerURL,
                                       resultsURL: resultsURL, queueURL: queueURL,
                                       downbeatURL: downbeatURL, historyURL: historyURL,
                                       into: context, now: now, defaults: defaults)
    }

    // #1613: sweep a run that DIED.
    //
    // Observed live on 2026-07-27: prep-run.sh died at parse time, so it never reached the heartbeat loop
    // that reads the cancel sentinel. The app called it stuck and offered Cancel, and Cancel writes a
    // sentinel only a LIVE runner ever reads, so the button could not do anything however many times it
    // was pressed. It cleared only when the files were deleted by hand in Application Support, which Dan
    // has no way to do from inside the app.
    //
    // Dan's call (2026-08-04): Overture clears it itself and says the run died, rather than waiting for a
    // click. So this is a sweep, not a button. It returns nil for every ending that is NOT a death, which
    // is what stops it touching a live batch mid-write and what makes calling it twice report once: the
    // second call finds no marker, reads .absent, and declines.
    //
    // The paid half goes through #1809's own settle rather than a second implementation of it: a check
    // that died still researched shows Dan paid for, and deleting its marker blind would throw those
    // answers away. Settled FIRST, then the marker is released, in that order, for the same reason
    // settleAnyCheckBefore does it that way.
    @discardableResult
    static func clearDeadRun(slot: RunSlot,
                             support: URL = StoreLocation.handoffDirectory,
                             markerURL: URL? = nil,
                             cancelURL: URL? = nil,
                             probeRunURL: URL? = nil,
                             into context: ModelContext, now: Date,
                             defaults: UserDefaults = .standard) -> DeadRunOutcome? {
        let markerURL = markerURL ?? slot.markerURL(in: support)
        let cancelURL = cancelURL ?? slot.cancelURL(in: support)
        let probeRunURL = probeRunURL ?? Self.probeRunURL(in: support)
        // The death is established FIRST and separately from the sweep below. It has to be: the settle
        // between them costs real work and, on a check, writes paid answers into the store, so running it
        // before knowing the run is dead would settle a check that is still going.
        guard DetachedRunEnding.of(heartbeat: heartbeat(slot: slot, markerURL: markerURL,
                                                        now: now)) == .died else {
            return nil
        }
        // Settled BEFORE the marker is released: dropping it first would leave a window where the run
        // reads as finished while answers Dan paid for are still unaccounted for. Same ordering, and the
        // same reason, as settleAnyCheckBefore.
        let report = settleOrphanedProbe(slot: slot, support: support, markerURL: probeRunURL,
                                         into: context, now: now, defaults: defaults)
        ReachabilityProbeMarker.clear(at: probeRunURL)
        // #2104: the marker and sentinel half is DetachedRunner's, shared with the scout read and the
        // reply run so the three cannot drift. The check settle above is the only Prep-specific part.
        DetachedRunner.sweepDeadRun(markerURL: markerURL, cancelURL: cancelURL, now: now,
                                    staleAfter: markerStaleAfter)
        // #3010: a run that DIED never reached its own EXIT trap, so its coverage is still on disk saying
        // it holds shows. AFTER the marker sweep above, never before: with the marker gone the read is
        // `.noLiveRun` whatever is left here, while the reverse order would leave a live-looking slot whose
        // coverage had vanished, which is the refusal state rather than a release.
        RunCoverage.clear(slot: slot, in: support)
        // #3014: a run that DIED never reached its own end, so the block must be released here too.
        LiveRunHoldings.refresh(support: support, now: now)
        return DeadRunOutcome(probeReport: report)
    }

    // #1809: a Prep run is definitively NOT a check, so no check marker may survive into its completion,
    // where it would make this run ingest probe-safely and silently drop every draft it produced.
    //
    // Settles any orphan FIRST and only then releases the marker: dropping it blind would discard answers
    // Dan already paid for. The report goes to `onOrphanSettled` so a caller with somewhere to show it can,
    // rather than the settle being silent, which is the whole thing this milestone is about.
    //
    // Lives HERE, in the service, and is called from startPrep rather than from the view. Put in
    // RootView.startPrep it covered only two of the three ways a Prep run begins: a per-row Re-prep goes
    // straight to the service from ProspectMutations with no RootView call at all, so that path would have
    // kept the exact bug this issue is about.
    //
    // #2760: it settles the CHECK slot's files. A leftover marker from a check now names a run whose
    // results and work-list are the check slot's, so reading the prep slot's here would settle a check
    // against the prep run's own answers.
    @discardableResult
    static func settleAnyCheckBefore(prepRunIn context: ModelContext, now: Date,
                                     support: URL = StoreLocation.handoffDirectory,
                                     defaults: UserDefaults = .standard,
                                     onOrphanSettled: (ReachabilityRunReport) -> Void = { _ in })
        -> ReachabilityRunReport? {
        let probeRunURL = Self.probeRunURL(in: support)
        // #3009: only a check that has ENDED is settled here, and only its record cleared. This gate used
        // to be the marker merely EXISTING, which was right while a prep and a check could not both be
        // alive. Without it, a prep launched during a live check settles that check against a results file
        // it has not finished writing and then deletes the marker it needs, so its paid answers are never
        // stamped, `OrgAnswerRecording` never runs, and every show it covered is paid for again. That is
        // #1594 restored, and the clear below is unconditional, so the refusal has to be here rather than
        // inside the settle.
        //
        // A check that ended CLEANLY removed its own marker, and one that DIED left a stale one, so both
        // read as not running and both are still settled exactly as before. The only case this refuses is
        // the one that is genuinely still working.
        guard !isRunning(slot: .check, markerURL: RunSlot.check.markerURL(in: support), now: now) else {
            // copy-inventory:ignore-start  a diagnostic log line, not a sentence Overture says on screen
            AgentLog.note("a check is still running, so it is not a finished run to settle before this prep: left its record alone (#3009).")
            // copy-inventory:ignore-end
            return nil
        }
        let report = settleOrphanedProbe(slot: .check, support: support, markerURL: probeRunURL,
                                         into: context, now: now, defaults: defaults)
        if let report { onOrphanSettled(report) }
        // Belt and braces: a settle that kept the marker (its save failed, #1677) must still not leave a
        // check marker standing in front of a Prep run. The answers are retried on the settle's own terms;
        // what must not survive is the marker's power to relabel THIS run.
        ReachabilityProbeMarker.clear(at: probeRunURL)
        return report
    }

    enum PrepLaunchError: LocalizedError, Equatable {
        case nothingToPrep
        case nothingToCheck
        // #2838: carries its reason, so it can name the setting that is wrong and what it points at.
        case runnerUnavailable(String)
        case alreadyRunning
        // #2760: a check is what is in the way, which `alreadyRunning` cannot say. Two launches share this
        // vocabulary and both can meet either run, including the upgrade case where a check started by an
        // older build holds the prep slot. Naming a Prep run there sends Dan looking for a run he never
        // started.
        case checkAlreadyRunning
        // #2765: every show this run would have covered is already in the OTHER run. Its own case rather
        // than `nothingToPrep`, whose sentence ("Keep some prospects first") describes a different
        // situation entirely and would send Dan to a control that is not the problem (L11). It names the
        // run holding them, because that is the thing he has to wait for.
        case everyShowHeld(runNoun: String)
        // #2765: the other slot is LIVE and what it holds cannot be established. Fail CLOSED: treating it
        // as "holds nothing" would be fail-open on the one control that stops two paid runs taking the
        // same show (L42, L105), and an unreadable answer arrives exactly when something has gone wrong.
        case holdingsUnreadable(runNoun: String)

        var errorDescription: String? {
            switch self {
            case .nothingToPrep:
                return "No kept prospects need prepping. Keep some prospects first."
            case .nothingToCheck:
                return "Nothing on this date still needs a reachability check."
            case .runnerUnavailable(let reason):
                return reason
            case .alreadyRunning:
                return "A Prep run is already in progress. Wait for it to finish."
            case .checkAlreadyRunning:
                return "A contact check is already going. Wait for it to finish."
            case .everyShowHeld(let runNoun):
                return "Every show here is already in the \(runNoun) that is running. Wait for it to finish and try again."
            case .holdingsUnreadable(let runNoun):
                return "Overture cannot tell which shows the \(runNoun) is working on, so it will not start a run that might take the same ones. Wait for that run to finish and try again."
            }
        }
    }

    // The in-flight marker the runner script drops on start and removes on exit. The
    // app also writes it on launch so the double-run guard is immediate (no race with
    // the detached script). While genuinely working the runner HEARTBEATS the marker
    // (touches it ~every 60s, see prep-run.sh), so a long multi-prospect batch never
    // looks stale (#47). The window is therefore a few-missed-beats crash detector, not
    // a guess at total run time: a marker untouched past it means the run died, so the
    // app can never get permanently stuck "running" yet also never falsely frees the
    // double-run guard mid-batch.
    static let markerStaleAfter: TimeInterval = RunTimeouts.prep

    // #2763: the name is RunSlot's to know, not this file's. #2760: and WHICH slot is now an argument on
    // every one of these, because the check is on its own.
    static func markerURL(for slot: RunSlot) -> URL {
        slot.markerURL(in: StoreLocation.handoffDirectory)
    }

    static func cancelURL(for slot: RunSlot) -> URL {
        slot.cancelURL(in: StoreLocation.handoffDirectory)
    }

    static var defaultMarkerURL: URL { markerURL(for: .prep) }

    // #1038: the cooperative-cancel sentinel. Prep is launched through the same DetachedRunner as scout,
    // so its run has no trackable PID (backgrounded via `sh -c '... &'` with no handle) and a hard kill is
    // impossible; instead the app writes this file and the runner checks for it on each heartbeat tick and
    // stops cleanly. Same pattern and same predicates (`lib/scout-cancel.sh`) as ScoutExtractService.
    static var defaultCancelURL: URL { cancelURL(for: .prep) }

    // Ask a running Prep run to stop. Writing the sentinel IS the request; the runner reads only its
    // presence, never its contents. Best-effort: if the run has already finished, the next startPrep
    // clears the file so it can never affect a later run.
    //
    // #2760: per slot, so Cancel on the check's takeover stops the check and not the prep run beside it.
    static func requestCancel(slot: RunSlot, cancelURL: URL? = nil) {
        let cancelURL = cancelURL ?? Self.cancelURL(for: slot)
        try? FileManager.default.createDirectory(at: cancelURL.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        try? Data().write(to: cancelURL)
    }

    // #1684: has a stop been asked for and not yet cleared? The panel reads this to acknowledge the click
    // at once instead of leaving Dan looking at a screen identical to a working run. The sentinel is the
    // same file the runner obeys, so the two can never disagree; `startPrep` clears it before launching,
    // so it can only ever describe the run in flight.
    static func cancelRequested(slot: RunSlot, cancelURL: URL? = nil) -> Bool {
        FileManager.default.fileExists(atPath: (cancelURL ?? Self.cancelURL(for: slot)).path)
    }

    static func isRunning(slot: RunSlot, markerURL: URL? = nil, now: Date) -> Bool {
        DetachedRunner.isRunning(markerURL: markerURL ?? Self.markerURL(for: slot), now: now,
                                 staleAfter: markerStaleAfter)
    }

    // #2760: is ANY run alive, in either slot. The exclusion between a prep and a check is still in force
    // (this phase makes concurrency safe; #2765 is what turns it on), so this is the question the launch
    // guard and the launch-time archive both really ask.
    static func anyRunIsRunning(now: Date, support: URL = StoreLocation.handoffDirectory) -> Bool {
        RunSlot.allCases.contains { isRunning(slot: $0, markerURL: $0.markerURL(in: support), now: now) }
    }

    // #1822: the same marker, read for whether it is beating, stale, or gone. A progress screen needs
    // the difference between the last two; `isRunning` cannot carry it.
    static func heartbeat(slot: RunSlot, markerURL: URL? = nil, now: Date) -> RunHeartbeat {
        DetachedRunner.heartbeat(markerURL: markerURL ?? Self.markerURL(for: slot), now: now,
                                 staleAfter: markerStaleAfter)
    }

    // #1322: whether the in-flight detached run is a reachability probe (its marker is present) rather than
    // a normal Prep. A probe and a prep share the single run lock, so isRunning alone can't tell them
    // apart; the probe-run marker, written on launch and cleared on settle, is what distinguishes them.
    // Requires the run to actually be live (a stale lock past a crash is not a running probe).
    // #1810: and the marker has to belong to THIS run. Presence alone was the whole defect in #1809: a
    // check's leftover marker was still sitting there when a later Prep run finished, so that run ingested
    // as a check, short-circuited before any draft handling, and every draft it wrote was discarded with
    // nothing on screen saying why. The decision is RunKind's, in one place, so every caller of this gets
    // the same answer and the class is closed rather than the two paths #1809 traced (L30).
    static func isProbeRunning(now: Date, support: URL = StoreLocation.handoffDirectory,
                               defaults: UserDefaults = .standard) -> Bool {
        runInFlight(now: now, support: support, defaults: defaults) == .reachabilityCheck
    }

    // #2760: what a finished run IN THE PREP SLOT was.
    //
    // `RunKind.of` survives only here, and that is what makes the upgrade safe: a check launched by the OLD
    // app is in flight in the prep slot with its marker beside it, and settles exactly as it does today.
    // The check slot needs no such inference, because nothing but a check is ever in it. The rule was
    // always fragile (it deduces identity by comparing two stamps, and #1809 is what it cost when it got it
    // wrong); it is kept for the upgrade window and nothing else.
    //
    // It LOGS when the branch is genuinely taken, so the issue that deletes it (#2800) can be closed on
    // evidence rather than on a guess about who has updated (L65). Nothing is said on the ordinary path: a
    // line on every prep run is a line nobody reads.
    static func prepSlotRunKind(runStartedAt: Date?, probeMarkerStartedAt: String?,
                                log: (String) -> Void = { AgentLog.note($0) }) -> RunKind {
        let kind = RunKind.of(runStartedAt: runStartedAt, probeMarkerStartedAt: probeMarkerStartedAt)
        if kind == .reachabilityCheck {
            // copy-inventory:ignore-start  a diagnostic log line, not a sentence Overture says on screen
            log("a reachability check is in the prep slot: it was started by a build older than #2760. Settled as a check. #2800 deletes this branch once this line stops appearing.")
            // copy-inventory:ignore-end
        }
        return kind
    }

    // #2614: WHICH run is in flight, or nil for none, in one call. Every surface that NAMES the run reads
    // this rather than pairing `isRunning` with `isProbeRunning` itself: two booleans read separately is a
    // state space with a corner the app can never be in, and three surfaces were reading only the first of
    // them and so called every check a prep run.
    //
    // #2760: it asks BOTH slots. The check slot answers `.reachabilityCheck` outright, because only checks
    // are in it. The prep slot goes through the legacy rule above.
    //
    // The two marker URLs are injectable together rather than derived from `support` alone, because the
    // launch that asks this has already resolved its OWN marker and must be judged against that exact
    // file. A guard reading a path the lock dance is not using would be asking about a different machine
    // than the one it is protecting.
    static func runInFlight(now: Date, support: URL = StoreLocation.handoffDirectory,
                            prepMarkerURL: URL? = nil, checkMarkerURL: URL? = nil,
                            defaults: UserDefaults = .standard) -> RunKind? {
        if isRunning(slot: .prep, markerURL: prepMarkerURL ?? RunSlot.prep.markerURL(in: support),
                     now: now) {
            let marker = (try? ReachabilityProbeMarker.read(from: probeRunURL(in: support))) ?? nil
            return prepSlotRunKind(runStartedAt: lastRunStartedAt(slot: .prep, defaults: defaults),
                                   probeMarkerStartedAt: marker?.startedAt)
        }
        if isRunning(slot: .check, markerURL: checkMarkerURL ?? RunSlot.check.markerURL(in: support),
                     now: now) {
            return .reachabilityCheck
        }
        return nil
    }

    // #2765: which shows the OTHER slot's live run is already on, so this launch can leave them out.
    //
    // The one genuine domain conflict between the two runs is a draft written against a contact a check is
    // midway through replacing. Dan's call, 2026-08-15: exclude the overlapping SHOWS and say so, never
    // refuse the whole run. And 2026-08-20: whichever run starts SECOND yields, in both directions, so
    // there is no kind-based priority here and this is the same call from either side.
    //
    // THROWS rather than returning empty when the other slot is live and its holdings cannot be read. That
    // is the fail-closed direction and it is the whole reason `RunCoverage` has three cases: an empty
    // answer would let both runs take the same show, and it arrives exactly when something has gone wrong
    // (L42, L105, L98).
    static func heldByOtherRun(slot: RunSlot, now: Date,
                               support: URL = StoreLocation.handoffDirectory,
                               defaults: UserDefaults = .standard) throws -> Set<String> {
        var held: Set<String> = []
        for other in RunSlot.allCases where other != slot {
            switch RunCoverage.read(slot: other, in: support, now: now) {
            case .noLiveRun:
                continue
            case .holds(let keys):
                held.formUnion(keys)
            case .unreadable:
                let noun = runInFlight(slot: other, now: now, support: support,
                                       defaults: defaults)?.runNoun ?? RunKind.prep.runNoun
                throw PrepLaunchError.holdingsUnreadable(runNoun: noun)
            }
        }
        return held
    }

    // #2765: what this run may take, and what it must leave to the run already on it.
    //
    // Pure and separate from both launches on purpose. The exclusion between the two runs is STILL IN
    // FORCE until #3015 lifts it, so neither launch can reach this decision with the other slot live: a
    // launch-level test would be refused by `runInFlightRefusal` before it ever got here. That makes this
    // the only level at which the decision can be exercised today, and #3015 is where the end-to-end path
    // becomes testable. Naming that rather than leaving the code with no reachable test (L3).
    struct RunSelection: Equatable, Sendable {
        var kept: Set<String>
        var dropped: Set<String>
        // Nothing survived AND something was taken away: the run has nothing to do BECAUSE of the other
        // one, which is a different fact from an empty selection Dan simply made, and gets its own
        // sentence (L11).
        var isEmptyBecauseHeld: Bool { kept.isEmpty && !dropped.isEmpty }
    }

    static func selection(from candidates: Set<String>, excluding held: Set<String>) -> RunSelection {
        RunSelection(kept: candidates.subtracting(held), dropped: candidates.intersection(held))
    }

    // #3012: the SAME question, asked of ONE slot.
    //
    // `runInFlight` above returns a single `RunKind?` and so cannot describe two live runs. That is fine
    // for a reader asking "is anything going", and wrong for any control that ACTS on a particular run:
    // the label and the action then come from different lookups and can disagree. They did. The Cancel
    // button's label read `runInFlight`, which asks the prep slot first and, through `RunKind.of`'s
    // `sameRunTolerance`, resolves a check started after a live prep to `.reachabilityCheck`, while
    // `cancelPrep()` targets `takeover.presented`, the run that started FIRST. So the button said "Cancel
    // reachability check" and stopped the PREP, and the check carried on spending.
    //
    // The fix is not a second lookup that happens to agree, it is asking OF the slot being acted on. The
    // prep slot still goes through the legacy rule, so #2614's wording stays right for the upgrade window
    // where a check started by a build older than #2760 sits in the prep slot and must not be called a
    // prep run.
    static func runInFlight(slot: RunSlot, now: Date, support: URL = StoreLocation.handoffDirectory,
                            markerURL: URL? = nil, defaults: UserDefaults = .standard) -> RunKind? {
        guard isRunning(slot: slot, markerURL: markerURL ?? slot.markerURL(in: support), now: now) else {
            return nil
        }
        switch slot {
        case .check:
            return .reachabilityCheck
        case .prep:
            let marker = (try? ReachabilityProbeMarker.read(from: probeRunURL(in: support))) ?? nil
            return prepSlotRunKind(runStartedAt: lastRunStartedAt(slot: .prep, defaults: defaults),
                                   probeMarkerStartedAt: marker?.startedAt)
        }
    }

    // #2760: the exclusion, in ONE place, spoken by both launches.
    //
    // It is STILL IN FORCE after this phase, deliberately. Making the state per slot is what makes running
    // the two at once SAFE; #2765 is what turns it on, because it owns the one genuine domain conflict (a
    // draft written against a contact a check is midway through replacing).
    //
    // The refusal names WHICH run is in the way. `alreadyRunning` names a Prep run, so it is wrong for
    // every case where a check is what holds the slot, including the upgrade window in which a legacy check
    // sits in the prep slot and a new check would otherwise find the check slot empty and start a second.
    static func runInFlightRefusal(now: Date, support: URL = StoreLocation.handoffDirectory,
                                   prepMarkerURL: URL? = nil, checkMarkerURL: URL? = nil,
                                   defaults: UserDefaults = .standard) -> PrepLaunchError? {
        switch runInFlight(now: now, support: support, prepMarkerURL: prepMarkerURL,
                           checkMarkerURL: checkMarkerURL, defaults: defaults) {
        case .none: return nil
        case .prep: return .alreadyRunning
        case .reachabilityCheck: return .checkAlreadyRunning
        }
    }

    // Writes the work-list and launches the detached run. Returns the count queued.
    // URLs are injectable for testing; production uses the default locations.
    @discardableResult
    static func startPrep(from context: ModelContext, now: Date,
                          support: URL = StoreLocation.handoffDirectory,
                          defaults: UserDefaults = .standard,
                          includedKeys: Set<String>? = nil,
                          queueURL: URL? = nil,
                          markerURL: URL? = nil,
                          voiceFeedbackURL: URL = VoiceFeedbackBuilder.defaultURL,
                          recentOpenersURL: URL = RecentOpenersBuilder.defaultURL,
                          cancelURL: URL? = nil,
                          onOrphanSettled: (ReachabilityRunReport) -> Void = { _ in },
                          // #1824: how a show's own listing page is loaded, so the run is handed what the
                          // show IS instead of drafting blind. Injected for tests; the production default
                          // refuses to run under test, so a test that forgets the seam cannot reach the web.
                          render: @escaping ShowListingReader.Render = ShowListingReader.liveRender,
                          onListingProgress: @MainActor (Int, Int) -> Void = { _, _ in },
                          // Async only so the double-launch test can nest a real second start inside the
                          // first's launch, which is the check-then-act window #480 exists to close.
                          // #1938: a started run tells the app it started, so nothing has to poll the
                          // marker to find out. Here rather than at the call sites (the Prep button, a
                          // per-row Re-prep that reaches this service with no view call at all, and the
                          // reachability check) because a call site that forgot would leave its run
                          // unwatched: no takeover, and no ingest when it finished. Fires only once the
                          // launch has actually succeeded.
                          announce: @MainActor () -> Void = { DetachedRunActivity.prep.runStarted() },
                          launch: @MainActor () async throws -> Void = { try launchRunner(slot: .prep) })
        async throws -> Int {
        // An injected marker decides the support directory for everything else, the exclusion included:
        // a guard that read the live folder while the lock dance read a temp one would be asking about a
        // different machine than the one it is protecting.
        let support = markerURL?.deletingLastPathComponent() ?? support
        let queueURL = queueURL ?? RunSlot.prep.queueURL(in: support)
        let markerURL = markerURL ?? RunSlot.prep.markerURL(in: support)
        let cancelURL = cancelURL ?? RunSlot.prep.cancelURL(in: support)
        // #2760: the exclusion, still in force and now stated once for both launches. It names a CHECK when
        // a check is what is in the way, which the old `alreadyRunning` could not: that sentence names a
        // Prep run, and Dan would have gone looking for one that was not there.
        if let refusal = runInFlightRefusal(now: now, support: support, prepMarkerURL: markerURL,
                                            defaults: defaults) { throw refusal }
        // #1809: every Prep run passes through here, whichever surface started it, so this is the one place
        // that can guarantee no leftover check marker survives to relabel this run and discard its drafts.
        // A per-row Re-prep reaches the service directly with no RootView call, so doing this in the view
        // covered only two of the three ways a Prep run can begin.
        settleAnyCheckBefore(prepRunIn: context, now: now, support: support, defaults: defaults,
                             onOrphanSettled: onOrphanSettled)

        let stamp = ISO8601DateFormatter().string(from: now)
        // #5 Phase 1: stamp an A/B arm onto each eligible prospect under the active experiment (sticky,
        // forward-only), and PERSIST it here, BEFORE the queue is built and encoded, so a later phase's
        // drafter instruction can never name an arm the store didn't record. No active experiment is a
        // no-op, so this changes nothing until Dan starts an experiment. Fail-loud: a save failure throws.
        // Assigned over the SAME eligible set buildQueue encodes (shared eligibleProspects), never the
        // probe path (buildProbeQueue), which must never consume an assignment.
        // #2765: the selection is reduced FIRST, and `assignArms` runs over what survives.
        //
        // Two things ride on that order. The exclusion has to reach the built queue at all, and
        // `assignArms` PERSISTS a sticky, forward-only arm onto every prospect it is handed. The old
        // refusal (`runInFlightRefusal`) ran before it, but this one is computed from the selection and so
        // necessarily lands after the queue is known, and a show this run then left out would keep an arm
        // it never earned, permanently (L95).
        //
        // `includedKeys` is resolved to a concrete set here rather than subtracted from, because `nil`
        // legitimately means "every eligible prospect" and there is nothing to subtract from. Resolving it
        // through the same `eligibleProspects` both callers already use keeps one definition of eligible
        // (L107), and with nothing held it reproduces today's set exactly.
        let eligibleKeys = Set(eligibleProspects(from: context, includedKeys: includedKeys).map(\.naturalKey))
        let prepSelection = selection(from: eligibleKeys,
                                      excluding: try heldByOtherRun(slot: .prep, now: now,
                                                                    support: support, defaults: defaults))
        if prepSelection.isEmptyBecauseHeld {
            let noun = runInFlight(slot: .check, now: now, support: support, defaults: defaults)?.runNoun
                ?? RunKind.reachabilityCheck.runNoun
            throw PrepLaunchError.everyShowHeld(runNoun: noun)
        }
        let selectedKeys = prepSelection.kept

        // #5 Phase 1, continued: over the SURVIVING set, so an excluded show is never stamped.
        try ExperimentAssignment.assignArms(
            to: eligibleProspects(from: context, includedKeys: selectedKeys), in: context)
        // #953: only the rows Dan checked in the Prep sheet, minus anything the other run is holding.
        let queue = buildQueue(from: context, generatedAt: stamp, includedKeys: selectedKeys)
        guard !queue.items.isEmpty else { throw PrepLaunchError.nothingToPrep }

        // Take the lock ATOMICALLY (#480, mirrors ReplyClassifyService): clear any stale marker, then
        // exclusive-create so two near-simultaneous starts can't both proceed and clobber the shared
        // results file. If the exclusive create fails, a racer already holds the lock.
        try FileManager.default.createDirectory(at: markerURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? FileManager.default.removeItem(at: markerURL)
        do {
            try Data().write(to: markerURL, options: .withoutOverwriting)
        } catch {
            throw PrepLaunchError.alreadyRunning
        }

        // #1038: clear any leftover cancel sentinel before this run starts, so a stale one from a
        // previously cancelled run can never make the new run's heartbeat stop on its first tick. The
        // runner clears it too, as defence in depth.
        try? FileManager.default.removeItem(at: cancelURL)

        // #3010: publish which shows this run holds, immediately after the lock and before the listing
        // read, for the same reasons as the check's. A prep item is one show, so there is no
        // `alsoAnswersFor` here. Fail-loud (L12), and consumed by #2765.
        do {
            try RunCoverage.write(keys: Set(queue.items.map(\.naturalKey)), slot: .prep, in: support)
        } catch {
            try? FileManager.default.removeItem(at: markerURL)
            throw error
        }
        // #3014: and a prep starting is what supplies the shows to protect.
        LiveRunHoldings.refresh(support: support, now: now)

        do {
            // #1824: read what each show IS from its own listing page, and hand the text over in the queue.
            // Inside the lock and before the file is written, deliberately: the run opens the queue the
            // moment it launches, so a listing read after the launch would arrive too late to be read, and
            // reading it before the lock would let two presses each pay for the same renders.
            //
            // This is the slow part of a launch (a hidden browser per show), which is why it reports
            // progress to the caller rather than leaving Dan on an indefinite spinner.
            let listings = await ShowListingReader.readAll(for: queue.items, render: render,
                                                           onProgress: onListingProgress)
            let data = try PrepQueueBuilder.encode(PrepQueueBuilder.attaching(listings, to: queue))
            try FileManager.default.createDirectory(at: queueURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: queueURL, options: .atomic)

            // Refresh the voice-learning handoff so the run drafts with Dan's latest edits (#241). Best
            // effort: a feedback-write failure must never block the Prep run itself.
            try? VoiceFeedbackService.export(from: context, generatedAt: stamp, url: voiceFeedbackURL)

            // Refresh the cross-run anti-repetition handoff so the run steers away from openers recent
            // runs already used (#730). Same best-effort contract: a write failure never blocks the run.
            try? RecentOpenersService.export(from: context, generatedAt: stamp, url: recentOpenersURL)

            // Back up the voice-guidance file so Dan's notes can be restored if the run drops them (#251).
            VoiceNotesProtector.backup(fileURL: VoiceGuidanceGuard.defaultURL,
                                       backupURL: VoiceNotesProtector.defaultBackupURL)

            try await launch()
            recordRunStarted(slot: .prep, at: now, defaults: defaults)
            announce()     // #1938: the run is real and launched; tell the app rather than making it look
            // #1940: record which re-prep requests this run is carrying, now that it is genuinely under
            // way. A queued re-prep takes a show out of the Review count, so when the run ends without
            // serving it, something has to give the request back (ReprepRelease), and only this stamp can
            // tell a request a run declined from one Dan queued by hand that no run has picked up yet.
            //
            // AFTER the launch, so a launch that threw hands nothing over and leaves the request waiting
            // for the next run. Not inside the do/catch's throwing path either: the catch above releases
            // the runner lock, which would be wrong once a run is actually live.
            markHandedToRun(keys: Set(queue.items.map(\.naturalKey)), in: context)
        } catch {
            try? FileManager.default.removeItem(at: markerURL)   // release the lock if we never launched
            // #3010: and the coverage with it, for the same reason the check's launch does.
            RunCoverage.clear(slot: .prep, in: support)
            throw error
        }
        return queue.items.count
    }

    // #1940: record which shows' re-prep requests went out with the run that has just launched, keyed on
    // the items really encoded into the queue file rather than on the eligible set, so a show Dan left
    // unticked in the Prep sheet is never marked as one this run is carrying.
    //
    // Only a show with a request pending is marked: a first prep carries no request to give back, and
    // marking it would make the release a statement about every show in every run.
    private static func markHandedToRun(keys: Set<String>, in context: ModelContext) {
        let all = (try? context.fetch(FetchDescriptor<Prospect>())) ?? []
        var marked = false
        for p in all where keys.contains(p.naturalKey) && p.isReprepQueued {
            p.reprepHandedToRun = true
            marked = true
        }
        guard marked else { return }
        // Best effort, and the one place in this file that is: the run is already live, so throwing from
        // here would unwind into startPrep's catch and release a lock a real runner is holding. A stamp
        // that fails to save degrades to the pre-#1940 behaviour for that show (its request stands and it
        // stays under Prep until a run serves it), never to a request silently thrown away.
        try? context.save()
    }

    // #2760: per slot. Shared, a check launched after a prep moved the prep's own start stamp, and the
    // prep's finished run was then judged (by `RunKind.of` and by `DetachedRunOutcome.phase`) against a
    // moment belonging to a run it knows nothing about. `.prep` keeps today's key, so an upgrade does not
    // forget when the last prep ran.
    static let lastRunKey = RunSlot.prep.lastRunStartedAtKey

    // Prep could not have run before Overture existed, so any persisted timestamp older than this
    // floor is a sentinel/epoch artifact (e.g. a fresh Debug store) and means "never ran".
    nonisolated static let earliestPlausibleRun = Date(timeIntervalSince1970: 1_577_836_800) // 2020-01-01 UTC

    // #333: collapse an implausibly-old stored date to nil so the header reads "never" (omits the
    // clause) instead of rendering a ~56-year "last prep 20632d ago".
    nonisolated static func sanitizedLastRun(_ stored: Date?) -> Date? {
        guard let stored, stored >= earliestPlausibleRun else { return nil }
        return stored
    }

    static func lastRunStartedAt(slot: RunSlot, defaults: UserDefaults = .standard) -> Date? {
        sanitizedLastRun(defaults.object(forKey: slot.lastRunStartedAtKey) as? Date)
    }

    static func recordRunStarted(slot: RunSlot, at now: Date, defaults: UserDefaults = .standard) {
        defaults.set(now, forKey: slot.lastRunStartedAtKey)
    }

    static var lastRunStartedAt: Date? { lastRunStartedAt(slot: .prep) }

    // Launches the Prep runner script detached. The script (docs/prep-runbook) drives
    // a Claude Code run that reads the queue and writes overture-prep-results.json.
    // Resolved from a known location so the app never blocks on it.
    private static func launchRunner(slot: RunSlot) throws {
        // #2838: see ScoutExtractService.launchRunner. One rule for all three runs.
        let script: URL
        switch DetachedRunner.resolveRunner(.prep) {
        case .configured(let url), .derivedFromInstalledRepo(let url):
            script = url
        case .unavailable(let configuredPath, let derivedPath):
            throw PrepLaunchError.runnerUnavailable(
                RunnerScripts.unavailableMessage(.prep, configuredPath: configuredPath,
                                                 derivedPath: derivedPath))
        }
        // #2763: the slot is stated rather than left to the runner's default. #2760: and it is now the
        // caller's, so a check tells the runner to open the check slot's files.
        try DetachedRunner.launch(scriptPath: script.path,   // detached; never waits
                                  supportDirectory: StoreLocation.handoffDirectory,
                                  extra: RunSlot.environment(base: [:], slot: slot))
    }

    // Where the Prep runner script is: `DetachedRunner.resolveRunner(.prep)`, shared with the other two
    // detached runs (#2838). The wrapper that used to sit here read one hardcoded defaults key and is
    // gone, because a resolver each caller reaches through its own one-line copy is how three keys came
    // to be maintained separately in the first place (L29, dead code is worse than deleted code).
}
