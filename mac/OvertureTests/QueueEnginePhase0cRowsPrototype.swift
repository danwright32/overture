import Foundation
import SwiftData

// #4106 plan v7, Phase 0c probe 0c.5: a TEST-ONLY prototype of term T7, the per-row entries.
//
// WHAT IT IS. Plan section 7's T7 shape, built to find out whether it can agree with today's code and what
// one row costs: a per-PID entry holding the row's `QueueScopeRow`, its stages, its contribution to every
// pill count, its DueWork contribution and its Reached out entry (computed ONCE and read by the list and
// both AgentInputs counts), plus running totals over those contributions, a refcount of organisation rows
// by presenter key, and the inquiries and context scalars recomputed whole. It is not the product type
// (Phase 3 builds that) and nothing in the app calls it.
//
// WHAT ITS ORACLES ARE. Today's functions, over the whole input, in the canonical order of Step T0: the rows
// `QueueModel.scope` builds, `StageNavigation.placements`, `AgentInputs.from`, `organisationRowCounts`,
// `DueWork.counts` and `nextChange`, and `ReachedOutQueue.activeWithDates`, whose representative is judged
// by tie class (`CanonicalOracle.reachedOutTieClass`) because it follows relationship order, which no
// input sort can reach.
//
// WHERE IT SHARES A MECHANISM WITH ITS ORACLE, said rather than hidden (L70). Each entry is built by
// calling today's per-row pieces on ONE row (`placements(in: [p])`, `DueWork.counts(prospects: [p])`,
// `activeWithDates(from: [p])`), so what the comparison proves is the AGGREGATION and the PATCHING: that
// the whole equals the sum of per-row parts, and that after an operation, rebuilding only the rows the
// operation and its upstream hand-offs name leaves every total equal to a full rebuild. It cannot find a
// per-row predicate that is wrong in both, and does not claim to.
//
// UPSTREAM. `hidden` (T1's collapse) and `inherited` (T5's ledger) arrive as whole tables computed by the
// caller through the canonical oracles; the prototype diffs them against the tables it last saw and
// rebuilds the rows whose value moved. That diff stands in for the upstream nodes' ChangedKeys (plan
// section 5), which is the hand-off this probe exists to exercise.
//
// TIME. Each entry records `validUntil`, the earliest instant its output could differ, derived here from
// the row's own dated rules (see `validUntil(...)`). A row whose output moves with the clock continuously
// records its own build instant. This is a stand-in for plan T10's TimeProbe, which does not exist yet, and
// the clock arm of the probe reports whether it was sufficient rather than assuming it.

struct Phase0cReach {
    let representative: Recipient
    let next: Date
    let isDue: Bool
}

/// One row's facts and contributions, as plan T7 shapes them.
struct Phase0cRowEntry {
    let key: String
    let inQueue: Bool
    let row: QueueScopeRow?
    let focuses: [StageFocus]
    let deadEnd: Bool
    let stalled: Int
    let due: DueWork.Counts
    let dueNext: Date?
    let reach: Phase0cReach?
    let presenterKey: String?
    let readsReplyRunAlive: Bool
    let geoHides: Bool
    /// The relationship order `p.recipients` returned when this entry was built, kept to measure whether
    /// that order moves under an unchanged row (it is not reachable by any input sort, L143).
    let contactOrder: [String]
    let builtAt: Date
    let validUntil: Date

    /// Whether a reader of either entry would see the same thing.
    func sameOutput(as o: Phase0cRowEntry) -> Bool {
        let sameReach: Bool
        switch (reach, o.reach) {
        case (nil, nil): sameReach = true
        case let (a?, b?): sameReach = a.representative === b.representative && a.next == b.next && a.isDue == b.isDue
        default: sameReach = false
        }
        return key == o.key && inQueue == o.inQueue && row == o.row && focuses == o.focuses && deadEnd == o.deadEnd
            && stalled == o.stalled && due == o.due && dueNext == o.dueNext && sameReach
            && presenterKey == o.presenterKey
    }
}

/// Everything outside the rows that an entry reads.
struct Phase0cRowContext {
    var stage: StageContext
    var replyRunAlive: Bool
    var inquiries: [Inquiry]
    var gmailConnected = false
    var runInFlight: RunKind? = nil
}

