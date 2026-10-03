import Testing
import Foundation
import SwiftData

// #4357 (plan v7 Phase 3 step 2, oracle part one): TEMPORARY. The computed members slice D1 moves onto the facts
// protocols, as their model only bodies stood on origin/main 5b368ba9 (Recipient.swift, FormOutreach.swift,
// ReplyWatchable.swift, PerformanceStatus.swift, Prospect.swift), copied verbatim bar being written as
// functions of the model, run against the protocol bodies over ONE frozen snapshot of the live clone and its
// fourfold copy. Its output is pasted into the PR, and then this file is deleted in the same PR (L613).
@MainActor
@Suite("Oracle part one for slice D1: the model only members against the facts protocol bodies (#4357, temporary)")
final class OldAgainstNewFactsMembersTests {
    private let sandboxes = TemporarySandboxes()

    // MARK: the old bodies, verbatim from 5b368ba9 bar the receiver.
    enum Old {
        static func sendState(_ r: Recipient) -> SendState { SendState(rawValue: r.sendStateRaw) ?? .pending }
        static func resolution(_ r: Recipient) -> RecipientResolution? { r.resolutionRaw.flatMap(RecipientResolution.init) }
        static func outcomeSource(_ r: Recipient) -> OutcomeSource? { r.outcomeSourceRaw.flatMap(OutcomeSource.init) }
        static func outreachChannel(_ r: Recipient) -> OutreachChannel {
            r.outreachChannelRaw.flatMap(OutreachChannel.init) ?? .email
        }
        static func hasWatchableConversation(_ r: Recipient) -> Bool {
            guard let t = r.gmailThreadId else { return false }
            return !t.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        static func isUnwatchedFormPitch(_ r: Recipient) -> Bool {
            outreachChannel(r) == .contactForm && !hasWatchableConversation(r)
        }
        static func hasProvenOutreach(_ r: Recipient) -> Bool {
            if r.formOutreachRecordedAt != nil { return true }
            return r.gmailMessageId != nil && (r.email?.isEmpty == false)
        }
        static func isSilent(_ r: Recipient) -> Bool { sendState(r) == .sent && !r.replied && !r.bounced }
        static func replyWatchConversationIsAttached(_ r: Recipient) -> Bool {
            guard hasWatchableConversation(r) else { return false }
            if r.attachDisplacedThreadId != nil { return r.gmailMessageId == r.attachDisplacedMessageId }
            return outreachChannel(r) == .contactForm && r.gmailMessageId == nil
        }
        static func isAwaitingFollowUp(_ r: Recipient) -> Bool {
            isSilent(r) && resolution(r) == nil && outcomeSource(r) != .manual && outreachChannel(r) == .email
                && !replyWatchConversationIsAttached(r)
        }
        static func replyArrivedAt(_ r: Recipient) -> Date? { r.inboundReplySentAt ?? r.repliedAt }
        static func hasUnhandledReply(_ r: Recipient) -> Bool {
            guard r.replied, resolution(r) == nil, !r.bounced else { return false }
            guard let handled = r.replyHandledAt else { return true }
            guard let theirs = replyArrivedAt(r) else { return false }
            return theirs > handled
        }
        static func standing(_ r: Recipient) -> RecipientStanding {
            let reachable = (r.email?.isEmpty == false) || (r.contactFormURL?.isEmpty == false)
            return RecipientStanding(sendState: sendState(r), resolution: resolution(r), bounced: r.bounced,
                                     hasContactPath: reachable)
        }
        static func isClosingNoteStoodDown(_ r: Recipient) -> Bool {
            guard let stoodDown = r.closingNoteStoodDownAt else { return false }
            if let repliedAt = r.repliedAt, repliedAt > stoodDown { return false }
            return true
        }
        static func isOutreachStoodDown(_ r: Recipient) -> Bool {
            guard let stoodDown = r.outreachStoodDownAt else { return false }
            if let repliedAt = r.repliedAt, repliedAt > stoodDown { return false }
            return true
        }

        static func status(_ p: Prospect) -> ReviewStatus { ReviewStatus(rawValue: p.statusRaw) ?? .new }
        static func showOutcome(_ p: Prospect) -> ShowOutcome? { p.showOutcomeRaw.flatMap(ShowOutcome.init(rawValue:)) }
        static func outcome(_ p: Prospect) -> Outcome { Outcome.fromStored(p.outcomeRaw) }
        static func performanceStatus(_ p: Prospect) -> PerformanceStatus {
            if let recorded = showOutcome(p)?.asPerformanceStatus { return recorded }
            return PerformanceStatus.derive(p.recipients.map(standing), leadBooked: outcome(p) == .booked)
        }
        static func isBooked(_ p: Prospect) -> Bool { performanceStatus(p) == .booked }
        static func isOutreachStoodDown(_ p: Prospect, asOf repliedAt: Date?) -> Bool {
            guard let stoodDown = p.outreachStoodDownAt else { return false }
            if let repliedAt, repliedAt > stoodDown { return false }
            return true
        }

        // Both sides through ONE renderer, so a difference is in the value and never in how an optional
        // enum prints (the first run read 994 of these, every one a rendering artifact).
        private static func t(_ value: Any) -> String { OldAgainstNewFactsMembersTests.text(value) }

        static func contact(_ r: Recipient) -> [String: String] {
            ["sendState": t(sendState(r)), "resolution": t(resolution(r)),
             "outcomeSource": t(outcomeSource(r)), "outreachChannel": t(outreachChannel(r)),
             "hasWatchableConversation": t(hasWatchableConversation(r)),
             "isUnwatchedFormPitch": t(isUnwatchedFormPitch(r)), "hasProvenOutreach": t(hasProvenOutreach(r)),
             "isSilent": t(isSilent(r)), "replyWatchConversationIsAttached": t(replyWatchConversationIsAttached(r)),
             "isAwaitingFollowUp": t(isAwaitingFollowUp(r)), "replyArrivedAt": t(replyArrivedAt(r)),
             "hasUnhandledReply": t(hasUnhandledReply(r)), "standing": t(standing(r)),
             "isOutreachStoodDown": t(isOutreachStoodDown(r)), "isClosingNoteStoodDown": t(isClosingNoteStoodDown(r))]
        }

        static func show(_ p: Prospect) -> [String: String] {
            ["status": t(status(p)), "showOutcome": t(showOutcome(p)), "outcome": t(outcome(p)),
             "performanceStatus": t(performanceStatus(p)), "isBooked": t(isBooked(p)),
             "stoodDownBeforeAnyReply": t(isOutreachStoodDown(p, asOf: nil)),
             "stoodDownAfterEveryReply": t(isOutreachStoodDown(p, asOf: .distantFuture))]
        }
    }

