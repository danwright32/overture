import Foundation
import SwiftData

// #4358 slice E4b (plan v7 Phases 4 and 5): the queue's own derivation for the engine, unwired.
//
// WHAT IT IS. `QueueEngine` takes its value pass as an injected `QueueEngineDerivation`, because until slice E4a the
// queue's pass (`QueueRenderPass.make`) could only run over the live models. E4a made it generic over a row family
// and nonisolated, so this hands it the engine's retained facts: the shows in key order, the inquiries, answers and
// sources as their records, Dan's struck addresses, producer corrections and town refusals as the values the pass
// already takes, and the inputs that arrive by a signal as the engine read them for this pass. The same function runs
// in the engine's turn on the main actor and in the verifier's rebuild on its own thread, so the two can disagree only
// about their inputs, never about the code.
//
// WHAT IT ADDS BESIDE `make`, one each for what the engine asks of an answer:
//   * `differingFields`, the RenderData comparator (`RenderDataComparison`), by member name only (C7, L222);
//   * `nextChange`, the earliest moment a rule already in play comes due: `DueWork.nextChange` over the facts, and
//     the soonest Reached out moment the answer holds. A LOWER BOUND, as `DueWork.nextChange` says of itself; the
//     engine's 60 second floor covers what it cannot see;
//   * the card check at publish (#4357 step 9), over the row the MAIN CONTEXT holds, and the verifier's comparison
//     (iv), over models a context of its own reads. Neither builds its side through `RowFacts.extract`, which is
//     where the answer's own cards came from, so neither can agree with the answer for the reason it is wrong (L70).
//
// ROW ORDER IS DECLARED (L343). The facts are dictionaries, so every list the pass is handed is put in an order here:
// shows by natural key in byte order and then identifier (`Prospect.inKeyOrder`'s rule), the rest by their own
// stored key and then identifier. The memo path hands the pass whatever order its query returned; the cutover's
// natural key tie break (plan item 13, slice E4d) is what makes the two agree on ties.
//
// NOTHING IN THE APP BUILDS THIS YET. The cutover (#4358, slice E4d) hands it to the engine RootView builds.

/// One pass of the queue as the engine publishes it.
///
/// `@unchecked Sendable`, and why that is true rather than convenient: `RenderData` holds the pass's card store, a
/// class the main thread writes to as rows are drawn (a card nobody asked the pass for is built on the spot and
/// kept). The engine hands a pass to the verifier's thread inside a snapshot, and every read the verifier makes is of
/// a value: the RenderData members other than the store, the store's `preamble` (a `let`), and `builtCards`, the
/// store's contents as captured when the pass was derived, before any surface could draw from it. Nothing on another
/// thread reads the store's mutable state. E4a's second half turns the store into a value snapshot (#4371), after
/// which this can be checked by the compiler.
struct QueueEnginePass: @unchecked Sendable {
    let data: QueueView.RenderData
    /// What the card store held when the pass was derived, as a value.
    let builtCards: QueueModel.CardStore.Contents
    /// The earliest instant a rule in this pass comes due, or nil when none is in play.
    let nextChange: Date?
    /// The built card the check at publish samples: the riskiest, chosen by the scope's own rule (C4).
    let checkKey: String?
    /// #4358 slice E4d (plan item 3): the shows the next Prep run would take (`PrepQueueBuilder.needsPrepEligible` on the
    /// pass's own day), in key order, as identities. RootView's "Prep kept" gate and its selection sheet read this in
    /// place of the query they held over the prep status (`needsPrepPredicate`), which could not follow the clock.
    let toPrep: [ShowIdentity]
    /// Cards the check at publish proved wrong, each replaced by the fresh build (C1). Drawn in place of the store's.
    fileprivate(set) var corrected: [String: QueueItem] = [:]

    /// The card for a drawn row: through the store, which records that the row was drawn whatever the answer (the
    /// next pass prebuilds from that record), then the fresh card if the check at publish replaced it. `shows` is the
    /// surface's resolver (#4371), which the engine's store, built over facts, never needs to ask; E4d hands in the
    /// engine itself.
    @MainActor
    func card(for row: QueueScopeRow, resolving shows: some ShowResolver) -> QueueItem {
        let built = data.cards.card(for: row, resolving: shows)
        return corrected[row.id] ?? built
    }
}

enum QueueEngineQueue {

