import Foundation
import SwiftData

// #2718: the pass that ties the milestone together on the reconcile tick.
//
// It reads the mailbox once (#2713), ranks what it found against each in-scope contact (#2714), and
// stores at most one question per contact (#2718). This is where the first two get a reader in the
// shipping runtime; until it existed both were correct and unreachable, which is L3.
//
// One search per TICK, not one per contact: the search is already shaped that way, and this scores
// every contact against the same message set rather than paying for the mailbox once per pitch.
@MainActor
struct ReplyProposalSweep {

    // Four outcomes, and "found nothing" is reachable from exactly one of them. A tick that could not
    // read Gmail must never leave a row looking like one where nobody wrote (L10, L11, L98).
    enum Outcome: Equatable {
        case notConnected
        case nothingInScope
        case failed(reason: String)
        // `proposed` counts questions this tick RAISED, not questions standing: a tick that re-found the
        // same message reports zero, because nothing new happened and a count that said otherwise would
        // make every tick look like fresh work.
        //
        // #2712: `attached` is the same measure for the inquiry half, and it is a SEPARATE number rather
        // than added into `proposed`. The two are different acts: a proposal is a question waiting on Dan,
        // an attach is a conversation Overture has already started watching, and one count covering both
        // would promise rows that do not exist on the Due pill (L16).
        case swept(proposed: Int, attached: Int, saveFailed: Bool)
    }

    var fromEmail: String = SendIdentity.danWright.email

    // `search` and `save` are injected, defaulting to the real ones, so the whole decision path runs with
    // no network and so the save-failure branch is reachable at all (a SwiftData in-memory container
    // cannot be made to fail its save on demand).
    @discardableResult
    // #2712: `attach` is the inquiry half, injected for the same reason `search` is: it makes two Gmail
    // calls per matched inquiry, and without a seam neither the attach nor its unreadable-thread branch
    // could be driven from a test at all (L2, L3).
    func run(in context: ModelContext,
             now: Date = Date(),
             defaults: UserDefaults = .standard,
             save: (() throws -> Void)? = nil,
             search: (() async -> GmailReplySearch.Outcome)? = nil,
             attach: (@MainActor (_ inquiries: [Inquiry], _ candidates: [GmailReplySearch.InboundMessage])
                        async -> InquiryConversationAttach.Outcome)? = nil) async -> Outcome {
        let outcome: GmailReplySearch.Outcome
        if let search {
            outcome = await search()
        } else {
            outcome = await GmailReplySearch(fromEmail: fromEmail)
                .search(in: context, now: now, defaults: defaults)
        }

        let candidates: [GmailReplySearch.InboundMessage]
        var saveFailed: Bool
        switch outcome {
        case .notConnected: return .notConnected
        case .nothingInScope: return .nothingInScope
        case .failed(let reason): return .failed(reason: reason)
        case .searched(let found, _, let searchSaveFailed):
            candidates = found
            // The search's own save failure is carried rather than dropped: both halves mean "this tick
            // could not record what it did", and reporting only the proposal half would let the searched
            // stamps fail silently.
            saveFailed = searchSaveFailed
        }

        let prospects = (try? context.fetch(FetchDescriptor<Prospect>())) ?? []
        var proposed = 0
        for p in prospects {
            guard !p.replyWatchManualOutcome, !p.replyWatchIsBooked else { continue }
            for r in p.recipients where ReplySearchScope.inScope(r, now: now) {
                // A question already standing is left exactly as it is: it is not re-asked, not
                // re-stamped, and not replaced by a better candidate (see `ProposedConversation.propose`).
                guard ProposedConversation.stored(on: r) == nil else { continue }
                guard case .proposed(let top) = ReplyCandidateMatch.judge(candidates, for: r, on: p,
                                                                          selfEmail: fromEmail) else {
                    // `.ambiguous` deliberately proposes nothing. Asking Dan to pick between two equally
                    // plausible messages is asking him to guess, and a wrong confirmation writes a
                    // stranger's address onto the contact.
                    continue
                }
                ProposedConversation.propose(
                    ProposedConversation.Candidate(messageId: top.message.messageId,
                                                   threadId: top.message.threadId,
                                                   fromAddress: top.message.fromAddress,
                                                   fromName: top.message.fromName,
                                                   subject: top.message.subject,
                                                   sentAt: top.message.sentAt,
                                                   score: top.score),
                    on: r, now: now)
                if ProposedConversation.stored(on: r) != nil { proposed += 1 }
            }
        }

        // #2712: the inquiry half of the same read. A hire inquiry Dan answered in his own Gmail is in
        // exactly the position a form pitch is, so it rides these same candidates rather than a second
        // mailbox pass. `try?` keeps a container that predates Inquiry working: it yields none.
        let inquiries = (try? context.fetch(FetchDescriptor<Inquiry>())) ?? []
        let attachOutcome: InquiryConversationAttach.Outcome
        if let attach {
            attachOutcome = await attach(inquiries, candidates)
        } else {
            attachOutcome = await InquiryConversationAttach(fromEmail: fromEmail)
                .run(inquiries: inquiries, candidates: candidates, now: now)
        }

        if proposed > 0 || attachOutcome.attached > 0 {
            do {
                if let save { try save() } else { try context.save() }
            } catch {
                saveFailed = true
                // copy-inventory:ignore-start  developer diagnostic log, not the app's own voice (#915)
                AgentLog.note("[Overture] The reply proposal sweep could not save: \(error)")
                // copy-inventory:ignore-end
            }
        }
        return .swept(proposed: proposed, attached: attachOutcome.attached, saveFailed: saveFailed)
    }
}
