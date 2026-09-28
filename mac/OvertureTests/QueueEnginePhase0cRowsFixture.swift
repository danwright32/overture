import Foundation
import SwiftData

// #4106 Phase 0c probe 0c.5: the synthetic store the T7 prototype is proved on, and the seeded operations
// it is proved under.
//
// Every name and address is invented (L155, L222): titles, rooms and presenters that CONTAIN one another,
// so any rule that folds or matches names has real work to do, and example.org addresses. The generator is
// seeded (L339), so a failure names a seed and a step that reproduce it. The clock is pinned: the store is
// built around 2027-01-15 12:00 UTC and moves only when an operation moves it (L130).

@MainActor
final class Phase0cRowsFixture {
    static let baseNow = Date(timeIntervalSince1970: 1_800_014_400)   // 2027-01-15, Eastern

    static let titles = ["Lantern", "Glass Lantern", "Lantern Revue", "Glass Lantern Revue", "Harbor Lights",
                         "Harbor Lights Encore", "Cedar Strings", "Cedar Strings Trio", "Juniper Choral",
                         "Juniper Choral Society", "Marble Steps", "Marble Steps Dance"]
    static let venues = ["Harbor Hall", "Harbor Hall Annex", "Quarry Hall", "The Quarry Hall", "Willow Barn",
                         "Willow Barn Stage"]
    static let presenters: [String?] = ["Lark & Finch Players", "Lark and Finch Players", "Finch Players",
                                        "Harbor Hall", "Quarry Arts", "Quarry Arts Collective", nil]
    static let locations: [String?] = ["Beacon, NY", "Brooklyn, NY", "Stamford, CT", "Hudson, NY", nil]
    static let disciplines = ["theater", "dance", "music", "opera"]
    static let larkPresenter = "Lark & Finch Players"
    static let refusableTown = "beacon"

    let container: ModelContainer
    let context: ModelContext
    let size: Int
    let seed: UInt64
    private(set) var rows: [Prospect] = []
    private(set) var inquiries: [Inquiry] = []
    private(set) var answers: [OrgReachabilityAnswer] = []
    var refusalRows: [ContactRefusal.Ledger.Row] = []
    var excludedTowns: Set<String> = []
    // Dan's producer corrections, which decide which presenters qualify and so which rows inherit an
    // org answer. Starts empty; the `producerOverride` operation toggles one of each direction.
    var overrides = ProducerOverrides.none
    var now: Date = baseNow
    var replyRunAlive = false
    private var rng: SeededGenerator
    private var inserted = 0