    /// The queue's derivation, as the cutover hands it to the engine. `watch` is the app's freeze watch, which every
    /// pass the engine's turn runs is counted and timed on (#3760, #3815), from here rather than inside `make`, which
    /// is pure (#4357 step 8); the verifier's rebuilds are not. No default: a derivation nobody handed the watch
    /// would run every pass uncounted, and a freeze spanning them would report zero passes, which reads as quiet
    /// (L168). A test that is not about freezes hands in nil by name.
    static func derivation(freezeWatch watch: @escaping @MainActor () -> FreezeWatch?)
        -> QueueEngineDerivation<QueueEnginePass> {
        var derivation = QueueEngineDerivation<QueueEnginePass>(
            derive: { derive($0) },
            differingFields: { differingFields($0, $1) },
            nextChange: { $0.nextChange })
        derivation.onTheMainActor = { input in
            let freezeWatch = watch()
            freezeWatch?.recordPass()
            // The uptime clock, which cannot go backwards under a duration (`QueueView.makeRenderData`'s rule).
            let started = DispatchTime.now().uptimeNanoseconds
            defer {
                freezeWatch?.recordPassCost(
                    seconds: Double(DispatchTime.now().uptimeNanoseconds - started) / 1_000_000_000)
            }
            let pass = derive(input)
            // #4358 slice E4d (#4357 step 8): the queue's Debug derivation record, once per pass the engine's turn
            // runs, which is where the queue derives now; the verifier's rebuilds are not passes and record nothing.
            #if DEBUG
            QueueRenderCounter.recordDerivation(inputs: [
                "shows": "\(input.facts.shows.count)", "inquiries": "\(input.facts.inquiries.count)",
                "stage": String(describing: input.viewInputs.focusedStage),
                "focusedKeys": "\(input.viewInputs.focusedKeys?.count ?? -1)",
                "gmail": "\(input.context.gmailConnected)", "runInFlight": String(describing: input.context.runInFlight),
            ], rows: pass.data.rows)
            #endif
            return pass
        }
        derivation.checkAtPublish = { try checkAtPublish($0, $1) }
        derivation.compareCards = { try compareCards($0, $1) }
        return derivation
    }

    // MARK: - The pass

    /// The shows in the declared order: natural key in byte order, then identifier.
    ///
    /// #4623: decided over the two keys, never by sorting the rows themselves. A `RowFacts` carries every stored
    /// field of a show, so each move a sort makes copies all of them; sorting the rows cost 46.9 ms of a 269.4 ms
    /// pass at 1x and 229.8 ms at 4x in an optimised build (2026-10-08, `PassCostByTermProbeTests`), the one thing
    /// the engine's pass paid that the pass over models did not. Here each row is copied into its place once.
    static func shows(_ facts: FactStore) -> [RowFacts] {
        let rows = Array(facts.shows.values)
        let keys = rows.map { (bytes: Array($0.naturalKey.utf8), id: $0.persistentModelID) }
        let order = keys.indices.sorted { i, j in
            let byBytes = byteOrder(keys[i].bytes, keys[j].bytes)
            return byBytes == 0 ? keys[i].id < keys[j].id : byBytes < 0
        }
        return order.map { rows[$0] }
    }

    /// Two encodings compared byte by byte as unsigned values, shorter first on a shared prefix: negative, zero or
    /// positive, the order `utf8.lexicographicallyPrecedes` gives, in one native comparison.
    static func byteOrder(_ a: [UInt8], _ b: [UInt8]) -> Int {
        let shared = min(a.count, b.count)
        let prefix = shared == 0 ? 0 : a.withUnsafeBufferPointer { x in
            b.withUnsafeBufferPointer { y in Int(memcmp(x.baseAddress!, y.baseAddress!, shared)) }
        }
        return prefix != 0 ? prefix : a.count - b.count
    }

