import Testing
import Foundation
import SwiftData

// #4357 (plan v7 Phase 3 step 2, oracle part one): TEMPORARY. The stage placement and every member slice E1
// moves onto the facts protocols, as their model only bodies stood on origin/main 5267382b (StageNavigation.swift,
// GeoRefusals.swift, ClientHorizon.swift, Prospect.swift, Recipient.swift), copied verbatim bar being written as
// functions of the model, run against the ported code over ONE frozen snapshot of the live clone and its fourfold
// copy. Its output is pasted into the PR, and then this file is deleted in the same PR (L613).
@MainActor
@Suite("Oracle part one for slice E1: the model only placement against the ported one (#4357, temporary)")
final class OldAgainstNewStagePlacementTests {
    private let sandboxes = TemporarySandboxes()

    // MARK: the old bodies, verbatim from 5267382b bar the receiver.
    enum Old {
        // Recipient.swift
        static func effectiveBody(_ r: Recipient) -> String? { r.prospect?.draftBody }
        static func draftLintBlockers(_ r: Recipient) -> [DraftIssue] {
            guard let body = effectiveBody(r), !body.isEmpty else { return [] }
            return DraftCheck.blockingFindings(in: body)
        }
        static func isLintOverridden(_ r: Recipient) -> Bool {
            r.lintOverriddenBody != nil && r.lintOverriddenBody == effectiveBody(r)
        }
        static func isBlockedByDraftLint(_ r: Recipient, lintBlockers: [DraftIssue]) -> Bool {
            !lintBlockers.isEmpty && !isLintOverridden(r)
        }
        static func draftIsMissingGreeting(_ r: Recipient) -> Bool {
            guard let body = effectiveBody(r), !body.isEmpty else { return false }
            return !DraftGreeting.opensWithAGreeting(body)
        }
        static func greetingMisaddressed(_ r: Recipient) -> Bool {
            guard let prospect = r.prospect else { return false }
            return greetingAudienceSize(prospect) > 1 && DraftGreeting.namesSomeone(effectiveBody(r))
        }
        static func greetingNamesSomeoneElse(_ r: Recipient) -> Bool {
            DraftGreeting.namesSomeoneElse(greeting: effectiveBody(r), contactName: r.name)
        }
        static func isGreetingOverridden(_ r: Recipient) -> Bool {
            r.greetingOverriddenBody != nil && r.greetingOverriddenBody == effectiveBody(r)
        }
        static func isBlockedByGreeting(_ r: Recipient) -> Bool {
            (draftIsMissingGreeting(r) || greetingMisaddressed(r) || greetingNamesSomeoneElse(r))
                && !isGreetingOverridden(r)
        }
        static func isLooksLikeAnotherPersons(_ r: Recipient) -> Bool {
            r.looksLikeAnotherPersons && !r.looksLikeAnotherPersonsDismissed
        }
        static func isBlockedAwaitingReview(_ r: Recipient, lintBlockers: [DraftIssue]) -> Bool {
            guard r.sendState == .pending, r.email?.isEmpty == false, !r.pausedByReply else { return false }
            return isBlockedByGreeting(r)
                || (r.looksLikeVenue && !r.looksLikeVenueDismissed)
                || (r.looksLikePressContact && !r.looksLikePressContactDismissed)
                || (r.looksLikeDuplicateContact && !r.looksLikeDuplicateContactDismissed)
                || isLooksLikeAnotherPersons(r)
                || isBlockedByDraftLint(r, lintBlockers: lintBlockers)
        }
        static func isSendStuck(_ r: Recipient, now: Date, timeout: TimeInterval = RunTimeouts.send) -> Bool {
            guard r.sendState == .sending, let claimed = r.sendClaimedAt else { return false }
            return now.timeIntervalSince(claimed) >= timeout
        }

        // Prospect.swift
        static func sendsTogether(_ p: Prospect) -> Bool { p.sendsTogetherOverride ?? true }
        static func greetingAudienceSize(_ p: Prospect) -> Int {
            let reachable = p.recipients.filter {
                $0.sendState == .pending && $0.email?.isEmpty == false && !$0.pausedByReply
            }
            return sendsTogether(p) ? reachable.count : min(reachable.count, 1)
        }
        static func blockedContactCount(_ p: Prospect) -> Int {
            p.recipients.filter { isBlockedAwaitingReview($0, lintBlockers: draftLintBlockers($0)) }.count
        }
        static func hasEnteredSendHalf(_ p: Prospect) -> Bool {
            SendHalf.entered(status: p.status, sentAt: p.sentAt,
                             hasSentRecipient: p.recipients.contains { $0.sendState == .sent })
        }
        static func hasOpened(_ p: Prospect, today: String) -> Bool {
            EasternDate.runHasOpened(openingNight: p.performanceDate, today: today)
        }
        static func hasDraft(_ p: Prospect) -> Bool { p.draftBody != nil }
        static func isReprepQueued(_ p: Prospect) -> Bool {
            ReprepRequest.isQueued(draftRequested: p.reprepDraftRequested,
                                   contactsRequested: p.reprepContactsRequested)
        }

