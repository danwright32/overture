import Foundation
import SwiftData

// #4363 (plan v7 Phase 4b(d), discussion #4267 section 7 T7 and T10): the per-show terms of the queue's pass as a
// PATCHABLE VALUE, which the queue engine keeps between passes and brings up to date from the shows that changed, the
// context fields that moved and the deadlines that passed, in place of recomputing every show's row, stages, pill
// contributions, due work and Reached out row on every pass.
//
// WHAT AN ENTRY HOLDS (the plan's shape). Per show, by `persistentModelID`: its organisation key (for
// `organisationRowCounts`, a refcount), its due work and next due moment (every show, dismissed ones included, as the
// Follow-ups count and the badge are), and while the queue's own scope holds it: its `QueueScopeRow`, its stages, its
// dead end, its stalled reply drafts and its Reached out row, computed ONCE and read by the list and both pill counts.
// Beside them, what the entry READ: the context fields it consulted (`ContextReader`) and the instant its answer could
// next change (`TimeProbe`). The pills are running totals over the entries (`AgentInputs.RowTotals`).
//
// WHAT AN ENTRY DOES NOT HOLD, and why T7 lands before T5. The plan's T7 reads `hidden[PID]` from T1 and
// `inherited[PID]` from T5. Measured against the code, neither reaches anything an entry computes: the collapse
// decides only whether a row is DRAWN, which `QueueModel.scope`'s loop decides per pass from the same table the cards
// read, and the inherited answer reaches only `QueueScopeRow.inheritedReachability`, which that loop joins onto the
// entry's row from the same table again. Stages, due work, the Reached out row and the pills read neither (they are
// over every show the scope holds, hidden or not). So an entry is a function of its own show, the context and the
// clock, no hand-off from T1 or T5 can leave one stale, and T7 can merge before T5 (#4364) with nothing waiting on it.
//
// THE NEIGHBOURHOOD. A show's change rebuilds that show's entry; a context field's change rebuilds the entries that
// consulted it (Dan's geography refusals and the client window: every show the scope holds; the reply run's flag:
// only shows with a reply draft asked for); the clock rebuilds the entries whose `validUntil` passed. Day rollover
// rebuilds the shows the scope holds and the shows with a contact, never a dismissed show nobody was pitched.
//
// ITS ORACLES are today's functions over every show (`mismatches(against:inquiries:)`), which the verifier runs
// (`QueueEnginePatches.mismatches`, `patchMismatch`), and so do `PatchableRowEntriesTests` and the engine's whole pass
// harness. Each entry is built by calling today's per-show pieces on ONE show (the bodies `placements`,
// `activeWithDates`, `DueWork.counts`, `DraftedDeadEnd` and `StalledReplyDraft` ask per show), so what the comparison
// proves is the AGGREGATION and the PATCHING: that the whole equals the sum of per-show parts and that an entry left
// standing still answers what a rebuild would. It cannot find a per-show rule that is wrong in both, and does not
// claim to (L70). The one rule restated rather than shared is the pills' combination (`AgentInputs.from(totals:...)`).

/// Everything outside a show's own facts and the clock that an entry reads, through `ContextReader`.
struct RowEntryContext: Equatable, Sendable {
    /// Dan's geography refusals. The engine's copy is resolved over the shows the scope holds (a memo of the verdict,
    /// which `GeoRefusals ==` ignores, so it never reads as a change).
    var geo: GeoRefusals
    var clients: ClientWindow
    var replyRunAlive: Bool

    /// The context the engine's pass reads, from its facts and its signals: the same geography the pass's inputs
    /// build (`FactStore.geoRefusals`) and the same two signals.
    init(facts: FactStore, signals: QueueEngineContextInputs) {
        self.init(geo: facts.geoRefusals, clients: signals.clients, replyRunAlive: signals.replyRunAlive)
    }

    init(geo: GeoRefusals, clients: ClientWindow, replyRunAlive: Bool) {
        self.geo = geo
        self.clients = clients
        self.replyRunAlive = replyRunAlive
    }

    enum Field: CaseIterable, Sendable { case geo, clients, replyRunAlive }

    /// The field an entry read through `path`, which is how a `ContextReader`'s record is kept as a value.
    static func field(_ path: PartialKeyPath<RowEntryContext>) -> Field? {
        if path == \RowEntryContext.geo { return .geo }
        if path == \RowEntryContext.clients { return .clients }
        if path == \RowEntryContext.replyRunAlive { return .replyRunAlive }
        return nil
    }

