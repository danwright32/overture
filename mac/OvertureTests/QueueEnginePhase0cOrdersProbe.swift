import Testing
import Foundation
import SwiftData

// #4106 Phase 0c probe 0c.10: what each total order in decisions 13 and 18 would change on the live store,
// before Dan answers them (plan section 6, "0c.10 counts, per proposal, how many live rows change and how
// often full ties occur, including how many tied rows a re-key would move").
//
// "Today" is each production function over the store in the order a plain fetch returns it, which is the
// order the app's own query hands the pass. "Proposed" is the plan's Step T order for that term. Counts and
// hashes only, never a name (L222). Opt in, with the rest of this suite.

enum Phase0cEngagementRule { case lastAppended, latestNight }

enum Phase0cOrders {
    /// `EngagementLink.group`, restated so the chain rule can be swapped. Proved equal to the production
    /// function on the live store before any count is read from it (L70).
    static func engagement(_ rows: [EngagementLink.Row], rule: Phase0cEngagementRule) -> [String: [EngagementLink.Member]] {
        func canon(_ s: String?) -> String { (s ?? "").lowercased().trimmingCharacters(in: .whitespaces) }
        var byTitle: [String: [EngagementLink.Row]] = [:]
        for r in rows where r.performanceDate != nil {
            byTitle[GroupNameMatch.normalize(r.groupName), default: []].append(r)
        }
        var out: [String: [EngagementLink.Member]] = [:]
        for (_, titleRows) in byTitle {
            // The product's own total order since #4346 (date, run end, venue, naturalKey). #4347 retired the
            // date only arm, which priced the Step T sort before it shipped and could only ever read 0 after.
            let sorted = titleRows.sorted {
                ($0.performanceDate ?? "", $0.runEndDate ?? "", $0.venue ?? "", $0.id)
                    < ($1.performanceDate ?? "", $1.runEndDate ?? "", $1.venue ?? "", $1.id)
            }
            var clusters: [[EngagementLink.Row]] = []
            var clusterEnd: [String?] = []
            for r in sorted {
                let anchor: String?
                switch rule {
                case .lastAppended:
                    anchor = clusters.last?.last.flatMap {
                        EasternDate.runLastNight(runEndDate: $0.runEndDate, performanceDate: $0.performanceDate)
                    }
                case .latestNight:
                    anchor = clusterEnd.last ?? nil
                }
                if let anchor, let gap = EasternDate.daysUntil(from: anchor, to: r.performanceDate!),
                   gap <= RunGrouping.gapDays, !clusters.isEmpty {
                    clusters[clusters.count - 1].append(r)
                    let mine = EasternDate.runLastNight(runEndDate: r.runEndDate, performanceDate: r.performanceDate)
                    if let mine, mine > (clusterEnd[clusterEnd.count - 1] ?? "") { clusterEnd[clusterEnd.count - 1] = mine }
                } else {
                    clusters.append([r])
                    clusterEnd.append(EasternDate.runLastNight(runEndDate: r.runEndDate, performanceDate: r.performanceDate))
                }
            }
            for cluster in clusters where Set(cluster.map { canon($0.venue) }).count > 1 {
                for r in cluster {
                    out[r.id] = cluster.filter { $0.id != r.id }.map { EngagementLink.Member(venue: $0.venue, date: $0.performanceDate!) }
                }
            }
        }
        return out
    }

    /// The plan's proposed representative: among replied contacts by (earliest reply, email, PID); with no
    /// reply, by (next, email, PID). PID enters only as an ordering key and is never printed.
    @MainActor
    static func proposedRepresentative(of p: Prospect, now: Date) -> Recipient? {
        let live = p.recipients.compactMap { r -> (recipient: Recipient, next: Date)? in
            ReachedOutQueue.nextReachOut(for: r, of: p, now: now).map { (recipient: r, next: $0) }
        }
        func pid(_ r: Recipient) -> String { String(describing: r.persistentModelID) }
        let replied = live.filter { $0.recipient.replied }
        if !replied.isEmpty {
            return replied.min {
                let a = ($0.recipient.replyArrivedAt ?? .distantFuture, $0.recipient.email ?? "", pid($0.recipient))
                let b = ($1.recipient.replyArrivedAt ?? .distantFuture, $1.recipient.email ?? "", pid($1.recipient))
                return a < b
            }?.recipient
        }
        return live.min {
            ($0.next, $0.recipient.email ?? "", pid($0.recipient)) < ($1.next, $1.recipient.email ?? "", pid($1.recipient))
        }?.recipient
    }
}