    // The new side, read through the protocols, rendered the same way.
    static func rendered(_ value: Any) -> [String: String] {
        Dictionary(uniqueKeysWithValues: Mirror(reflecting: value).children.compactMap { child in
            child.label.map { ($0, Self.text(child.value)) }
        })
    }

    nonisolated static func text(_ value: Any) -> String {
        // Optionals render as `Optional(x)` or `nil` on both sides, matching `String(describing:)` above.
        let mirror = Mirror(reflecting: value)
        if mirror.displayStyle == .optional { return mirror.children.first.map { "Optional(\($0.value))" } ?? "nil" }
        return "\(value)"
    }

    @Test(.enabled(if: LiveStorePresence.exists, LiveStorePresence.absenceReason))
    func theProtocolBodiesAnswerAsTheModelOnlyOnesDidOnOneFrozenSnapshot() async throws {
        await RealStoreTestLock.shared.acquire()
        do {
            let dir = try sandboxes.make(named: "old-against-new-facts-members")
            guard let base = try LiveStoreClone.makeClone(in: dir) else {
                throw LiveStoreClone.Refusal.backupFailed("no live store on this machine")
            }
            let corpora = [("live clone", base), ("4x", try Phase0.scaledCopy(of: base, factor: 4, in: dir))]
            for (label, url) in corpora {
                let rows = try ModelContext(try Phase0.openContainer(at: url)).fetch(FetchDescriptor<Prospect>())
                #expect(!rows.isEmpty, "the \(label) holds no shows, so nothing below compared anything")
                var diff: [String] = []
                var contacts = 0
                var trueCounts: [String: Int] = [:]
                for p in rows {
                    let old = Old.show(p), new = Self.rendered(TermsOverFacts.ShowMembers(p))
                    for key in old.keys.sorted() where old[key] != new[key] {
                        diff.append("\(key) differs for row \(p.persistentModelID)")
                    }
                    for r in p.recipients {
                        contacts += 1
                        let oldC = Old.contact(r), newC = Self.rendered(TermsOverFacts.ContactMembers(r))
                        for key in oldC.keys.sorted() where oldC[key] != newC[key] {
                            diff.append("\(key) differs for contact \(r.persistentModelID)")
                        }
                        for (key, value) in oldC where value == "true" { trueCounts[key, default: 0] += 1 }
                    }
                    for (key, value) in old where value == "true" { trueCounts[key, default: 0] += 1 }
                }
                // Every key the two sides render must be the same set, or a member compared nothing (L98).
                if let p = rows.first, let r = rows.lazy.flatMap(\.recipients).first {
                    #expect(Set(Old.show(p).keys) == Set(Self.rendered(TermsOverFacts.ShowMembers(p)).keys))
                    #expect(Set(Old.contact(r).keys) == Set(Self.rendered(TermsOverFacts.ContactMembers(r)).keys))
                }
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