    func differs(from other: RowEntryContext, in field: Field) -> Bool {
        switch field {
        case .geo: return geo != other.geo
        case .clients: return clients != other.clients
        case .replyRunAlive: return replyRunAlive != other.replyRunAlive
        }
    }
}

/// One show's entry: what it contributes to every per-show term, and what it read to work that out.
struct RowEntry: Sendable {
    let key: String
    /// `ProducerGate.key` of the presenter, which `organisationRowCounts` counts by.
    let presenterKey: String?
    let due: DueWork.Counts
    let dueNext: Date?
    /// Nil for a show the queue's own scope does not hold (`QueueModel.queueScopeHolds`).
    let inScope: InScope?
    let builtAt: Date
    /// The earliest instant an answer here could differ (`TimeProbe.validUntil`), or nil when it read no clock.
    let validUntil: Date?
    let consulted: Set<RowEntryContext.Field>

    struct InScope: Sendable {
        /// The row the pass draws, with no inherited answer: the scope's loop joins that from its own table.
        let row: QueueScopeRow
        let focuses: [StageFocus]
        let deadEnd: Bool
        let stalled: Int
        let reach: Reach?
    }

    /// The show's Reached out row (`ReachedOutQueue.entry`) and whether its pill counts it as due.
    struct Reach: Sendable {
        let show: RowFacts
        let contact: RecipientRecord
        let next: Date
        let isDue: Bool
    }

    /// One show's entry at `now`, every term asked through the body today's whole-store function asks per show.
    static func build(_ p: RowFacts, context: RowEntryContext, now: Date) -> RowEntry {
        let probe = TimeProbe(now: now)
        let reader = ContextReader(context)
        let contacts = p.factContacts
        let theirs: (RowFacts) -> [RecipientRecord] = { $0.factContacts }
        // The reply run's flag. Both rules that consult it (the stall timeout and DueWork's next moment) consult it
        // only beside a reply draft that was asked for, so a show with none neither reads it nor is rebuilt by it,
        // and is handed false, which would show in the oracle comparison if that claim ever stopped holding.
        let asksForADraft = contacts.contains { $0.awaitedReplyDraftRequestedAt != nil }
        let alive = asksForADraft ? reader.read(\.replyRunAlive) : false
        let due = DueWork.counts(from: [p], contacts: theirs, inquiries: [InquiryRecord](), now: now,
                                 replyRunAlive: alive)
        let dueNext = DueWork.nextChange(from: [p], contacts: theirs, now: now, replyRunAlive: alive)
        // The clock outside the stages: every due work rule is a rule about a contact, so a show with none reads no
        // clock here. With one, the day (a run that has played stops the nudges) and the due rules' own next moment.
        if !contacts.isEmpty {
            _ = probe.today
            probe.answerChanges(at: dueNext)
            for r in contacts {
                if let requested = r.awaitedReplyDraftRequestedAt {
                    probe.answerChanges(at: requested.addingTimeInterval(Recipient.replyDraftStallTimeout))
                }
            }
        }
        var inScope: InScope?
        if QueueModel.queueScopeHolds(p) {
            // The stages read the day (an untriaged show's window, a kept show's last night) and, for a stuck send,
            // the instant its claim times out.
            _ = probe.today
            let stage = StageContext(now: now, geo: reader.read(\.geo), clients: reader.read(\.clients))
            let focuses = StageNavigation.focuses(of: p, contacts: { contacts }, context: stage)
            let show = ReachedOutQueue.Show(p, contacts: contacts)
            for r in contacts {
                if r.sendState == .sending, let claimed = r.sendClaimedAt {
                    probe.answerChanges(at: claimed.addingTimeInterval(RunTimeouts.send))
                }
                guard r.sentAt != nil else { continue }
                // A reply with no arrival instant, or one stamped ahead, is dated at `now` itself
                // (`NextReachOut.arrived`), so the row's date moves with every second until it arrives.
                if r.hasUnhandledReply, r.replyArrivedAt.map({ $0 > now }) ?? true { _ = probe.readContinuously() }
                // Whether the row is due flips when the contact's owed moment arrives.
                probe.answerChanges(at: ReachedOutQueue.nextActionableMoment(for: r, of: show, now: now))
            }
            let reach = ReachedOutQueue.entry(for: p, contacts: contacts, now: now).map { found in
                Reach(show: p, contact: found.recipient, next: found.next,
                      isDue: ReachedOutQueue.isDueNow(for: found.recipient, of: show, now: now))
            }
            inScope = InScope(row: QueueScopeRow(p, facts: RecipientFacts.of(p, contacts: contacts)),
                              focuses: focuses,
                              deadEnd: DraftedDeadEnd.hasNobodyToSendTo(p, contacts: contacts),
                              stalled: StalledReplyDraft.dueRecipients(from: [p], contacts: theirs, now: now,
                                                                       runAlive: alive).count,
                              reach: reach)
        }
        return RowEntry(key: p.naturalKey, presenterKey: p.presenter.flatMap { ProducerGate.key($0) }, due: due,
                        dueNext: dueNext, inScope: inScope, builtAt: now, validUntil: probe.validUntil,
                        consulted: Set(reader.consulted.compactMap(RowEntryContext.field)))
    }
}

