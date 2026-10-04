import Testing
import Foundation
import SwiftData

// #4357 (plan v7 Phase 3 step 2, oracle part one): TEMPORARY. The slice E2 terms as they stood at 50676275
// (DueWork.swift, FollowUp.dueRecipients, PostEventPrompt.dueRecipients, ProposedConversation.dueRecipients
// and the state it reads, ReplySearchScope.inScope, ReplyToAnswer.dueConversations, Prospect.hasUnhandledReply,
// ReplyIdentity.answering, the three SendGroup helpers, and the reply watch members), copied verbatim bar names
// and comments, run against the generic terms through their model entry points over ONE frozen snapshot of
// the live clone and its fourfold copy. Its output is pasted into the PR, and then this file is deleted in
// the same PR (L613).
@MainActor
@Suite("Oracle part one for slice E2: the model only due work terms against the generic ones (#4357, temporary)")
final class OldAgainstNewDueWorkTermsTests {
    private let sandboxes = TemporarySandboxes()

    enum Old {
        static func replyWatchManualOutcome(_ p: Prospect) -> Bool { p.outcomeSourceRaw == OutcomeSource.manual.rawValue }
        static func replyWatchIsBooked(_ p: Prospect) -> Bool { p.outcome == .booked }
        static func replyWatchManualOutcome(_ r: Recipient) -> Bool { r.outcomeSourceRaw == OutcomeSource.manual.rawValue }
        static func replyWatchIsBooked(_ r: Recipient) -> Bool { r.resolution == .booked }
        static func replyWatchConversationIsOpen(_ r: Recipient) -> Bool { r.resolution == nil && !r.bounced }

        static func peers(of recipient: Recipient, in prospect: Prospect) -> [Recipient] {
            guard let id = recipient.sendGroupId, !id.isEmpty else { return [recipient] }
            return prospect.recipients.filter { $0.sendGroupId == id }.sorted { $0.id < $1.id }
        }

        static func groupKey(_ recipient: Recipient) -> String {
            if let id = recipient.sendGroupId, !id.isEmpty { return id }
            return recipient.id
        }

        static func oneRowPerGroup<T>(_ qualifying: [T], recipient: (T) -> Recipient) -> [T] {
            var seen = Set<String>()
            return qualifying
                .sorted { recipient($0).id < recipient($1).id }
                .filter { seen.insert(groupKey(recipient($0))).inserted }
        }

        static func answering(for recipient: Recipient, in prospect: Prospect) -> Recipient {
            guard recipient.hasUnhandledReply, let writer = recipient.replyFromAddress, !writer.isEmpty else {
                return recipient
            }
            return peers(of: recipient, in: prospect)
                .first { ReplyDetection.isSameAddress($0.email, writer) } ?? recipient
        }

        static func hasUnhandledReply(_ p: Prospect) -> Bool {
            p.performanceStatus != .booked && p.recipients.contains(where: \.hasUnhandledReply)
        }

        static func inScope(_ r: Recipient, now: Date) -> Bool {
            guard let pitchedAt = r.formOutreachRecordedAt else { return false }
            guard !r.hasWatchableConversation else { return false }
            guard replyWatchConversationIsOpen(r), !replyWatchManualOutcome(r), !replyWatchIsBooked(r) else {
                return false
            }
            return now.timeIntervalSince(pitchedAt) < ReplySearchScope.horizon
        }

        static func stored(on r: Recipient) -> ProposedConversation.Candidate? {
            guard let messageId = r.replyProposedMessageId,
                  let threadId = r.replyProposedThreadId,
                  let from = r.replyProposedFromAddress,
                  let sentAt = r.replyProposedSentAt else { return nil }
            return ProposedConversation.Candidate(messageId: messageId, threadId: threadId, fromAddress: from,
                                                  fromName: r.replyProposedFromName, subject: r.replyProposedSubject ?? "",
                                                  sentAt: sentAt, score: r.replyProposedScore)
        }

        static func declined(_ r: Recipient) -> Set<String> { Set(r.dismissedConversationIds ?? []) }

        static func isAskable(_ r: Recipient) -> Bool {
            r.formOutreachRecordedAt != nil && !r.hasWatchableConversation
        }