    /// What `QueueRenderPass.make` is handed for one engine pass.
    static func passInputs(_ input: QueueEnginePassInput, shows: [RowFacts]) -> QueueRenderPass.PassInputs<RowFacts> {
        let facts = input.facts
        let context = input.context
        let inquiries = facts.inquiries.values.sorted {
            $0.createdAt != $1.createdAt ? $0.createdAt < $1.createdAt : $0.persistentModelID < $1.persistentModelID
        }
        let answers = facts.orgAnswers.values.sorted {
            $0.orgKey != $1.orgKey ? $0.orgKey < $1.orgKey : $0.persistentModelID < $1.persistentModelID
        }
        let sources = facts.watchedSources.values.sorted {
            $0.sourceId != $1.sourceId ? $0.sourceId < $1.sourceId : $0.persistentModelID < $1.persistentModelID
        }
        let geo = GeoRefusals(userExcludedTowns: Set(facts.excludedTowns.values.map(\.town)),
                              allowedSeedTowns: Set(facts.allowedSeedTowns.values.map(\.town)))
        var inputs = QueueRenderPass.PassInputs<RowFacts>(
            allProspects: QueueRenderPass.RowCorpus(shows), inquiries: inquiries, orgAnswers: answers,
            sources: sources, refusals: facts.refusalLedger,
            overrides: facts.producerOverrides,
            context: StageContext(now: input.now, geo: geo, clients: context.clients),
            focusedStage: input.viewInputs.focusedStage, focusedKeys: input.viewInputs.focusedKeys)
        inputs.gmailConnected = context.gmailConnected
        inputs.runInFlight = context.runInFlight
        inputs.prepSlotRunning = context.prepSlotRunning
        inputs.checkSlotRunning = context.checkSlotRunning
        inputs.checkRunSince = context.checkRunSince
        inputs.checkLookups = context.checkLookups
        inputs.replyRunAlive = context.replyRunAlive
        // Only the cards the surface drew last, never every row: the engine's view is the surface's request.
        inputs.requestedCardKeys = input.viewInputs.requestedCardKeys
        // The engine checks a card at publish, over the main context's model, rather than inside the pass.
        inputs.checksACardInThePass = false
        // #4360 (plan v7 Phase 4b(a)): T1 from the engine's patched value when it handed one in; the verifier's rebuild
        // hands none, so its pass derives T1 over the facts, which is the oracle the patch is held to.
        inputs.showLink = input.patches?.showLink?.tables
        // #4362 (plan v7 Phase 4b(c)): T4 the same way. Before the switch `QueueView` kept these in a memo; the engine
        // built them cold on every pass until this (#4623 measured 25.1 ms at 1x and 201.7 ms at 4x, optimised).
        inputs.producerTables = input.patches?.producerTables?.tables
        // #4361: T2 and T3 as the engine keeps them patched, T3 taken only when it was judged at this pass's own Eastern
        // day: a value judged at another day would describe that day's breaks, so the pass derives both itself instead
        // (the engine brings T3 to the pass's day before every pass it runs, so this is a net, not a path).
        if let t2 = input.patches?.contradictions, let t3 = input.patches?.feedBreaks,
           t3.asOf == EasternDate.today(input.now) {
            inputs.contradictedCancellations = t2.contradictedKeys
            inputs.feedBreakEvents = t3.output
        }
        // #4364 (plan v7 Phase 4b(e)): T5 the same way, brought up to this pass's instant (`QueueEnginePatches.bringUp`).
        inputs.inherited = input.patches?.ledger?.inherited
        return inputs
    }

    /// One pass over the engine's facts.
    static func derive(_ input: QueueEnginePassInput) -> QueueEnginePass {
        let shows = shows(input.facts)
        let data = QueueRenderPass.make(passInputs(input, shows: shows))
        let built = data.cards.contents
        let now = input.now
        var soonest = DueWork.nextChange(from: shows, contacts: { $0.factContacts }, now: now,
                                         replyRunAlive: input.context.replyRunAlive)
        // A Reached out row's moment to reach out again changes how it draws when it arrives.
        if let reached = data.reachedOut.map(\.next).filter({ $0 > now }).min() {
            soonest = min(soonest ?? reached, reached)
        }
        let builtShows = shows.filter { built.cards[$0.naturalKey] != nil }
        let checkKey = QueueModel.riskiestKey(
            among: built.cards.keys,
            contactsByKey: Dictionary(builtShows.map { ($0.naturalKey, $0.factContacts) }, uniquingKeysWith: { a, _ in a }),
            draftBodies: Dictionary(builtShows.map { ($0.naturalKey, $0.draftBody) }, uniquingKeysWith: { a, _ in a }))
        let today = EasternDate.today(now)
        let toPrep = shows.filter { PrepQueueBuilder.needsPrepEligible(PrepEligibilityView(row: $0), today: today) }
            .map(ShowIdentity.init)
        return QueueEnginePass(data: data, builtCards: built, nextChange: soonest, checkKey: checkKey, toPrep: toPrep)
    }

    /// The members of two passes that differ, by name, judged on each pass's cards as captured when it was derived.
    static func differingFields(_ a: QueueEnginePass, _ b: QueueEnginePass) -> [String] {
        RenderDataComparison.differingFields(a.data, b.data, cards: (a.builtCards, b.builtCards))
            + (a.toPrep == b.toPrep ? [] : ["toPrep"])
    }

    // MARK: - The card check at publish (#4357 step 9)

