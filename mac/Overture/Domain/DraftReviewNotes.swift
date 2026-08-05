import Foundation

// #885: the sentences on the draft review screen, out of the view body.
//
// This is the screen with the most at stake: the last thing between a draft and a stranger's inbox. It
// tells Dan a draft WON'T send, that a contact is HELD BACK from sending, and that a send went out
// DESPITE a warning he confirmed. Each of those is a claim about what the app is doing, and each was a
// string assembled inside a SwiftUI body, where no test could read it.
//
// Pure functions, never a computation inside the body: a rule computed in a view is a rule no test can
// reach, and two of those have already drifted here under a green suite (#863, #876).
enum DraftReviewNotes {

    // #789's deliberate audit trail. An overridden warning TONES DOWN rather than disappearing, so there
    // is still a visible record that the send happened despite it. A sentence that vanished on override
    // would erase precisely the thing worth keeping.
    static func salutation(needsReview: Bool, overridden: Bool) -> String? {
        guard needsReview else { return nil }
        guard !overridden else { return "Sending despite the greeting warning you confirmed." }
        return "This old draft may still have a name in the greeting Overture couldn't safely remove; "
            + "edit it before sending."
    }

    // The same shape for the draft lint (#789). Blocked names what is holding it; overridden leaves the
    // trail; a clean draft says nothing, because a note that fires on every draft is a note Dan skims.
    static func lint(blocked: Bool, blockers: [DraftIssue]) -> String? {
        if blocked { return DraftCheck.blockMessage(blockers: blockers) }
        guard !blockers.isEmpty else { return nil }
        return "Sending despite the draft warning you confirmed."
    }

    // #843: the blocking lint findings appear as warning flags near the draft body AND, while the draft is
    // still blocked, in the "This draft won't send: …" gate by the button, which names the very same
    // reason. That is the same finding on one screen twice. The gate is the one to keep (it sits with the
    // button and its Override), so the flags near the body step aside exactly when it is showing. After an
    // override the gate no longer names the reason (it tones down to "Sending despite the draft warning
    // you confirmed."), so the flags come back: they are then the only place the finding is still shown.
    //
    // #2050: no longer asks whether the show is approved. The gate used to appear only on an approved
    // card, so before approval both were shown and this had to say so; now that one button carries the
    // draft all the way to sent, the gate is beside it the whole time.
    static func showsBlockingFlagsNearBody(lintBlocked: Bool) -> Bool {
        !lintBlocked
    }

    // Whether the ADVISORY voice findings are shown. They exist to catch the drafter's AI-tells, so they
    // stand down once the words are Dan's: on a draft he edited (the rule since #11), and #2007's case,
    // one he wrote from scratch, where they were never a model's words at all.
    //
    // This says nothing about the BLOCKING findings, which show whatever the provenance and are what
    // actually holds the send. That is deliberate: the manual path is a shortcut around the model, not
    // around the quality gate.
    static func showsVoiceFindings(editedByDan: Bool, writtenByDan: Bool) -> Bool {
        !editedByDan && !writtenByDan
    }

    // #1311: an approved show with NO emailable contact at all can never send (SendService hard-blocks a
    // blank address), and the greyed Send button never said why. This explains the stall so Dan can act,
    // rather than leaving him staring at a disabled button. Only when there is genuinely no address: an
    // email held by a review guard is a different, already-explained case, and saying "no email to send
    // to" there would be untrue.
    // #2052: an approved draft with no subject line can never send (Recipient.isSendablePending holds
    // it), and without this the Send button is simply greyed with nothing said. The same shape as
    // noSendableEmail below, for the same reason: a disabled control that does not say why is a dead end.
    // It names the fix, because unlike a missing contact this one is two clicks away in the editor.
    // #2050/#2012: no longer gated on approval, and no longer opening with "Approved, but". Approving is
    // not a separate step Dan can reach any more, so a sentence that waited for it was a sentence that
    // never arrived: he met a greyed-out button with nothing said beside it. Everything that holds a send
    // holds it while the draft is still a draft, so this speaks there.
    static func noSubject(subject: String?) -> String? {
        guard (subject ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return "No subject line. Edit the draft to add one."
    }

    static func noSendableEmail(hasPendingRecipient: Bool, hasAnyEmailContact: Bool) -> String? {
        guard !hasPendingRecipient, !hasAnyEmailContact else { return nil }
        return "No email to send to. Add a contact by hand."
    }

    // #792: "Sent" was once the whole story, and a contact held back by a review guard is not sendable,
    // so a show read as fully done while a real person never received anything. This count is what says
    // otherwise, and a count is a promise about rows (#863).
    static func heldContacts(_ count: Int) -> String? {
        guard count > 0 else { return nil }
        return "\(count) \(count == 1 ? "contact" : "contacts") held for a check"
    }

    // The three contact warnings. Each names WHY the contact is suspect and then states the
    // CONSEQUENCE, which is the load-bearing half: this person will not be emailed until Dan says so.
    static func venueSuspect(name: String) -> String {
        "\(name) may be the venue itself, not the act; blocked from sending."
    }

    static func pressSuspect(name: String) -> String {
        "\(name) may be a press/media contact, not the act; blocked from sending."
    }

    static func duplicateSuspect(name: String) -> String {
        "\(name) may already be pitched for a nearby show; blocked from sending."
    }
}

// #885 (guard sweep): the rest of DraftReviewView's computed copy.
extension DraftReviewNotes {
    // A destructive, irreversible choice, and it names the ORGANIZATION it will silence. The one button
    // in the app whose label must never be able to name the wrong org.
    static func neverContactOrg(groupName: String) -> String { "Never contact \(groupName) again" }