/// The two upstream outputs T7 reads, keyed by natural key as today's tables are.
struct Phase0cUpstream: Equatable {
    var hidden: Set<String>
    var inherited: [String: OrgAnswerLedger.Inherited]
}

@MainActor
enum Phase0cRowBuild {
    static let eastern: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "America/New_York")!
        return c
    }()

    static func nextEasternMidnight(after now: Date) -> Date {
        eastern.nextDate(after: now, matching: DateComponents(hour: 0, minute: 0, second: 0),
                         matchingPolicy: .nextTime) ?? now.addingTimeInterval(86_400)
    }

    /// The earliest instant this row's output could differ from what it is at `now`. A stand-in for
    /// TimeProbe: every dated rule the entry's pieces consult, plus the Eastern day, which the stage
    /// predicates and the post-event prompt read.
    static func validUntil(_ p: Prospect, now: Date, dueNext: Date?) -> Date {
        var soonest = nextEasternMidnight(after: now)
        func consider(_ moment: Date?) {
            guard let moment, moment > now, moment < soonest else { return }
            soonest = moment
        }
        consider(dueNext)
        for r in p.recipients {
            // A reply with no arrival instant, or one stamped in the future, is dated at `now` itself
            // (`NextReachOut.arrived`), so the row's sort key moves with the clock.
            if r.hasUnhandledReply, r.replyArrivedAt.map({ $0 > now }) ?? true { return now }
            consider(ReachedOutQueue.nextReachOut(for: r, of: p, now: now))
            consider(ReachedOutQueue.nextActionableMoment(for: r, of: p, now: now))
            if r.sendState == .sending, let claimed = r.sendClaimedAt {
                consider(claimed.addingTimeInterval(RunTimeouts.send))
            }
            if let requested = r.awaitedReplyDraftRequestedAt {
                consider(requested.addingTimeInterval(Recipient.replyDraftStallTimeout))
            }
        }
        return soonest
    }

    static func entry(_ p: Prospect, context: Phase0cRowContext, upstream: Phase0cUpstream) -> Phase0cRowEntry {
        let key = p.naturalKey
        let now = context.stage.now
        let alive = context.replyRunAlive
        let due = DueWork.counts(prospects: [p], inquiries: [], now: now, replyRunAlive: alive)
        let dueNext = DueWork.nextChange(prospects: [p], now: now, replyRunAlive: alive)
        let presenterKey = p.presenter.flatMap { ProducerGate.key($0) }
        let readsAlive = p.recipients.contains { $0.awaitedReplyDraftRequestedAt != nil }
        let validUntil = validUntil(p, now: now, dueNext: dueNext)
        guard p.statusRaw != "dismissed" else {
            return Phase0cRowEntry(key: key, inQueue: false, row: nil, focuses: [], deadEnd: false, stalled: 0,
                                   due: due, dueNext: dueNext, reach: nil, presenterKey: presenterKey,
                                   readsReplyRunAlive: readsAlive, geoHides: false,
                                   contactOrder: p.recipients.map(\.id), builtAt: now,
                                   validUntil: validUntil)
        }
        var row: QueueScopeRow?
        if !upstream.hidden.contains(key) {
            let contacts = p.countedRecipients
            row = QueueScopeRow(p, facts: RecipientFacts.of(p, contacts: contacts),
                                inheritedReachability: upstream.inherited[key])
            row?.facts = canonicalFacts(p)
        }
        let placement = StageNavigation.placements(in: [p], context: context.stage)
        let focuses = StageNavigation.countedFocuses.filter {
            !StageNavigation.naturalKeys(for: $0, in: placement).isEmpty
        }
        let reach = ReachedOutQueue.activeWithDates(from: [p], now: now).first.map {
            Phase0cReach(representative: $0.recipient, next: $0.next,
                         isDue: ReachedOutQueue.isDueNow(for: $0.recipient, of: p, now: now))
        }
        return Phase0cRowEntry(
            key: key, inQueue: true, row: row, focuses: focuses,
            deadEnd: DraftedDeadEnd.hasNobodyToSendTo(p),
            stalled: StalledReplyDraft.dueRecipients(from: [p], now: now, runAlive: alive).count,
            due: due, dueNext: dueNext, reach: reach, presenterKey: presenterKey, readsReplyRunAlive: readsAlive,
            geoHides: context.stage.geo.hidesFromQueue(p), contactOrder: p.recipients.map(\.id), builtAt: now,
            validUntil: validUntil)
    }

    /// A row's contact facts over its contacts in id order. `RecipientFacts` keeps the order the relationship
    /// hands back, which the store does not hold still (see `contactOrder`), so both sides of every
    /// comparison use this rather than whatever order a fault happened to return.
    static func canonicalFacts(_ p: Prospect) -> RecipientFacts {
        RecipientFacts.of(p, contacts: p.recipients.sorted { $0.id < $1.id })
    }

    static func add(_ a: DueWork.Counts, _ b: DueWork.Counts, sign: Int) -> DueWork.Counts {
        DueWork.Counts(followUps: a.followUps + sign * b.followUps,
                       afterTheShow: a.afterTheShow + sign * b.afterTheShow,
                       conversationsToConfirm: a.conversationsToConfirm + sign * b.conversationsToConfirm,
                       stalledReplyDrafts: a.stalledReplyDrafts + sign * b.stalledReplyDrafts,
                       repliesToAnswer: a.repliesToAnswer + sign * b.repliesToAnswer)
    }
}

