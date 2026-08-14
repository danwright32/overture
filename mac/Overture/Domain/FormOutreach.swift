import Foundation

// #1630: how a contact was actually reached. Until now there was one channel (Gmail) and it was
// implicit, which is why `nil` reads as email rather than as unknown: every record written before
// this existed went out by email, and saying so costs no migration.
enum OutreachChannel: String, CaseIterable, Sendable {
    case email
    case contactForm = "contact_form"
}

extension Recipient {
    // #2716: HOW THE PITCH WENT OUT, and nothing else. It is stamped at send and never flips (L37): a
    // pitch that left through a contact form did not retrospectively become an email because a reply to
    // it arrived by one. Milestone #58 lets Dan attach the Gmail conversation such a pitch was answered
    // on, and the question that then matters, "can Overture watch this?", is the separate predicate
    // below rather than a second meaning loaded onto this one.
    var outreachChannel: OutreachChannel {
        get { outreachChannelRaw.flatMap(OutreachChannel.init) ?? .email }
        set { outreachChannelRaw = newValue.rawValue }
    }

    // #2716: is there a conversation Overture can read on this contact? Written by every genuine send
    // (`SendService.deliver`, the reply path, the batch send), by `RecipientBackfill` carrying a lead
    // rollup down, and, from #2715, by Dan attaching one to a form or DM pitch by hand.
    //
    // An empty string is not a conversation. SwiftData hands back whatever was stored, and a blank id
    // would otherwise read as watchable and be fetched, which is why every Gmail reader in the app
    // already spells the same `!isEmpty` guard inline. One definition instead of six.
    var hasWatchableConversation: Bool {
        guard let t = gmailThreadId else { return false }
        return !t.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    // #2716: a pitch Overture can neither send on nor watch, which until this milestone was the whole
    // meaning of `.contactForm`. The four rules that used to ask the channel ask this instead, so a form
    // pitch carrying an attached conversation stops being treated as a silent one.
    var isUnwatchedFormPitch: Bool {
        outreachChannel == .contactForm && !hasWatchableConversation
    }
}

// #1630: everything the two surfaces SAY about a form pitch, out of the view bodies (the #885/#863
// rule). The stakes here are the same as the send screen's: these sentences are the only account Dan
// gets of an outreach Overture cannot observe.
enum FormOutreachCopy {
    static let copyAndOpen = "Copy pitch and open form"
    // #2612: the same two-step act with a different app open, so it is the same control with the right
    // noun in it rather than a second control. What goes on the clipboard is unchanged and needs no
    // change: `OutgoingPitch.text` has only ever copied the BODY, never a subject line, so a DM (which
    // has no subject) was already handled by the path this reuses.
    static let copyAndOpenProfile = "Copy pitch and open profile"
    static func copyAndOpen(isSocial: Bool) -> String { isSocial ? copyAndOpenProfile : copyAndOpen }
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

    // #2169: WHERE the pitch went, for the slot that names who the next email reaches on every other row.
    //
    // Dan, reading the Alex Syiek row cold: "why does it say 'no contact' and 'sent through their form'".
    // The slot fell back to "no contact" because a form pitch has no address, while the record it renders
    // from was holding the form URL the whole time. A line may claim only what its check measured, and
    // what was measured is "no email address", not "no contact" (L11).
    //
    // The host alone, without the scheme, the leading www or the path: "alexsyiek.com" reads as a place
    // Dan recognises, where the full URL reads as a link he has to parse. Nil rather than a guess when
    // there is no usable host, so the caller decides what to say instead of being handed a fragment.
    static func routeLine(formURL: String?) -> String? {
        guard let formURL, !formURL.isEmpty,
              let host = URL(string: formURL)?.host(), !host.isEmpty else { return nil }
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }

    static func awaitingQuestion(startedAt: Date, now: Date, isSocial: Bool = false) -> String {
        guard now.timeIntervalSince(startedAt) >= elapsedWorthSaying else { return "Did you send it?" }
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .full
        let when = f.localizedString(for: startedAt, relativeTo: now)
        // #2612: named for what he actually opened, so the question is answerable. "You opened their
        // form" about an Instagram profile is a question about something that did not happen.
        guard isSocial else { return "You opened their form \(when). Did you send it?" }
        return "You opened their profile \(when). Did you send it?"
    }

    // Deliberately NOT the #483 wording ("sent, but replies can't be watched"), which names a FAILURE Dan
    // should go and check in Gmail. Nothing failed here. Saying it the same way would send him hunting a
    // problem that does not exist (L11).
    static let sentLine = "Sent through their form. Overture cannot see a reply to this one."
    // #2612: the same fact about a DM. Its own sentence because "through their form" is false of one,
    // and this line is the only account Dan gets of an outreach Overture cannot observe.
    static let sentLineSocial = "Sent as a DM. Overture cannot see a reply to this one."
    static func sentLine(formURL: String?) -> String {
        guard let formURL, Reachability.isSocialOnly(formURL) else { return sentLine }
        return sentLineSocial
    }

    // #2716: the same fact once Dan has attached the conversation the presenter answered on (#2715).
    // The route still leads, because that is where the pitch actually went and it is what Dan
    // recognises; what changes is the half that is no longer true. Leaving the old line up beside the
    // address the attach saved would put two adjacent statements on the card, each correct alone,
    // contradicting each other on the surface he triages from (L118, #843).
    static let watchedLine = "Sent through their form. Overture is watching the email conversation you linked."
    static let watchedLineSocial = "Sent as a DM. Overture is watching the email conversation you linked."

    // #2711: and the same fact once Dan has told Overture they answered on a channel it cannot watch.
    // The "cannot see a reply to this one" half is true right up until he says one arrived, and leaving
    // it up then would have the card contradict the reply badge beside it (L118, #843). It says who
    // recorded it, because a reply Overture read and a reply Dan reported are different things and the
    // row must not blur them.
    static let markedLine = "Sent through their form. You told Overture they replied."
    static let markedLineSocial = "Sent as a DM. You told Overture they replied."

    // One entry point for what the card says about the route, so a caller cannot pair the wrong half of
    // the pair with the wrong state.
    //
    // An attached conversation wins over a hand mark: Overture really is watching one, which is the more
    // useful fact and the one that says where the words are.
    static func channelLine(formURL: String?, hasWatchableConversation: Bool,
                            replyMarkedByHand: Bool = false) -> String {
        let isSocial = formURL.map(Reachability.isSocialOnly) ?? false
        if hasWatchableConversation { return isSocial ? watchedLineSocial : watchedLine }
        if replyMarkedByHand { return isSocial ? markedLineSocial : markedLine }
        return isSocial ? sentLineSocial : sentLine
    }
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
        // #2612: and a social DM, which is the same act with a different app open. Dan asked for the
        // existing path to be reused rather than a second one built, and the scope rule is unchanged:
        // only where a hand route is the ONLY way through, so this can never become a way to mark a show
        // with a working address as pitched.
        let verdict = prospect.reachabilityResultFromRecipients
        guard verdict == .contactFormOnly || verdict == .socialOnly else { return .unavailable }
        let routes = prospect.usableContactFormURLs + prospect.socialRouteURLs
        let candidates = prospect.recipients
            .filter { r in
                guard let raw = r.contactFormURL?.trimmingCharacters(in: .whitespacesAndNewlines) else { return false }
                return routes.contains(raw)
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
