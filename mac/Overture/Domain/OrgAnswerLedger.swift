import Foundation

// #1598 (milestone 32 Phase 5): which shows may show an answer Dan paid for on a DIFFERENT show, and
// which must be paid for again.
//
// Pure and out of the views (#863/#885), because every rule in here is a spending decision or a claim
// on a card, and neither may be stated in a SwiftUI body where nothing can reach it. The SwiftData rows
// are mapped to plain values at the boundary so the rules are testable without a store.
//
// The asymmetry that shapes all of it: a wrongly reused positive costs one wasted Prep read, while a
// wrongly reused negative makes Dan dismiss a bookable show and he never learns it was wrong. So every
// rule fails toward paying again.
enum OrgAnswerLedger {

    // A stored answer, flattened off the model.
    struct Answer: Equatable, Sendable {
        let orgKey: String
        let result: Reachability.ProbeResult
        let probedAt: Date
        let presenterName: String
        let emails: [String]
    }

    // A prospect, as the fan-out needs it. `hasOwnAnswer` is what keeps a show's own paid verdict
    // untouchable.
    struct Show: Equatable, Sendable {
        let key: String
        let presenter: String?
        let venue: String?
        let hasOwnAnswer: Bool
    }

    // What a row shows when the answer came from elsewhere. It carries the ORIGINAL check's date, so
    // staleness is judged from when the work was actually done, and the organisation's name so the help
    // text can say where the answer came from.
    struct Inherited: Equatable, Sendable {
        let result: Reachability.ProbeResult
        let probedAt: Date
        let organisation: String
        let emails: [String]
    }

