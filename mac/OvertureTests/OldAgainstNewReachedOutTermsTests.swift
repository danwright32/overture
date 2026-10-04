import Testing
import Foundation
import SwiftData

// #4357 (plan v7 Phase 3 step 2, oracle part one): TEMPORARY. The model only reached-out terms as they stood on
// 25daff53 (slice D1's head: ReachedOutQueue.swift, ReachedOutAction.swift, FollowUp.swift, PostEventPrompt.swift),
// copied verbatim bar their names and comments, run against the new generic terms through their model entry
// points over ONE frozen snapshot of the live clone and its fourfold copy. Its output is pasted into the PR,
// and then this file is deleted in the same PR (L613).
@MainActor
@Suite("Oracle part one for slice D2: the model only reached-out terms against the generic ones (#4357, temporary)")
final class OldAgainstNewReachedOutTermsTests {
    private let sandboxes = TemporarySandboxes()

    // MARK: the old terms, verbatim from 25daff53 bar names and comments.
    enum Old {
        static func nextReachOut(for r: Recipient, of p: Prospect, now: Date,
                                 followUpConfig: FollowUpConfig = .init()) -> Date? {
            NextReachOut.date(isInPlay: isInPlay(r, of: p), now: now) {
                let promptDate = nextPromptDate(for: r, of: p)
                return [.scheduled(nextFollowUp(for: r, now: now, config: followUpConfig)),
                        .scheduled(nextFormDecision(for: r, of: p, config: followUpConfig)),
                        .scheduled(promptDate),
                        r.hasUnhandledReply ? .waiting(since: r.replyArrivedAt) : .scheduled(nil),
                        .scheduled(EasternDate.date(from: p.performanceDate ?? ""))]
            }
        }

        static func isInPlay(_ r: Recipient, of p: Prospect) -> Bool {
            guard r.sentAt != nil else { return false }
            guard r.hasProvenOutreach else { return false }
            guard !p.isBooked else { return false }
            guard p.showOutcome == nil else { return false }
            return r.standing.isInPlay
        }

        static func activeWithDates(from prospects: [Prospect], now: Date,
                                    followUpConfig: FollowUpConfig = .init()) -> [(prospect: Prospect, recipient: Recipient, next: Date)] {
            prospects
                .compactMap { p -> (prospect: Prospect, recipient: Recipient, next: Date)? in
                    let live = p.recipients.compactMap { r -> (recipient: Recipient, next: Date)? in
                        nextReachOut(for: r, of: p, now: now, followUpConfig: followUpConfig)
                            .map { (recipient: r, next: $0) }
                    }
                    guard !live.isEmpty else { return nil }
                    let representative = live.filter { $0.recipient.replied }.min(by: Self.earlierReplier)
                        ?? live.min(by: Self.dueSooner)
                    guard let representative else { return nil }
                    guard let soonest = live.map(\.next).min() else { return nil }
                    return (prospect: p, recipient: representative.recipient, next: soonest)
                }
                .sorted { ($0.next, $0.prospect.naturalKey) < ($1.next, $1.prospect.naturalKey) }
        }

        private static func earlierReplier(_ a: (recipient: Recipient, next: Date),
                                           _ b: (recipient: Recipient, next: Date)) -> Bool {
            let (ra, rb) = (a.recipient.replyArrivedAt ?? .distantFuture, b.recipient.replyArrivedAt ?? .distantFuture)
            if ra != rb { return ra < rb }
            return addressThenIdentifier(a.recipient, b.recipient)
        }

        private static func dueSooner(_ a: (recipient: Recipient, next: Date),
                                      _ b: (recipient: Recipient, next: Date)) -> Bool {
            if a.next != b.next { return a.next < b.next }
            return addressThenIdentifier(a.recipient, b.recipient)
        }

        private static func addressThenIdentifier(_ a: Recipient, _ b: Recipient) -> Bool {
            let (ea, eb) = (a.email ?? "", b.email ?? "")
            if ea != eb { return ea < eb }
            return a.persistentModelID < b.persistentModelID
        }

        static func nextActionableMoment(for r: Recipient, of p: Prospect, now: Date,
                                         followUpConfig: FollowUpConfig = .init()) -> Date? {
            let nudge = FollowUp.nextDue(eligible: isAwaitingNudge(r, in: p, now: now), sentAt: r.sentAt,
                                         lastFollowUpAt: r.lastFollowUpAt, followUpCount: r.followUpCount,
                                         remindedAt: r.nudgeRemindedAt, config: followUpConfig)
            let candidates = [nudge,
                              nextFormDecision(for: r, of: p, config: followUpConfig),
                              nextPromptDate(for: r, of: p),
                              r.hasUnhandledReply ? r.replyArrivedAt : nil]
            return candidates.compactMap { $0 }.min()
        }

