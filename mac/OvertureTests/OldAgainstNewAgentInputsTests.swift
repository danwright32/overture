import Testing
import Foundation
import SwiftData

// #4357 (plan v7 Phase 3 step 2, oracle part one): TEMPORARY. `AgentInputs.from` as it stood at 12c674a4, copied
// verbatim bar names and comments, with the two helpers this slice changed spelled as their old bodies
// (`DueWork.counts`, which wrapped every row before counting it, and `ReachedOutQueue.showCount(of:)` over model
// rows), run against the generic body through its model entry point over ONE frozen snapshot of the live clone
// and its fourfold copy. Every other term the old body called is unchanged by this slice and is called as it
// was. Its output is pasted into the PR, and then this file is deleted in the same PR (L613).
@MainActor
@Suite("Oracle part one for slice G3: the model only AgentInputs.from against the generic one (#4357, temporary)")
final class OldAgainstNewAgentInputsTests {
    private let sandboxes = TemporarySandboxes()

    enum Old {
        static func from(prospects: [Prospect], allProspects: [Prospect], inquiries: [Inquiry] = [],
                         context: StageContext,
                         gmailConnected: Bool, runInFlight: RunKind?, replyRunAlive: Bool,
                         placement: StageNavigation.Placement? = nil,
                         reachedOut: [(prospect: Prospect, recipient: Recipient, next: Date)]? = nil) -> AgentInputs {
            let focusCounts = StageNavigation.counts(
                in: placement ?? StageNavigation.placements(in: prospects, context: context))
            let dueWork = DueWork.rows(prospects: allProspects, inquiries: inquiries, now: context.now,
                                       replyRunAlive: replyRunAlive).counts
            func count(_ focus: StageFocus) -> Int { focusCounts[focus] ?? 0 }
            let reachedOutRows = reachedOut ?? ReachedOutQueue.activeWithDates(from: prospects, now: context.now)
            func inquiryCount(_ focus: StageFocus) -> Int {
                inquiries.filter { StageNavigation.stage(for: $0) == focus }.count
            }
            return AgentInputs(
                toTriage: count(.scout),
                keptToPrep: count(.prep),
                runInFlight: runInFlight,
                toReview: count(.review) + inquiryCount(.review),
                readyToSend: count(.sendApproved),
                gmailConnected: gmailConnected,
                sendErrors: count(.sendErrors),
                followUpsDue: dueWork.total,
                conversationsToConfirm: dueWork.conversationsToConfirm,
                repliesToAnswer: dueWork.repliesToAnswer,
                reviewDeadEnds: DraftedDeadEnd.count(in: prospects),
                stalledReplyDrafts: StalledReplyDraft.dueRecipients(from: prospects, now: context.now,
                                                                    runAlive: replyRunAlive).count,
                stuckSends: count(.sendStuck),
                degradedReplyTracking: count(.sendDegraded),
                degradedThreading: count(.sendThreadingDegraded),
                blockedContacts: count(.sendBlocked),
                reachedOut: Set(reachedOutRows.map { $0.prospect.naturalKey }).count
                    + inquiryCount(.reachedOut),
                reachedOutDue: reachedOutRows
                    .filter { ReachedOutQueue.isDueNow(for: $0.recipient, of: $0.prospect, now: context.now) }.count
                    + inquiries.filter { StageNavigation.stage(for: $0) == .reachedOut && $0.hasUnhandledReply }.count
            )
        }
    }

    /// Every field of the value, as `label value`. The pill counts carry no title or address, so they may be
    /// printed, which is what shows which ones the snapshot compared non empty.
    static func fields(_ inputs: AgentInputs) -> String {
        Mirror(reflecting: inputs).children.compactMap { child in
            child.label.map { "\($0) \(String(describing: child.value))" }
        }.joined(separator: ", ")
    }