        static func state(of r: Recipient, now: Date) -> ProposedConversation.State {
            if r.conversationAttachedAt != nil {
                return r.hasUnhandledReply ? .attachedAwaitingAnswer : .attachedAndAnswered
            }
            guard isAskable(r) else { return .notApplicable }
            if r.replyMarkedByHandAt != nil { return .notApplicable }
            if let c = stored(on: r) { return .proposed(c) }
            if !declined(r).isEmpty { return .allDeclined }
            guard inScope(r, now: now) else { return .stoppedLooking }
            return .none(searched: r.replyCandidateSearchedAt != nil)
        }

        static func confirm(from prospects: [Prospect], now: Date) -> [ProposedConversation.DueRecipient] {
            prospects.flatMap { p -> [ProposedConversation.DueRecipient] in
                guard !replyWatchManualOutcome(p), !replyWatchIsBooked(p) else { return [] }
                return p.recipients.compactMap { r in
                    guard case .proposed(let c) = state(of: r, now: now) else { return nil }
                    guard replyWatchConversationIsOpen(r) else { return nil }
                    return ProposedConversation.DueRecipient(prospect: p, recipient: r, candidate: c)
                }
            }
        }

        static func replies(prospects: [Prospect], inquiries: [Inquiry]) -> [ReplyToAnswer.DueConversation] {
            var due: [ReplyToAnswer.DueConversation] = []
            for p in prospects where hasUnhandledReply(p) {
                let waiting = p.recipients.filter(\.hasUnhandledReply)
                for member in oneRowPerGroup(waiting, recipient: { $0 }) {
                    due.append(.show(prospect: p, recipient: answering(for: member, in: p)))
                }
            }
            due.append(contentsOf: inquiries.filter(\.hasUnhandledReply).map { .inquiry($0) })
            return due.sorted { ($0.arrivedAt ?? .distantPast) < ($1.arrivedAt ?? .distantPast) }
        }

        static func afterTheShow(from prospects: [Prospect], now: Date) -> [PostEventPrompt.DueRecipient] {
            var due: [PostEventPrompt.DueRecipient] = []
            for p in prospects {
                let here = p.recipients.compactMap { r -> PostEventPrompt.DueRecipient? in
                    PostEventPrompt.prompt(for: r, of: p, now: now).map { PostEventPrompt.DueRecipient(prospect: p, recipient: r, prompt: $0) }
                }
                due.append(contentsOf: oneRowPerGroup(here) { $0.recipient })
            }
            return due.sorted {
                let ra = PostEventPrompt.urgencyRank($0.prompt.kind), rb = PostEventPrompt.urgencyRank($1.prompt.kind)
                if ra != rb { return ra < rb }
                return ($0.prospect.performanceDate ?? "9999") < ($1.prospect.performanceDate ?? "9999")
            }
        }

        static func silent(from prospects: [Prospect], now: Date, config: FollowUpConfig = .init()) -> [FollowUp.DueRecipient] {
            var due: [FollowUp.DueRecipient] = []
            for p in prospects {
                if p.outcomeSourceRaw == OutcomeSource.manual.rawValue || p.outcome == .booked { continue }
                let dueHere = p.recipients.filter { r in
                    FollowUp.isDue(eligible: FollowUp.isAwaitingNudge(r, in: p, now: now), sentAt: r.sentAt,
                                   lastFollowUpAt: r.lastFollowUpAt, followUpCount: r.followUpCount,
                                   remindedAt: r.nudgeRemindedAt, now: now, config: config)
                }
                due.append(contentsOf: oneRowPerGroup(dueHere) { $0 }
                    .map { FollowUp.DueRecipient(prospect: p, recipient: $0) })
            }
            return due
        }

