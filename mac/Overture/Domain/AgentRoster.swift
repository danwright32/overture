import Foundation

// Per-stage status so Dan can see at a glance where he's needed, without digging into
// each agent (#15). The stages that can wait on him are Scout (#370: the keep/dismiss
// triage on freshly found events), Prep, Review, Send, Follow-ups; the scout RUN itself is
// automatic (#33) and never blocks on a decision, only its output (undecided prospects) does. Pure.
enum AgentState: String, Equatable, Sendable {
    case idle, working, needsAttention, error
}

struct AgentStatus: Equatable, Identifiable, Sendable {
    var id: String { name }
    let name: String
    let state: AgentState
    let detail: String
    // #863: what this pill is CURRENTLY about, and how many shows that is. Send reports whichever of
    // five problems is most urgent, and each names a different set of shows, so the pill's tap has to
    // follow the sentence it actually chose, not the pill's name. `count` is the number that sentence
    // states, and it is always a count of SHOWS, so it equals the rows a tap lands on: a pill that
    // says 3 and lands Dan on 2 rows is the same broken promise as one that lands him on none.
    let focus: StageFocus
    let count: Int
    // #565: true only for the Send status's "N approved, connect Gmail to send" case, so a tap on
    // the chip can route to the actual Gmail-connect flow (#488) instead of just filtering the
    // queue. A structured flag, not a text match on `detail`, which is prose meant to change freely.
    var needsGmailConnect: Bool = false
}

struct AgentInputs: Sendable {
    var toTriage: Int        // #370: freshly scouted, undecided (status .new), awaiting keep/dismiss
    var keptToPrep: Int      // kept, no draft yet, waiting on a Prep run
    var prepRunning: Bool
    var toReview: Int        // drafted, awaiting Dan's review/approval
    var readyToSend: Int     // approved, not yet sent
    var gmailConnected: Bool
    var sendErrors: Int      // approved sends that failed
    var followUpsDue: Int
    var stalledReplyDrafts: Int = 0   // #431: reply-draft runs that died without producing a draft
    var stuckSends: Int = 0   // #475/#476: claimed .sending, never resolved (outcome unknown)
    var degradedReplyTracking: Int = 0   // #483: sent, but no usable threadId so replies can't be auto-detected
    // #792: real contacts held back by a review guard (the venue guess, the press contact, the
    // duplicate, the salutation review, the draft lint), each waiting on one glance from Dan. They used
    // to be invisible: the show they belong to reads as fully Sent, because a held contact is not
    // "sendable", so it left the queue and nothing ever surfaced the person still waiting.
    var blockedContacts: Int = 0
    // #1134: contacted recipients Dan is still working, counted from ReachedOutQueue (one per recipient),
    // so the Reached out pill's number equals the rows the reached-out view lands him on.
    var reachedOut: Int = 0
}

