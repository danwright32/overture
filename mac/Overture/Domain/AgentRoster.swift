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
    // #1583/#1691: kept, no draft, and held back by a date clash that landed AFTER Dan kept it. Its own
    // number rather than a fold into keptToPrep: the Prep run still refuses these, so counting them as
    // "ready to prep" would state a backlog the run then does not work through (#863).
    var prepBlocked: Int = 0
    // #2614: WHICH detached run holds the single slot, or nil for none. Deliberately one value rather
    // than a boolean beside a second boolean: a check is by definition also "running", so two independent
    // flags is a state space with an impossible corner in it, and the pill read the flag that could not
    // tell three kinds of run apart. `RunKind` already makes this decision in one place for
    // `isProbeRunning`, so nothing new decides it here.
    var runInFlight: RunKind? = nil
    var toReview: Int        // drafted, awaiting Dan's review/approval
    var readyToSend: Int     // approved, not yet sent
    var gmailConnected: Bool
    var sendErrors: Int      // approved sends that failed
    var followUpsDue: Int
    var stalledReplyDrafts: Int = 0   // #431: reply-draft runs that died without producing a draft
    var stuckSends: Int = 0   // #475/#476: claimed .sending, never resolved (outcome unknown)
    var degradedReplyTracking: Int = 0   // #483: sent, but no usable threadId so replies can't be auto-detected
    // #2647: sent, but the real Message-ID could not be read back, so Overture's own next message on
    // that conversation cannot reference it. Its own count beside degradedReplyTracking, never folded
    // into it: they are different problems on different shows, and one number for both would state a
    // total whose tap lands on a different list (#863) while naming only one of the two causes (L11).
    var degradedThreading: Int = 0
    // #792: real contacts held back by a review guard (the venue guess, the press contact, the
    // duplicate, the salutation review, the draft lint), each waiting on one glance from Dan. They used
    // to be invisible: the show they belong to reads as fully Sent, because a held contact is not
    // "sendable", so it left the queue and nothing ever surfaced the person still waiting.
    var blockedContacts: Int = 0
    // #1134: contacted recipients Dan is still working, counted from ReachedOutQueue (one per recipient),
    // so the Reached out pill's number equals the rows the reached-out view lands him on.
    var reachedOut: Int = 0
    // #2114: how many of those rows are due NOW or overdue. Dan's rule, 2026-08-05: "if anything requires
    // a response today (a follow-up or a response to an inbound), the pill should be highlighted." Its own
    // input rather than a flag, so the pill can say how many and not merely that something is.
    var reachedOutDue: Int = 0
}

