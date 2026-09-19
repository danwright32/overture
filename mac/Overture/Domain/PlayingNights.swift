import Foundation

// #3286: which nights does this run play. ONE answer, asked by every reader that reasons per night.
//
// `Prospect.runNights` arrived with #1523. Rows stored before it hold a span (`performanceDate` plus
// `runEndDate`) and an EMPTY nights list, and since 2026-09-17 we know the list can also EMPTY on a
// current row (`DroppedNight.keeping` subtracting every night while the span stays). Measured through
// the shipped predicates that day, 22 rows sat in that state, 9 of them live, and none has ever gained
// nights (#3963). So "no recorded nights" is a permanent condition for those rows, not a transient one.
//
// Before this type, every reader answered the empty list for itself: `BlockedCalendar.conflict` walked
// the span, `QueueModel.selfBookingNights` took the opening night alone, `RunNightDrop.dropNight`
// refused outright. Each was right for its own reason, and each had to REMEMBER that the empty list
// was a case at all, which is L98 exactly: an empty list reads as "no nights" to whoever forgets.
//
// So the fallback is decided ONCE, here, by returning WHICH case the row is in rather than a bare array
// a caller could mistake for the answer. A reader switching on it has to say what it does with a
// span-only row, and the compiler refuses one that forgets (L113, L544). What each reader then DOES is
// still its own call, because the three genuinely want different things, and each says why where it
// switches.
enum PlayingNights: Equatable, Sendable {

    // The nights the feed published, deduplicated and in date order.
    //
    // DEDUPLICATED here, once, because the store holds duplicates: measured 2026-09-17 through
    // `QueueModel.selfBookingNights`, 19 rows carry repeated entries, 11 of them live, and one live row
    // stores every night of a twenty night run twice (#3963). Every reader used to dedupe or not by
    // accident; now none of them can see a repeat.
    case recorded([String])

    // A dated row whose nights nobody recorded. The span is all that is known: the opening, and the
    // last night the span claims (the opening itself for a row with no end date).
    //
    // The SPAN is not a list of nights. On a weekly series most of the days between the two ends are
    // dark, so a reader must decide for itself whether walking it invents clashes (the self-booking
    // check refuses to) or whether ignoring it loses real ones (the calendar check refuses to).
    case spanOnly(opening: String, lastNight: String)

    // No usable date at all: "date to be confirmed". Collides with nothing and has no nights to judge.
    case undated

    static func of(runNights: [String], performanceDate: String?, runEndDate: String?) -> PlayingNights {
        let recorded = Set(runNights.filter { !$0.isEmpty }).sorted()
        if !recorded.isEmpty { return .recorded(recorded) }
        guard let opening = performanceDate, !opening.isEmpty else { return .undated }
        let last = EasternDate.runLastNight(runEndDate: runEndDate, performanceDate: opening) ?? opening
        return .spanOnly(opening: opening, lastNight: last)
    }

    // The recorded nights, or nil for a row that has none. For a reader that must refuse a span-only
    // row (a night cannot be picked off a run whose nights nobody knows), which is a decision the nil
    // makes it state at the call site.
    var recordedNights: [String]? {
        if case .recorded(let nights) = self { return nights }
        return nil
    }
}

extension Prospect {
    // The one question, asked of a stored row.
    var playingNights: PlayingNights {
        PlayingNights.of(runNights: runNights, performanceDate: performanceDate, runEndDate: runEndDate)
    }
}