// #863: every count a pill can show is built HERE, from the same prospects StageNavigation resolves
// its targets from, rather than inline in QueueView. It lived in the view, which is why the invariant
// in StageNavigation's header ("what a pill shows is what tapping it navigates to") could drift twice
// (#792, #861) without a single test noticing: a SwiftUI view's computed property has no seam a test
// can reach. Everything the roster needs that is NOT a prospect (is Gmail connected, is a run alive)
// is passed in, so this stays pure and testable.
extension AgentInputs {
    static func from(prospects: [Prospect], inquiries: [Inquiry] = [], now: Date, today: String,
                     gmailConnected: Bool, prepRunning: Bool, replyRunAlive: Bool) -> AgentInputs {
        // Counted THROUGH StageNavigation, never alongside it, so a pill's number and the rows its tap
        // lands on come from one predicate and cannot answer the same question differently.
        // #1121: one traversal for every focus (StageNavigation.counts), not one traversal per focus, so
        // the send-related counts fault each prospect's `recipients` at most once instead of once each.
        let focusCounts = StageNavigation.counts(in: prospects, today: today, now: now)
        func count(_ focus: StageFocus) -> Int { focusCounts[focus] ?? 0 }
        // #1436: inquiries share two of these stages, so a logged inquiry is counted where it renders.
        func inquiryCount(_ focus: StageFocus) -> Int {
            inquiries.filter { StageNavigation.stage(for: $0) == focus }.count
        }
        return AgentInputs(
            toTriage: count(.scout),
            keptToPrep: count(.prep),
            prepRunning: prepRunning,
            toReview: count(.review),
            readyToSend: count(.sendApproved) + inquiryCount(.sendApproved),
            gmailConnected: gmailConnected,
            sendErrors: count(.sendErrors),
            followUpsDue: FollowUp.dueRecipients(from: prospects, now: now).count,
            stalledReplyDrafts: prospects.reduce(0) { sum, p in
                sum + p.recipients.filter { $0.isReplyDraftStalled(now: now, runAlive: replyRunAlive) }.count
            },
            stuckSends: count(.sendStuck),
            degradedReplyTracking: count(.sendDegraded),
            blockedContacts: count(.sendBlocked),
            // #1134: the SAME function the reached-out view lists its rows from, so the pill's count and
            // that list agree by construction (one per contacted recipient still in play).
            reachedOut: ReachedOutQueue.showCount(from: prospects, now: now)   // #1194: shows, not recipients
                + inquiryCount(.reachedOut)   // #1436: replied inquiries awaiting a response
        )
    }
}

// #357/#863: what tapping a chip actually DOES, pulled out of QueueView's Button closure so this
// dispatch has a seam a test can reach. Most pills navigate the queue to their focus; a handful
// route somewhere else entirely (a Gmail-connect flow, the Follow-ups sheet).
enum AgentChipAction: Equatable, Sendable {
    case connectGmail
    case showFollowUps
    case focusOnStage
}

enum AgentRoster {
    static func statuses(_ i: AgentInputs) -> [AgentStatus] {
        // #1146: the Send-issues pill appears only when it has a real problem/blocker to show; when idle
        // it is dropped from the strip entirely rather than resting at a permanent zero.
        let sendIssues = send(i)
        var result = [scout(i), prep(i), review(i)]
        if sendIssues.state != .idle { result.append(sendIssues) }
        // #1134: Reached out is its own navigation stage now (separate from Follow-ups), always present so
        // Dan can get to it. It is never "needs you": the people to nudge surface under Follow-ups.
        result.append(reachedOut(i))
        result.append(followUps(i))
        return result
    }

    // #565/#338: needsGmailConnect outranks everything (a real instruction with something to click),
    // then the one pill that routes somewhere other than the queue, then ordinary navigation.
    static func chipAction(for status: AgentStatus) -> AgentChipAction {
        if status.needsGmailConnect { return .connectGmail }
        if status.name == "Follow-ups" { return .showFollowUps }
        return .focusOnStage
    }

    static func needsYouCount(_ statuses: [AgentStatus]) -> Int {
        statuses.filter { $0.state == .needsAttention || $0.state == .error }.count
    }

    // #332: a first-time user could not tell what Prep/Review/Send/Follow-ups each mean, only
    // their live count. This is a short, stable sentence per pill, independent of the live
    // `detail` above, meant to be shown ALONGSIDE it (not replacing it) in the pill's tooltip, so
    // hovering explains both the concept and the current count in one place. Deliberately worded
    // as a queue ("shows waiting to...") rather than a step in a sequence, since these four are
    // parallel work queues a single show can skip entirely (e.g. dismissed before Send), not
    // stages every show passes through in order.
    // #885: what a chip's hover actually says: the concept ("what this pill IS") followed by the live
    // detail ("what is in it right now"). Both halves were domain-computed already; the sentence that
    // joins them was the view's, which meant the one thing nobody could test was the only part that was
    // ever going to be got wrong (a missing space, a swapped order).
    static func chipHelp(name: String, detail: String) -> String {
        // #1134: a stage with no live detail yet (Reached out with no one in it) shows only the concept,
        // with no dangling trailing space after it.
        detail.isEmpty ? conceptSummary(for: name) : "\(conceptSummary(for: name)) \(detail)"
    }

