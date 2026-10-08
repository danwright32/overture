import Foundation

// #3654 step 4c: THE READER, built in the same change as the check.
//
// A detector that reports to nobody is the brief unmet, and a field only ever written looks alive to
// every is-this-used check while the purpose it was added for silently never happens (L46). This is
// `FreezeReport`'s shape, deliberately: the same file layout, the same once-per-record rule, the same
// memory of what has already been said, and its own words.
enum CardDivergenceReport {

    // What Dan is told, or nil when there is nothing new to tell him.
    //
    // THREE STATES, each with its own wording, because an empty file means all three (L11, L98):
    //
    //   1. nothing new to say                      nil, and nothing is drawn
    //   2. the check found a wrong card            the report
    //   3. the check has never run at all          said plainly, because a queue whose cards are all
    //                                              correct and a queue nothing has ever checked leave the
    //                                              same empty file
    //
    // State 3 is why `CardDivergenceLog.lastRanKey` exists. Without a stamp, "the narrowing is sound" and
    // "nothing has ever looked" are one silence, and a monitor that has never once passed is not
    // measuring anything (L557).
    static func newlyReported(in support: URL,
                              now: Date = Date(),
                              defaults: UserDefaults = .standard,
                              read: (URL) -> CardDivergenceLog.Read = CardDivergenceLog.read(at:)) -> String? {
        let found = read(CardDivergenceLog.url(in: support))
        let alreadySaid = Set(defaults.stringArray(forKey: CardDivergenceLog.reportedIdsKey) ?? [])
        // #4354: only CARD divergences are said as wrong cards. The log now holds other kinds (the queue
        // engine's no-op dirties and fact mismatches, #4358), and counting one of those here would tell Dan
        // a card was built wrongly when none was (L11). Saying those kinds is the verifier's reader, #4358.
        let fresh = found.records.filter { $0.kind == .cardDivergence && !alreadySaid.contains($0.identity) }
        defaults.set(found.records.map(\.identity), forKey: CardDivergenceLog.reportedIdsKey)

        if let worst = fresh.max(by: { $0.fields.count < $1.fields.count }) {
            return CardDivergenceCopy.report(count: fresh.count, fields: worst.fields,
                                             unreadableLines: found.unreadableLines)
        }
        // A FILE WITH RECORDS IN IT IS ITSELF PROOF THE CHECK RAN, whatever the stamp says, and reading
        // only the stamp got this wrong: after saying a divergence once, the next launch fell through to
        // "nothing has ever looked" while holding the record that proves otherwise. The stamp exists for
        // the case where there is nothing else to go on, which is an EMPTY file (L11).
        // #4354: a CARD divergence is that proof; the queue engine's other kinds say nothing about whether
        // the card check ran, so a file holding only those falls through to the stamp.
        guard !found.records.contains(where: { $0.kind == .cardDivergence }) else { return nil }
        // Said ONCE per install rather than on every launch with nothing to report. A notice carrying no
        // action, delivered every time, is what teaches a person to skip the whole surface.
        guard defaults.object(forKey: CardDivergenceLog.lastRanKey) == nil,
              !defaults.bool(forKey: CardDivergenceLog.neverRanSaidKey) else { return nil }
        defaults.set(true, forKey: CardDivergenceLog.neverRanSaidKey)
        _ = now
        return CardDivergenceCopy.neverRan
    }

    // The WRITE side's decision about the stamp, as a pure function so the throttle can be exercised
    // rather than watched not to happen.
    //
    // Throttled to once a minute because the check runs on every render pass, and a defaults write per
    // render is a cost on the exact path this milestone exists to make cheap. What the stamp has to
    // support is only "has this ever looked, and recently", which a minute answers exactly as well as a
    // millisecond.
    static let stampInterval: TimeInterval = 60

    static func shouldStamp(last: Date?, now: Date, interval: TimeInterval = stampInterval) -> Bool {
        guard let last else { return true }
        return now.timeIntervalSince(last) >= interval
    }
}

enum CardDivergenceCopy {

    // COLD READ, 2026-09-08, each branch read in the order a person meets it (#843). The first draft
    // failed it twice and both failures are worth keeping, because they are the two this repository names
    // most often.
    //
    // IT NAMED THE FIELD. "The difference was in presenterLine" puts a code identifier in front of
    // somebody who does not write code, and it is the only concrete thing in the sentence, so it is the
    // half he would try hardest to read (L604, L611). The field name is in the file, for whoever looks;
    // the sentence is for Dan.
    //
    // IT SAID "a fresh one". That is the mechanism talking: it means something precise inside the render
    // pass and nothing at all on screen. What Dan needs is what happened to his queue and what it asks of
    // him, which is nothing.
    //
    // ONE and SEVERAL are separate sentences rather than one with a count in it, on
    // `FreezeNoticeCopy.report`'s finding: written the obvious way, a single card reads "built 1 queue
    // cards", and the plural of a superlative over a set of one is the same shape.
    static func report(count: Int, fields: [String], unreadableLines: Int) -> String {
        _ = fields
        var sentence: String
        if count == 1 {
            sentence = "Overture built a card in your queue wrongly and corrected it before drawing it."
        } else {
            sentence = "Overture built \(count) cards in your queue wrongly and corrected them before drawing them."
        }
        sentence += " Nothing was lost and nothing here needs deciding, but it is worth reporting."
        if unreadableLines > 0 {
            sentence += " "
            sentence += unreadableSentence(unreadableLines)
        }
        return sentence
    }