/// Identities by the instant each comes due, earliest first, so the ones due by an instant are found without walking
/// every entry.
struct DeadlineIndex: Sendable {
    private var byInstant: [Date: Set<PersistentIdentifier>] = [:]
    /// Every instant held, ascending, each once.
    private var instants: [Date] = []

    mutating func insert(_ id: PersistentIdentifier, at instant: Date) {
        if byInstant[instant] == nil {
            instants.insert(instant, at: Self.firstIndex(notBefore: instant, in: instants))
        }
        byInstant[instant, default: []].insert(id)
    }

    mutating func remove(_ id: PersistentIdentifier, at instant: Date) {
        guard var ids = byInstant[instant], ids.remove(id) != nil else { return }
        if ids.isEmpty {
            byInstant[instant] = nil
            let i = Self.firstIndex(notBefore: instant, in: instants)
            if i < instants.count, instants[i] == instant { instants.remove(at: i) }
        } else {
            byInstant[instant] = ids
        }
    }

    /// Takes out, and returns, every identity due at or before `instant`.
    mutating func takeThrough(_ instant: Date) -> Set<PersistentIdentifier> {
        var out: Set<PersistentIdentifier> = []
        while let first = instants.first, first <= instant {
            out.formUnion(byInstant.removeValue(forKey: first) ?? [])
            instants.removeFirst()
        }
        return out
    }

    /// The earliest instant held strictly after `instant`.
    func first(after instant: Date) -> Date? {
        var low = 0, high = instants.count
        while low < high {
            let mid = (low + high) / 2
            if instants[mid] <= instant { low = mid + 1 } else { high = mid }
        }
        return low < instants.count ? instants[low] : nil
    }

    private static func firstIndex(notBefore instant: Date, in sorted: [Date]) -> Int {
        var low = 0, high = sorted.count
        while low < high {
            let mid = (low + high) / 2
            if sorted[mid] < instant { low = mid + 1 } else { high = mid }
        }
        return low
    }
}

/// What the queue's pass reads from T7 in place of deriving it: every entry (the rows and the stages, by identity), the
/// Reached out list in its own order, the pill totals and the organisation row counts.
struct RowEntryTables<Row: QueuePassRow> {
    let entries: [PersistentIdentifier: RowEntry]
    let reachedOut: [(prospect: Row, recipient: Row.Contact, next: Date)]
    let totals: AgentInputs.RowTotals
    let rowCounts: [String: Int]

    /// The pills: the totals plus the pass's inquiries and scalars (`AgentInputs.from(totals:...)`).
    func agentInputs(inquiries: [Row.PassInquiry], now: Date, gmailConnected: Bool, runInFlight: RunKind?,
                     replyRunAlive: Bool) -> AgentInputs {
        AgentInputs.from(totals: totals, contacts: { (row: Row) in row.passContacts }, inquiries: inquiries, now: now,
                         gmailConnected: gmailConnected, runInFlight: runInFlight, replyRunAlive: replyRunAlive)
    }
}

/// T7's patchable value: one entry per show the engine holds, and running totals over them.
struct PatchableRowEntries: Sendable {
    private(set) var entries: [PersistentIdentifier: RowEntry] = [:]
    /// The instant every entry is valid at: the last pass's, or the first build's.
    private(set) var now: Date
    private(set) var context: RowEntryContext
    private(set) var totals = AgentInputs.RowTotals()
    private(set) var rowCounts: [String: Int] = [:]
    /// How many entries the last bring-up rebuilt, for the cost report.
    private(set) var lastRebuilt = 0
    private var expiries = DeadlineIndex()
    private var dueMoments = DeadlineIndex()
    private var readers: [RowEntryContext.Field: Set<PersistentIdentifier>] = [:]
    /// The entries holding a Reached out row, so the list is gathered without walking every entry.
    private var reached: Set<PersistentIdentifier> = []