    static func day(_ offset: Int, from base: Date = baseNow) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "America/New_York")
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: base.addingTimeInterval(Double(offset) * 86_400))
    }

    // MARK: the seeded draws

    private func int(_ range: ClosedRange<Int>) -> Int {
        range.lowerBound + Int(rng.next() % UInt64(range.count))
    }

    private func chance(_ p: Double) -> Bool { Double(rng.next() % 10_000) / 10_000 < p }

    private func pick<T>(_ items: [T]) -> T { items[Int(rng.next() % UInt64(items.count))] }

    // MARK: building

    init(size: Int, seed: UInt64) throws {
        self.size = size
        self.seed = seed
        rng = SeededGenerator(seed: seed)
        container = try TestModelContainer.inMemory([Prospect.self, Recipient.self, Inquiry.self])
        context = container.mainContext
        for i in 0..<size { rows.append(makeRow(key: String(format: "row-%04d", i))) }
        // Productions the collapse joins: every tenth row and its successor share title, room and night.
        for i in stride(from: 1, to: size - 2, by: 10) {
            let front = rows[i]
            for sibling in [rows[i + 1]] + (chance(0.5) ? [rows[i + 2]] : []) {
                sibling.groupName = front.groupName
                sibling.venue = front.venue
                sibling.performanceDate = front.performanceDate ?? Self.day(20)
                front.performanceDate = sibling.performanceDate
                sibling.runEndDate = nil
                front.runEndDate = nil
            }
        }
        // A presenter at two rooms, so it qualifies as a producer and its answer can be inherited.
        for (i, room) in [(0, "Harbor Hall"), (5 % size, "Quarry Hall"), (9 % size, "Willow Barn")] {
            rows[i].presenter = Self.larkPresenter
            rows[i].venue = room
        }
        for row in rows where chance(0.1) {
            row.arrivedLookingLike = rows[int(0...(size - 1))].naturalKey
        }
        answers = [
            OrgReachabilityAnswer(orgKey: OrgKey.stored(for: Self.larkPresenter) ?? "",
                                  result: .emailFound, probedAt: Self.baseNow.addingTimeInterval(-86_400),
                                  sourceNaturalKey: rows[0].naturalKey, sourceGroupName: rows[0].groupName,
                                  presenterName: Self.larkPresenter,
                                  foundEmails: ["box@example.org", "desk@example.org"]),
            OrgReachabilityAnswer(orgKey: OrgKey.stored(for: "Quarry Arts") ?? "",
                                  result: .emailFound, probedAt: Self.baseNow.addingTimeInterval(-2 * 86_400),
                                  sourceNaturalKey: rows[1].naturalKey, sourceGroupName: rows[1].groupName,
                                  presenterName: "Quarry Arts", foundEmails: ["hello@example.org"]),
        ]
        for k in 0..<5 {
            let q = Inquiry(source: .contactForm, inquirerName: "Inquirer \(k)", inquirerEmail: "inq\(k)@example.org",
                            eventName: "Gala \(k)", performanceDate: Self.day(10 + k), venue: "Willow Barn",
                            createdAt: Self.baseNow.addingTimeInterval(-Double(k) * 86_400))
            if k % 2 == 1 { q.sentAt = Self.baseNow.addingTimeInterval(-2 * 86_400) }
            if k == 3 {
                q.replied = true
                q.repliedAt = Self.baseNow.addingTimeInterval(-86_400)
            }
            context.insert(q)
            inquiries.append(q)
        }
        try context.save()
    }

    private func makeRow(key: String) -> Prospect {
        let statuses: [ReviewStatus] = [.new, .new, .new, .queued, .drafted, .drafted, .approved, .contacted,
                                        .contacted, .dismissed]
        let status = pick(statuses)
        let offset = int(-15...110)
        let date: String? = chance(0.05) ? nil : Self.day(offset)
        let p = Prospect(naturalKey: key, groupName: pick(Self.titles), discipline: pick(Self.disciplines),
                         venue: pick(Self.venues), performanceDate: date, sourceListingURL: nil,
                         priorRelationship: "none", production: "self", profile: "strong",
                         coverage: "likely_uncovered", fitScore: int(1...9), tier: "mid", fitReason: "r",
                         matchedClientName: nil, possibleMatchSource: nil, possibleMatchName: nil, status: status,
                         ingestedAt: Self.baseNow)
        if date != nil, chance(0.2) { p.runEndDate = Self.day(offset + int(1...4)) }
        p.presenter = pick(Self.presenters)
        p.location = pick(Self.locations)
        if chance(0.05) { p.sendError = "refused" }
        if chance(0.08) { p.missedScoutCount = 2 }
        p.firstSeenAt = chance(0.5) ? Self.baseNow.addingTimeInterval(-Double(int(0...40)) * 86_400) : nil
        if status == .drafted || status == .approved { p.draftBody = "Hello" }
        if chance(0.06) { p.reprepContactsRequested = true }
        context.insert(p)
        let sends = status == .contacted || status == .approved || status == .drafted
        let count = sends ? (status == .drafted && chance(0.3) ? 0 : int(1...3)) : (chance(0.1) ? 1 : 0)
        var contacts: [Recipient] = []
        for j in 0..<count {
            let id = "\(key)-c\(j)@example.org"
            let r = Recipient(id: id, email: id, provenance: .act)
            if status == .contacted || (status == .approved && chance(0.3)) {
                let sent = Self.baseNow.addingTimeInterval(-Double(int(1...25)) * 86_400 - Double(int(0...3_600)))
                r.sentAt = sent
                r.sendState = .sent
                r.gmailMessageId = "msg-\(key)-\(j)"
                if p.sentAt == nil {
                    p.sentAt = sent
                    p.gmailMessageId = "msg-\(key)"
                }
                if chance(0.25) {
                    r.replied = true
                    r.repliedAt = sent.addingTimeInterval(Double(int(1...4)) * 86_400)
                    if chance(0.5) { r.inboundReplySentAt = r.repliedAt }
                }
                if chance(0.1) { r.replyDraftRequestedAt = Self.baseNow.addingTimeInterval(-Double(int(0...600))) }
                if chance(0.05) { r.replyTrackingDegraded = true }
                if chance(0.05) { r.threadingDegraded = true }
                if chance(0.1) {
                    r.followUpCount = 1
                    r.lastFollowUpAt = sent.addingTimeInterval(5 * 86_400)
                }
            } else if chance(0.05) {
                r.sendState = .sending
                r.sendClaimedAt = Self.baseNow.addingTimeInterval(-30)
            }
            contacts.append(r)
        }
        p.setRecipients(contacts)
        return p
    }

    // MARK: what the prototype and the oracle read

    var refusals: ContactRefusal.Ledger { ContactRefusal.Ledger(rows: refusalRows) }
    var geo: GeoRefusals { GeoRefusals(userExcludedTowns: excludedTowns) }
    var stage: StageContext { StageContext(now: now, geo: geo, clients: .none) }
    var rowsByPID: [PersistentIdentifier: Prospect] {
        Dictionary(rows.map { ($0.persistentModelID, $0) }, uniquingKeysWith: { a, _ in a })
    }
    var rowsByKey: [String: Prospect] {
        Dictionary(rows.map { ($0.naturalKey, $0) }, uniquingKeysWith: { a, _ in a })
    }

    func rowContext() -> Phase0cRowContext {
        let inQueue = rows.filter { $0.statusRaw != "dismissed" }
        return Phase0cRowContext(stage: stage.resolvingPlaces(of: inQueue), replyRunAlive: replyRunAlive,
                                 inquiries: inquiries)
    }

    func upstream() -> Phase0cUpstream {
        Phase0cRowOracle.upstream(every: rows, answers: answers, refusals: refusals, overrides: overrides, now: now)
    }

    func oracle(order: [Prospect]? = nil) -> Phase0cRowOracle {
        Phase0cRowOracle(every: order ?? rows, inquiries: inquiries, answers: answers, refusals: refusals,
                         overrides: overrides,
                         stage: stage, replyRunAlive: replyRunAlive)
    }

    // MARK: operations

    enum Kind: String, CaseIterable {
        case stageMove, dismissToggle, sentAt, reprep, reply, clock, replyRunAlive, geo, presenter, inquiry,
             collapsedFront, refusal, recipientFlag, insertRow, dateMove, producerOverride
    }

    struct Op {
        let kind: Kind
        let label: String
        let changed: Set<PersistentIdentifier>
        let undo: () -> Set<PersistentIdentifier>
    }

    func pickKind() -> Kind { pick(Kind.allCases) }

    func draw(_ n: Int) -> Int { Int(rng.next() % UInt64(max(n, 1))) }

    func coin(_ p: Double) -> Bool { chance(p) }

    // Every operation returns the rows it touched and an undo that restores exactly what it changed.
    func perform(_ kind: Kind) -> Op? {
        let p = pick(rows)
        let pid = p.persistentModelID
        switch kind {
        case .stageMove:
            let old = p.status
            let to = pick(ReviewStatus.allCases.filter { $0 != old && $0 != .dismissed })
            p.status = to
            return Op(kind: kind, label: "stage \(old.rawValue) to \(to.rawValue)", changed: [pid]) {
                p.status = old; return [pid]
            }
        case .dismissToggle:
            let old = p.status
            p.status = old == .dismissed ? .new : .dismissed
            return Op(kind: kind, label: "dismiss toggle", changed: [pid]) { p.status = old; return [pid] }
        case .sentAt:
            let old = p.sentAt
            let contact = p.recipients.first
            let oldContact = contact?.sentAt
            let oldState = contact?.sendState
            let oldMessage = contact?.gmailMessageId
            let at = now.addingTimeInterval(-Double(draw(20) + 1) * 86_400)
            p.sentAt = old == nil ? at : nil
            if let contact {
                contact.sentAt = oldContact == nil ? at : nil
                contact.sendState = oldContact == nil ? .sent : .pending
                contact.gmailMessageId = oldContact == nil ? "msg-op-\(draw(1_000_000))" : oldMessage
            }
            return Op(kind: kind, label: "sentAt toggle", changed: [pid]) {
                p.sentAt = old
                if let contact, let oldState {
                    contact.sentAt = oldContact
                    contact.sendState = oldState
                    contact.gmailMessageId = oldMessage
                }
                return [pid]
            }
        case .reprep:
            let old = p.reprepContactsRequested
            p.reprepContactsRequested = !old
            return Op(kind: kind, label: "reprep toggle", changed: [pid]) {
                p.reprepContactsRequested = old; return [pid]
            }
        case .reply:
            guard let r = p.recipients.first(where: { $0.sentAt != nil }) else { return nil }
            let (oldReplied, oldAt, oldInbound) = (r.replied, r.repliedAt, r.inboundReplySentAt)
            r.replied = !oldReplied
            r.repliedAt = oldReplied ? nil : now.addingTimeInterval(-3_600)
            r.inboundReplySentAt = coin(0.5) ? r.repliedAt : nil
            return Op(kind: kind, label: "reply toggle", changed: [pid]) {
                r.replied = oldReplied
                r.repliedAt = oldAt
                r.inboundReplySentAt = oldInbound
                return [pid]
            }
        case .clock:
            let old = now
            let target: Date
            switch draw(7) {
            case 0: target = now.addingTimeInterval(61)
            case 1: target = now.addingTimeInterval(6 * 60)
            case 2: target = now.addingTimeInterval(86_400)
            case 3: target = now.addingTimeInterval(3 * 86_400)
            case 4: target = Phase0cRowBuild.nextEasternMidnight(after: now).addingTimeInterval(1)
            case 5:
                // Today crossing a row's opening night.
                guard let d = p.performanceDate, let night = EasternDate.date(from: d), night > now else { return nil }
                target = Phase0cRowBuild.nextEasternMidnight(after: night).addingTimeInterval(1)
            default:
                // Today crossing a row's lead-time edge.
                guard let d = p.performanceDate, let night = EasternDate.date(from: d) else { return nil }
                let edge = night.addingTimeInterval(-Double(QueueModel.leadTimeWindowDays) * 86_400)
                guard edge > now else { return nil }
                target = Phase0cRowBuild.nextEasternMidnight(after: edge).addingTimeInterval(1)
            }
            now = target
            return Op(kind: kind, label: "clock +\(Int(target.timeIntervalSince(old)))s", changed: []) {
                self.now = old; return []
            }
        case .replyRunAlive:
            replyRunAlive.toggle()
            return Op(kind: kind, label: "replyRunAlive toggle", changed: []) { self.replyRunAlive.toggle(); return [] }
        case .geo:
            let old = excludedTowns
            excludedTowns = old.isEmpty ? [Self.refusableTown] : []
            return Op(kind: kind, label: "geo refusal toggle", changed: []) { self.excludedTowns = old; return [] }
        case .presenter:
            let old = p.presenter
            p.presenter = pick(Self.presenters.filter { $0 != old })
            return Op(kind: kind, label: "presenter respelling", changed: [pid]) { p.presenter = old; return [pid] }
        case .inquiry:
            let q = pick(inquiries)
            let (oldSent, oldReplied, oldOutcome) = (q.sentAt, q.replied, q.outcomeRaw)
            switch draw(3) {
            case 0: q.sentAt = oldSent == nil ? now : nil
            case 1: q.replied = !oldReplied
            default: q.outcome = q.outcome == .booked ? .noResponse : .booked
            }
            return Op(kind: kind, label: "inquiry edit", changed: []) {
                q.sentAt = oldSent
                q.replied = oldReplied
                q.outcomeRaw = oldOutcome
                return []
            }
        case .collapsedFront:
            let drawn = Set(rows.filter { $0.statusRaw != "dismissed" }.map(\.naturalKey))
            let fronts = CanonicalOracle.showLinkCollapse(
                rows.sorted(by: CanonicalOracle.byNaturalKey).map(ShowLink.Row.init), drawn: drawn).fronts
            let candidates = fronts.keys.filter { drawn.contains($0) }.sorted()
            guard !candidates.isEmpty, let front = rowsByKey[pick(candidates)] else { return nil }
            let old = front.status
            front.status = .dismissed
            let fpid = front.persistentModelID
            return Op(kind: kind, label: "collapsed front dismissed", changed: [fpid]) {
                front.status = old; return [fpid]
            }
        case .refusal:
            let orgKey = OrgKey.stored(for: Self.larkPresenter) ?? ""
            let address = pick(["box@example.org", "desk@example.org"])
            let row = ContactRefusal.Ledger.Row(scopeRaw: "organisation", scopeId: orgKey, handleKey: address)
            let old = refusalRows
            if let i = refusalRows.firstIndex(of: row) { refusalRows.remove(at: i) } else { refusalRows.append(row) }
            return Op(kind: kind, label: "org refusal toggle", changed: []) { self.refusalRows = old; return [] }
        case .recipientFlag:
            guard let r = p.recipients.first else { return nil }
            let (oldState, oldClaim, oldDegraded, oldThreading, oldError) =
                (r.sendState, r.sendClaimedAt, r.replyTrackingDegraded, r.threadingDegraded, p.sendError)
            let oldRequested = r.replyDraftRequestedAt
            switch draw(5) {
            case 0:
                r.sendState = .sending
                r.sendClaimedAt = now.addingTimeInterval(-Double(draw(90)))
            case 1: r.replyTrackingDegraded.toggle()
            case 2: r.threadingDegraded.toggle()
            case 3: p.sendError = oldError == nil ? "refused" : nil
            default: r.replyDraftRequestedAt = oldRequested == nil ? now.addingTimeInterval(-Double(draw(600))) : nil
            }
            return Op(kind: kind, label: "recipient flag", changed: [pid]) {
                r.sendState = oldState
                r.sendClaimedAt = oldClaim
                r.replyTrackingDegraded = oldDegraded
                r.threadingDegraded = oldThreading
                r.replyDraftRequestedAt = oldRequested
                p.sendError = oldError
                return [pid]
            }
        case .insertRow:
            inserted += 1
            let fresh = makeRow(key: String(format: "row-new-%04d", inserted))
            // Half the time, a copy of an existing row's production, so it joins or splits a cluster.
            if coin(0.5) {
                fresh.groupName = p.groupName
                fresh.venue = p.venue
                fresh.performanceDate = p.performanceDate
                fresh.runEndDate = p.runEndDate
            }
            try? context.save()
            rows.append(fresh)
            let fpid = fresh.persistentModelID
            return Op(kind: kind, label: "insert row", changed: [fpid]) {
                self.rows.removeAll { $0 === fresh }
                self.context.delete(fresh)
                try? self.context.save()
                return [fpid]
            }
        case .producerOverride:
            let old = overrides
            let lark = ProducerGate.key(Self.larkPresenter) ?? ""
            let finch = ProducerGate.key("Finch Players") ?? ""
            if coin(0.5) {
                if overrides.demoted.contains(lark) { overrides.demoted.remove(lark) } else { overrides.demoted.insert(lark) }
            } else {
                if overrides.promoted.contains(finch) { overrides.promoted.remove(finch) } else { overrides.promoted.insert(finch) }
            }
            return Op(kind: kind, label: "producer override toggle", changed: []) { self.overrides = old; return [] }
        case .dateMove:
            let (oldDate, oldEnd) = (p.performanceDate, p.runEndDate)
            p.performanceDate = Self.day(draw(120) - 10, from: now)
            p.runEndDate = nil
            return Op(kind: kind, label: "date move", changed: [pid]) {
                p.performanceDate = oldDate
                p.runEndDate = oldEnd
                return [pid]
            }
        }
    }
}