    // Moved out of the pass for the engine (`checksACardInThePass`), because over retained facts the pass's own check
    // rebuilt its card from the very facts the card came from. Here the sample is the scope's (the riskiest built
    // card, C4) and the other side is the show the MAIN CONTEXT holds, resolved by the card's identifier through the
    // context rather than through the engine's members (L345), and built through the shipping card body with its
    // contacts read again. So it finds a fact the intake never took in, which is the defect a retained value hides
    // for ever (L40). On a divergence the fresh card is the one drawn (C1), and the finding is recorded.
    @MainActor
    static func checkAtPublish(_ pass: QueueEnginePass,
                               _ context: ModelContext) throws -> QueueEngineCardCheck<QueueEnginePass>? {
        guard let key = pass.checkKey, let mine = pass.builtCards.cards[key], let id = mine.showID else { return nil }
        // A row the store no longer holds, or holds under another key, is the intake's next change rather than a
        // wrong card: the turn that takes it in derives a pass without this card.
        guard let show = try FactStore.Table.shows.liveRow(id, in: context) as? Prospect,
              show.naturalKey == key else { return nil }
        let fresh = QueueRenderPass.WorkTally.$asOracle.withValue(true) {
            QueueModel.card(show, contacts: nil, preamble: pass.data.cards.preamble)
        }
        let fields = QueueModel.differingFieldNames(mine, fresh)
        guard !fields.isEmpty else { return nil }
        var corrected = pass
        corrected.corrected[key] = fresh
        return QueueEngineCardCheck(fields: fields, cardsBuilt: pass.builtCards.cards.count, corrected: corrected)
    }

    // MARK: - Comparison (iv)

    /// Every card the pass built, built again from the show a context of this comparison's own reads from the saved
    /// store, and compared field by field. Run on the verifier's thread once the facts and the output have agreed, so
    /// a difference here is the card term answering differently over facts than over the model. Returns the field
    /// names that differ, empty when every card agrees.
    static func compareCards(_ pass: QueueEnginePass, _ container: ModelContainer) throws -> [String] {
        let built = pass.builtCards.cards
        guard !built.isEmpty else { return [] }
        let reader = ModelContext(container)
        let stored = try FactStore.Table.fetched(Prospect.self, built.values.compactMap(\.showID), in: reader)
        let byID = Dictionary(stored.map { ($0.persistentModelID, $0) }, uniquingKeysWith: { a, _ in a })
        var fields: Set<String> = []
        for (key, mine) in built {
            // A card with no stored show, or one whose show holds another key now, differs in which show it is.
            guard let id = mine.showID, let show = byID[id], show.naturalKey == key else {
                fields.insert("showID")
                continue
            }
            let fresh = QueueRenderPass.WorkTally.$asOracle.withValue(true) {
                QueueModel.card(show, contacts: nil, preamble: pass.data.cards.preamble)
            }
            fields.formUnion(QueueModel.differingFieldNames(mine, fresh))
        }
        return fields.sorted()
    }
}

// MARK: - What "Reload this show" says (plan item 12)

extension QueueEngineReload {
    // COLD READ, 2026-10-08, each read in the order Dan meets it: a card says Overture's copy of the show is out of
    // step, he presses Reload this show, and one of these appears in the card's own feedback line. Each is a whole
    // sentence naming the show, because the line can outlive the card scrolling away. "Saved show", never "the
    // store", which is not his word (L399), and each says what changed, if anything, before what to do.
    //
    // `unsavedEdit` names the edit as the thing in the way, because it is: a reload throws the unsaved values away
    // and the engine will not do that to Dan's own work (decision 9(a)). What unsticks it is finishing the change,
    // which saves it, and that is the action named (L111). `stillOutOfStep` asks nothing: recovery keeps trying on its
    // own schedule, and pressing again at once would only repeat a fetch that has just not converged.
    func sentence(org: String) -> String {
        switch self {
        case .reloaded:
            return "\(org) was reloaded from the saved show, so it is safe to change again"
        case .alreadyInStep:
            return "\(org) already matches the saved show, so there was nothing to reload"
        case .unsavedEdit:
            return "\(org) has a change that is not saved yet, and reloading now would lose it. Nothing was "
                + "reloaded. Finish that change, then reload it"
        case .stillOutOfStep:
            return "Overture reloaded \(org), and its copy still does not match the saved show. Nothing was "
                + "changed, and Overture will keep trying on its own"
        case .gone:
            return ActionAck.couldNotFindShow(org: org)
        // COLD READ, 2026-10-08 (#4358 slice E4d): Dan pressed Reload this show on a card whose show had already left
        // the queue before the press, so nothing was compared with the saved show at all. It says so rather than
        // "already matches", which would be a match nobody measured (L11), and names the card as what is stale.
        case .notHeld:
            return "\(org) left the queue before this card could be reloaded, so nothing was checked or reloaded. "
                + "The card you pressed is out of date"
        case .unreadable:
            return "Overture could not read the saved copy of \(org), so nothing was reloaded. Try again in a moment"
        }
    }
}
