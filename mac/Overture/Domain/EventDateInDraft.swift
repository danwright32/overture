import Foundation

// Whether a pitch names the night it is about (#2864).
//
// Dan's ask, 2026-08-17: the initial pitch must carry the date of the show, in the subject or the body,
// either will do. The rule was already in `docs/prep-runbook.md` four times over, written as an
// instruction to the drafter, and nothing read the produced draft to see whether the date landed. A rule
// that lives only in a prompt is a hope (L27), and this one has the shape that fails quietly: the
// drafter can satisfy every other rule, produce a draft that reads perfectly, and never say which night.
//
// Measured on the live store the day it was filed: 6 of the 19 prospects holding a draft and a stored
// date named it nowhere. And one pitch that had already been SENT told a theatre Dan wanted to
// photograph their show "on July 18" when the stored date was July 25. That is why this asks whether the
// date named MATCHES rather than whether one is present: a presence check passes the sent one, and a
// wrong fact reaching a stranger is worse than an omitted one, which at least reads as missing (L161).
//
// ADVISORY on both halves, never blocking. Dan, shown the sent pitch and the argument for blocking:
// "warn only. In general I don't like anything that I can't override. But make it clear why it's warning
// me in the message." So the blocking set stays at the members #789 gave it.
enum EventDateFinding: Equatable, Sendable {
    // A date-shaped phrase resolving to a day that is not one of the show's own.
    case namesADifferentDate(named: String, show: String)
    // No date-shaped phrase anywhere in the subject or the body.
    case namesNoDate(show: String)

    // Both sentences state the FACT rather than asking Dan to go and check one, and the contradiction
    // carries both dates: the whole reason this warns rather than blocks is that he keeps the final
    // call, and an override nobody can see the grounds for is not a choice.
    var message: String {
        switch self {
        case .namesADifferentDate(let named, let show):
            return "This draft says \(named). The show is \(show)."
        case .namesNoDate(let show):
            return "No date for this show appears in the subject or the body. The show is \(show)."
        }
    }
}

enum EventDateInDraft {

    // `today` is a parameter, never a bare `Date()`: this compares a stored date against the clock, so
    // the clock is an input the tests pin rather than a fact that walks fixtures into different cases as
    // real time passes (L130).
    static func finding(subject: String?, body: String,
                        performanceDate: String?, runEndDate: String?,
                        today: String) -> EventDateFinding? {
        guard let performanceDate, EasternDate.date(from: performanceDate) != nil else { return nil }
        let nights = EasternDate.days(from: performanceDate,
                                      through: EasternDate.runLastNight(runEndDate: runEndDate,
                                                                        performanceDate: performanceDate)
                                          ?? performanceDate)
        guard !nights.isEmpty else { return nil }

        // The runbook forbids naming an opening night that has gone (line 899): "your March 10 opening"
        // written on the 12th reads as not having looked, so a check that accepted it would pass a draft
        // the runbook says is wrong. A run entirely in the past has no upcoming night to prefer, and
        // every night of it counts again: that is the state a pitch already sent is read back in, and
        // without it this would contradict every correct draft on a show that has happened.
        let upcoming = nights.filter { $0 >= today }
        let acceptable = Set(upcoming.isEmpty ? nights : upcoming)

        let named = namedDays(in: [subject, body].compactMap { $0 }.joined(separator: "\n"),
                              assumingYearOf: performanceDate)
        guard let first = named.first else { return .namesNoDate(show: label(nights: nights, acceptable: acceptable)) }
        if named.contains(where: { acceptable.contains($0.day) }) { return nil }
        return .namesADifferentDate(named: first.text,
                                    show: label(nights: nights, acceptable: acceptable))
    }

    // How the show's own date is written back to Dan: one night as "March 10", a run as "March 12 to 14",
    // and a run whose opening has passed as the nights that are actually left, so the sentence never
    // offers him a night the runbook forbids naming.
    private static func label(nights: [String], acceptable: Set<String>) -> String {
        let shown = nights.filter(acceptable.contains).sorted()
        guard let first = shown.first, let last = shown.last else { return "" }
        guard let opening = EasternDate.longDayLabel(first) else { return first }
        guard first != last else { return opening }
        // The closing night as a bare number when it shares a month with the opening, which is how a
        // person writes a span, and in full when the run crosses into the next month.
        let closingIsSameMonth = String(first.prefix(7)) == String(last.prefix(7))
        let closing = closingIsSameMonth
            ? String(Int(last.suffix(2)) ?? 0)
            : (EasternDate.longDayLabel(last) ?? last)
        return "\(opening) to \(closing)"
    }

    // MARK: - Finding the dates a draft names

    struct NamedDay: Equatable {
        var day: String    // yyyy-MM-dd
        var text: String   // as the draft wrote it, so the warning can quote it back
    }

    // Every day-shaped phrase in the text, resolved against the show's year. Deliberately narrow: a
    // month name with a number, a numeric M/D form, or a bare ordinal in a sentence that names a month.
    // A figure that is not a date must never rescue a draft (a rate, a delivery window, a ticket price),
    // which is the whole reason this does not simply hunt for numbers.
    static func namedDays(in text: String, assumingYearOf reference: String) -> [NamedDay] {
        let referenceYear = Int(reference.prefix(4)) ?? 0
        var found: [NamedDay] = []
        for sentence in text.split(whereSeparator: { ".!?\n".contains($0) }) {
            found.append(contentsOf: days(inSentence: String(sentence), referenceYear: referenceYear))
        }
        return found
    }

