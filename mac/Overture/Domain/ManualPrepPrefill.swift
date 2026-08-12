import Foundation

// #2007: what the manual-prep editor already knows about who to send to, before Dan types anything.
//
// The rule is asymmetric BY SOURCE, and that asymmetry is the whole design (Dan's call, 2026-08-03):
//
//  - An address he has ALREADY EMAILED about this organisation is FILLED INTO the field. He wrote to it,
//    so it is trusted, and typing it again is work the app can do for him.
//  - An address off the BOOKING SHEET is only ever OFFERED beside the field, with its source named, and
//    he clicks to use it. `HistoryMatch` says why: that column "routinely holds an AGENT's address, an
//    ensemble's, an unrelated org's, or no address at all ('DM on instagram')". A prefilled field does
//    not invite the second look that would catch one of those.
//  - An address OVERTURE'S OWN RESEARCH put on this show is offered on the same terms, for the same
//    reason: nobody has written to it, so it carries a find's confidence, not a correspondence's.
//  - With none of the three, the field is empty and SAYS which sources were checked. An empty field with
//    no explanation is a silent failure, and the failure it hides is the one where an address existed and
//    the lookup missed it.
//
// Pure and SwiftData-free in the sense that matters: no ModelContext, no fetch, no file read. It is
// handed the prospects and the history and decides, so every branch above is reachable by a unit test.
enum ManualPrepPrefill {
    // One address Dan has provably emailed about this organisation, and the show he emailed it about, so
    // an address that appears by itself is never a mystery.
    struct PriorOutreach: Equatable, Sendable {
        let email: String
        let showName: String
        let sentAt: Date
    }

    enum SuggestionSource: Equatable, Sendable {
        case bookingSheet        // the imported booking history's free-text Email column
        case foundOnThisShow     // an address Overture found for this show and nobody has written to
    }

    struct Suggestion: Equatable, Sendable {
        let email: String
        let source: SuggestionSource
    }

    // Why the field is empty. Only ever set when there is nothing to fill AND nothing to offer, because
    // these two sentences are answers to "where did you look", and a field with a suggestion beside it is
    // not asking that question.
    enum EmptyReason: Equatable, Sendable {
        case nothingFound        // both sources were read, both came back with nothing
        case historyUnreadable   // the booking sheet could not be read, so it was NOT checked
    }

    struct Result: Equatable, Sendable {
        var filled: PriorOutreach?
        var suggestions: [Suggestion]
        var emptyReason: EmptyReason?
    }

    // `historyUnreadable` is what `LocalHistory.importedWithHealth` reports. It is passed in rather than
    // inferred from an empty array, because absent and corrupt are different answers (#754) and only the
    // caller that opened the file can tell them apart.
    static func build(for prospect: Prospect, amongst prospects: [Prospect],
                      history: [HistoryRecord], historyUnreadable: Bool = false) -> Result {
        let names = HistoryMatch.candidateNames(prospect.groupName, prospect.presenter)

        // Every address written to about this organisation, newest first. The prospect itself is included
        // (a show already emailed once is still the same org), which is why the caller passes the whole
        // list rather than "the others".
        let priors: [PriorOutreach] = prospects
            .filter { isSameOrg($0, as: names) }
            .flatMap { other in
                other.recipients.compactMap { r -> PriorOutreach? in
                    guard let sentAt = r.sentAt, let email = normalized(r.email) else { return nil }
                    return PriorOutreach(email: email, showName: other.groupName, sentAt: sentAt)
                }
            }
            .sorted { $0.sentAt > $1.sentAt }

        if let filled = priors.first {
            return Result(filled: filled, suggestions: [], emptyReason: nil)
        }

        var suggestions: [Suggestion] = []
        var seen = Set<String>()
        // This show's own found-but-unwritten-to addresses first: they are about THIS performance, where a
        // booking-sheet address is about the organisation in general.
        for r in prospect.recipients {
            guard r.sentAt == nil, let email = normalized(r.email), seen.insert(email).inserted else { continue }
            suggestions.append(Suggestion(email: email, source: .foundOnThisShow))
        }
        for record in HistoryMatch.confidentRecords(names: names, in: history)
            where record.origin == .bookingImport {
            for raw in HistoryMatch.addresses(in: record.email) {
                guard let email = normalized(raw), seen.insert(email).inserted else { continue }
                suggestions.append(Suggestion(email: email, source: .bookingSheet))
            }
        }

        guard suggestions.isEmpty else {
            return Result(filled: nil, suggestions: suggestions, emptyReason: nil)
        }
        return Result(filled: nil, suggestions: [],
                      emptyReason: historyUnreadable ? .historyUnreadable : .nothingFound)
    }