        // ClientHorizon.swift and ClientWindow.swift
        static func isPastClientShow(_ p: Prospect, clientSourceIds: Set<String>) -> Bool {
            if p.priorRelationship == "booked" { return true }
            if let matched = p.matchedClientName, !matched.isEmpty { return true }
            return p.sourceIds.contains { clientSourceIds.contains($0) }
        }

        // GeoRefusals.swift
        static func hidesFromQueue(_ geo: GeoRefusals, _ p: Prospect) -> Bool {
            guard GeoRefusals.isOvertureToCut(p.status) else { return false }
            if p.keptVisibleAfterGenreChange {
                return geo.hidesFromQueue(location: p.location, discipline: .other)
            }
            return geo.hidesFromQueue(location: p.location,
                                      discipline: Discipline(rawValue: p.discipline) ?? .other)
        }

        // StageNavigation.swift
        static func isWithinLeadTime(_ p: Prospect, context: StageContext, clients: Set<String>) -> Bool {
            if QueueModel.isWithinOrdinaryLeadTime(performanceDate: p.performanceDate, today: context.today) {
                return true
            }
            return QueueModel.isOfferedEarlyAsAClient(performanceDate: p.performanceDate,
                                                      isPastClient: isPastClientShow(p, clientSourceIds: clients),
                                                      today: context.today)
        }

        static func matches(_ focus: StageFocus, _ p: Prospect, context: StageContext, clients: Set<String>) -> Bool {
            if hidesFromQueue(context.geo, p) { return false }
            switch focus {
            case .scout:
                return p.status == .new && !hasOpened(p, today: context.today)
                    && isWithinLeadTime(p, context: context, clients: clients)
            case .prep:
                return PrepQueueBuilder.needsPrepEligible(p, today: context.today)
            case .review:
                return (p.status == .drafted || p.status == .approved) && !isReprepQueued(p)
            case .sendApproved:
                return p.status == .approved && p.sentAt == nil
            case .sendBlocked:
                return blockedContactCount(p) > 0 && hasEnteredSendHalf(p)
            case .sendErrors:
                return p.sendError != nil
            case .sendStuck:
                return p.recipients.contains { isSendStuck($0, now: context.now) }
            case .sendDegraded:
                return p.recipients.contains { $0.replyTrackingDegraded }
            case .sendThreadingDegraded:
                return p.recipients.contains { $0.threadingDegraded }
            case .followUps, .reachedOut:
                return false
            }
        }

        static func focuses(_ p: Prospect, context: StageContext, clients: Set<String>) -> [StageFocus] {
            StageNavigation.countedFocuses.filter { matches($0, p, context: context, clients: clients) }
        }

        static func resolvedPlaceCount(_ geo: GeoRefusals, _ prospects: [Prospect]) -> Int {
            var seen = Set<String>()
            for p in prospects {
                let discipline = Discipline(rawValue: p.discipline) ?? .other
                seen.insert("\(discipline.rawValue)\u{1}\(p.location ?? "\u{0}")")
            }
            return seen.count
        }
    }

    // MARK: the comparison