    static func conceptSummary(for name: String) -> String {
        switch name {
        case "Scout": return "Freshly found events waiting for you to keep or dismiss."
        case "Prep": return "Finds a contact and drafts an email for shows you've kept."
        case "Review": return "Drafts waiting for you to read, edit, and approve."
        case "Send issues": return "Sent emails that hit a problem, or approved ones you can't send yet."
        case "Reached out": return "Shows you've pitched and are waiting to hear back on."
        case "Follow-ups": return "Nudges due on shows you've already reached out to."
        default: return ""
        }
    }

    // #370: the freshly scouted, undecided triage. Deliberately never .working (the scout run
    // itself already surfaces its own live state via ScoutStatus/isScanning elsewhere); this pill
    // only reflects its OUTPUT, the backlog still awaiting a keep/dismiss decision.
    private static func scout(_ i: AgentInputs) -> AgentStatus {
        if i.toTriage > 0 {
            return AgentStatus(name: "Scout", state: .needsAttention, detail: "\(i.toTriage) to triage",
                               focus: .scout, count: i.toTriage)
        }
        return AgentStatus(name: "Scout", state: .idle, detail: "Nothing new", focus: .scout, count: 0)
    }

    private static func prep(_ i: AgentInputs) -> AgentStatus {
        if i.prepRunning {
            // #843: the tooltip shows this after the concept ("Finds a contact and drafts an email…"), so
            // "Finding contacts and drafting…" only said the concept again in the present tense. The live
            // detail's job here is just to say it is happening now.
            return AgentStatus(name: "Prep", state: .working, detail: "Running now…",
                               focus: .prep, count: i.keptToPrep)
        }
        if i.keptToPrep > 0 {
            return AgentStatus(name: "Prep", state: .needsAttention, detail: "\(i.keptToPrep) ready to prep",
                               focus: .prep, count: i.keptToPrep)
        }
        return AgentStatus(name: "Prep", state: .idle, detail: "Nothing waiting", focus: .prep, count: 0)
    }

    private static func review(_ i: AgentInputs) -> AgentStatus {
        if i.toReview > 0 {
            return AgentStatus(name: "Review", state: .needsAttention,
                               detail: "\(i.toReview) draft\(i.toReview == 1 ? "" : "s") to review",
                               focus: .review, count: i.toReview)
        }
        return AgentStatus(name: "Review", state: .idle, detail: "Nothing to review", focus: .review, count: 0)
    }

    // #863: every branch here now names the SHOWS it is about, and hands that focus to the pill, so the
    // tap follows the sentence. Each count is a count of shows for the same reason: the number Dan reads
    // is a promise about how many rows he is about to land on. "3 contacts held" landing him on 2 rows
    // breaks that promise just as surely as landing him on none.
    // #1146: the Send pill is now "Send issues". It surfaces ONLY when a send needs Dan: a post-send
    // problem (stuck / failed / can't-be-watched-for-a-reply / a contact held for a check), or approved
    // emails he can't send because Gmail isn't connected. The ordinary "approved and ready to send" case
    // is deliberately NOT surfaced: Approve and Send are two buttons on the same review card, so a
    // connected, ready-to-send show is one click from done and only rested the old pill at a permanent
    // zero. When idle, `statuses` drops this pill from the strip entirely rather than showing a dead "0".
    private static func send(_ i: AgentInputs) -> AgentStatus {
        // An interrupted send outranks even a confirmed failure (#475/#476): Dan doesn't yet know
        // whether it actually went out, so it needs his eyes on Gmail, not just a retry.
        if i.stuckSends > 0 {
            let n = i.stuckSends
            return AgentStatus(name: "Send issues", state: .error,
                               detail: "\(n) \(shows(n)) with an unconfirmed send: check Gmail",
                               focus: .sendStuck, count: n)
        }
        if i.sendErrors > 0 {
            return AgentStatus(name: "Send issues", state: .error, detail: "\(i.sendErrors) failed to send",
                               focus: .sendErrors, count: i.sendErrors)
        }
        // #483: the send went out fine, just with no usable threadId to watch for a reply. Not a
        // failure, but silent otherwise, so it still has to surface.
        if i.degradedReplyTracking > 0 {
            let n = i.degradedReplyTracking
            return AgentStatus(name: "Send issues", state: .needsAttention,
                               detail: "\(n) \(shows(n)) sent, but replies can't be tracked: check Gmail",
                               focus: .sendDegraded, count: n)
        }
        // #792: a contact held back by a review guard. It ranks BELOW a real failure (a send that failed,
        // or one whose outcome is unknown, needs Dan's eyes more urgently than a heuristic he only has to
        // glance at).
        if i.blockedContacts > 0 {
            let n = i.blockedContacts
            return AgentStatus(name: "Send issues", state: .needsAttention,
                               detail: "\(n) \(shows(n)) with a contact held for a check",
                               focus: .sendBlocked, count: n)
        }
        // #1146: approved emails Dan can't send because Gmail isn't connected is a real blocker worth
        // surfacing. The connected, ready-to-send case is intentionally NOT surfaced (see the header) and
        // falls through to idle.
        if i.readyToSend > 0 && !i.gmailConnected {
            return AgentStatus(name: "Send issues", state: .needsAttention,
                               detail: "\(i.readyToSend) approved, connect Gmail to send",
                               focus: .sendApproved, count: i.readyToSend, needsGmailConnect: true)
        }
        return AgentStatus(name: "Send issues", state: .idle, detail: "Nothing to send",
                           focus: .sendApproved, count: 0)
    }