    static let neverRan =
        "Overture has not yet checked whether the cards it builds for your queue are right, so nothing here can say whether they are."

    static func unreadableSentence(_ count: Int) -> String {
        if count == 1 {
            return "One earlier record could not be read."
        }
        return "\(count) earlier records could not be read."
    }
}

// #4358 slice E4b (plan item 10): what the launch notice says about the queue engine's verifier, as values. The
// cutover (slice E4d) wires them into the notice and decides which session's counts they are handed; until then
// `QueueEngineNoticeCopyTests` is their reader.
//
// ZERO IS "NEVER CHECKED", NEVER "CLEAN" (L557, L98). A verifier that has not matched once has measured nothing, and
// a sentence counting zero matches would read as a queue nothing found wrong. So zero has its own sentence, in the
// words `neverRan` already uses for the card check's same gap.
enum QueueEngineNoticeCopy {

    // COLD READ, 2026-10-08, each branch in the order Dan meets it, in the launch notice under the card check's line.
    // "Your saved shows" for what the queue is checked against, never "the store" (L399). ONE match and SEVERAL are
    // separate sentences, on `FreezeNoticeCopy.report`'s finding that a count spliced into one sentence reads "1
    // times". The instant is absolute and says its day, because a notice read the next morning makes "at 3:40 PM"
    // ambiguous, and a relative time would need an anchor the notice does not show (L589).
    static func verifierSentence(matches: Int, lastMatchedAt: Date?, timeZone: TimeZone = .current) -> String {
        guard matches > 0 else {
            return "Overture has not yet checked your queue against your saved shows, so nothing here can say "
                + "whether they match."
        }
        guard let lastMatchedAt else {
            return matches == 1
                ? "Overture checked your queue against your saved shows once, and they matched."
                : "Overture checked your queue against your saved shows and found they matched \(matches) times."
        }
        let when = instant(lastMatchedAt, timeZone: timeZone)
        return matches == 1
            ? "Overture checked your queue against your saved shows once, on \(when), and they matched."
            : "Overture checked your queue against your saved shows and found they matched \(matches) times, "
                + "most recently on \(when)."
    }

    // Nothing when no show is out of step: a line saying so on every launch is a notice with no action in it (L36).
    // A show stuck over an hour asks for Dan's hand, by the button on its card (L80); one still inside recovery's
    // bounds asks for nothing, because recovery is still working on it.
    static func faultSentence(_ summary: QueueEngineFaults.Summary) -> String? {
        switch (summary.count, summary.stuck) {
        case (0, _):
            return nil
        case (1, 0):
            return "One show in your queue is out of step with its saved copy, and Overture is still reloading it."
        case (1, _):
            return "One show in your queue has been out of step with its saved copy for over an hour. Press "
                + "Reload this show on its card."
        case (let count, 0):
            return "\(count) shows in your queue are out of step with their saved copies, and Overture is still "
                + "reloading them."
        case (let count, let stuck):
            return "\(count) shows in your queue are out of step with their saved copies, \(stuck) of them for "
                + "over an hour. Press Reload this show on each one's card."
        }
    }

    /// The four full-read nets and the verifier's state as one log line, so #4343's real-use day can be read from the
    /// log (the E4 plan's section 1, point 1). Never shown to Dan.
    static func logLine(matches: Int, lastMatchedAt: Date?, faults: QueueEngineFaults.Summary,
                        counters: QueueEngineCounters) -> String {
        let iso = ISO8601DateFormatter()
        // copy-inventory:ignore-start  a developer log line, never shown to Dan (#4358)
        return "Queue engine: verifier matches \(matches), last matched "
            + (lastMatchedAt.map { iso.string(from: $0) } ?? "never")
            + "; faulted rows \(faults.count), oldest " + (faults.oldestSince.map { iso.string(from: $0) } ?? "none")
            + ", stuck \(faults.stuck); full reads \(counters.fullReads); foreign saves \(counters.foreignSaves.times)"
            + ", unclassified saves \(counters.unclassifiedSaves.times)"
            + ", merged inserts \(counters.insertsMergedAway.times), unread rows \(counters.unreadRows.times)."
        // copy-inventory:ignore-end
    }

    /// An instant with its day, in Dan's own time zone (the Mac's), as the notice says it.
    static func instant(_ date: Date, timeZone: TimeZone) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        // copy-inventory:ignore-start  a date format, not a sentence
        formatter.dateFormat = "MMMM d 'at' h:mm a"
        // copy-inventory:ignore-end
        return formatter.string(from: date)
    }
}
