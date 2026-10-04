import Foundation

// #4357 (plan v7 Phase 3, slice E1): the computed members `StageNavigation.placements` reads, on the facts
// protocols, so a live model and a retained `RowFacts` answer every stage question by ONE body (L263, L370).
//
// In a file of its own rather than in ProspectFactsMembers.swift or ContactFactsMembers.swift, because slice
// D2 grows those beside this slice, and two slices editing one file at once is a merge waiting to happen.
//
// TWO KINDS, as slice D1 found.
//
// RULES OF THE ROW ALONE move outright and are deleted from the model, which answers them by conforming:
// `hasDraft`, `hasOpened(today:)`, `isReprepQueued`, `sendsTogether` on the show; `isLooksLikeAnotherPersons`
// and `isSendStuck(now:timeout:)` on the contact.
//
// RULES THAT NEED THE SHOW, or the show's other contacts, take them as arguments. A contact's draft holds and
// its greeting holds are judged on the SHOW's draft (`Recipient.effectiveBody` is `prospect?.draftBody`) and
// on how many people one send reaches, and a `ContactFacts` value has no show to ask. So the rule is written
// once here, over the body and the audience it is handed, and `Recipient` keeps its familiar members as one
// line each that hand it its own show's. The show side does the same with its contacts: `blockedContactCount`,
// `hasEnteredSendHalf` and `greetingAudienceSize` are written once over contacts they are handed, the protocol
// member hands them `factContacts` (the counted accessor, so a generic term pays for what it reads), and
// `Prospect`'s same-named members hand them its own `recipients`, uncounted as they always were, so no
// `WorkTally.recipientReaches` pin moves.
extension ProspectFacts {
    var hasDraft: Bool { draftBody != nil }

    // #861/#864/#1540: "is this show past the point where Dan would ever work it?", asked in one place. The
    // Scout pill asks it to decide what is still waiting on Dan, and the launch retirement asks it to decide
    // what has rotted; they are the same question. Once a run has OPENED its client no longer needs photos, so
    // the opening night decides, a run opening tonight has not opened, and an undated show has not opened.
    func hasOpened(today: String) -> Bool {
        EasternDate.runHasOpened(openingNight: performanceDate, today: today)
    }

    // #1940: a Prep run has work queued on this show, through the shared definition QueueItem's badge reads.
    var isReprepQueued: Bool {
        ReprepRequest.isQueued(draftRequested: reprepDraftRequested, contactsRequested: reprepContactsRequested)
    }

    var sendsTogether: Bool { sendsTogetherOverride ?? true }

    // #2545: how many people ONE send reaches, which is what decides whether a greeting may name somebody.
    // Sending separately is one email each however many contacts the show carries, so the answer there is one.
    // Deliberately NOT `SendGroup.previewGroup`, which filters on `isSendablePending`, and the greeting hold is
    // part of that predicate, so asking it would have the two read each other without end. This counts who could
    // receive the mail from the fields alone: a contact held by some OTHER guard is still a person the greeting
    // has to be right for once that guard clears.
    func greetingAudienceSize(among contacts: [some ContactFacts]) -> Int {
        let reachable = contacts.filter {
            $0.sendState == .pending && $0.email?.isEmpty == false && !$0.pausedByReply
        }
        return sendsTogether ? reachable.count : min(reachable.count, 1)
    }

    var greetingAudienceSize: Int { greetingAudienceSize(among: factContacts) }

    // #792: contacts on this show held back by a review guard and waiting on Dan. A show can be genuinely
    // contacted AND still have somebody waiting, and both facts have to survive at once.
    // #3498: given a way to look up each contact's lint findings rather than deriving them, for a card build
    // that already holds the answer. One definition of what counts as blocked, two spellings.
    func blockedContactCount<C: ContactFacts>(among contacts: [C], lintBlockers: (C) -> [DraftIssue]) -> Int {
        contacts.filter {
            $0.isBlockedAwaitingReview(body: draftBody, audience: greetingAudienceSize(among: contacts),
                                       lintBlockers: lintBlockers($0))
        }.count
    }

    func blockedContactCount(among contacts: [some ContactFacts]) -> Int {
        blockedContactCount(among: contacts) { $0.draftLintBlockers(body: draftBody) }
    }

    var blockedContactCount: Int { blockedContactCount(among: factContacts) }

    // #1797: whether this show has reached the half of the funnel a send belongs to, which decides who speaks
    // for a held contact (Send issues, or the triage card). One rule, in SendHalf.
    func hasEnteredSendHalf(among contacts: [some ContactFacts]) -> Bool {
        SendHalf.entered(status: status, sentAt: sentAt, hasSentRecipient: contacts.contains { $0.sendState == .sent })
    }