    // A performer with their own directly-addressed draft gets a DIFFERENT email from the shared one
    // above it. Saying whose, and what, is the entire point.
    static func willInsteadReceive(name: String) -> String { "\(name) will instead receive:" }

    static func willReceive(body: String) -> String { "Will receive: \(body)" }

    // The two-step confirm behind an override: it repeats WHAT is blocking before asking him to send
    // anyway, so the confirm is never a bare "are you sure" about a fact he has forgotten.
    static func lintOverrideConfirm(blockers: [DraftIssue]) -> String {
        DraftCheck.blockMessage(blockers: blockers)
            + " Confirm you've checked it and it's fine to send as-is."
    }
}

// #885: "Connect Gmail first" was written out four times, in four files, as the disabled half of a
// ternary on a Send button's help. One sentence, one home. A send affordance that cannot explain why it
// is disabled is a dead button, which is the #888 failure in miniature.
enum GmailCopy {
    static let notConnected = "Connect Gmail first"

    // #2087's "Anyone reading in dark mode sees a white box around your signature. Edit it in Gmail
    // settings." is GONE, deliberately, and this note is here so nobody adds it back without reading why.
    //
    // It told Dan to fix the signature in Gmail Settings. On 2026-08-04 that turned out to be impossible:
    // the bordered wrappers come from the signature generator's own markup, so they ride along with any
    // copy of the rendered signature, and Gmail's editor offers no way to select a wrapper or set a
    // border colour. A refetch after Dan re-pasted his signature returned a genuinely different value
    // with all three border rules byte identical. So the sentence was asking him to do something that
    // could not be done, which is worse than saying nothing (L21: copy is a contract).
    //
    // Overture strips those borders on the way out instead (#2086, Dan's call). Because the stripper is
    // defined as removing exactly what GmailSignatureHealth.darkBackgroundReason flags, nothing it flags
    // can survive to the message being previewed, so the warning became UNREACHABLE rather than merely
    // rare, and unreachable copy pretending to be a guard is the thing L29 says to delete. If a
    // dark-background defect outside the detector's reach ever needs surfacing, that is a new sentence
    // with a new check behind it, not this one revived.

    // #2086: the preview's Light and Dark switch. The preview had one background, true white, which is
    // the one background a white border is invisible on, so it could not show what a dark-mode reader
    // gets. This says what the two buttons are for, on a control whose labels alone do not say whose
    // background it means.
    static let previewBackgroundHelp =
        "Show this email the way a recipient reading in light or dark mode sees it."

    static func sendHelp(connected: Bool, whenConnected: String) -> String {
        connected ? whenConnected : notConnected
    }

    // The masthead's own wording, deliberately NOT the terse "Connect Gmail first" above. This is where
    // a first-time user meets the idea, so it says what authorizing is FOR. Preserved word for word:
    // collapsing it into the shared sentence would have quietly changed what Dan reads.
    static func connectionHelp(connected: Bool) -> String {
        connected
            ? "Gmail is connected for sending"
            : "Authorize your photography Gmail so you can send approved emails"
    }
}