// #863: every count a pill can show is built HERE, from the same prospects StageNavigation resolves
// its targets from, rather than inline in QueueView. It lived in the view, which is why the invariant
// in StageNavigation's header ("what a pill shows is what tapping it navigates to") could drift twice
// (#792, #861) without a single test noticing: a SwiftUI view's computed property has no seam a test
// can reach. Everything the roster needs that is NOT a prospect (is Gmail connected, is a run alive)
// is passed in, so this stays pure and testable.
extension AgentInputs {
    // #2365: the day, the instant and Dan's geography refusals arrive as ONE required value. `geo` used
    // to be defaulted here with a comment saying a test not about geography was unchanged by it, which is
    // exactly how a SHIPPING caller forgets a gate invisibly: a pill built without it counts shows its own
    // stage list will not render, which is #1570 over again.
    static func from(prospects: [Prospect], inquiries: [Inquiry] = [], context: StageContext,
                     gmailConnected: Bool, runInFlight: RunKind?, replyRunAlive: Bool) -> AgentInputs {
        // Counted THROUGH StageNavigation, never alongside it, so a pill's number and the rows its tap
        // lands on come from one predicate and cannot answer the same question differently.
        // #1121: one traversal for every focus (StageNavigation.counts), not one traversal per focus, so
        // the send-related counts fault each prospect's `recipients` at most once instead of once each.
        let focusCounts = StageNavigation.counts(in: prospects, context: context)
        func count(_ focus: StageFocus) -> Int { focusCounts[focus] ?? 0 }
        // #1436: inquiries share two of these stages, so a logged inquiry is counted where it renders.
        func inquiryCount(_ focus: StageFocus) -> Int {
            inquiries.filter { StageNavigation.stage(for: $0) == focus }.count
        }
        return AgentInputs(
            toTriage: count(.scout),
            keptToPrep: count(.prep),
            prepBlocked: count(.prepBlocked),
            runInFlight: runInFlight,
            toReview: count(.review) + inquiryCount(.review),   // #1436: un-replied inquiries live here
            readyToSend: count(.sendApproved),
            gmailConnected: gmailConnected,
            sendErrors: count(.sendErrors),
            followUpsDue: FollowUp.dueRecipients(from: prospects, now: context.now).count,
            stalledReplyDrafts: prospects.reduce(0) { sum, p in
                sum + p.recipients.filter { $0.isReplyDraftStalled(now: context.now, runAlive: replyRunAlive) }.count
            },
            stuckSends: count(.sendStuck),
            degradedReplyTracking: count(.sendDegraded),
            degradedThreading: count(.sendThreadingDegraded),
            blockedContacts: count(.sendBlocked),
            // #1134: the SAME function the reached-out view lists its rows from, so the pill's count and
            // that list agree by construction (one per contacted recipient still in play).
            reachedOut: ReachedOutQueue.showCount(from: prospects, now: context.now)   // #1194: shows, not recipients
                + inquiryCount(.reachedOut),   // #1436: replied inquiries awaiting a response
            // #2114: how many of those rows are actually due. Counted from the SAME rows the reached-out
            // view lists, and asked the SAME question each of those rows is asked, so the pill's gold and
            // the list Dan lands on cannot disagree about what is waiting.
            //
            // #2802: which means `isDueNow(for:of:now:)`, never `isDueNow(next:)` over `$0.next`. The two
            // dates a reached-out row carries are deliberately different: `$0.next` is the SORT key, and it
            // folds in #2397's floor pinning an open pitch to the show's own night so a live pitch can never
            // fall off the stage (L45). The floor is an anchor and asserts nothing about anything being
            // owed. #2550 moved the ROW onto what is owed and left this count on the sort key, and this
            // comment went on claiming they agreed without a character of it changing (L32). So every
            // pitched show counted as due on its own night: on 2026-08-16 the masthead read
            // "Reached out  1 due" in gold over four rows counting down in days, none of them rust.
            //
            // Asked of the ROW's representative contact (`$0.recipient`), which is the one the row speaks
            // for and paints its urgency from. Stated rather than left implicit, because a show could hold a
            // quiet representative beside a colleague who is owed something: counting that colleague would
            // land Dan on a row that disagrees with the number that sent him there, which is #863 over
            // again in the other direction.
            //
            // An inquiry with a reply nobody has dealt with is due by definition: somebody is waiting on an
            // answer, which is the whole reason an inquiry rides this queue at all (AGENTS.md). It carries
            // no reach-out schedule of its own to consult.
            //
            // #2943: `hasUnhandledReply`, not `replied`. Answering used to clear `replied`, so the plain
            // flag was the only reading available; now that the answer is its own fact, `replied` stays
            // true for the rest of the conversation and this pill would count a conversation Dan has
            // already answered as still owing him something, on every launch, for ever.
            reachedOutDue: ReachedOutQueue.activeWithDates(from: prospects, now: context.now)
                .filter { ReachedOutQueue.isDueNow(for: $0.recipient, of: $0.prospect, now: context.now) }.count
                + inquiries.filter { StageNavigation.stage(for: $0) == .reachedOut && $0.hasUnhandledReply }.count
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
    static func chipHelp(focus: StageFocus, detail: String) -> String {
        // #1134: a stage with no live detail yet (Reached out with no one in it) shows only the concept,
        // with no dangling trailing space after it.
        detail.isEmpty ? conceptSummary(for: focus) : "\(conceptSummary(for: focus)) \(detail)"
    }

    // #2654: keyed on `StageFocus`, which every AgentStatus already carries, rather than on the pill's
    // DISPLAY NAME.
    //
    // Keyed on text this could not be made exhaustive at all, and its default returned "", which renders
    // as nothing rather than as a gap: renaming a pill in the UI silently blanked the sentence explaining
    // what that stage is for, and there was no version of that failure anybody would see. A default is
    // indistinguishable from a deliberate choice (L113), and a lookup keyed on a display name is one
    // rename away from answering for nothing.
    //
    // Now the compiler asks the question. A stage added to StageFocus breaks the build here, and a pill
    // renamed tomorrow keeps its sentence, because the name was never what identified it.
    static func conceptSummary(for focus: StageFocus) -> String {
        switch focus {
        case .scout: return "Freshly found events waiting for you to keep or dismiss."
        case .prep: return "Finds a contact and drafts an email for shows you've kept."
        // #2050: "and send", because a show now stays here until it has gone out.
        case .review: return "Drafts waiting for you to read, edit, and send."
        // The five send focuses and the threading one are ONE pill, "Send issues", so they share its
        // sentence. Named individually rather than collapsed to a default, which is the whole point.
        case .sendApproved, .sendBlocked, .sendErrors, .sendStuck, .sendDegraded, .sendThreadingDegraded:
            return "Sent emails that hit a problem, or approved ones you can't send yet."
        case .reachedOut: return "Shows you've pitched and are waiting to hear back on."
        case .followUps: return "Nudges due on shows you've already reached out to."
        // A show held by a date clash DOES reach a pill: `statuses` returns a "Prep" status carrying this
        // focus whenever `prepBlocked > 0`, and it outranks the ordinary ready-to-prep state, so it is
        // what Dan hovers on exactly the day something is stuck.
        //
        // Said plainly because the first version of this switch returned "" here, on the belief that this
        // focus had no pill of its own. It has: the pill is named "Prep" and only its FOCUS differs. That
        // wrong belief blanked this tooltip whenever a show was held, which is the very defect #2654 was
        // written to close, reintroduced by closing it.
        case .prepBlocked: return "Shows you kept that a date clash is holding back."
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
        if i.runInFlight == .prep {
            // #843: the tooltip shows this after the concept ("Finds a contact and drafts an email…"), so
            // "Finding contacts and drafting…" only said the concept again in the present tense. The live
            // detail's job here is just to say it is happening now.
            return AgentStatus(name: "Prep", state: .working, detail: "Running now…",
                               focus: .prep, count: i.keptToPrep)
        }
        // #2614: a reachability check holds the same single slot, so no Prep run can start, but nothing is
        // drafting. Dan's decision, shown the alternatives: state his real backlog AND why it cannot move,
        // rather than describing the check. The count and the focus stay on the backlog, so the number is
        // still a promise about the rows the tap lands on (#863), and "held by" is the phrasing the date
        // clash branch below already uses for a backlog that exists and cannot move (#1583/#1691).
        //
        // `.working` rather than `.needsAttention`: a held backlog is not something he can act on, and gold
        // is reserved for what he can, which is also what keeps it distinguishable from that clash.
        //
        // Said only when there IS a backlog. "0 ready, held by a check" would promise rows the tap cannot
        // land on, and with nothing kept the fact that Prep cannot start costs him nothing.
        if i.runInFlight == .reachabilityCheck, i.keptToPrep > 0 {
            return AgentStatus(name: "Prep", state: .working,
                               detail: "\(i.keptToPrep) ready, held by a check",
                               focus: .prep, count: i.keptToPrep)
        }
        // #1583/#1691: a show Dan kept and a booking then landed on. It outranks the ordinary backlog for
        // the same reason a send problem outranks an approved email waiting on a click: the routine case
        // resolves itself (the next Prep run picks those shows up), while this one is stuck until he
        // answers it, and before this focus existed it was stuck INVISIBLY, in no stage at all.
        //
        // A separate focus, never folded into the count above, because the Prep run still refuses these
        // shows: a number promising work the run will not do is the mismatch #863 exists to prevent.
        if i.prepBlocked > 0 {
            let n = i.prepBlocked
            return AgentStatus(name: "Prep", state: .needsAttention,
                               detail: "\(n) \(shows(n)) held by a date clash",
                               focus: .prepBlocked, count: n)
        }
        if i.keptToPrep > 0 {
            return AgentStatus(name: "Prep", state: .needsAttention, detail: "\(i.keptToPrep) ready to prep",
                               focus: .prep, count: i.keptToPrep)
        }
        return AgentStatus(name: "Prep", state: .idle, detail: "Nothing waiting", focus: .prep, count: 0)
    }

    private static func review(_ i: AgentInputs) -> AgentStatus {
        if i.toReview > 0 {
            // #2050: "N to review", not "N drafts to review". Approving no longer moves a show out of this
            // stage, so the number now covers a show Dan has approved but not yet sent as well as one he
            // has not read, and calling every one of them a draft would be false of the approved ones.
            // The unqualified count also reads like its neighbours ("464 to triage", "5 ready to prep").
            return AgentStatus(name: "Review", state: .needsAttention,
                               detail: "\(i.toReview) to review",
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
        // #2647: the send went out and its replies ARE watched; what was lost is the id Overture's own
        // next message would reference, so a nudge on that conversation reads as a separate one in any
        // client that isn't Gmail. Ranked below the reply-tracking gap, which is the worse of the two:
        // that one loses their answer entirely, this one only breaks how ours is filed.
        if i.degradedThreading > 0 {
            let n = i.degradedThreading
            return AgentStatus(name: "Send issues", state: .needsAttention,
                               detail: "\(n) \(shows(n)) sent, but a later nudge will arrive as a new email, not a reply",
                               focus: .sendThreadingDegraded, count: n)
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

    // #1134: the Reached out stage. The count rides in `detail` and the view shows it beside the name even
    // while idle (agentChip special-cases .reachedOut for exactly this). Empty detail when there is no one
    // yet, so the pill reads just "Reached out" rather than a bare "0".
    //
    // #2114: it is no longer permanently informational. It was hard-coded to .idle on the premise that
    // Follow-ups owned everything due, and that premise died when replies owing an answer moved into this
    // queue: Dan sat looking at a dimmed "Reached out 4" with Nicole waiting on him. It goes gold when any
    // of its own rows is due now or overdue, and says how many, because a gold pill whose number has not
    // changed does not say what changed. It stays quiet otherwise, since a pill that is always gold is a
    // pill nobody reads.
    private static func reachedOut(_ i: AgentInputs) -> AgentStatus {
        let due = i.reachedOutDue > 0
        // One construction rather than a return per branch, so the pill's NAME is written once: three
        // copies of it in one function is the drift docs/copy-inventory.md exists to surface.
        return AgentStatus(name: "Reached out",
                           state: due ? .needsAttention : .idle,
                           detail: due ? "\(i.reachedOutDue) due"
                                       : (i.reachedOut > 0 ? "\(i.reachedOut)" : ""),
                           focus: .reachedOut, count: i.reachedOut)
    }

    private static func shows(_ n: Int) -> String { Plural.word(n, "show") }   // #885: one pluralizer

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