        static func rows(prospects: [Prospect], inquiries: [Inquiry], now: Date, replyRunAlive: Bool,
                         followUp: FollowUpConfig = .init()) -> DueWork.Rows {
            let toConfirm = confirm(from: prospects, now: now)
            let confirmKeys = Set(toConfirm.map(\.recipient.id))
            let stalled = StalledReplyDraft.dueRecipients(from: prospects, now: now, runAlive: replyRunAlive)
            let stalledConversations = Set(stalled.map { groupKey($0.recipient) })
            let replies = replies(prospects: prospects, inquiries: inquiries)
                .filter { conversation in
                    guard case .show(_, let r) = conversation else { return true }
                    return !stalledConversations.contains(groupKey(r))
                }
            let waitingConversations = Set(replies.compactMap { conversation -> String? in
                guard case .show(let p, let r) = conversation else { return nil }
                return "\(p.naturalKey)|\(groupKey(r))"
            })
            return DueWork.Rows(afterTheShow: afterTheShow(from: prospects, now: now)
                    .filter { !confirmKeys.contains($0.recipient.id) }
                    .filter { !waitingConversations.contains("\($0.prospect.naturalKey)|\(groupKey($0.recipient))") },
                 silent: silent(from: prospects, now: now, config: followUp)
                    .sorted { ($0.recipient.sentAt ?? .distantPast) < ($1.recipient.sentAt ?? .distantPast) },
                 stalledReplyDrafts: stalled,
                 conversationsToConfirm: toConfirm,
                 repliesToAnswer: replies)
        }

        static func nextChange(prospects: [Prospect], now: Date, replyRunAlive: Bool,
                               followUp: FollowUpConfig = .init()) -> Date? {
            var soonest: Date?
            func consider(_ moment: Date?) {
                guard let moment, moment > now else { return }
                if let best = soonest, best <= moment { return }
                soonest = moment
            }
            for p in prospects {
                let followUpsStopped = p.outcomeSourceRaw == OutcomeSource.manual.rawValue || p.outcome == .booked
                for r in p.recipients {
                    consider(PostEventPrompt.nextPromptDate(for: r, of: p))
                    if !followUpsStopped {
                        consider(FollowUp.nextDue(eligible: FollowUp.isAwaitingNudge(r, in: p, now: now),
                                                  sentAt: r.sentAt, lastFollowUpAt: r.lastFollowUpAt,
                                                  followUpCount: r.followUpCount,
                                                  remindedAt: r.nudgeRemindedAt, config: followUp))
                    }
                    if !replyRunAlive, let requested = r.awaitedReplyDraftRequestedAt {
                        consider(requested.addingTimeInterval(Recipient.replyDraftStallTimeout))
                    }
                }
            }
            return soonest
        }
    }

    /// Each list as lines of identifiers and the value it carries, in order. Compared, never printed.
    static func lines(_ rows: DueWork.Rows) -> [String: [String]] {
        func id(_ p: Prospect, _ r: Recipient) -> String { "\(p.persistentModelID) \(r.persistentModelID)" }
        return [
            "afterTheShow": rows.afterTheShow.map { "\(id($0.prospect, $0.recipient)) \($0.prompt)" },
            "silent": rows.silent.map { id($0.prospect, $0.recipient) },
            "stalledReplyDrafts": rows.stalledReplyDrafts.map { "\(id($0.prospect, $0.recipient)) \($0.requestedAt)" },
            "conversationsToConfirm": rows.conversationsToConfirm.map { "\(id($0.prospect, $0.recipient)) \($0.candidate)" },
            "repliesToAnswer": rows.repliesToAnswer.map { "\($0.id)" },
        ]
    }