/// The patchable value: entries by PID and running totals over them.
@MainActor
struct Phase0cRowEntries {
    private(set) var entries: [PersistentIdentifier: Phase0cRowEntry] = [:]
    private(set) var keyToPID: [String: PersistentIdentifier] = [:]
    private(set) var focusCounts: [StageFocus: Int] = [:]
    private(set) var due = DueWork.Counts(followUps: 0, afterTheShow: 0)
    private(set) var deadEnds = 0
    private(set) var stalled = 0
    private(set) var reachedShows = 0
    private(set) var reachedDue = 0
    private(set) var rowCounts: [String: Int] = [:]
    private var serials: [PersistentIdentifier: Int] = [:]
    private var nextSerial = 0
    // Every row's DueWork next moment, sorted, so the whole's `nextChange` is the first entry after `now`
    // without a sweep.
    private var nextOrder: [(date: Date, serial: Int)] = []
    private(set) var context: Phase0cRowContext
    private(set) var upstream: Phase0cUpstream
    /// How many entries the last `apply` rebuilt, for the cost report.
    private(set) var lastRebuilt = 0

    init(rows: [Prospect], context: Phase0cRowContext, upstream: Phase0cUpstream) {
        self.context = context
        self.upstream = upstream
        for p in rows { rebuild(p.persistentModelID, p) }
    }

    // MARK: contributions

    private mutating func addContribution(_ e: Phase0cRowEntry, serial: Int) {
        due = Phase0cRowBuild.add(due, e.due, sign: 1)
        if let k = e.presenterKey { rowCounts[k, default: 0] += 1 }
        if let n = e.dueNext { insertNext(n, serial) }
        guard e.inQueue else { return }
        for f in e.focuses { focusCounts[f, default: 0] += 1 }
        if e.deadEnd { deadEnds += 1 }
        stalled += e.stalled
        if let r = e.reach {
            reachedShows += 1
            if r.isDue { reachedDue += 1 }
        }
    }

    private mutating func subtractContribution(_ e: Phase0cRowEntry, serial: Int) {
        due = Phase0cRowBuild.add(due, e.due, sign: -1)
        if let k = e.presenterKey {
            let left = (rowCounts[k] ?? 0) - 1
            rowCounts[k] = left == 0 ? nil : left
        }
        if let n = e.dueNext { removeNext(n, serial) }
        guard e.inQueue else { return }
        for f in e.focuses {
            let left = (focusCounts[f] ?? 0) - 1
            focusCounts[f] = left == 0 ? nil : left
        }
        if e.deadEnd { deadEnds -= 1 }
        stalled -= e.stalled
        if let r = e.reach {
            reachedShows -= 1
            if r.isDue { reachedDue -= 1 }
        }
    }