        static func timingLabel(for r: Recipient, of p: Prospect, now: Date, today: String,
                                followUpConfig: FollowUpConfig = .init()) -> String {
            if r.isUnwatchedFormPitch, let day = p.performanceDate,
               EasternDate.date(from: day) != nil {
                return ReachedOutQueue.formNightLabel(eventDay: day, today: today)
            }
            guard let next = nextActionableMoment(for: r, of: p, now: now, followUpConfig: followUpConfig) else {
                return ReachedOutQueue.heldOpenLabel
            }
            let action = actionOf(r, in: p, now: now, today: today, followUpConfig: followUpConfig)
            return ReachedOutQueue.timingLabel(next: next, now: now, awaitingDecision: !action.sendsAnEmail,
                                               decisionLabel: action == .sayHowItEnded
                                                ? ReachedOutQueue.endingLabel : ReachedOutQueue.decisionLabel)
        }

        static func isDueNow(for r: Recipient, of p: Prospect, now: Date,
                             followUpConfig: FollowUpConfig = .init()) -> Bool {
            guard let next = nextActionableMoment(for: r, of: p, now: now, followUpConfig: followUpConfig)
            else { return false }
            return ReachedOutQueue.isDueNow(next: next, now: now)
        }

        private static func nextFormDecision(for r: Recipient, of p: Prospect,
                                             config: FollowUpConfig) -> Date? {
            guard r.outreachChannel == .contactForm, let recordedAt = r.formOutreachRecordedAt else { return nil }
            if let night = ReachedOutQueue.formDecisionDate(eventDay: p.performanceDate) {
                return r.hasWatchableConversation ? nil : night
            }
            return recordedAt.addingTimeInterval(TimeInterval(config.gapDays) * 86_400)
        }

        private static func nextFollowUp(for r: Recipient, now: Date, config: FollowUpConfig) -> Date? {
            guard let sentAt = r.sentAt else { return nil }
            guard r.isAwaitingFollowUp else { return nil }
            guard r.followUpCount < config.maxFollowUps else { return nil }
            let lastTouch = r.lastFollowUpAt ?? sentAt
            return lastTouch.addingTimeInterval(TimeInterval(config.gapDays) * 86_400)
        }

        // FollowUp.swift
        static func isAwaitingNudge(_ r: Recipient, in p: Prospect, now: Date) -> Bool {
            guard p.status != .dismissed else { return false }
            guard r.isAwaitingFollowUp, !r.isOutreachStoodDown else { return false }
            guard !hasPerformed(p, now: now) else { return false }
            return !p.isOutreachStoodDown(asOf: r.repliedAt)
        }

        static func hasPerformed(_ p: Prospect, now: Date) -> Bool {
            EasternDate.runHasPassed(
                lastNight: EasternDate.runLastNight(runEndDate: p.runEndDate,
                                                    performanceDate: p.performanceDate),
                today: EasternDate.today(now))
        }

        // PostEventPrompt.swift
        static func nextPromptDate(for r: Recipient, of p: Prospect) -> Date? {
            guard p.showOutcome == nil else { return nil }
            guard p.status != .dismissed else { return nil }
            guard !p.isBooked else { return nil }
            guard r.sentAt != nil, r.hasProvenOutreach else { return nil }
            guard !r.bounced else { return nil }
            guard !r.isClosingNoteStoodDown else { return nil }
            guard let dayAfter = dayAfterShow(p.performanceDate) else { return nil }
            if let anchored = r.conversationRemindedAt, anchored >= dayAfter { return nil }
            return dayAfter
        }

        static func kind(for r: Recipient, of p: Prospect) -> PostEventPrompt.Kind {
            p.recipients.contains { $0.replied } ? .closeOut : .closeOutUnanswered
        }

        static func prompt(for r: Recipient, of p: Prospect, now: Date) -> PostEventPrompt.Prompt? {
            guard let due = nextPromptDate(for: r, of: p), now >= due else { return nil }
            let kind = kind(for: r, of: p)
            return PostEventPrompt.Prompt(kind: kind, reason: PostEventPrompt.reason(for: kind))
        }

        private static func dayAfterShow(_ performanceDate: String?) -> Date? {
            performanceDate
                .flatMap { EasternDate.date(from: $0) }
                .flatMap { EasternDate.calendar.date(byAdding: .day, value: 1, to: $0) }
        }