    @Test(.enabled(if: LiveStorePresence.exists, LiveStorePresence.absenceReason))
    func theGenericAgentInputsAnswerAsTheModelOnlyOneDidOnOneFrozenSnapshot() async throws {
        await RealStoreTestLock.shared.acquire()
        do {
            let dir = try sandboxes.make(named: "old-against-new-agent-inputs")
            guard let base = try LiveStoreClone.makeClone(in: dir) else {
                throw LiveStoreClone.Refusal.backupFailed("no live store on this machine")
            }
            let corpora = [("live clone", base), ("4x", try Phase0.scaledCopy(of: base, factor: 4, in: dir))]
            let now = Date()
            for (label, url) in corpora {
                let ctx = ModelContext(try Phase0.openContainer(at: url))
                let every = try ctx.fetch(FetchDescriptor<Prospect>())
                let inquiries = try ctx.fetch(FetchDescriptor<Inquiry>())
                #expect(!every.isEmpty, "the \(label) holds no shows, so nothing below compared anything")
                let inQueue = QueueModel.queueScope(every)
                // A client window over half the source ids the rows carry, sorted so it is the same set every run,
                // so the client arm of the lead time rule is asked on both sides of its line.
                let sources = Set(every.flatMap(\.sourceIds)).sorted()
                let clients = ClientWindow(clientSourceIds: Set(sources.enumerated()
                    .filter { $0.offset % 2 == 0 }.map(\.element)))
                var diff: [String] = []
                var compared = 0
                for (instant, when) in [(now, "now"), (now.addingTimeInterval(30 * 86_400), "a month on")] {
                    let context = StageContext(now: instant, geo: .none, clients: clients).resolvingPlaces(of: inQueue)
                    for (scope, which) in [(inQueue, "the queue"), (every, "every row")] {
                        let placement = StageNavigation.placements(in: scope, context: context)
                        let reachedOut = ReachedOutQueue.activeWithDates(from: scope, now: context.now)
                        for alive in [false, true] {
                            for handed in [false, true] {
                                let old = Old.from(prospects: scope, allProspects: every, inquiries: inquiries,
                                                   context: context, gmailConnected: true, runInFlight: nil,
                                                   replyRunAlive: alive, placement: handed ? placement : nil,
                                                   reachedOut: handed ? reachedOut : nil)
                                let new = AgentInputs.from(prospects: scope, allProspects: every, inquiries: inquiries,
                                                           context: context, gmailConnected: true, runInFlight: nil,
                                                           replyRunAlive: alive, placement: handed ? placement : nil,
                                                           reachedOut: handed ? reachedOut : nil)
                                compared += 1
                                if old != new {
                                    diff.append("AgentInputs.from \(TermsOverFacts.differingLabels(old, new).joined(separator: ", ")) "
                                                + "differ \(when) over \(which), reply run \(alive ? "alive" : "dead"), "
                                                + (handed ? "placement handed in" : "placement decided here"))
                                }
                                if !alive, handed {
                                    print("old against new, \(label): \(when) over \(which): \(Self.fields(old))")
                                }
                            }
                        }
                    }
                }
                let context = StageContext(now: now, geo: .none, clients: clients).resolvingPlaces(of: inQueue)
                let oldT = Phase0.median5 {
                    _ = Old.from(prospects: inQueue, allProspects: every, inquiries: inquiries, context: context,
                                 gmailConnected: true, runInFlight: nil, replyRunAlive: false)
                }
                let newT = Phase0.median5 {
                    _ = AgentInputs.from(prospects: inQueue, allProspects: every, inquiries: inquiries, context: context,
                                         gmailConnected: true, runInFlight: nil, replyRunAlive: false)
                }
                print("old against new, \(label): \(every.count) row(s), \(inQueue.count) in the queue, "
                      + "\(inquiries.count) inquir(ies), \(compared) comparison(s), \(diff.count) difference(s)")
                print("old against new, \(label): AgentInputs.from old \(oldT.text), new \(newT.text); load \(Phase0.load())")
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