    private static func differences(_ rows: [Prospect], context: StageContext, clients: Set<String>,
                                    trueCounts: inout [String: Int]) -> [String] {
        var diff: [String] = []
        let placed = StageNavigation.placements(in: rows, context: context)
        var newFocuses: [String: [StageFocus]] = [:]
        for focus in StageNavigation.countedFocuses {
            for key in StageNavigation.naturalKeys(for: focus, in: placed) { newFocuses[key, default: []].append(focus) }
        }
        for p in rows {
            let pid = String(describing: p.persistentModelID)
            let old = Old.focuses(p, context: context, clients: clients)
            if old != (newFocuses[p.naturalKey] ?? []) { diff.append("placement differs for row \(pid)") }
            for focus in old { trueCounts["focus \(focus.rawValue)", default: 0] += 1 }
            let pairs: [(String, Bool, Bool)] = [
                ("hasDraft", Old.hasDraft(p), p.hasDraft),
                ("hasOpened", Old.hasOpened(p, today: context.today), p.hasOpened(today: context.today)),
                ("isReprepQueued", Old.isReprepQueued(p), p.isReprepQueued),
                ("sendsTogether", Old.sendsTogether(p), p.sendsTogether),
                ("hasEnteredSendHalf", Old.hasEnteredSendHalf(p), p.hasEnteredSendHalf),
                ("hidesFromQueue", Old.hidesFromQueue(context.geo, p), context.geo.hidesFromQueue(p)),
                ("isPastClientShow", Old.isPastClientShow(p, clientSourceIds: clients), context.clients.isPastClientShow(p)),
            ]
            for (name, a, b) in pairs {
                if a != b { diff.append("\(name) differs for row \(pid)") }
                if a { trueCounts[name, default: 0] += 1 }
            }
            if Old.greetingAudienceSize(p) != p.greetingAudienceSize { diff.append("greetingAudienceSize differs for row \(pid)") }
            if Old.blockedContactCount(p) != p.blockedContactCount { diff.append("blockedContactCount differs for row \(pid)") }
            if Old.blockedContactCount(p) > 0 { trueCounts["blockedContactCount > 0", default: 0] += 1 }
            for r in p.recipients {
                let cid = String(describing: r.persistentModelID)
                let lint = Old.draftLintBlockers(r)
                let cpairs: [(String, Bool, Bool)] = [
                    ("isLooksLikeAnotherPersons", Old.isLooksLikeAnotherPersons(r), r.isLooksLikeAnotherPersons),
                    ("isSendStuck", Old.isSendStuck(r, now: context.now), r.isSendStuck(now: context.now)),
                    ("draftIsMissingGreeting", Old.draftIsMissingGreeting(r), r.draftIsMissingGreeting),
                    ("greetingMisaddressed", Old.greetingMisaddressed(r), r.greetingMisaddressed),
                    ("greetingNamesSomeoneElse", Old.greetingNamesSomeoneElse(r), r.greetingNamesSomeoneElse),
                    ("isGreetingOverridden", Old.isGreetingOverridden(r), r.isGreetingOverridden),
                    ("isBlockedByGreeting", Old.isBlockedByGreeting(r), r.isBlockedByGreeting),
                    ("isLintOverridden", Old.isLintOverridden(r), r.isLintOverridden),
                    ("isBlockedAwaitingReview", Old.isBlockedAwaitingReview(r, lintBlockers: lint),
                     r.isBlockedAwaitingReview(lintBlockers: r.draftLintBlockers)),
                ]
                for (name, a, b) in cpairs {
                    if a != b { diff.append("\(name) differs for contact \(cid)") }
                    if a { trueCounts[name, default: 0] += 1 }
                }
                if lint != r.draftLintBlockers { diff.append("draftLintBlockers differs for contact \(cid)") }
            }
        }
        if Old.resolvedPlaceCount(context.geo, rows) != context.resolvingPlaces(of: rows).geo.resolvedPlaceCount {
            diff.append("resolvingPlaces resolved a different number of places")
        }
        return diff
    }

    @Test(.enabled(if: LiveStorePresence.exists, LiveStorePresence.absenceReason))
    func thePortedPlacementAnswersAsTheModelOnlyOneDidOnOneFrozenSnapshot() async throws {
        await RealStoreTestLock.shared.acquire()
        do {
            let dir = try sandboxes.make(named: "old-against-new-stage-placement")
            guard let base = try LiveStoreClone.makeClone(in: dir) else {
                throw LiveStoreClone.Refusal.backupFailed("no live store on this machine")
            }
            let corpora = [("live clone", base), ("4x", try Phase0.scaledCopy(of: base, factor: 4, in: dir))]
            for (label, url) in corpora {
                let context0 = ModelContext(try Phase0.openContainer(at: url))
                let rows = try context0.fetch(FetchDescriptor<Prospect>())
                #expect(!rows.isEmpty, "the \(label) holds no shows, so nothing below compared anything")
                let excluded = Set(try context0.fetch(FetchDescriptor<ExcludedTown>()).map(\.town))
                let allowed = Set(try context0.fetch(FetchDescriptor<AllowedSeedTown>()).map(\.town))
                // Every other source id is a client's, so the client arm is asked on both sides of its line.
                let sources = Set(rows.flatMap(\.sourceIds)).sorted()
                let clients = Set(sources.enumerated().filter { $0.offset % 2 == 0 }.map(\.element))
                var diff: [String] = []
                var trueCounts: [String: Int] = [:]
                // Two days: today, and a day four months back, so rows that have since opened are judged while
                // still ahead too. Dan's own town refusals from the clone, so his arm of the gate is asked.
                for day in [EasternDate.today(Date()), EasternDate.today(Date().addingTimeInterval(-120 * 86_400))] {
                    let now = (EasternDate.date(from: day) ?? Date()).addingTimeInterval(12 * 3600)
                    let context = StageContext(now: now,
                                               geo: GeoRefusals(userExcludedTowns: excluded, allowedSeedTowns: allowed),
                                               clients: ClientWindow(clientSourceIds: clients), today: day)
                    diff += Self.differences(rows, context: context, clients: clients, trueCounts: &trueCounts)
                }
                let contacts = rows.reduce(0) { $0 + $1.recipients.count }
                print("old against new, \(label): \(rows.count) row(s), \(contacts) contact(s), \(diff.count) difference(s)")
                print("old against new, \(label): true counts "
                      + trueCounts.keys.sorted().map { "\($0) \(trueCounts[$0] ?? 0)" }.joined(separator: ", "))
                for line in diff.prefix(20) { print("old against new, \(label): " + line) }
                #expect(diff.isEmpty, Comment(rawValue: diff.prefix(20).joined(separator: "\n")))
            }
            await RealStoreTestLock.shared.release()
        } catch {
            await RealStoreTestLock.shared.release()
            throw error
        }
    }
}