    private func nextIndex(_ date: Date, _ serial: Int) -> Int {
        var low = 0, high = nextOrder.count
        while low < high {
            let mid = (low + high) / 2
            let m = nextOrder[mid]
            if m.date < date || (m.date == date && m.serial < serial) { low = mid + 1 } else { high = mid }
        }
        return low
    }

    private mutating func insertNext(_ date: Date, _ serial: Int) {
        nextOrder.insert((date, serial), at: nextIndex(date, serial))
    }

    private mutating func removeNext(_ date: Date, _ serial: Int) {
        let i = nextIndex(date, serial)
        if i < nextOrder.count, nextOrder[i].date == date, nextOrder[i].serial == serial { nextOrder.remove(at: i) }
    }

    /// Rebuilds one entry; returns whether anything a reader sees changed. `p == nil` removes it.
    @discardableResult
    mutating func rebuild(_ pid: PersistentIdentifier, _ p: Prospect?) -> Bool {
        let serial: Int
        if let s = serials[pid] { serial = s } else { serial = nextSerial; nextSerial += 1; serials[pid] = serial }
        let old = entries[pid]
        if let old = entries[pid] { subtractContribution(old, serial: serial) }
        guard let p else {
            entries[pid] = nil
            if let old, keyToPID[old.key] == pid { keyToPID[old.key] = nil }
            return old != nil
        }
        let fresh = Phase0cRowBuild.entry(p, context: context, upstream: upstream)
        entries[pid] = fresh
        if let old, old.key != fresh.key, keyToPID[old.key] == pid { keyToPID[old.key] = nil }
        keyToPID[fresh.key] = pid
        addContribution(fresh, serial: serial)
        return !(old?.sameOutput(as: fresh) ?? false)
    }

    // MARK: the patch

    /// Applies one change: the rows the change touched, the upstream tables as they now stand, and the
    /// context as it now stands. Returns the PIDs whose entry changed (the node's ChangedKeys).
    @discardableResult
    mutating func apply(changed: Set<PersistentIdentifier>, rows: [PersistentIdentifier: Prospect],
                        upstream newUp: Phase0cUpstream, context newContext: Phase0cRowContext)
        -> Set<PersistentIdentifier> {
        var dirty = changed
        // Upstream hand-offs: a key whose hidden flag or inherited answer moved.
        if newUp != upstream {
            for key in upstream.hidden.symmetricDifference(newUp.hidden) {
                if let pid = keyToPID[key] { dirty.insert(pid) }
            }
            for key in Set(upstream.inherited.keys).union(newUp.inherited.keys)
            where upstream.inherited[key] != newUp.inherited[key] {
                if let pid = keyToPID[key] { dirty.insert(pid) }
            }
        }
        // Context reads.
        let old = context
        if newContext.replyRunAlive != old.replyRunAlive {
            for (pid, e) in entries where e.readsReplyRunAlive { dirty.insert(pid) }
        }
        if newContext.stage.geo != old.stage.geo {
            for (pid, e) in entries where e.inQueue {
                if let p = rows[pid], newContext.stage.geo.hidesFromQueue(p) != e.geoHides { dirty.insert(pid) }
            }
        }
        if newContext.stage.now != old.stage.now || newContext.stage.today != old.stage.today {
            let now = newContext.stage.now
            for (pid, e) in entries where now < e.builtAt || now >= e.validUntil || e.validUntil <= e.builtAt {
                dirty.insert(pid)
            }
        }
        // `clients` is part of the stage context too; a change there is not in this op mix, so it rebuilds
        // everything rather than claiming a neighbourhood nobody measured.
        if newContext.stage.clients != old.stage.clients { dirty.formUnion(entries.keys) }
        context = newContext
        upstream = newUp
        var out = Set<PersistentIdentifier>()
        for pid in dirty where rebuild(pid, rows[pid]) { out.insert(pid) }
        lastRebuilt = dirty.count
        return out
    }

    // MARK: readers

    var nextChange: Date? {
        let now = context.stage.now
        return nextOrder.first(where: { $0.date > now })?.date
    }

    var inquiryDue: DueWork.Counts {
        DueWork.counts(prospects: [], inquiries: context.inquiries, now: context.stage.now,
                       replyRunAlive: context.replyRunAlive)
    }

