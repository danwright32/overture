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
        if i.toTriage > 0 { return AgentStatus(name: "Scout", state: .needsAttention, detail: "\(i.toTriage) to triage") }
        return AgentStatus(name: "Scout", state: .idle, detail: "Nothing new")
    }

    private static func prep(_ i: AgentInputs) -> AgentStatus {
        if i.prepRunning { return AgentStatus(name: "Prep", state: .working, detail: "Finding contacts and drafting…") }
        if i.keptToPrep > 0 { return AgentStatus(name: "Prep", state: .needsAttention, detail: "\(i.keptToPrep) ready to prep") }
        return AgentStatus(name: "Prep", state: .idle, detail: "Nothing waiting")
    }

    private static func review(_ i: AgentInputs) -> AgentStatus {
        if i.toReview > 0 { return AgentStatus(name: "Review", state: .needsAttention, detail: "\(i.toReview) draft\(i.toReview == 1 ? "" : "s") to review") }
        return AgentStatus(name: "Review", state: .idle, detail: "Nothing to review")
    }

    private static func send(_ i: AgentInputs) -> AgentStatus {
        // An interrupted send outranks even a confirmed failure (#475/#476): Dan doesn't yet know
        // whether it actually went out, so it needs his eyes on Gmail, not just a retry.
        if i.stuckSends > 0 {
            let n = i.stuckSends
            return AgentStatus(name: "Send", state: .error,
                               detail: "\(n) send\(n == 1 ? "" : "s") unconfirmed: check Gmail")
        }
        if i.sendErrors > 0 {
            return AgentStatus(name: "Send", state: .error, detail: "\(i.sendErrors) failed to send")
        }
        // #483: the send went out fine, just with no usable threadId to watch for a reply. Not a
        // failure, but silent otherwise, so it still has to surface.
        if i.degradedReplyTracking > 0 {
            let n = i.degradedReplyTracking
            return AgentStatus(name: "Send", state: .needsAttention,
                               detail: "\(n) sent but can't be watched for replies: check Gmail")
        }
        // #792: a contact held back by a review guard. It ranks BELOW a real failure (a send that failed,
        // or one whose outcome is unknown, needs Dan's eyes more urgently than a heuristic he only has to
        // glance at) and ABOVE an ordinary queue of approved sends, because an approved send is waiting on
        // a click and this one is waiting on a decision he does not yet know he owes.
        if i.blockedContacts > 0 {
            let n = i.blockedContacts
            return AgentStatus(name: "Send", state: .needsAttention,
                               detail: "\(n) contact\(n == 1 ? "" : "s") held for a check")
        }
        if i.readyToSend > 0 {
            let detail = i.gmailConnected
                ? "\(i.readyToSend) approved, ready to send"
                : "\(i.readyToSend) approved, connect Gmail to send"
            return AgentStatus(name: "Send", state: .needsAttention, detail: detail,
                               needsGmailConnect: !i.gmailConnected)
        }
        return AgentStatus(name: "Send", state: .idle, detail: "Nothing to send")
    }

    private static func followUps(_ i: AgentInputs) -> AgentStatus {
        // A dead reply-drafter run takes priority: it's an abnormal stall Dan should clear (#431).
        if i.stalledReplyDrafts > 0 {
            let n = i.stalledReplyDrafts
            return AgentStatus(name: "Follow-ups", state: .needsAttention,
                               detail: "\(n) reply draft\(n == 1 ? "" : "s") stalled")
        }
        if i.followUpsDue > 0 { return AgentStatus(name: "Follow-ups", state: .needsAttention, detail: "\(i.followUpsDue) nudge\(i.followUpsDue == 1 ? "" : "s") due") }
        return AgentStatus(name: "Follow-ups", state: .idle, detail: "None due")
    }
}
