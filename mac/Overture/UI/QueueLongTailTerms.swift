import Foundation

// #4357 (plan v7 Phase 3, slice H): the long tail of the queue's whole-corpus terms (T8), each over any
// `ProspectFacts`, so the render pass and the engine (Phase 4) call one term over live models and over
// retained facts. Each one used to be written over `[Prospect]`, most of them inline in `QueueModel.scope` or
// `QueueRenderPass.make`, so no other caller could ask the same question without spelling it again (L263).
//
// In a file of its own because slices D2, E1 and F grow the queue's other files at the same time.

extension ProspectFacts {
    // Closed for routine follow-ups/reminders: booked, every contact resolved (derived), or Dan closed the lead
    // by hand / with a closing note (a lead lostSoft/lostHard not yet written through to a contact). A fresh
    // reply still surfaces independently via `hasUnhandledReply`.
    //
    // #4357 slice H: the RULE, written once over the performance status it is handed. The protocol member hands
    // it `performanceStatus` over `factContacts` (counted, so a generic term pays for what it reads), and
    // `Prospect.isClosed` hands it the model's own, uncounted, as it always read it, so no
    // `WorkTally.recipientReaches` pin moves.
    func isClosed(given status: PerformanceStatus) -> Bool {
        // #769: the org asked Dan to stop. Nothing routine may fire again, on any of their shows. This is the
        // load-bearing line: without it a do-not-contact org would keep receiving follow-ups and reminders on a
        // show already sent, which is precisely the email that issue exists to prevent.
        if orgDoNotContact { return true }
        switch status {
        // #1840: a show Dan stopped working is closed for ROUTINE follow-ups, same as the two lost states. The
        // one thing it keeps raising, its post-event closing note, is carved out inside ConversationReminder.
        // #3669: the three ended states come from `endedWithoutAShoot`, the same answer the self booking check
        // reads, so the two cannot drift apart over which endings count as closed.
        case .booked: return true
        case .lostDoorOpen, .lostNotInterested, .stoodDown, .active, .new:
            return status.endedWithoutAShoot || outcome == .lostSoft || outcome == .lostHard
        }
    }

    var isClosed: Bool { isClosed(given: performanceStatus) }
}

extension QueueModel {
    // The order `queueScope` sorts by, for any `ProspectFacts`: date ascending, fit descending, with the
    // `String` comparison `SortDescriptor` uses by default (`.localizedStandard`), which is what the removed
    // query used. `queueScopeOrder` beside `queueScope` is the same two descriptors over `Prospect` itself,
    // kept because a fetch can only translate a key path to a stored property, and one written in a generic
    // context goes through the protocol. Two spellings of one order, so they are held to each other:
    // `QueueScopeMatchesTheQueryTests` compares `queueScope` over models against a real fetch sorted by
    // `queueScopeOrder`, and `TermsOverFacts` compares it over models against facts.
    static func queueScopeOrder<Row: ProspectFacts>(for _: Row.Type) -> [SortDescriptor<Row>] {
        [SortDescriptor(\Row.performanceDate, order: .forward), SortDescriptor(\Row.fitScore, order: .reverse)]
    }

    // #3330: the title of each stored row, so a card carrying an arrival tag can name the row it looked like.
    // The first row holding a key wins, as `Dictionary(_:uniquingKeysWith:)` did inline in `scope`.
    static func titlesByKey(among rows: [some ProspectFacts]) -> [String: String] {
        Dictionary(rows.map { ($0.naturalKey, $0.groupName) }, uniquingKeysWith: { first, _ in first })
    }

    // #4146: the arrival tag read backwards, NEWEST FIRST by the row's own first sighting, a row with no
    // `firstSeenAt` last. #4349 (plan v7 Step T, decision 13(vi)): equal sightings fall back to the natural
    // key, so the title the note names is the same on every render.
    static func laterLookalikes(among rows: [some ProspectFacts]) -> [String: [String]] {
        var byTarget: [String: [(key: String, seen: Date)]] = [:]
        for row in rows {
            guard let target = row.arrivedLookingLike else { continue }
            byTarget[target, default: []].append((row.naturalKey, row.firstSeenAt ?? .distantPast))
        }
        return byTarget.mapValues { pairs in
            pairs.sorted { $0.seen != $1.seen ? $0.seen > $1.seen : $0.key < $1.key }.map(\.key)
        }
    }

    // #4042: each stored row's opening night, by key, for the same read-time resolution. An undated row, or
    // one dated with the empty string, holds none.
    static func nightsByKey(among rows: [some ProspectFacts]) -> [String: String] {
        Dictionary(rows.compactMap { row -> (String, String)? in
            guard let night = row.performanceDate, !night.isEmpty else { return nil }
            return (row.naturalKey, night)
        }, uniquingKeysWith: { first, _ in first })
    }
}

extension QueueRenderPass {
    // #3596: the rows a merge kept that the next sweep did not list, FUTURE and OPEN only, which is what stops
    // the finding standing for ever on a show that has since played or that Dan has closed. "Still ahead" is
    // the live-run rule `FeedReconcile.isFuture` applies, through the same helper, so the pass that RECORDS
    // the finding and the pass that SHOWS it cannot come to disagree (L16).
    //
    // Two entry points onto one body, as `StageNavigation.placements` has (#4357 slice E1): the models' own
    // `isClosed`, uncounted, for the pass that holds models, and the protocol's for any other conformer.
    static func unseenSurvivors(among rows: [Prospect], today: String) -> [String] {
        unseenSurvivors(of: rows, today: today, closed: { $0.isClosed })
    }

    static func unseenSurvivors<Row: ProspectFacts>(among rows: [Row], today: String) -> [String] {
        unseenSurvivors(of: rows, today: today, closed: { $0.isClosed })
    }

    // #4357 slice I3 (plan v7 Phase 3, step 6): in key order rather than the corpus's, which is the unsorted
    // query's (L343). The notice's control carries these keys, so its value moved with the store's order.
    static func unseenSurvivors<Row: ProspectFacts>(of rows: [Row], today: String,
                                                            closed: (Row) -> Bool) -> [String] {
        rows.filter { p in
            guard p.mergeSurvivorUnseenAt != nil, !closed(p) else { return false }
            return EasternDate.runIsLive(
                lastNight: EasternDate.runLastNight(runEndDate: p.runEndDate, performanceDate: p.performanceDate),
                today: today)
        }.map(\.naturalKey).sorted()
    }
}