    var hasEnteredSendHalf: Bool { hasEnteredSendHalf(among: factContacts) }
}

extension ContactFacts {
    var isLooksLikeAnotherPersons: Bool { looksLikeAnotherPersons && !looksLikeAnotherPersonsDismissed }

    // True when a send was claimed and has run long enough to be considered stuck rather than a normal brief
    // send (#475/#476): the app was interrupted between claiming the send and recording its outcome. Must be
    // surfaced for Dan to check Gmail and resolve by hand: never auto-resent and never auto-assumed sent.
    func isSendStuck(now: Date, timeout: TimeInterval = RunTimeouts.send) -> Bool {
        guard sendState == .sending, let claimed = sendClaimedAt else { return false }
        return now.timeIntervalSince(claimed) >= timeout
    }

    // #789: the blocking lint findings in the text this contact would be sent (the show's draft, `body`).
    // Derived live rather than stored at ingest: a pure function of text already on disk, so it can never go
    // stale. #2048: counted at the point the lint really runs, AFTER the empty-body guard, so the number is
    // the work done rather than the times the question was asked.
    func draftLintBlockers(body: String?) -> [DraftIssue] {
        guard let body, !body.isEmpty else { return [] }
        QueueRenderPass.WorkTally.recordDraftLintRun()
        return DraftCheck.blockingFindings(in: body)
    }

    // True only when the outgoing text is the EXACT text Dan overrode; a mismatch (edited since, or never
    // overridden) means the block still applies.
    func isLintOverridden(body: String?) -> Bool {
        lintOverriddenBody != nil && lintOverriddenBody == body
    }

    func isBlockedByDraftLint(body: String?, lintBlockers: @autoclosure () -> [DraftIssue]) -> Bool {
        !lintBlockers().isEmpty && !isLintOverridden(body: body)
    }

    // #2545: the body must open with a greeting, because nothing composes one above it any more. A missing
    // body is not this guard's business (the send already refuses one), so it answers false.
    func draftIsMissingGreeting(body: String?) -> Bool {
        guard let body, !body.isEmpty else { return false }
        return !DraftGreeting.opensWithAGreeting(body)
    }

    // #2545: a greeting that names one person on an email more than one person receives. `audience` is nil
    // for a contact with no show, which is never misaddressed. #3549 removed the performer carve-out.
    func greetingMisaddressed(body: String?, audience: @autoclosure () -> Int?) -> Bool {
        guard let audience = audience() else { return false }
        return audience > 1 && DraftGreeting.namesSomeone(body)
    }

    // #2579: the greeting names somebody who is clearly not this contact, the single-contact case the
    // audience guard above cannot see.
    func greetingNamesSomeoneElse(body: String?) -> Bool {
        DraftGreeting.namesSomeoneElse(greeting: body, contactName: name)
    }

    // #2545: Dan's override of the greeting holds, pinned to the EXACT text he took it on.
    func isGreetingOverridden(body: String?) -> Bool {
        greetingOverriddenBody != nil && greetingOverriddenBody == body
    }

    // #2579 joins this disjunction rather than standing beside it, so it inherits Dan's override.
    func isBlockedByGreeting(body: String?, audience: @autoclosure () -> Int?) -> Bool {
        (draftIsMissingGreeting(body: body) || greetingMisaddressed(body: body, audience: audience())
            || greetingNamesSomeoneElse(body: body))
            && !isGreetingOverridden(body: body)
    }

    // `@autoclosure` is load bearing on both deferred arguments: the guard returns false for a contact that is
    // not pending WITHOUT consulting the lint or counting the audience, and Swift evaluates arguments eagerly,
    // so a plain parameter would run a whole pass of `DraftCheck` for every already-sent contact before the
    // guard could refuse it (measured 2026-09-03: 24 extra lint runs per render; L62).
    func isBlockedAwaitingReview(body: String?, audience: @autoclosure () -> Int?,
                                 lintBlockers: @autoclosure () -> [DraftIssue]) -> Bool {
        guard sendState == .pending, email?.isEmpty == false, !pausedByReply else { return false }
        // #2545: the greeting hold belongs HERE and not only in `isSendablePending`: a body that forgot its
        // greeting is one edit from sendable, so the person behind it is waiting, not finished.
        return isBlockedByGreeting(body: body, audience: audience())
            || (looksLikeVenue && !looksLikeVenueDismissed)
            || (looksLikePressContact && !looksLikePressContactDismissed)
            || (looksLikeDuplicateContact && !looksLikeDuplicateContactDismissed)
            || isLooksLikeAnotherPersons
            || isBlockedByDraftLint(body: body, lintBlockers: lintBlockers())
    }
}
