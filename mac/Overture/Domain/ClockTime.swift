import Foundation

// #1699: the one place a published curtain time is read.
//
// A source states a start as 24-hour "HH:mm" (the three native readers all normalize to it). Two things
// then need it and must never disagree about whether a given string IS a time: the card, which RENDERS it
// beside the date, and the self-booking clash check, which REASONS about how far apart two shows are.
//
// Split across two validators they drift, and the drift is silent in the worst direction: a string one
// accepts and the other rejects would print a curtain time on a card while the clash check treated the
// night as unknown, or the reverse. One parser, and an unreadable string is nothing at every call site
// rather than a value that lands somewhere on a threshold (L50).
enum ClockTime {
    // Minutes since midnight, or nil for anything that is not exactly two-digit 24-hour "HH:mm".
    static func minutesOfDay(_ raw: String) -> Int? {
        let parts = raw.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 2, parts[0].count == 2, parts[1].count == 2,
              parts[0].allSatisfy(\.isNumber), parts[1].allSatisfy(\.isNumber),
              let hour = Int(parts[0]), let minute = Int(parts[1]),
              (0...23).contains(hour), (0...59).contains(minute) else { return nil }
        return hour * 60 + minute
    }

    // The 12-hour label Dan reads ("2:00 PM"), or nil for a string that is not a time. Rendered FROM the
    // parse above, so anything the clash check can reason about is exactly what can appear on screen.
    static func label(_ raw: String) -> String? {
        guard let minutes = minutesOfDay(raw) else { return nil }
        let hour = minutes / 60, minute = minutes % 60
        // Noon and midnight are where a 12-hour clock goes wrong, and a show really can start at either.
        let hour12 = hour % 12 == 0 ? 12 : hour % 12
        return String(format: "%d:%02d %@", hour12, minute, hour < 12 ? "AM" : "PM")
    }

    // #1699: a whole day's curtain times as one phrase ("5:00 PM and 9:15 PM"), or nil when nothing in
    // the list reads as a time.
    //
    // Both times of a double bill are named (Dan's call, 2026-08-02, choosing D from the rendered
    // options). Showing one would state that the day starts then, and the second performance is the whole
    // reason a matinee day is worth telling apart from an evening one.
    //
    // Lives here rather than on the queue model because three surfaces now say this same phrase (the
    // card, the hover behind "Times vary", and the workable same-night note), and the last of those is
    // written in the domain. One phrasing, so they cannot drift into three ways of saying one fact.
    //
    // An unreadable entry is DROPPED here, because a card showing the times it did understand is better
    // than a card showing none. The clash check deliberately does the opposite and treats a partly
    // readable schedule as unknown: rendering has nothing to lose by being generous, and a rule that can
    // quiet a double-booking warning has everything to lose (L11).
    static func listLabel(_ times: [String]) -> String? {
        let rendered = times.compactMap(label)
        guard !rendered.isEmpty else { return nil }   // nothing readable stays nil, not an empty label
        return Plural.list(rendered)
    }
}