    /// Every show, built from nothing at `now`.
    init(shows: [PersistentIdentifier: RowFacts], context: RowEntryContext, now: Date) {
        self.now = now
        self.context = context
        self.context.geo = context.geo.resolving(Self.inScope(shows))
        for (id, facts) in shows { rebuild(id, facts) }
        lastRebuilt = shows.count
    }

    /// Brings every entry to `now` and `context`, and rebuilds the shows `changed` names from `shows` (absent from it
    /// means the show is gone). Each entry is rebuilt at most once, from the facts as they now stand.
    @discardableResult
    mutating func bringUp(changed: Set<PersistentIdentifier>, shows: [PersistentIdentifier: RowFacts],
                          now newNow: Date, context newContext: RowEntryContext) -> Int {
        var dirty = changed
        if newNow < now {
            // The clock went backwards (a system clock change): an answer is only known to hold forward of its
            // build, so every entry is rebuilt.
            dirty.formUnion(entries.keys)
        } else {
            dirty.formUnion(expiries.takeThrough(newNow))
        }
        for field in RowEntryContext.Field.allCases where context.differs(from: newContext, in: field) {
            dirty.formUnion(readers[field] ?? [])
        }
        // The geography's place memo is resolved over the shows the scope held when Dan's refusals last changed, and
        // kept while they stand. A show added since, or moved to a place the memo never saw, is NOT judged against a
        // stale verdict: `GeoRefusals.hidesFromQueue` works a missing place out from the refusals themselves, the same
        // way `resolving` would (#1962: a miss costs what the whole thing used to and can never change an answer).
        // `aShowMovedToAPlaceTheMemoNeverSawIsJudgedOnItsNewPlace` holds that, since the lessons review asked.
        if newContext.geo != context.geo {
            context = newContext
            context.geo = newContext.geo.resolving(Self.inScope(shows))
        } else {
            context = RowEntryContext(geo: context.geo, clients: newContext.clients,
                                      replyRunAlive: newContext.replyRunAlive)
        }
        now = newNow
        for id in dirty { rebuild(id, shows[id]) }
        lastRebuilt = dirty.count
        return dirty.count
    }

    /// The earliest moment after `now` at which a due work rule comes due, `DueWork.nextChange`'s answer.
    var nextDueChange: Date? { dueMoments.first(after: now) }

    /// What the pass reads.
    func tables() -> RowEntryTables<RowFacts> {
        let list = reached.compactMap { id -> (prospect: RowFacts, recipient: RecipientRecord, next: Date)? in
            entries[id]?.inScope?.reach.map { (prospect: $0.show, recipient: $0.contact, next: $0.next) }
        }
        return RowEntryTables(entries: entries, reachedOut: ReachedOutQueue.inListOrder(list), totals: totals,
                              rowCounts: rowCounts)
    }

    // MARK: - Contributions

    private mutating func rebuild(_ id: PersistentIdentifier, _ facts: RowFacts?) {
        if let old = entries.removeValue(forKey: id) { contribute(old, id, sign: -1) }
        guard let facts else { return }
        let fresh = RowEntry.build(facts, context: context, now: now)
        entries[id] = fresh
        contribute(fresh, id, sign: 1)
    }

    private mutating func contribute(_ e: RowEntry, _ id: PersistentIdentifier, sign: Int) {
        let adding = sign > 0
        func bump(_ value: inout Int, by n: Int = 1) { value += sign * n }
        bump(&totals.due.followUps, by: e.due.followUps)
        bump(&totals.due.afterTheShow, by: e.due.afterTheShow)
        bump(&totals.due.conversationsToConfirm, by: e.due.conversationsToConfirm)
        bump(&totals.due.stalledReplyDrafts, by: e.due.stalledReplyDrafts)
        bump(&totals.due.repliesToAnswer, by: e.due.repliesToAnswer)
        if let key = e.presenterKey {
            let left = (rowCounts[key] ?? 0) + sign
            rowCounts[key] = left > 0 ? left : nil
        }
        if let at = e.validUntil {
            if adding { expiries.insert(id, at: at) } else { expiries.remove(id, at: at) }
        }
        if let at = e.dueNext {
            if adding { dueMoments.insert(id, at: at) } else { dueMoments.remove(id, at: at) }
        }
        for field in e.consulted {
            if adding { readers[field, default: []].insert(id) } else { readers[field]?.remove(id) }
        }
        guard let s = e.inScope else { return }
        for focus in s.focuses {
            let left = (totals.focusCounts[focus] ?? 0) + sign
            totals.focusCounts[focus] = left > 0 ? left : nil
        }
        if s.deadEnd { bump(&totals.reviewDeadEnds) }
        bump(&totals.stalledReplyDrafts, by: s.stalled)
        if let r = s.reach {
            bump(&totals.reachedOutShows)
            if r.isDue { bump(&totals.reachedOutDue) }
            if adding { reached.insert(id) } else { reached.remove(id) }
        }
    }