    @Test(.enabled(if: LiveStorePresence.exists, LiveStorePresence.absenceReason))
    func theGenericDueWorkTermsAnswerAsTheModelOnlyOnesDidOnOneFrozenSnapshot() async throws {
        await RealStoreTestLock.shared.acquire()
        do {
            let dir = try sandboxes.make(named: "old-against-new-due-work")
            guard let base = try LiveStoreClone.makeClone(in: dir) else {
                throw LiveStoreClone.Refusal.backupFailed("no live store on this machine")
            }
            let corpora = [("live clone", base), ("4x", try Phase0.scaledCopy(of: base, factor: 4, in: dir))]
            let now = Date()
            for (label, url) in corpora {
                let ctx = ModelContext(try Phase0.openContainer(at: url))
                let rows = try ctx.fetch(FetchDescriptor<Prospect>())
                let inquiries = try ctx.fetch(FetchDescriptor<Inquiry>())
                #expect(!rows.isEmpty, "the \(label) holds no shows, so nothing below compared anything")
                var diff: [String] = []
                var sizes: [String] = []
                for (instant, when) in [(now, "now"), (Date.distantFuture, "at the end of time")] {
                    for alive in [false, true] {
                        let old = Old.rows(prospects: rows, inquiries: inquiries, now: instant, replyRunAlive: alive)
                        let new = DueWork.rows(prospects: rows, inquiries: inquiries, now: instant, replyRunAlive: alive)
                        let oldLines = Self.lines(old), newLines = Self.lines(new)
                        for list in oldLines.keys.sorted() where oldLines[list] != newLines[list] {
                            diff.append("DueWork.rows \(list) differs \(when), alive \(alive): "
                                        + "\(oldLines[list]?.count ?? 0) old, \(newLines[list]?.count ?? 0) new")
                        }
                        if !alive {
                            sizes.append("\(when): " + oldLines.keys.sorted().map { "\($0) \(oldLines[$0]?.count ?? 0)" }
                                .joined(separator: ", "))
                        }
                    }
                }
                for (instant, when) in [(now, "now"), (Date(timeIntervalSince1970: 0), "from 1970")] {
                    for alive in [false, true] {
                        let old = Old.nextChange(prospects: rows, now: instant, replyRunAlive: alive)
                        let new = DueWork.nextChange(prospects: rows, now: instant, replyRunAlive: alive)
                        if old != new { diff.append("DueWork.nextChange differs \(when), alive \(alive)") }
                    }
                }
                var states = 0
                for p in rows {
                    if Old.hasUnhandledReply(p) != p.hasUnhandledReply {
                        diff.append("Prospect.hasUnhandledReply differs for row \(p.persistentModelID)")
                    }
                    if Old.replyWatchManualOutcome(p) != p.replyWatchManualOutcome || Old.replyWatchIsBooked(p) != p.replyWatchIsBooked {
                        diff.append("the show's reply watch members differ for row \(p.persistentModelID)")
                    }
                    for r in p.recipients {
                        if Old.state(of: r, now: now) != ProposedConversation.state(of: r, now: now) {
                            diff.append("ProposedConversation.state differs for contact \(r.persistentModelID)")
                        }
                        if Old.state(of: r, now: now) != .notApplicable { states += 1 }
                        if Old.inScope(r, now: now) != ReplySearchScope.inScope(r, now: now) {
                            diff.append("ReplySearchScope.inScope differs for contact \(r.persistentModelID)")
                        }
                        if Old.answering(for: r, in: p).persistentModelID != ReplyIdentity.answering(for: r, in: p).persistentModelID {
                            diff.append("ReplyIdentity.answering differs for contact \(r.persistentModelID)")
                        }
                        if Old.replyWatchConversationIsOpen(r) != r.replyWatchConversationIsOpen
                            || Old.replyWatchManualOutcome(r) != r.replyWatchManualOutcome
                            || Old.replyWatchIsBooked(r) != r.replyWatchIsBooked {
                            diff.append("the contact's reply watch members differ for contact \(r.persistentModelID)")
                        }
                    }
                }

                let oldT = Phase0.median5 {
                    _ = Old.rows(prospects: rows, inquiries: inquiries, now: now, replyRunAlive: false)
                    _ = Old.nextChange(prospects: rows, now: now, replyRunAlive: false)
                }
                let newT = Phase0.median5 {
                    _ = DueWork.rows(prospects: rows, inquiries: inquiries, now: now, replyRunAlive: false)
                    _ = DueWork.nextChange(prospects: rows, now: now, replyRunAlive: false)
                }
                print("old against new, \(label): \(rows.count) row(s), \(inquiries.count) inquir(ies), "
                      + "\(states) contact(s) with a conversation state, \(diff.count) difference(s)")
                for line in sizes { print("old against new, \(label): lists " + line) }
                print("old against new, \(label): rows and nextChange old \(oldT.text), new \(newT.text); load \(Phase0.load())")
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