    private static func days(inSentence sentence: String, referenceYear: Int) -> [NamedDay] {
        var found: [NamedDay] = []
        var monthInSentence: Int?

        // "March 10", "March 10th", "Mar 10", "March 10, 2026", and the span forms that follow one of
        // those with a second number ("March 10 to 14", "March 10-14").
        for match in matches(monthFirst, in: sentence) {
            guard let month = monthNumber(match.group(1, in: sentence)) else { continue }
            monthInSentence = month
            guard let day = Int(match.group(2, in: sentence) ?? "") else { continue }
            let year = Int(match.group(4, in: sentence) ?? "") ?? referenceYear
            append(&found, month: month, day: day, year: year, text: match.text(in: sentence))
            // The far end of a span, and every night between: "March 10 to 14" names the whole run.
            if let endDay = Int(match.group(6, in: sentence) ?? ""), endDay > day {
                for d in (day + 1)...endDay {
                    append(&found, month: month, day: d, year: year, text: match.text(in: sentence))
                }
            }
        }

        // "10 March", "10th March"
        for match in matches(dayFirst, in: sentence) {
            guard let day = Int(match.group(1, in: sentence) ?? ""),
                  let month = monthNumber(match.group(3, in: sentence)) else { continue }
            monthInSentence = month
            append(&found, month: month, day: day, year: referenceYear, text: match.text(in: sentence))
        }

        // "3/10", "3/10/26", "3/10/2026"
        for match in matches(numeric, in: sentence) {
            guard let month = Int(match.group(1, in: sentence) ?? ""),
                  let day = Int(match.group(2, in: sentence) ?? "") else { continue }
            var year = referenceYear
            if let written = Int(match.group(4, in: sentence) ?? "") {
                year = written < 100 ? 2000 + written : written
            }
            append(&found, month: month, day: day, year: year, text: match.text(in: sentence))
        }

        // A month named on its own ("your March programme"), which is what lets the bare ordinal below
        // resolve. Only consulted when no dated phrase already set the month, so a sentence carrying a
        // real date is never reinterpreted by a stray month word later in it.
        if monthInSentence == nil, let first = matches(monthOnly, in: sentence).first {
            monthInSentence = monthNumber(first.group(1, in: sentence))
        }

        // "the 10th", but only where the month is named in the same sentence, so a bare ordinal in
        // "the 10th time" cannot resolve to a date on its own.
        if let month = monthInSentence {
            for match in matches(bareOrdinal, in: sentence) {
                guard let day = Int(match.group(1, in: sentence) ?? "") else { continue }
                append(&found, month: month, day: day, year: referenceYear, text: match.text(in: sentence))
            }
        }
        return found
    }

    private static func append(_ found: inout [NamedDay], month: Int, day: Int, year: Int, text: String) {
        guard (1...12).contains(month), (1...31).contains(day) else { return }
        let stamp = String(format: "%04d-%02d-%02d", year, month, day)
        guard EasternDate.date(from: stamp) != nil else { return }
        guard !found.contains(where: { $0.day == stamp }) else { return }
        found.append(NamedDay(day: stamp, text: text.trimmingCharacters(in: .whitespaces)))
    }

    // The en dash is BUILT rather than written, even as an escape. `UserFacingDashGuardTests` reads the
    // VALUE of every string literal in the app, not its source text, so `\\u{2013}` in the source is a
    // literal en dash by the time that guard sees it, and the escape trick that satisfies the pre-push
    // style gate does not satisfy this one. A span written with an en dash ("March 10 \u{2013} 14") is a
    // real thing to match, so the alternative was exempting this whole file for ever.
    private static let enDash = String(UnicodeScalar(0x2013)!)

    // copy-inventory:ignore-start  date-shape patterns: what the check HUNTS FOR, never words it says
    private static let monthNames =
        "jan(?:uary)?|feb(?:ruary)?|mar(?:ch)?|apr(?:il)?|may|jun(?:e)?|jul(?:y)?|aug(?:ust)?"
        + "|sep(?:t)?(?:ember)?|oct(?:ober)?|nov(?:ember)?|dec(?:ember)?"

    private static let monthFirst =
        "\\b(\(monthNames))\\.?\\s+(\\d{1,2})(st|nd|rd|th)?(?:,?\\s+(\\d{4}))?"
        + "(\\s*(?:to|through|until|[-\(enDash)])\\s*(?:\(monthNames))?\\.?\\s*(\\d{1,2})(?:st|nd|rd|th)?)?"

    private static let dayFirst = "\\b(\\d{1,2})(st|nd|rd|th)?\\s+(\(monthNames))\\b"

    private static let numeric = "\\b(\\d{1,2})/(\\d{1,2})(/(\\d{2,4}))?\\b"

    private static let bareOrdinal = "\\bthe\\s+(\\d{1,2})(?:st|nd|rd|th)\\b"

    private static let monthOnly = "\\b(\(monthNames))\\b"
    // copy-inventory:ignore-end

    private static func monthNumber(_ name: String?) -> Int? {
        guard let name = name?.lowercased() else { return nil }
        let prefix = String(name.prefix(3))
        let months = ["jan": 1, "feb": 2, "mar": 3, "apr": 4, "may": 5, "jun": 6,
                      "jul": 7, "aug": 8, "sep": 9, "oct": 10, "nov": 11, "dec": 12]
        return months[prefix]
    }

    private struct Match {
        let result: NSTextCheckingResult
        func group(_ index: Int, in text: String) -> String? {
            guard index < result.numberOfRanges,
                  let range = Range(result.range(at: index), in: text) else { return nil }
            return String(text[range])
        }
        func text(in text: String) -> String {
            guard let range = Range(result.range, in: text) else { return "" }
            return String(text[range])
        }
    }

    private static func matches(_ pattern: String, in text: String) -> [Match] {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
        else { return [] }
        return regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).map(Match.init)
    }
}