    // Same organisation, judged on the identities `HistoryMatch` already uses for this question (the
    // show's own title and its presenter), so this cannot drift into a second definition of who an org is.
    private static func isSameOrg(_ other: Prospect, as names: [String]) -> Bool {
        let theirs = HistoryMatch.candidateNames(other.groupName, other.presenter)
        return names.contains { mine in theirs.contains { GroupNameMatch.isConfident(mine, $0) } }
    }

    private static func normalized(_ email: String?) -> String? {
        guard let email else { return nil }
        let trimmed = email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return trimmed.isEmpty ? nil : trimmed
    }
}

// What the manual-prep editor will accept, in ONE place, so the Save button and the refusal that fires
// on click are the same rule: a button that looks enabled can never be refused, and a refusal can never
// name something the button did not gate on.
//
// #2052: a subject IS required. This originally reasoned that Dan might be writing into a thread that
// already had one, so an empty subject was a choice rather than an omission. It measured wrong: nothing
// downstream treats it as a choice. The draft saved, the show read as ready, and the send handed Gmail an
// empty `Subject:` header, with the confirmation sheet printing "(no subject)" beside a live Send button.
// He found it on the first show he prepped by hand: "Huge gap and easy to send without one." An email he
// is genuinely replying into a thread with is a reply, which is a different path with its own subject.
enum ManualPrepEditing {
    // #2544: what the sheet is refusing, as a value rather than as one of its two wordings. Everything
    // below is derived from it: whether Save draft is enabled, the reason shown beside it while it is not,
    // and the sentence spoken if a save is somehow attempted anyway. One predicate, three readings, so a
    // grey button and the reason next to it can never disagree, and the button can never be enabled while
    // a reason exists (L109).
    enum Refusal: Equatable {
        case needsRecipient
        case badAddress(String)
        case extraSeparator
        case needsSubject
        case needsBody

        // Why the button is refusing, in words that are true BEFORE any press.
        var reason: String {
            switch self {
            case .needsRecipient: return ActionAck.manualPrepNeedsRecipientReason
            case .badAddress(let piece): return ActionAck.manualPrepBadAddressReason(piece)
            case .extraSeparator: return ActionAck.manualPrepExtraSeparatorReason
            case .needsSubject: return ActionAck.manualPrepNeedsSubjectReason
            case .needsBody: return ActionAck.manualPrepNeedsBodyReason
            }
        }

        // The same refusal after a press, which is the only moment "Nothing was saved" is a true statement.
        var acknowledgement: String {
            switch self {
            case .needsRecipient: return ActionAck.manualPrepNeedsRecipient
            case .badAddress(let piece): return ActionAck.manualPrepBadAddress(piece)
            case .extraSeparator: return ActionAck.manualPrepExtraSeparator
            case .needsSubject: return ActionAck.manualPrepNeedsSubject
            case .needsBody: return ActionAck.manualPrepNeedsBody
            }
        }
    }

