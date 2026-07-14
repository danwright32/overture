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
}

// #863: every count a pill can show is built HERE, from the same prospects StageNavigation resolves
// its targets from, rather than inline in QueueView. It lived in the view, which is why the invariant
// in StageNavigation's header ("what a pill shows is what tapping it navigates to") could drift twice
// (#792, #861) without a single test noticing: a SwiftUI view's computed property has no seam a test
// can reach. Everything the roster needs that is NOT a prospect (is Gmail connected, is a run alive)
// is passed in, so this stays pure and testable.
extension AgentInputs {
    static func from(prospects: [Prospect], now: Date, today: String,
                     gmailConnected: Bool, prepRunning: Bool, replyRunAlive: Bool) -> AgentInputs {
        // Counted THROUGH StageNavigation, never alongside it, so a pill's number and the rows its tap
        // lands on come from one predicate and cannot answer the same question differently.
        func count(_ focus: StageFocus) -> Int {
            StageNavigation.naturalKeys(for: focus, in: prospects, today: today, now: now).count
        }
        return AgentInputs(
            toTriage: count(.scout),
            keptToPrep: count(.prep),
            prepRunning: prepRunning,
            toReview: count(.review),
            readyToSend: count(.sendApproved),
            gmailConnected: gmailConnected,
            sendErrors: count(.sendErrors),
            followUpsDue: FollowUp.dueRecipients(from: prospects, now: now).count,
            stalledReplyDrafts: prospects.reduce(0) { sum, p in
                sum + p.recipients.filter { $0.isReplyDraftStalled(now: now, runAlive: replyRunAlive) }.count
            },
            stuckSends: count(.sendStuck),
            degradedReplyTracking: count(.sendDegraded),
            blockedContacts: count(.sendBlocked)
        )
    }
}

enum AgentRoster {
    static func statuses(_ i: AgentInputs) -> [AgentStatus] {
        [scout(i), prep(i), review(i), send(i), followUps(i)]
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
        "\(conceptSummary(for: name)) \(detail)"
    }

    static func conceptSummary(for name: String) -> String {
        switch name {
        case "Scout": return "Freshly found events waiting for you to keep or dismiss."
        case "Prep": return "Finds a contact and drafts an email for shows you've kept."
        case "Review": return "Drafts waiting for you to read, edit, and approve."
        case "Send": return "Approved emails waiting to be sent."
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
            return AgentStatus(name: "Prep", state: .working, detail: "Finding contacts and drafting…",
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
    private static func send(_ i: AgentInputs) -> AgentStatus {
        // An interrupted send outranks even a confirmed failure (#475/#476): Dan doesn't yet know
        // whether it actually went out, so it needs his eyes on Gmail, not just a retry.
        if i.stuckSends > 0 {
            let n = i.stuckSends
            return AgentStatus(name: "Send", state: .error,
                               detail: "\(n) \(shows(n)) with an unconfirmed send: check Gmail",
                               focus: .sendStuck, count: n)
        }
        if i.sendErrors > 0 {
            return AgentStatus(name: "Send", state: .error, detail: "\(i.sendErrors) failed to send",
                               focus: .sendErrors, count: i.sendErrors)
        }
        // #483: the send went out fine, just with no usable threadId to watch for a reply. Not a
        // failure, but silent otherwise, so it still has to surface.
        if i.degradedReplyTracking > 0 {
            let n = i.degradedReplyTracking
            return AgentStatus(name: "Send", state: .needsAttention,
                               detail: "\(n) \(shows(n)) sent, but replies can't be tracked: check Gmail",
                               focus: .sendDegraded, count: n)
        }
        // #792: a contact held back by a review guard. It ranks BELOW a real failure (a send that failed,
        // or one whose outcome is unknown, needs Dan's eyes more urgently than a heuristic he only has to
        // glance at) and ABOVE an ordinary queue of approved sends, because an approved send is waiting on
        // a click and this one is waiting on a decision he does not yet know he owes.
        if i.blockedContacts > 0 {
            let n = i.blockedContacts
            return AgentStatus(name: "Send", state: .needsAttention,
                               detail: "\(n) \(shows(n)) with a contact held for a check",
                               focus: .sendBlocked, count: n)
        }
        if i.readyToSend > 0 {
            let detail = i.gmailConnected
                ? "\(i.readyToSend) approved, ready to send"
                : "\(i.readyToSend) approved, connect Gmail to send"
            return AgentStatus(name: "Send", state: .needsAttention, detail: detail,
                               focus: .sendApproved, count: i.readyToSend,
                               needsGmailConnect: !i.gmailConnected)
        }
        return AgentStatus(name: "Send", state: .idle, detail: "Nothing to send",
                           focus: .sendApproved, count: 0)
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
            return AgentStatus(name: "Follow-ups", state: .needsAttention,
                               detail: "\(i.followUpsDue) nudge\(i.followUpsDue == 1 ? "" : "s") due",
                               focus: .followUps, count: i.followUpsDue)
        }
        return AgentStatus(name: "Follow-ups", state: .idle, detail: "None due", focus: .followUps, count: 0)
    }
}
