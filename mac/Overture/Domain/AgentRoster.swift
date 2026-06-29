import Foundation

// Per-stage status so Dan can see at a glance where he's needed, without digging into
// each agent (#15). Only the stages that can wait on him are here — Prep, Review, Send,
// Follow-ups; the scout is automatic (#33) and never blocks on a decision. Pure.
enum AgentState: String, Equatable, Sendable {
    case idle, working, needsAttention, error
}

struct AgentStatus: Equatable, Identifiable, Sendable {
    var id: String { name }
    let name: String
    let state: AgentState
    let detail: String
}

struct AgentInputs: Sendable {
    var keptToPrep: Int      // kept, no draft yet — waiting on a Prep run
    var prepRunning: Bool
    var toReview: Int        // drafted, awaiting Dan's review/approval
    var readyToSend: Int     // approved, not yet sent
    var gmailConnected: Bool
    var sendErrors: Int      // approved sends that failed
    var followUpsDue: Int
    var stalledReplyDrafts: Int = 0   // #431: reply-draft runs that died without producing a draft
}

enum AgentRoster {
    static func statuses(_ i: AgentInputs) -> [AgentStatus] {
        [prep(i), review(i), send(i), followUps(i)]
    }

    static func needsYouCount(_ statuses: [AgentStatus]) -> Int {
        statuses.filter { $0.state == .needsAttention || $0.state == .error }.count
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
        if i.sendErrors > 0 {
            return AgentStatus(name: "Send", state: .error, detail: "\(i.sendErrors) failed to send")
        }
        if i.readyToSend > 0 {
            let detail = i.gmailConnected
                ? "\(i.readyToSend) approved, ready to send"
                : "\(i.readyToSend) approved, connect Gmail to send"
            return AgentStatus(name: "Send", state: .needsAttention, detail: detail)
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
