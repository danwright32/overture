import Foundation

// #1797/#1800: what a stage strip may double count, and who speaks for a held contact.
//
// The strip's numbers were each honest about their own predicate and silent about the set they shared
// with their neighbours. Nothing made the focuses exclusive and no test forbade an overlap, so one show
// could be promised by two pills at once and read as two pieces of work. Measured on the live store,
// 2026-08-01: of 507 live shows exactly one sat in two focuses, Raging of the Shrews (Under St Marks,
// Aug 14), counted under Scout as untriaged AND under Send issues as a show with a contact held for a
// check, on a show nothing had ever been sent to.
//
// Blanket exclusivity would be the wrong rule. A re-prep requested on a drafted show genuinely belongs
// to Prep and Review at once (PrepQueue.needsPrep admits `.drafted` and `.approved` when a re-prep is
// queued), and a show can genuinely have two send problems. So the rule is written down instead, as
// three invariants over the FAMILY a focus belongs to rather than as a table of pairs, which is what
// makes it survive a focus added later: `family` is exhaustive, so a new case cannot compile without
// someone saying which half of the funnel it is about.
enum StageOverlap {
    // Which question a focus asks. Lifecycle focuses ask where a show has got to; send-problem focuses
    // ask what went wrong with a send, which is orthogonal to that (a show can be drafted and also have
    // an earlier recipient's send stuck). The two that resolve no queue keys are their own case, since
    // no show is ever "in" them.
    enum Family: Equatable, Sendable {
        case lifecycle, sendProblem, resolvesNoKeys
    }

    // #2050: `.sendApproved` moved from lifecycle to sendProblem, because it stopped being a place a show
    // GETS TO. Review now holds a show from drafted until every contact has been emailed, so an approved
    // email's lifecycle position is Review; the only thing `.sendApproved` still answers is "how many
    // approved emails is a disconnected Gmail holding up", which is a problem with sending, and its pill
    // is the one called Send issues. Both rules below stay true of it under the new family: an approved
    // show is in the send half by SendHalf.entered, so it may carry a send problem.
    static func family(of focus: StageFocus) -> Family {
        switch focus {
        case .scout, .prep, .prepBlocked, .review: return .lifecycle
        case .sendApproved, .sendBlocked, .sendErrors, .sendStuck, .sendDegraded: return .sendProblem
        case .followUps, .reachedOut: return .resolvesNoKeys
        }
    }

    // The lifecycle focuses keyed purely on `status`, which is a single value, so a show can be in at
    // most one of them. `.prep` and `.prepBlocked` are deliberately NOT here: a re-prep request puts a
    // drafted or approved show in one of them alongside `.review`, which is a real state and not a
    // defect.
    static let mutuallyExclusiveByStatus: [StageFocus] = [.scout, .review]

    // What each rule is, in the words a failure should report. Kept beside the checks so a violation
    // names the rule it broke rather than only the focuses it found.
    // copy-inventory:ignore-start  test failure text, read by whoever broke a rule, never said to Dan (#915)
    enum Rule: String, Equatable, Sendable {
        case oneStatusFocus = "a show is in at most one status-keyed stage"
        case prepOrPrepBlocked = "a show is either ready to prep or held from prepping, never both"
        case sendProblemNeedsSendHalf = "only a show in the send half of the funnel can have a send problem"
    }
    // copy-inventory:ignore-end

    struct Violation: Equatable, Sendable {
        let key: String
        let rule: Rule
        let focuses: [StageFocus]
    }

    // Every way the strip is double counting right now, over real prospects. One implementation, so the
    // synthetic tests and the live-store claim are asking the same question rather than two similar ones.
    static func violations(in prospects: [Prospect], today: String = QueueModel.easternToday(),
                           now: Date = Date(), geo: GeoRefusals = .none) -> [Violation] {
        var found: [Violation] = []
        for p in prospects {
            let matched = StageNavigation.countedFocuses.filter {
                StageNavigation.naturalKeys(for: $0, in: [p], today: today, now: now, geo: geo).count == 1
            }
            let status = matched.filter { mutuallyExclusiveByStatus.contains($0) }
            if status.count > 1 {
                found.append(Violation(key: p.naturalKey, rule: .oneStatusFocus, focuses: status))
            }
            if matched.contains(.prep) && matched.contains(.prepBlocked) {
                found.append(Violation(key: p.naturalKey, rule: .prepOrPrepBlocked,
                                       focuses: [.prep, .prepBlocked]))
            }
            let problems = matched.filter { family(of: $0) == .sendProblem }
            if !problems.isEmpty && !p.hasEnteredSendHalf {
                found.append(Violation(key: p.naturalKey, rule: .sendProblemNeedsSendHalf,
                                       focuses: problems))
            }
        }
        return found
    }
}

// #1797: the one rule deciding WHO speaks for a contact a review guard is holding.
//
// `.sendBlocked` used to be the whole test `p.blockedContactCount > 0`, with no gate on status, on a
// draft existing, or on anything having been attempted. The comment above it stated the assumption that
// made that safe when #792 wrote it: a show with a held contact has usually already been sent to somebody
// else. That went stale when the triage reachability check (#1585) began writing contacts through
// PrepImporter, which runs the same three guards, so an untriaged show now collects guard flags without
// going anywhere near a send. Dan, 2026-07-30: "why is this marked as send issues if I've never tried to
// email them".
//
// A show in the send half keeps its held contact under Send issues, exactly as #792 built it. A show that
// is not there yet is spoken for by its triage card instead (Dan's call, 2026-08-01: he wants to see it
// while deciding keep or dismiss). The complement is the point: one predicate decides both, so a held
// contact is always said exactly once and can never fall silent between two surfaces, which is the #792
// defect this rule exists to prevent (L45).
enum SendHalf {
    static func entered(status: ReviewStatus, sentAt: Date?, hasSentRecipient: Bool) -> Bool {
        switch status {
        // A draft exists, so the send is the next thing that happens to this show and a held contact is
        // about to matter. #1797 names these three states.
        case .drafted, .approved, .contacted: return true
        // Not there yet by status, but a send that already went out settles it whatever the status says.
        case .new, .queued, .dismissed: return sentAt != nil || hasSentRecipient
        }
    }
}
