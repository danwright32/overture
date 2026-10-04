import Testing
import Foundation
import SwiftData

// #4357 (plan v7 Phase 3 step 2, oracle part one): TEMPORARY. The slice F terms as they stood on origin/main
// 9c220c02 (DraftedDeadEnd.swift, StalledReplyDraft.swift, Recipient.swift's two reply draft members, and the
// `organisationRowCounts` call site in QueueView+Model.swift), copied verbatim bar names and comments, run
// against the generic terms through their model entry points over ONE frozen snapshot of the live clone and
// its fourfold copy. Its output is pasted into the PR, and then this file is deleted in the same PR (L613).
@MainActor
@Suite("Oracle part one for slice F: the model only agent input terms against the generic ones (#4357, temporary)")
final class OldAgainstNewAgentInputTermsTests {
    private let sandboxes = TemporarySandboxes()

    enum Old {
        static func hasNobodyToSendTo(_ p: Prospect) -> Bool {
            p.status == .drafted && p.recipients.isEmpty
        }

        static func count(in prospects: [Prospect]) -> Int {
            prospects.filter(hasNobodyToSendTo).count
        }

        static func awaitedReplyDraftRequestedAt(_ r: Recipient) -> Date? {
            ReplyDraftRequest.awaited(requestedAt: r.replyDraftRequestedAt, draftBody: r.replyDraftBody,
                                      replacingDraftOnFile: r.replyDraftReplacesDraftOnFile,
                                      answeredAt: r.replyHandledAt)
        }

        static func isReplyDraftStalled(_ r: Recipient, now: Date, timeout: TimeInterval = Recipient.replyDraftStallTimeout,
                                        runAlive: Bool = false) -> Bool {
            guard let requested = awaitedReplyDraftRequestedAt(r) else { return false }
            return !runAlive && now.timeIntervalSince(requested) >= timeout
        }

        static func dueRecipients(from prospects: [Prospect], now: Date, runAlive: Bool) -> [StalledReplyDraft.DueRecipient] {
            prospects
                .flatMap { p in
                    p.recipients
                        .filter { isReplyDraftStalled($0, now: now, runAlive: runAlive) }
                        .compactMap { r in
                            r.replyDraftRequestedAt.map { StalledReplyDraft.DueRecipient(prospect: p, recipient: r, requestedAt: $0) }
                        }
                }
                .sorted { $0.requestedAt < $1.requestedAt }
        }
    }

    @Test(.enabled(if: LiveStorePresence.exists, LiveStorePresence.absenceReason))
    func theGenericAgentInputTermsAnswerAsTheModelOnlyOnesDidOnOneFrozenSnapshot() async throws {
        await RealStoreTestLock.shared.acquire()
        do {
            let dir = try sandboxes.make(named: "old-against-new-agent-inputs")
            guard let base = try LiveStoreClone.makeClone(in: dir) else {
                throw LiveStoreClone.Refusal.backupFailed("no live store on this machine")
            }
            let corpora = [("live clone", base), ("4x", try Phase0.scaledCopy(of: base, factor: 4, in: dir))]
            let now = Date()
            for (label, url) in corpora {
                let rows = try ModelContext(try Phase0.openContainer(at: url)).fetch(FetchDescriptor<Prospect>())
                #expect(!rows.isEmpty, "the \(label) holds no shows, so nothing below compared anything")
                var diff: [String] = []
                var awaited = 0
                for p in rows {
                    if Old.hasNobodyToSendTo(p) != DraftedDeadEnd.hasNobodyToSendTo(p) {
                        diff.append("hasNobodyToSendTo differs for row \(p.persistentModelID)")
                    }
                    for r in p.recipients {
                        if Old.awaitedReplyDraftRequestedAt(r) != r.awaitedReplyDraftRequestedAt {
                            diff.append("awaitedReplyDraftRequestedAt differs for contact \(r.persistentModelID)")
                        }
                        if Old.awaitedReplyDraftRequestedAt(r) != nil { awaited += 1 }
                        for (instant, alive) in [(now, false), (now, true), (Date.distantFuture, false)]
                        where Old.isReplyDraftStalled(r, now: instant, runAlive: alive)
                            != r.isReplyDraftStalled(now: instant, runAlive: alive) {
                            diff.append("isReplyDraftStalled differs for contact \(r.persistentModelID)")
                        }
                    }
                }
                let oldCount = Old.count(in: rows), newCount = DraftedDeadEnd.count(in: rows)
                if oldCount != newCount { diff.append("DraftedDeadEnd.count differs: \(oldCount) old, \(newCount) new") }
                // At the end of time every awaited draft is stalled, so the list is compared where it is not empty.
                for instant in [now, Date.distantFuture] {
                    let old = Old.dueRecipients(from: rows, now: instant, runAlive: false)
                    let new = StalledReplyDraft.dueRecipients(from: rows, now: instant, runAlive: false)
                    if old.map({ "\($0.recipient.persistentModelID) \($0.requestedAt)" })
                        != new.map({ "\($0.recipient.persistentModelID) \($0.requestedAt)" }) {
                        diff.append("StalledReplyDraft.dueRecipients differs at \(instant): \(old.count) old, \(new.count) new")
                    }
                }
                let oldCounts = QueueModel.organisationRowCounts(rows.map(\.presenter))
                if oldCounts != QueueModel.organisationRowCounts(among: rows) {
                    diff.append("organisationRowCounts differs")
                }
                let stalledAtEnd = Old.dueRecipients(from: rows, now: .distantFuture, runAlive: false).count

                let oldT = Phase0.median5 { _ = Old.dueRecipients(from: rows, now: now, runAlive: false); _ = Old.count(in: rows) }
                let newT = Phase0.median5 {
                    _ = StalledReplyDraft.dueRecipients(from: rows, now: now, runAlive: false); _ = DraftedDeadEnd.count(in: rows)
                }
                print("old against new, \(label): \(rows.count) row(s), \(oldCount) dead end(s), \(awaited) awaited draft(s), "
                      + "\(stalledAtEnd) stalled at the end of time, \(oldCounts.count) organisation(s), \(diff.count) difference(s)")
                print("old against new, \(label): stalled drafts and dead ends old \(oldT.text), new \(newT.text); load \(Phase0.load())")
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
