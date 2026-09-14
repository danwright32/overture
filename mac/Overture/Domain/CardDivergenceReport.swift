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
        let fresh = found.records.filter { !alreadySaid.contains($0.identity) }
        defaults.set(found.records.map(\.identity), forKey: CardDivergenceLog.reportedIdsKey)

        if let worst = fresh.max(by: { $0.fields.count < $1.fields.count }) {
            return CardDivergenceCopy.report(count: fresh.count, fields: worst.fields,
                                             unreadableLines: found.unreadableLines)
        }
        // A FILE WITH RECORDS IN IT IS ITSELF PROOF THE CHECK RAN, whatever the stamp says, and reading
        // only the stamp got this wrong: after saying a divergence once, the next launch fell through to
        // "nothing has ever looked" while holding the record that proves otherwise. The stamp exists for
        // the case where there is nothing else to go on, which is an EMPTY file (L11).
        guard found.records.isEmpty else { return nil }
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