    private static func inScope(_ shows: [PersistentIdentifier: RowFacts]) -> [RowFacts] {
        shows.values.filter { QueueModel.queueScopeHolds($0) }
    }

    // MARK: - The oracle comparison (plan v7 D7, one per patched term)

    /// Each of T7's published answers held to today's whole-store function over `shows`, at this value's own instant
    /// and context, by the name of what differs (`rowEntries.<table>`, C7: names only, never a value). The verifier's
    /// comparison, and the per term harness's.
    func mismatches(against shows: [PersistentIdentifier: RowFacts], inquiries: [InquiryRecord]) -> [String] {
        let all = shows.values.sorted {
            $0.naturalKey != $1.naturalKey ? $0.naturalKey < $1.naturalKey : $0.persistentModelID < $1.persistentModelID
        }
        let theirs: (RowFacts) -> [RecipientRecord] = { $0.factContacts }
        let inScope = QueueModel.queueScope(all)
        let stage = StageContext(now: now, geo: context.geo, clients: context.clients).resolvingPlaces(of: inScope)
        var out: [String] = []
        if Set(entries.keys) != Set(shows.keys) { out.append("rowEntries.members") }
        // The rows, as the scope's loop builds each from its show (the inherited answer is joined there, not here).
        var rowsDiffer = false
        var focusesDiffer = false
        let placement = StageNavigation.placements(of: inScope, contacts: theirs, context: stage)
        var oracleFocuses: [String: [StageFocus]] = [:]
        for focus in StageNavigation.countedFocuses {
            for key in StageNavigation.naturalKeys(for: focus, in: placement) { oracleFocuses[key, default: []].append(focus) }
        }
        var heldFocuses: [String: [StageFocus]] = [:]
        for p in inScope {
            guard let held = entries[p.persistentModelID]?.inScope else {
                rowsDiffer = true
                focusesDiffer = true
                continue
            }
            if held.row != QueueScopeRow(p, facts: RecipientFacts.of(p, contacts: p.factContacts)) { rowsDiffer = true }
            if !held.focuses.isEmpty { heldFocuses[p.naturalKey] = held.focuses }
        }
        if heldFocuses != oracleFocuses { focusesDiffer = true }
        let scopeIDs = Set(inScope.map(\.persistentModelID))
        if entries.contains(where: { $0.value.inScope != nil && !scopeIDs.contains($0.key) }) { rowsDiffer = true }
        if rowsDiffer { out.append("rowEntries.rows") }
        if focusesDiffer { out.append("rowEntries.focuses") }
        let oracleReach = ReachedOutQueue.activeWithDates(from: inScope, contacts: theirs, now: now)
        let heldReach = tables().reachedOut
        if oracleReach.map({ "\($0.prospect.persistentModelID)|\($0.recipient.persistentModelID)|\($0.next)" })
            != heldReach.map({ "\($0.prospect.persistentModelID)|\($0.recipient.persistentModelID)|\($0.next)" }) {
            out.append("rowEntries.reachedOut")
        }
        if rowCounts != QueueModel.organisationRowCounts(among: all) { out.append("rowEntries.rowCounts") }
        let oracleInputs = AgentInputs.from(prospects: inScope, allProspects: all, contacts: theirs, inquiries: inquiries,
                                            context: stage, gmailConnected: false, runInFlight: nil,
                                            replyRunAlive: context.replyRunAlive)
        let heldInputs = AgentInputs.from(totals: totals, contacts: theirs, inquiries: inquiries, now: now,
                                          gmailConnected: false, runInFlight: nil,
                                          replyRunAlive: context.replyRunAlive)
        if heldInputs != oracleInputs { out.append("rowEntries.agentInputs") }
        if nextDueChange != DueWork.nextChange(from: all, contacts: theirs, now: now,
                                               replyRunAlive: context.replyRunAlive) {
            out.append("rowEntries.dueNextChange")
        }
        return out
    }
}
