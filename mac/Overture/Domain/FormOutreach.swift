import Foundation

// #1630: how a contact was actually reached. Until now there was one channel (Gmail) and it was
// implicit, which is why `nil` reads as email rather than as unknown: every record written before
// this existed went out by email, and saying so costs no migration.
enum OutreachChannel: String, CaseIterable, Sendable {
    case email
    case contactForm = "contact_form"
}

extension Recipient {
    var outreachChannel: OutreachChannel {
        get { outreachChannelRaw.flatMap(OutreachChannel.init) ?? .email }
        set { outreachChannelRaw = newValue.rawValue }
    }
}

// #1630: everything the two surfaces SAY about a form pitch, out of the view bodies (the #885/#863
// rule). The stakes here are the same as the send screen's: these sentences are the only account Dan
// gets of an outreach Overture cannot observe.
enum FormOutreachCopy {
    static let copyAndOpen = "Copy pitch and open form"
    static let sentIt = "I sent it"
    static let didNotSend = "Didn't send"

    // Names when he started, because "did you send it?" about something he opened three weeks ago is a
    // question he has no way to answer.
    //
    // Except in the moment he pressed the button, when the row re-renders instantly and the relative
    // time renders as "in 0 seconds", which reads as a rendering fault rather than a fact. He was
    // there; the elapsed time only earns its place once enough of it has passed for him to have
    // forgotten. Caught by reading the rendered line cold, which is the only thing that catches it.
    static let elapsedWorthSaying: TimeInterval = 3_600

    static func awaitingQuestion(startedAt: Date, now: Date) -> String {
        guard now.timeIntervalSince(startedAt) >= elapsedWorthSaying else { return "Did you send it?" }
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .full
        return "You opened their form \(f.localizedString(for: startedAt, relativeTo: now)). Did you send it?"
    }

    // Deliberately NOT the #483 wording ("sent, but replies can't be watched"), which names a FAILURE Dan
    // should go and check in Gmail. Nothing failed here. Saying it the same way would send him hunting a
    // problem that does not exist (L11).
    static let sentLine = "Sent through their form. Overture cannot see a reply to this one."
}

// What the Review row offers for a form-only show, decided here so the SwiftUI row stays dumb and the
// rule is testable (#863). Four states, deliberately: the middle one (he opened the form and has not
// said whether he sent it) is a real thing that has happened, and collapsing it into either end is how
// a live pitch goes unrecorded.
enum FormPitch {
    enum State: Equatable {
        case unavailable
        case ready(recipientId: String, formURL: String)
        // Carries WHEN he opened the form, because the row has to say so: "did you send it?" about
        // something opened three weeks ago is a question he cannot answer.
        case awaitingConfirmation(recipientId: String, formURL: String, startedAt: Date)
        case recorded(at: Date)
    }

    static func state(of prospect: Prospect) -> State {
        if let recorded = prospect.recipients.compactMap(\.formOutreachRecordedAt).min() {
            return .recorded(at: recorded)
        }
        // Dan's scope (2026-07-28): forms only, and only where the form is the ONLY way through. A show
        // with a working address goes through Overture's own send path, so this can never become a way
        // to mark anything at all as pitched. `contactFormOnly` is the one shared judgment (#1626/#1629)
        // that already excludes a social page and the room's own booking form.
        guard prospect.reachabilityResultFromRecipients == .contactFormOnly else { return .unavailable }
        let candidates = prospect.recipients
            .filter { r in
                guard let raw = r.contactFormURL?.trimmingCharacters(in: .whitespacesAndNewlines) else { return false }
                return prospect.usableContactFormURLs.contains(raw)
            }
            .sorted { $0.sendOrderRank != $1.sendOrderRank ? $0.sendOrderRank < $1.sendOrderRank : $0.id < $1.id }
        guard let target = candidates.first,
              let formURL = target.contactFormURL?.trimmingCharacters(in: .whitespacesAndNewlines) else {
            return .unavailable
        }
        guard let startedAt = target.formOutreachStartedAt else {
            return .ready(recipientId: target.id, formURL: formURL)
        }
        return .awaitingConfirmation(recipientId: target.id, formURL: formURL, startedAt: startedAt)
    }
}

extension Prospect {
    // Dan copied the pitch and opened the form. Records nothing about an outreach (none has happened);
    // it only moves the row into the state that waits on his answer. Write-once, so re-opening the form
    // to check something does not restart anything.
    func beginFormPitch(_ recipient: Recipient, now: Date) {
        guard recipient.formOutreachStartedAt == nil else { return }
        recipient.formOutreachStartedAt = now
    }

    // Record that Dan pitched this contact through the act's own form. The stamping mirrors
    // SendService.deliver deliberately, field for field: the same recipient receipt, the same
    // write-once lead rollup (so the ~20 lead-level "was this contacted at all" readers keep
    // working), and the same flip to `.contacted` once nothing sendable is left. What it cannot
    // mirror is the Gmail side, and that absence is the point: no thread, no message id, so nothing
    // downstream goes looking for a conversation Overture cannot see.
    @discardableResult
    func recordFormOutreach(_ recipient: Recipient, now: Date, formURL: String? = nil) -> Bool {
        // Assume it runs twice. The recorded date is what the decide clock counts from and what #16
        // will attribute an outcome to, so a second click must not move it.
        guard recipient.formOutreachRecordedAt == nil else { return false }
        recipient.formOutreachPriorStatusRaw = status.rawValue
        recipient.outreachChannel = .contactForm
        recipient.formOutreachRecordedAt = now
        recipient.formOutreachURL = formURL
        recipient.sentAt = now
        recipient.sendState = .sent
        if sentAt == nil {
            sentAt = now
            priorRelationshipAtSend = priorRelationship
            freezeFeaturesAtSend()
            // Deliberately NOT stamping gmailThreadId/gmailMessageId: there is no conversation to
            // thread off and nothing for reply detection to watch.
        }
        freezeSentCopy(subject: draftSubject ?? "", body: recipient.effectiveBody ?? "")
        if !recipients.contains(where: \.isSendablePending) {
            status = .contacted
        }
        return true
    }

    // Unwind a form record Dan takes back ("Didn't send"), or a misclick. Refused once a real email has
    // also gone out on this show: the lead-level rollup (the send date, the frozen ranking features, the
    // relationship captured at send) then describes THAT send, and clearing it to unwind a form record
    // would rewrite the history of a genuine one. Refusing is honest; a partial undo is not.
    @discardableResult
    func undoFormOutreach(_ recipient: Recipient) -> Bool {
        guard recipient.formOutreachRecordedAt != nil else { return false }
        guard !recipients.contains(where: { $0.gmailMessageId != nil }) else { return false }

        if let raw = recipient.formOutreachPriorStatusRaw, let prior = ReviewStatus(rawValue: raw) {
            status = prior
        }
        recipient.formOutreachPriorStatusRaw = nil
        recipient.formOutreachRecordedAt = nil
        recipient.formOutreachURL = nil
        recipient.outreachChannelRaw = nil
        recipient.sentAt = nil
        recipient.sendState = .pending
        // Only this contact's record existed, so the show's whole send snapshot belongs to it.
        unfreezeSendSnapshot()
        return true
    }
}
