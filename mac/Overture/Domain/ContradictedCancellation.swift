import Foundation

// #3278: a show flagged "No longer in the feed, may be cancelled" while ANOTHER row in the same store,
// at the same venue, over overlapping nights, under a title the app itself calls the same act, was seen
// in the last sweep. The store contradicts itself, and the flag is the half that is wrong.
//
// Dan, 2026-08-30, from his own queue: a Sep 4 card read struck through while the show was on the
// venue's calendar and played Aug 30, Sep 3, 4, 5 and 6. Overture held two rows for it and believed
// opposite things about each.
//
// The rule deliberately reuses the app's OWN three tests rather than inventing a fourth: the venue fold
// the natural key uses, the run overlap the scout's re-key guard uses, and the title confidence the
// merge passes use. #3282 measured that nine of the fifteen pairs on the live store match under
// `GroupNameMatch.isConfident` unmodified, so spotting the contradiction needs no new fuzzy matching
// (L107: the number that justifies this must come from the code's own predicate, not a query beside it).
enum ContradictedCancellation {

    // The live row that contradicts `flagged`, or nil when nothing does.
    //
    // It answers about ONE row against a candidate set rather than returning pairs, because the caller
    // that matters is a row deciding whether to draw its own warning, and a pair list would make every
    // such row re-derive the whole store (L91).
    //
    // #4357 (plan v7 Phase 3, T2): generic over `ProspectFacts`, ONE body for the live models (the pass and
    // the tests today) and the retained `RowFacts` (the engine, Phase 4), so the rule cannot be copied
    // into a second implementation that drifts (L263, L370). It folds the room through its own
    // `canonicalVenue` rather than reading `foldedKeys`, which on a model would run every fold in
    // `RowKeys` per row (#4357's carried note, L383).
    static func liveTwin<Row: ProspectFacts>(of flagged: Row, among rows: [Row]) -> Row? {
        guard flagged.disappearedFromFeed else { return nil }
        return rows.first { candidate in
            guard candidate.persistentModelID != flagged.persistentModelID else { return false }
            // The twin must be one the feed still lists. A second row that is ALSO flagged contradicts
            // nothing: two rows can both be genuinely gone.
            guard candidate.missedScoutCount == 0 else { return false }
            guard sameVenue(candidate.venue, flagged.venue) else { return false }
            return isTwin(candidateStart: candidate.performanceDate, candidateEnd: candidate.runEndDate,
                          candidateTitle: candidate.groupName, flaggedStart: flagged.performanceDate,
                          flaggedEnd: flagged.runEndDate, flaggedTitle: flagged.groupName)
        }
    }

    // The two arms a live candidate in the flagged row's own room must pass to contradict it: overlapping nights and
    // a title the app calls the same act. #4361: one predicate, asked by `liveTwin`, by `contradictedKeys` and by the
    // queue engine's patched value (`PatchableContradictions`), so the rule cannot be copied into a second body that
    // drifts (L370).
    static func isTwin(candidateStart: String?, candidateEnd: String?, candidateTitle: String,
                       flaggedStart: String?, flaggedEnd: String?, flaggedTitle: String) -> Bool {
        ScoutService.runsOverlap(storedStart: candidateStart, storedEnd: candidateEnd,
                                 incomingStart: flaggedStart, incomingEnd: flaggedEnd)
            && GroupNameMatch.isSameShowTitle(candidateTitle, flaggedTitle)
    }

    // Every flagged row the store contradicts, by natural key, computed ONCE over the corpus.
    //
    // WHY THIS EXISTS BESIDE `liveTwin`. The render pass draws every card on screen, and asking
    // `liveTwin` per flagged row is that row against the whole corpus: 41 flagged against 1,233 on Dan's
    // store is fifty thousand comparisons a pass, each one a venue fold plus an overlap plus a title
    // confidence. That is a whole-store walk per pass, which is the cost milestone 80 spent itself
    // removing (L91).
    //
    // So the live rows are bucketed by their folded venue FIRST, and a flagged row is compared only
    // against the rows in its own room. The answer is identical by construction, because the venue test
    // was already the first arm every candidate had to pass; what changes is that the rows which could
    // never pass it are no longer visited. `theSetAgreesWithAskingRowByRow` asserts that equivalence
    // against the row-by-row answer rather than against a literal, so the index cannot drift from the
    // rule it indexes (L58).
    static func contradictedKeys<Row: ProspectFacts>(among rows: [Row]) -> Set<String> {
        QueueRenderPass.WorkTally.recordContradictionSweep()
        var liveByVenue: [String: [Row]] = [:]
        for row in rows where row.missedScoutCount == 0 {
            liveByVenue[canonicalVenue(row.venue), default: []].append(row)
        }
        guard !liveByVenue.isEmpty else { return [] }

        var contradicted: Set<String> = []
        for flagged in rows where flagged.disappearedFromFeed {
            let room = liveByVenue[canonicalVenue(flagged.venue)] ?? []
            let twin = room.first { candidate in
                guard candidate.persistentModelID != flagged.persistentModelID else { return false }
                return isTwin(candidateStart: candidate.performanceDate, candidateEnd: candidate.runEndDate,
                              candidateTitle: candidate.groupName, flaggedStart: flagged.performanceDate,
                              flaggedEnd: flagged.runEndDate, flaggedTitle: flagged.groupName)
            }
            if twin != nil { contradicted.insert(flagged.naturalKey) }
        }
        return contradicted
    }

    // Through the SAME fold the natural key uses, for the reason ScoutService.sameVenue records: these
    // rows are recognised by their listing and their room precisely when a title has drifted, which is
    // when the room is liable to be respelled by the same extract run (#1686).
    private static func sameVenue(_ a: String?, _ b: String?) -> Bool {
        canonicalVenue(a) == canonicalVenue(b)
    }

    // #4356: internal rather than private, so `RowKeys` folds a retained row through this rule
    // rather than through a copy of it.
    static func canonicalVenue(_ raw: String?) -> String {
        guard let raw, !raw.trimmingCharacters(in: .whitespaces).isEmpty else { return "" }
        return VenueNormalization.normalizeForKey(raw)
    }
}