    // Nil when it can be saved, otherwise WHICH refusal applies.
    //
    // #2023: the address field is READ here, not merely checked for emptiness. It may name several people,
    // and a string that cannot be read as addresses must never reach a Recipient: its identity is what
    // reply detection, follow-ups, bounce handling and the booking match all key off, so one contact
    // identified by "a@x.org, b@y.org" sends, reports success, and can never match a reply from either.
    static func refusalKind(email: String, subject: String, body: String) -> Refusal? {
        switch EmailAddressList.parse(email) {
        case .empty:
            return .needsRecipient
        case .invalid(let piece):
            return piece.isEmpty ? .extraSeparator : .badAddress(piece)
        case .addresses:
            break
        }
        // Refused in the order the fields sit on the sheet (address, subject, body), so the sentence
        // names the first thing he would look at rather than the last rule that happened to run.
        if subject.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return .needsSubject
        }
        if body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return .needsBody
        }
        return nil
    }

    // What the save path says once a press has happened.
    static func refusal(email: String, subject: String, body: String) -> String? {
        refusalKind(email: email, subject: subject, body: body)?.acknowledgement
    }

    // What the sheet shows beside Save draft while it is grey. Nil exactly when the button is enabled, so
    // a live reason and a working button are mutually exclusive by construction.
    static func reasonSaveIsDisabled(email: String, subject: String, body: String) -> String? {
        refusalKind(email: email, subject: subject, body: body)?.reason
    }

    static func canSave(email: String, subject: String, body: String) -> Bool {
        refusalKind(email: email, subject: subject, body: body) == nil
    }
}

// The sentences the manual-prep editor says about the address, kept out of the view so the copy Dan
// reads is testable (#863) and shows up in `docs/copy-inventory.md` as words rather than as Swift.
enum ManualPrepCopy {
    static func editorTitle(groupName: String) -> String { "Prep \(groupName) by hand" }

    // The one line under the address field, which is never empty.
    //
    // Dan, on the shipped sheet: "wait I thought we just shipped the ability to email multiple people?" It
    // had shipped and it worked, but the field looks exactly like the single-address box it always was, so
    // the capability was invisible to the person it was built for, which is the same as not having it. The
    // line INVITES the second address until there is one, then CONFIRMS what the addresses will do. Never
    // both at once: that is the #843 defect, a second line saying what the first already said.
    static func addressFieldNote(for typed: String) -> String {
        recipientCountNote(for: typed)
            ?? "Separate several addresses with commas to email more than one person."
    }

    // #2023, and L64: who a message goes to belongs in what Dan reviews, so naming a second person has to
    // say so before he saves rather than after. Nil for one address, because a line telling him a single
    // address makes a single contact is the #843 defect: a sentence that adds nothing to the one above it.
    // #2034: the count, and ONLY the count. How the email goes out is stated by the switch directly
    // beside this line, so repeating it here would be the #843 defect: a second line telling him what the
    // control next to it already says. Still nil for one address, where neither fact is worth a sentence.
    static func recipientCountNote(for typed: String) -> String? {
        guard case .addresses(let addresses) = EmailAddressList.parse(typed), addresses.count > 1
        else { return nil }
        return "This adds \(addresses.count) contacts."
    }

    // Names the show only when it is a DIFFERENT one from the show being prepped. On an annual booking
    // both are "Bargemusic", and repeating the name Dan is already looking at is the #843 defect: a second
    // line that tells him nothing the first did not. When they differ it is the whole point of the line.
    static func filledRecipientNote(_ outreach: ManualPrepPrefill.PriorOutreach,
                                    prepping groupName: String) -> String {
        let when = EasternDate.dayLabelWithYear(outreach.sentAt)
        guard outreach.showName != groupName else { return "You emailed this address on \(when)." }
        return "You emailed this address about \(outreach.showName) on \(when)."
    }

    static func suggestionNote(_ source: ManualPrepPrefill.SuggestionSource) -> String {
        switch source {
        // Each says its own reason for not being filled in, rather than both ending on one shared
        // caution, which read as the same sentence twice whenever both appeared.
        case .bookingSheet:
            return "From your booking sheet, which often holds an agent's address rather than theirs"
        case .foundOnThisShow:
            return "Found by Overture for this show, never written to"
        }
    }

    // Names what was checked, so an empty field is a report rather than a shrug.
    static func emptyRecipientNote(_ reason: ManualPrepPrefill.EmptyReason) -> String {
        switch reason {
        case .nothingFound:
            return "No address to fill in. Checked past emails to this organisation and the booking sheet."
        case .historyUnreadable:
            return "No past email to this organisation, and the booking sheet could not be read."
        }
    }
}