    // Built ONCE per render and folded into the row values (the EngagementLink.group precedent), never
    // per row: a per-row version would re-judge the gate against the whole store for every card drawn.
    //
    // `shows` MUST be every prospect in the store, dismissed ones included. Judged against only the
    // rows the queue is displaying, a house whose other bookings were dismissed starts looking like a
    // one-venue producer, and a producer can lose the second venue that qualifies it. Either way an
    // answer changes meaning because of an unrelated triage decision, with nothing on screen to say so,
    // and the bug would be invisible for weeks.
    // #3014 (phase 6 of #2765): `heldKeys` is the shows a live run is already on, and this refuses to move
    // an answer onto any of them.
    //
    // Dan's call, 2026-08-18: block the SPREADING, do not widen the run exclusion to the organisation. The
    // conflict the org level was reaching for is real and show-level exclusion cannot see it: a check on
    // org X's show A changes what is displayed on org X's show C while a prep drafts C, and neither run's
    // key set contains C. Widening would take shows out of a paid run to guard against a fan-out measured
    // at ZERO on the live store (0 of 724 shows on 2026-07-29). This closes the same hole precisely, costs
    // no show its place in a run, and still works if the fan-out ever becomes live.
    //
    // NO DEFAULT, deliberately, unlike `overrides` below. A default standing for "nothing is held" would
    // hand every existing caller the fail-open answer with the compiler never naming the one that forgot
    // (L168). It is evaluated on every build rather than latched, so a run ending releases it with no
    // separate step.
    // #3743: `corpus` is the producer index, when the caller has already built one.
    //
    // Defaulted to nil, meaning build it here, which is a correctness-preserving default rather than one
    // standing for absent data (L168): the answer is identical and only the cost differs. `QueueModel.scope`
    // passes the one it builds for the venue-brand table, which is the same index over the same shows;
    // measured on the live store it is 27.2 ms and was being built twice per pass. What stops that call
    // site quietly losing it is a COUNT rather than the signature: `ScopeBuildsOneProducerIndexTests`.
    static func inherited(from answers: [Answer], shows: [Show], now: Date,
                          heldKeys: Set<String>,
                          overrides: ProducerOverrides = .none,
                          corpus prebuilt: ProducerGate.Corpus? = nil) -> [String: Inherited] {
        // Only positives, only fresh, and only with an address behind them. A positive with nothing to
        // show cannot claim there is somebody to email.
        var usable: [String: Answer] = [:]
        for answer in answers where carriesAnAddress(answer) {
            guard !Reachability.probeIsStale(probedAt: answer.probedAt, now: now) else { continue }
            // Newest wins if a store somehow holds two rows for one organisation; the unique constraint
            // makes that impossible, and a tie broken silently the wrong way would be worse than either.
            // #4351 (plan v7 Step T): so an EQUAL `probedAt` is broken by the organisation's name as it was
            // asked, then by the addresses, rather than by whichever answer the fetch returned first.
            if let existing = usable[answer.orgKey], !supersedes(answer, existing) { continue }
            usable[answer.orgKey] = answer
        }
        guard !usable.isEmpty else { return [:] }

        // #1965: the corpus facts both arms of `qualifies` need, worked out ONCE here. Each organisation
        // asked used to walk every show again, twice, inside a pass that already walks every show.
        let corpus = prebuilt
            ?? ProducerGate.Corpus(shows.map { ProducerGate.Show(presenter: $0.presenter, venue: $0.venue) })
        // #4351 (plan v7 decision 7(a)): the producer verdict is remembered per PRODUCER KEY, the key the
        // verdict is actually about. It used to be remembered per orgKey, and two spellings can fold to one
        // orgKey and to two producer keys (`&amp;` is decoded by the org fold and not by the producer fold),
        // so every show under that orgKey took the verdict of whichever spelling the loop met first.
        var verdictByProducerKey: [String: Bool] = [:]
        var producerKeyByPresenter: [String: String?] = [:]
        // #1965: and the org key per distinct presenter NAME rather than per show. Folding it is a string
        // walk, and the live store's 700-odd rows carry far fewer distinct presenters between them.
        var orgKeyByPresenter: [String: String?] = [:]
        var out: [String: Inherited] = [:]

        // #3014: a show a live run is already on takes no inherited answer. Placed with the loop's own
        // `hasOwnAnswer` skip because it is the same kind of fact: a reason this show is not the fan-out's
        // to speak for.
        for show in shows where !show.hasOwnAnswer && !heldKeys.contains(show.key) {
            guard let presenter = show.presenter else { continue }
            let cachedKey = orgKeyByPresenter[presenter] ?? {
                let key = OrgKey.stored(for: presenter)
                orgKeyByPresenter[presenter] = key
                return key
            }()
            guard let orgKey = cachedKey,
                  let answer = usable[orgKey] else { continue }
            let producerKey = producerKeyByPresenter[presenter] ?? {
                let key = ProducerGate.key(presenter)
                producerKeyByPresenter[presenter] = key
                return key
            }()
            // A name with no producer key never qualifies, which is `ProducerGate.qualifies`'s own answer.
            guard let producerKey else { continue }
            let qualifies = verdictByProducerKey[producerKey]
                ?? ProducerGate.qualifies(presenterKey: producerKey, in: corpus, overrides: overrides)
            verdictByProducerKey[producerKey] = qualifies
            guard qualifies else { continue }
            out[show.key] = Inherited(answer)
        }
        return out
    }

    // #4364 (plan v7 Phase 4b(e)): whether an answer can be inherited at all, one definition read here and by the
    // queue engine's patched ledger (`PatchableAnswerLedger`), so the two cannot disagree about it (L370).
    static func carriesAnAddress(_ answer: Answer) -> Bool {
        answer.result == .emailFound && !answer.emails.isEmpty
    }

    // #4351: whether `candidate` replaces `existing` as one organisation's usable answer. The newer probe
    // wins; at one instant the smaller name, then the smaller address list, so the answer is a function of
    // the answers themselves and never of the order they arrived in.
    static func supersedes(_ candidate: Answer, _ existing: Answer) -> Bool {
        if candidate.probedAt != existing.probedAt { return candidate.probedAt > existing.probedAt }
        if candidate.presenterName != existing.presenterName { return candidate.presenterName < existing.presenterName }
        return candidate.emails.joined(separator: "\n") < existing.emails.joined(separator: "\n")
    }
}

extension OrgAnswerLedger.Inherited {
    // #4364: what a row shows for the answer it inherits, built here once for the ledger above and the queue engine's
    // patched ledger (`PatchableAnswerLedger`). It carries the ORIGINAL check's date (see `Inherited`).
    init(_ answer: OrgAnswerLedger.Answer) {
        self.init(result: answer.result, probedAt: answer.probedAt, organisation: answer.presenterName,
                  emails: answer.emails)
    }
}
