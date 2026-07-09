import Foundation

// #436: one documented home for every long action's "this has been going too long → stalled" window.
// The values legitimately differ by how long each run actually takes; they live together so the
// differences are deliberate and visible rather than scattered as magic numbers across services.
// Each surface routes its start time + the matching window through RunProgress.liveness.
enum RunTimeouts {
    // Prep: a detached Claude Code run that touches its marker ~every 60s; three missed touches reads
    // as dead. Matches the marker-stale guard that frees the run.
    static let prep: TimeInterval = 3 * 60

    // Reply classify / drafter handoff: the heaviest detached run (reads a thread, classifies, drafts),
    // so it gets the longest leash before the marker is considered stale.
    static let replyClassify: TimeInterval = 10 * 60

    // Reply drafter, per recipient: from "Draft a reply" stamped to a draft landing. Shorter than the
    // classify marker because Dan is watching this one and a stranded request should surface sooner.
    static let replyDraft: TimeInterval = 5 * 60

    // Scout: an in-process run; a normal scout returns in well under this, so passing it means stuck.
    static let scout: TimeInterval = 3 * 60

    // Gmail OAuth connect: the visible "looks stuck" warning, set below GmailAuthManager's hard 120s
    // internal give-up so Dan gets a heads-up to check the browser sign-in window before connect()
    // self-aborts and surfaces its failure alert.
    static let gmailConnect: TimeInterval = 90

    // Outbound / reply send: a token refresh plus a single Gmail API call, both bounded at 30s
    // each by GmailNetworking's timeout (#468), so 60s covers the real worst case of a
    // well-behaved failure surfacing on its own. Past this, something is genuinely wedged (not
    // just slow), so it should offer a retry rather than an open-ended "Sending…".
    static let send: TimeInterval = 60

    // OmniFocus sync (#469): a handful of AppleScript Apple events, normally done in well under a
    // second. Generous leash since a slow OmniFocus launch or a stalled Automation permission
    // prompt can legitimately take a while, but a run past this reads as stuck.
    static let omniFocusSync: TimeInterval = 60
}