    var dueWithInquiries: DueWork.Counts { Phase0cRowBuild.add(due, inquiryDue, sign: 1) }

    var agentInputs: AgentInputs {
        let inquiries = context.inquiries
        func count(_ f: StageFocus) -> Int { focusCounts[f] ?? 0 }
        func inquiryCount(_ f: StageFocus) -> Int { inquiries.filter { StageNavigation.stage(for: $0) == f }.count }
        let dueAll = dueWithInquiries
        return AgentInputs(
            toTriage: count(.scout), keptToPrep: count(.prep), runInFlight: context.runInFlight,
            toReview: count(.review) + inquiryCount(.review), readyToSend: count(.sendApproved),
            gmailConnected: context.gmailConnected, sendErrors: count(.sendErrors), followUpsDue: dueAll.total,
            conversationsToConfirm: dueAll.conversationsToConfirm, repliesToAnswer: dueAll.repliesToAnswer,
            reviewDeadEnds: deadEnds, stalledReplyDrafts: stalled, stuckSends: count(.sendStuck),
            degradedReplyTracking: count(.sendDegraded), degradedThreading: count(.sendThreadingDegraded),
            blockedContacts: count(.sendBlocked),
            reachedOut: reachedShows + inquiryCount(.reachedOut),
            reachedOutDue: reachedDue
                + inquiries.filter { StageNavigation.stage(for: $0) == .reachedOut && $0.hasUnhandledReply }.count)
    }

    var rowsByKey: [String: QueueScopeRow] {
        var out: [String: QueueScopeRow] = [:]
        for e in entries.values { if let r = e.row { out[e.key] = r } }
        return out
    }

    var focusesByKey: [String: [StageFocus]] {
        var out: [String: [StageFocus]] = [:]
        for e in entries.values where e.inQueue && !e.focuses.isEmpty { out[e.key] = e.focuses }
        return out
    }

    var reachByKey: [String: Phase0cReach] {
        var out: [String: Phase0cReach] = [:]
        for e in entries.values where e.inQueue { if let r = e.reach { out[e.key] = r } }
        return out
    }
}

/// Today's code, called through the canonical order, flattened to what T7's outputs are compared on.
@MainActor
struct Phase0cRowOracle {
    var rows: [String: QueueScopeRow]
    var focuses: [String: [StageFocus]]
    var agent: String
    var due: DueWork.Counts
    var dueNext: Date?
    var reachNext: [String: Date]
    var rowCounts: [String: Int]

    init(every: [Prospect], inquiries: [Inquiry], answers: [OrgReachabilityAnswer],
         refusals: ContactRefusal.Ledger, stage raw: StageContext, replyRunAlive: Bool) {
        let canonicalEvery = every.sorted(by: CanonicalOracle.byNaturalKey)
        let inQueue = CanonicalOracle.queueScope(every)
        let context = raw.resolvingPlaces(of: inQueue)
        let scope = QueueModel.scope(from: inQueue, answers: answers.sorted(by: CanonicalOracle.answerOrder),
                                     corpus: canonicalEvery, overrides: .none, refusals: refusals,
                                     clients: context.clients, now: context.now, cardKeys: [], today: context.today)
        let byKey = Dictionary(inQueue.map { ($0.naturalKey, $0) }, uniquingKeysWith: { a, _ in a })
        rows = Dictionary(scope.rows.map { row -> (String, QueueScopeRow) in
            var canonical = row
            if let p = byKey[row.id] { canonical.facts = Phase0cRowBuild.canonicalFacts(p) }
            return (row.id, canonical)
        }, uniquingKeysWith: { a, _ in a })
        let placement = StageNavigation.placements(in: inQueue, context: context)
        var focuses: [String: [StageFocus]] = [:]
        for f in StageNavigation.countedFocuses {
            for k in StageNavigation.naturalKeys(for: f, in: placement) { focuses[k, default: []].append(f) }
        }
        self.focuses = focuses
        agent = String(describing: AgentInputs.from(prospects: inQueue, allProspects: canonicalEvery,
                                                    inquiries: inquiries, context: context, gmailConnected: false,
                                                    runInFlight: nil, replyRunAlive: replyRunAlive))
        due = DueWork.counts(prospects: canonicalEvery, inquiries: inquiries, now: context.now,
                             replyRunAlive: replyRunAlive)
        dueNext = DueWork.nextChange(prospects: canonicalEvery, now: context.now, replyRunAlive: replyRunAlive)
        reachNext = Dictionary(CanonicalOracle.reachedOut(inQueue, now: context.now)
            .map { ($0.prospect.naturalKey, $0.next) }, uniquingKeysWith: { a, _ in a })
        rowCounts = QueueModel.organisationRowCounts(canonicalEvery.map(\.presenter))
    }

