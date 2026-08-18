import Foundation

// #2919: the row says that a reply arrived and that Dan answered it.
//
// #2170 gave the app a way to record that he answered, and every surface then went quiet about it. Once
// `replyHandledAt` clears a reply, `hasUnhandledReply` goes false, the Answer control retires itself, and
// the reached-out row falls back to exactly what it draws for a pitch nobody ever replied to: the group
// name, the show's date, and "Close this out". Measured on the live store 2026-08-17, a contact had
// written twice and Dan had answered both times, once from Overture and once from his mail client, and
// the row carried no trace of either. He asked why the reply had not been picked up. It had.
//
// That is L152 in its plainest form: the act that RESOLVES a conversation silences every surface that
// could have reported it, so the most complete success is the one the product says least about.
//
// Four decisions are recorded here rather than in the view, because they are the whole of what this is.
//
// WHAT IT SAYS. Two facts, and only the two the row is missing: somebody wrote, and it has been answered.
// The row already carries the group name, the show's date, the source listing (#2816) and the audience,
// so the line adds none of those again (#843). Dates are ABSOLUTE, like the show-date line above and
// unlike the relative countdown in the trailing column, which is what keeps the two from collapsing into
// one sentence (#2551's rule).
//
// WHETHER IT NAMES WHO WROTE. It does not, because the row already does. The writer's address is drawn
// among the audience in semibold ink while every other line is regular inkSoft, and its accessibility
// label already says "replied" (#2121). That marking survives the answer, because it is keyed on
// `replyFromAddress`, which nothing clears. `AnsweredReplyNoteTests` pins that rather than assuming it.
// Repeating the name here would be a line telling Dan nothing the line beside it did not.
//
// WHETHER IT SAYS WHERE HE ANSWERED FROM. It does not, because Overture cannot honestly tell. Only
// `recordAnswerSent` leaves `sentReplyBody`, so its presence proves an answer went through Overture, but
// its ABSENCE covers four different causes: a peer on a joint reply (#2191), an OmniFocus tick (#2899),
// an attach (#2715), and an answer sent from his mail client (#2865). #2865 declined a stored marker for
// exactly this, on purpose. A line naming one of four causes would be a claim its check never made (L11),
// and the decision this row asks for (is this conversation live, do I chase it) does not turn on which
// app the answer left from.
//
// HOW LONG IT LASTS. Until Dan closes the pitch out, or until they write again. It is derived from two
// stored stamps and never from the clock, so it cannot age off on its own, which is the same rule that
// keeps a sent pitch on this stage until he ends it. A new reply outranks it: the row goes back to asking,
// and this goes quiet, because answered and waiting are two states and never one.
enum AnsweredReplyNote {

    // The peer whose answered exchange this row reports, or nil when there is none.
    //
    // Resolved over the send group rather than read off the contact the list happens to stand on, which is
    // #2113's lesson in this exact area: the row's representative is chosen by the queue and is not
    // guaranteed to be the person who wrote. `SendGroup.peers` is the same grouping `AnsweredReply`
    // fans the answered stamp out over, so this can only ever report an exchange the row is about.
    //
    // Newest answer wins, so a group that has been round twice reports the exchange Dan finished last.
    static func exchange(for recipient: Recipient, in prospect: Prospect) -> Recipient? {
        SendGroup.peers(of: recipient, in: prospect)
            .filter(\.replyIsAnswered)
            .max { ($0.replyHandledAt ?? .distantPast) < ($1.replyHandledAt ?? .distantPast) }
    }

    // The sentence, or nil where there is nothing to report.
    //
    // Nil rather than a placeholder is the whole of the empty branch: no heading over an absence, no
    // reserved gap, nothing at all on the three other states this row can be in (L45, #1547).
    static func line(for recipient: Recipient, in prospect: Prospect, now: Date) -> String? {
        guard let answeredPeer = exchange(for: recipient, in: prospect),
              let arrived = answeredPeer.replyArrivedAt,
              let answered = answeredPeer.replyHandledAt else { return nil }
        return text(arrived: arrived, answered: answered, now: now)
    }

    // The copy itself, over the two instants, so the wording is testable without a store.
    static func text(arrived: Date, answered: Date, now: Date) -> String {
        // A pitch never ages off until Dan closes it, so a row can sit here past new year, and "Nov 2"
        // for a date eleven months back reads as this coming November (#2007's finding, in
        // `dayLabelWithYear`). Once EITHER end needs its year, BOTH carry it: one bare and one dated in
        // a single sentence reads worse than either rule applied consistently.
        let needsYear = !isThisYear(arrived, now: now) || !isThisYear(answered, now: now)
        let theirs = label(arrived, withYear: needsYear)
        let his = label(answered, withYear: needsYear)
        // Answering the same day is the common case, and "you answered Aug 14" printed directly beside
        // "Replied Aug 14" reads as a rendering fault rather than as a fact. Same two facts, said the way
        // a person says them. The same reasoning as FormOutreachCopy's elapsed-time guard (#2169).
        guard theirs != his else { return "Replied \(theirs), you answered that day" }
        return "Replied \(theirs), you answered \(his)"
    }

    // Eastern throughout, like every other date this app puts on screen, so a late-evening answer is
    // dated the day Dan actually sent it rather than the UTC day after it.
    private static func label(_ date: Date, withYear: Bool) -> String {
        guard !withYear else { return EasternDate.dayLabelWithYear(date) }
        let day = EasternDate.dayString(from: date)
        return EasternDate.dayLabel(day) ?? day
    }

    private static func isThisYear(_ date: Date, now: Date) -> Bool {
        EasternDate.dayString(from: date).prefix(4) == EasternDate.dayString(from: now).prefix(4)
    }
}