    // #1134: the Reached out stage. Informational, never "needs you" (Follow-ups owns what is due), so it
    // stays .idle; the count rides in `detail` and the view shows it beside the name even while idle
    // (agentChip special-cases .reachedOut for exactly this). Empty detail when there is no one yet, so
    // the pill reads just "Reached out" rather than a bare "0".
    private static func reachedOut(_ i: AgentInputs) -> AgentStatus {
        AgentStatus(name: "Reached out", state: .idle,
                    detail: i.reachedOut > 0 ? "\(i.reachedOut)" : "",
                    focus: .reachedOut, count: i.reachedOut)
    }

    private static func shows(_ n: Int) -> String { Plural.word(n, "show") }   // #885: one pluralizer

    // #885: the roll-up line above the agent chips. The VERB is what agrees here, and it inverts: one
    // NEEDS you, three NEED you. Written inline in the view as `n == 1 ? "s" : ""`, backwards from every
    // other pluralization in the app, which is exactly the sort of thing that survives until somebody
    // "tidies" it into agreeing with its neighbours and silently breaks it.
    //
    // Nothing needing Dan says nothing at all: a line that is always there is a line he stops reading.
    static func needsYouLabel(_ needs: Int) -> String? {
        guard needs > 0 else { return nil }
        return "\(needs) \(Plural.word(needs, "needs", "need")) you"
    }

    // #863: the one pill exempt from "the number equals the rows you land on", because it does not land
    // Dan on rows at all: it opens FollowUpsView, which lists the due RECIPIENTS. So a recipient count is
    // the honest one here, and .followUps deliberately resolves no queue keys.
    private static func followUps(_ i: AgentInputs) -> AgentStatus {
        // A dead reply-drafter run takes priority: it's an abnormal stall Dan should clear (#431).
        if i.stalledReplyDrafts > 0 {
            let n = i.stalledReplyDrafts
            return AgentStatus(name: "Follow-ups", state: .needsAttention,
                               detail: "\(n) reply draft\(n == 1 ? "" : "s") stalled",
                               focus: .followUps, count: n)
        }
        if i.followUpsDue > 0 {
            // #843: the tooltip shows this after the concept ("Nudges due on shows you've already reached
            // out to."), so "N nudges due" repeated "nudges due" verbatim. The count is the only new
            // thing; the concept supplies the rest.
            return AgentStatus(name: "Follow-ups", state: .needsAttention,
                               detail: "\(i.followUpsDue) due",
                               focus: .followUps, count: i.followUpsDue)
        }
        return AgentStatus(name: "Follow-ups", state: .idle, detail: "None due", focus: .followUps, count: 0)
    }
}