    /// The upstream tables as today's code computes them, in the canonical order.
    static func upstream(every: [Prospect], answers: [OrgReachabilityAnswer], refusals: ContactRefusal.Ledger,
                         now: Date) -> Phase0cUpstream {
        let canonicalEvery = every.sorted(by: CanonicalOracle.byNaturalKey)
        let drawn = Set(every.filter { $0.statusRaw != "dismissed" }.map(\.naturalKey))
        let hidden = CanonicalOracle.showLinkCollapse(canonicalEvery.map(ShowLink.Row.init), drawn: drawn).hidden
        let inherited = QueueModel.inheritedAnswers(answers.sorted(by: CanonicalOracle.answerOrder),
                                                    corpus: canonicalEvery, overrides: .none, refusals: refusals,
                                                    heldKeys: [], now: now)
        return Phase0cUpstream(hidden: hidden, inherited: inherited)
    }

    /// Every place the prototype and this oracle disagree, by component, as counts and key hashes only.
    func mismatches(_ proto: Phase0cRowEntries, rowsByKey: [String: Prospect]) -> [String] {
        var out: [String] = []
        func keyed<T: Equatable>(_ name: String, _ a: [String: T], _ b: [String: T]) {
            let bad = Set(a.keys).union(b.keys).filter { a[$0] != b[$0] }.sorted()
            if !bad.isEmpty {
                out.append("\(name): \(bad.count) keys (\(bad.prefix(3).map(Phase0b.hash8).joined(separator: " ")))")
            }
        }
        let protoRows = proto.rowsByKey
        keyed("rows", protoRows, rows)
        // Which side lacks the row, or which fields differ, by FIELD NAME only.
        for key in Set(protoRows.keys).union(rows.keys).sorted() where protoRows[key] != rows[key] {
            guard let a = protoRows[key], let b = rows[key] else {
                out.append("  row \(Phase0b.hash8(key)) present only in \(protoRows[key] == nil ? "the oracle" : "the prototype")")
                continue
            }
            let fields = zip(Mirror(reflecting: a).children, Mirror(reflecting: b).children)
                .filter { String(describing: $0.0.value) != String(describing: $0.1.value) }
                .compactMap { $0.0.label }
            out.append("  row \(Phase0b.hash8(key)) differs in \(fields.joined(separator: ","))")
            break
        }
        keyed("focuses", proto.focusesByKey, focuses)
        keyed("rowCounts", proto.rowCounts, rowCounts)
        let reach = proto.reachByKey
        keyed("reachedOut next", reach.mapValues(\.next), reachNext)
        let now = proto.context.stage.now
        var outsideTieClass = 0
        for (key, r) in reach {
            guard let p = rowsByKey[key] else { continue }
            if !CanonicalOracle.reachedOutTieClass(of: p, now: now).contains(where: { $0 === r.representative }) {
                outsideTieClass += 1
            }
        }
        if outsideTieClass > 0 { out.append("reachedOut representative outside its tie class: \(outsideTieClass)") }
        let agentText = String(describing: proto.agentInputs)
        if agentText != agent { out.append("AgentInputs: \(Phase0b.hash8(agentText)) against \(Phase0b.hash8(agent))") }
        if proto.dueWithInquiries != due { out.append("DueWork.counts: \(proto.dueWithInquiries) against \(due)") }
        if proto.nextChange != dueNext {
            out.append("DueWork.nextChange: \(proto.nextChange?.timeIntervalSince1970 ?? -1) against \(dueNext?.timeIntervalSince1970 ?? -1)")
        }
        return out
    }
}