extension QueueEnginePhase0cRowsProbeTests {

    @Test(.enabled(if: Phase0.liveStoreExists, "no live store on this machine"))
    func probe0c10TotalOrders() throws {
        if skip("0c.10") { return }
        let export = try scratchExport()
        let dir = try sandboxes.make(named: "phase0c-rows-10")
        guard let url = try LiveStoreClone.makeClone(in: dir) else {
            throw LiveStoreClone.Refusal.backupFailed("no live store on this machine")
        }
        let container = try Phase0.openContainer(at: url)
        let t = try Phase0cRowsTables(ModelContext(container), export: export)
        let every = t.rows
        let now = Date()
        let today = EasternDate.today(now)
        let byKey = Dictionary(every.map { ($0.naturalKey, $0) }, uniquingKeysWith: { a, _ in a })
        var lines: [String] = ["0c.10 [live clone] \(every.count) shows, \(Phase0.load())"]

        // (i) queueScope: full ties broken by naturalKey.
        let inQueueToday = QueueModel.queueScope(every)
        let todayScope = inQueueToday.map(\.naturalKey)
        let proposedScope = CanonicalOracle.queueScope(every).map(\.naturalKey)
        let scopePos = Dictionary(todayScope.enumerated().map { ($1, $0) }, uniquingKeysWith: { a, _ in a })
        let scopeMoved = proposedScope.enumerated().filter { scopePos[$1] != $0 }.count
        var scopeTies: [String: Int] = [:]
        for p in inQueueToday { scopeTies["\(p.performanceDate ?? "\u{0}")|\(p.fitScore)", default: 0] += 1 }
        let scopeTieGroups = scopeTies.values.filter { $0 > 1 }
        lines.append("(i) queueScope: \(inQueueToday.count) rows; full ties (same night and fit) \(scopeTieGroups.count) groups holding \(scopeTieGroups.reduce(0, +)) rows (largest \(scopeTieGroups.max() ?? 0)); rows whose position changes under naturalKey tie-break \(scopeMoved); rows a re-key could move (every row in a tie group) \(scopeTieGroups.reduce(0, +))")

        // (ii) ReachedOut: the list by (next, naturalKey), and the representative.
        let reachedToday = ReachedOutQueue.activeWithDates(from: inQueueToday, now: now)
        let reachedProposed = reachedToday.sorted {
            ($0.next, $0.prospect.naturalKey) < ($1.next, $1.prospect.naturalKey)
        }
        let reachedPos = Dictionary(reachedToday.enumerated().map { ($1.prospect.naturalKey, $0) },
                                    uniquingKeysWith: { a, _ in a })
        let reachedMoved = reachedProposed.enumerated().filter { reachedPos[$1.prospect.naturalKey] != $0 }.count
        var nextTies: [Date: Int] = [:]
        for r in reachedToday { nextTies[r.next, default: 0] += 1 }
        let nextTieGroups = nextTies.values.filter { $0 > 1 }
        var widerClasses = 0, classDueDisagree = 0, classLabelDisagree = 0
        var repChanged = 0, repDueChanged = 0, repLabelChanged = 0, dueToday = 0, dueProposed = 0
        var repliedBranch = 0
        for row in reachedToday {
            let p = row.prospect
            let cls = CanonicalOracle.reachedOutTieClass(of: p, now: now)
            if cls.contains(where: { $0.replied }) { repliedBranch += 1 }
            if cls.count > 1 {
                widerClasses += 1
                if Set(cls.map { ReachedOutQueue.isDueNow(for: $0, of: p, now: now) }).count > 1 { classDueDisagree += 1 }
                if Set(cls.map { ReachedOutQueue.timingLabel(for: $0, of: p, now: now, today: today) }).count > 1 {
                    classLabelDisagree += 1
                }
            }
            let todayDue = ReachedOutQueue.isDueNow(for: row.recipient, of: p, now: now)
            if todayDue { dueToday += 1 }
            guard let proposed = Phase0cOrders.proposedRepresentative(of: p, now: now) else { continue }
            let proposedDue = ReachedOutQueue.isDueNow(for: proposed, of: p, now: now)
            if proposedDue { dueProposed += 1 }
            if proposed !== row.recipient {
                repChanged += 1
                if proposedDue != todayDue { repDueChanged += 1 }
                if ReachedOutQueue.timingLabel(for: proposed, of: p, now: now, today: today)
                    != ReachedOutQueue.timingLabel(for: row.recipient, of: p, now: now, today: today) {
                    repLabelChanged += 1
                }
            }
        }
        lines.append("(ii) ReachedOut: \(reachedToday.count) rows; full ties on next \(nextTieGroups.count) groups holding \(nextTieGroups.reduce(0, +)) rows; rows whose list position changes under (next, naturalKey) \(reachedMoved); rows a re-key could move \(nextTieGroups.reduce(0, +))")
        lines.append("    representative: \(repliedBranch) rows in the replied branch; tie classes wider than one contact \(widerClasses); of those, members disagreeing on isDueNow \(classDueDisagree), on the timing label \(classLabelDisagree)")
        lines.append("    proposed rule (earliest reply, email, PID / next, email, PID): named person changes on \(repChanged) rows, of which isDueNow changes \(repDueChanged) and the timing label \(repLabelChanged); reachedOutDue today \(dueToday), proposed \(dueProposed)")

        // (iv) FeedBreakEvent label.
        let events = FeedBreakEvent.events(among: every, asOf: today)
        var multiSpelling = 0, topTie = 0, changedMostCommon = 0, changedSmallestKey = 0
        var rowsMostCommon = 0, rowsSmallestKey = 0
        for e in events {
            let members = e.memberKeys.compactMap { byKey[$0] }.sorted(by: CanonicalOracle.byNaturalKey)
            var counts: [String: Int] = [:]
            for m in members { counts[m.venue ?? "", default: 0] += 1 }
            if counts.count > 1 { multiSpelling += 1 }
            let top = counts.values.max() ?? 0
            let topSpellings = Set(counts.filter { $0.value == top }.keys)
            if topSpellings.count > 1 { topTie += 1 }
            let mostCommon = members.first { topSpellings.contains($0.venue ?? "") }?.venue ?? ""
            let smallestKey = members.first?.venue ?? ""
            if mostCommon != e.venue { changedMostCommon += 1; rowsMostCommon += members.count }
            if smallestKey != e.venue { changedSmallestKey += 1; rowsSmallestKey += members.count }
        }
        lines.append("(iv) FeedBreakEvent: \(events.count) events; holding more than one spelling \(multiSpelling); top spelling tied \(topTie); label changes under most-common (recommended) \(changedMostCommon) events, \(rowsMostCommon) member rows; under smallest-key \(changedSmallestKey) events, \(rowsSmallestKey) member rows; a re-key could move the label on the \(topTie) tied events")

        // (v) Bookings: naturalKey after (date, kind, groupName). Two fresh contexts, neither saved.
        let loaded = DownbeatBridge.loadWithHealth(from: export, now: now)
        func booked(_ order: ([Prospect]) -> [Prospect]) throws -> [String: String] {
            let c = ModelContext(container)
            let rows = try c.fetch(FetchDescriptor<Prospect>())
            let inquiries = try c.fetch(FetchDescriptor<Inquiry>())
            let entities = order(rows).map { $0 as any BookingMatchable } + inquiries.map { $0 as any BookingMatchable }
            DownbeatBooking.reconcileBooked(entities: entities, clients: loaded.clients, bookings: loaded.bookings,
                                            health: .ok, now: now)
            return Dictionary(rows.map { ($0.naturalKey, "\(String(describing: $0.outcomeRaw))|\($0.bookingSuggested)") },
                              uniquingKeysWith: { a, _ in a })
        }
        let bookedToday = try booked { $0 }
        let bookedProposed = try booked { $0.sorted(by: CanonicalOracle.byNaturalKey) }
        let bookedChanged = bookedToday.keys.filter { bookedToday[$0] != bookedProposed[$0] }.count
        var bookingTies: [String: Int] = [:]
        for p in every where p.wasProvablyContacted {
            bookingTies["\(p.performanceDate ?? "")|\(p.groupName)", default: 0] += 1
        }
        let bookingTieGroups = bookingTies.values.filter { $0 > 1 }
        if loaded.bookings.isEmpty {
            lines.append("(v) bookings: UNMEASURED, the Downbeat export on this Mac holds no bookings (health \(loaded.health)), so no tie can reach a booking; contacted rows tied on (date, kind, groupName) \(bookingTieGroups.count) groups holding \(bookingTieGroups.reduce(0, +)) rows")
        } else {
        lines.append("(v) bookings: \(loaded.bookings.count) bookings in the export (health \(loaded.health), run as ok); contacted rows tied on (date, kind, groupName) \(bookingTieGroups.count) groups holding \(bookingTieGroups.reduce(0, +)) rows; rows whose booked or suggested outcome changes under the naturalKey tie-break \(bookedChanged); rows a re-key could move \(bookingTieGroups.reduce(0, +))")
        }

        // (vi) laterLookalikes: nil and equal firstSeenAt broken by naturalKey.
        var lookalikes: [String: [Prospect]] = [:]
        for row in every { if let target = row.arrivedLookingLike { lookalikes[target, default: []].append(row) } }
        var shownTargets = 0, multi = 0, firstChanged = 0, orderChanged = 0, topTied = 0, nilTied = 0
        for (target, rows) in lookalikes where byKey[target] != nil {
            shownTargets += 1
            guard rows.count > 1 else { continue }
            multi += 1
            let todayOrder = rows.sorted { ($0.firstSeenAt ?? .distantPast) > ($1.firstSeenAt ?? .distantPast) }.map(\.naturalKey)
            let proposed = rows.sorted {
                let a = $0.firstSeenAt ?? .distantPast, b = $1.firstSeenAt ?? .distantPast
                return a != b ? a > b : $0.naturalKey < $1.naturalKey
            }.map(\.naturalKey)
            if todayOrder.first != proposed.first { firstChanged += 1 }
            if todayOrder != proposed { orderChanged += 1 }
            let newest = rows.map { $0.firstSeenAt ?? .distantPast }.max()
            let atTop = rows.filter { ($0.firstSeenAt ?? .distantPast) == newest }
            if atTop.count > 1 { topTied += 1 }
            if atTop.count > 1, atTop.allSatisfy({ $0.firstSeenAt == nil }) { nilTied += 1 }
        }
        lines.append("(vi) laterLookalikes: \(lookalikes.count) targets, \(shownTargets) still stored; \(multi) with more than one later lookalike; top tied \(topTied) (all nil \(nilTied)); the named title changes on \(firstChanged) cards, the order on \(orderChanged); a re-key could change the named title on the \(topTied) tied cards")

        // Decision 18: EngagementLink's chain rule, over the rows the pass links (the queue scope).
        let linkRows = inQueueToday.map(EngagementLink.Row.init)
        let production = EngagementLink.group(linkRows)
        // Since #4347 the product measures the chain from the cluster's latest night (decision 18(b)). Compared
        // as MEMBERSHIP, because the restatement walks equal nights in a total order the product may not.
        let replica = Phase0cOrders.engagement(linkRows, rule: .latestNight)
        let replicaAgrees = Set(replica.keys) == Set(production.keys)
            && replica.keys.allSatisfy { Set(replica[$0]!) == Set(production[$0] ?? []) }
        // #4347: only the agreement check above and rule (a) against (b) remain. The pre-decision lines (the
        // Step T sort under today's rule, equal-date ties, (b) against today's production) priced decisions
        // 13 and 18 before they were answered, and once both shipped they compare the product with itself.
        let ruleA = Phase0cOrders.engagement(linkRows, rule: .lastAppended)
        let ruleBDiffers = Set(ruleA.keys).union(replica.keys)
            .filter { Set(ruleA[$0] ?? []) != Set(replica[$0] ?? []) }.count
        lines.append("decision 18, EngagementLink: \(linkRows.count) rows, \(production.count) linked today; the restated rule reproduces production: \(replicaAgrees ? "yes" : "NO, counts below are not evidence")")
        lines.append("    rule (b), latest night so far, against (a) with the same sort: membership changes on \(ruleBDiffers) rows (\(replica.count) linked under (b), \(ruleA.count) under (a))")
        Phase0cRows.say(lines.joined(separator: "\n  "))
        #expect(replicaAgrees, "the restated EngagementLink rule does not reproduce production on the clone")
    }
}