        // ReachedOutAction.swift
        static func actionOf(_ recipient: Recipient, in prospect: Prospect, now: Date, today: String,
                             followUpConfig: FollowUpConfig = .init()) -> ReachedOutAction {
            if recipient.isUnwatchedFormPitch {
                guard let next = nextReachOut(for: recipient, of: prospect, now: now,
                                              followUpConfig: followUpConfig),
                      ReachedOutQueue.isDueNow(next: next, now: now) else { return .none }
                return .sayWhatHappened
            }
            if prompt(for: recipient, of: prospect, now: now) != nil {
                return .sayHowItEnded
            }
            if FollowUp.isDue(eligible: isAwaitingNudge(recipient, in: prospect, now: now),
                              sentAt: recipient.sentAt, lastFollowUpAt: recipient.lastFollowUpAt,
                              followUpCount: recipient.followUpCount, remindedAt: recipient.nudgeRemindedAt,
                              now: now, config: followUpConfig) {
                return .sendNudge
            }
            return .none
        }
    }

    // MARK: the comparison

    @Test(.enabled(if: LiveStorePresence.exists, LiveStorePresence.absenceReason))
    func theGenericReachedOutTermsAnswerAsTheModelOnlyOnesDidOnOneFrozenSnapshot() async throws {
        await RealStoreTestLock.shared.acquire()
        do {
            let dir = try sandboxes.make(named: "old-against-new-reached-out")
            guard let base = try LiveStoreClone.makeClone(in: dir) else {
                throw LiveStoreClone.Refusal.backupFailed("no live store on this machine")
            }
            let corpora = [("live clone", base), ("4x", try Phase0.scaledCopy(of: base, factor: 4, in: dir))]
            let now = Date()
            let today = EasternDate.today(now)
            for (label, url) in corpora {
                let rows = try ModelContext(try Phase0.openContainer(at: url)).fetch(FetchDescriptor<Prospect>())
                #expect(!rows.isEmpty, "the \(label) holds no shows, so nothing below compared anything")
                var diff: [String] = []
                var contacts = 0
                var actions: [ReachedOutAction: Int] = [:]
                for p in rows {
                    for r in p.recipients {
                        contacts += 1
                        let id = "contact \(r.persistentModelID)"
                        func check<T: Equatable>(_ name: String, _ old: T, _ new: T) {
                            if old != new { diff.append("\(name) differs for \(id)") }
                        }
                        check("isInPlay", Old.isInPlay(r, of: p), ReachedOutQueue.isInPlay(r, of: p))
                        check("nextReachOut", Old.nextReachOut(for: r, of: p, now: now),
                              ReachedOutQueue.nextReachOut(for: r, of: p, now: now))
                        check("nextActionableMoment", Old.nextActionableMoment(for: r, of: p, now: now),
                              ReachedOutQueue.nextActionableMoment(for: r, of: p, now: now))
                        check("isDueNow", Old.isDueNow(for: r, of: p, now: now),
                              ReachedOutQueue.isDueNow(for: r, of: p, now: now))
                        check("timingLabel", Old.timingLabel(for: r, of: p, now: now, today: today),
                              ReachedOutQueue.timingLabel(for: r, of: p, now: now, today: today))
                        let action = ReachedOutAction.of(r, in: p, now: now, today: today)
                        check("action", Old.actionOf(r, in: p, now: now, today: today), action)
                        actions[action, default: 0] += 1
                        check("isAwaitingNudge", Old.isAwaitingNudge(r, in: p, now: now),
                              FollowUp.isAwaitingNudge(r, in: p, now: now))
                        check("nextPromptDate", Old.nextPromptDate(for: r, of: p),
                              PostEventPrompt.nextPromptDate(for: r, of: p))
                        check("prompt", Old.prompt(for: r, of: p, now: now),
                              PostEventPrompt.prompt(for: r, of: p, now: now))
                    }
                    if Old.hasPerformed(p, now: now) != FollowUp.hasPerformed(p, now: now) {
                        diff.append("hasPerformed differs for row \(p.persistentModelID)")
                    }
                }
                let old = Old.activeWithDates(from: rows, now: now)
                let new = ReachedOutQueue.activeWithDates(from: rows, now: now)
                if old.map({ "\($0.prospect.persistentModelID) \($0.recipient.persistentModelID) \($0.next)" })
                    != new.map({ "\($0.prospect.persistentModelID) \($0.recipient.persistentModelID) \($0.next)" }) {
                    diff.append("activeWithDates differs: \(old.count) row(s) old, \(new.count) new")
                }

                // Decision 5 (generic over models): the new entry points over models cost no more than the old.
                let oldT = Phase0.median5 { _ = Old.activeWithDates(from: rows, now: now) }
                let newT = Phase0.median5 { _ = ReachedOutQueue.activeWithDates(from: rows, now: now) }

                print("old against new, \(label): \(rows.count) row(s), \(contacts) contact(s), \(old.count) on the list, "
                      + "actions " + ReachedOutAction.allCases.map { "\($0) \(actions[$0] ?? 0)" }.joined(separator: ", ")
                      + ", \(diff.count) difference(s)")
                print("old against new, \(label): activeWithDates old \(oldT.text), new \(newT.text); load \(Phase0.load())")
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
