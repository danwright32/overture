import Foundation

// Collapse a multi-night run (same venue, a similar enough act name, performances <=3 days
// apart) into the opening night, tagged with the run's closing date, all member source URLs,
// and a flag when the same venue has more than one run/date for that act in the batch.
// #369: title matching uses GroupNameMatch.isConfident (a shared name-similarity check, already
// used for repeat-client history matching) instead of exact string equality, so a ceremony and
// its differently-titled sub-event (e.g. a "Guest Artist:" night) still merge.
enum RunGrouping {
    struct RunRow: Equatable, Sendable {
        // #797: the row's own identity, assigned by the caller. The caller used to find its way back
        // from a grouped run to the event it came from through `sourceListingURL`, but a listing URL
        // is NOT unique (an org that publishes a whole season on one page gives every show the same
        // one) and is not even always present. Both cost real shows, silently. Identity does what a
        // URL was never able to.
        var id: Int = 0
        var groupName: String
        var venue: String?
        var performanceDate: String?
        var sourceListingURL: String?
        // #1174: the feed's own production id, when the source supplies one (VenueTix tags every night of
        // one show with a shared seriesId). It is authoritative: rows that share a non-nil seriesId are one
        // production and collapse into a single run REGARDLESS of the gap-and-title rule below, which is
        // what lets a residency's nights weeks apart still read as one run. Nil for every source that names
        // no such id, which is all of them today except VenueTix, so their grouping is unchanged.
        var seriesId: String? = nil
    }

    struct GroupedRun: Equatable, Sendable {
        var row: RunRow
        var runEndDate: String?
        var partOfRelatedRun: Bool
        var runSourceURLs: [String]
        // #797: every row that went INTO this run, representative included. `runSourceURLs` cannot
        // serve: it is a compactMap over the members' URLs, so it silently omits exactly the
        // URL-less members. This is what lets the caller account for the nights it collapsed.
        var memberIds: [Int] = []
        // #1523: every member night's date, in order. `runEndDate` alone describes a SPAN, and a weekly
        // series is dark for most of its own span, so the conflict check needs the nights themselves.
        var memberDates: [String] = []
    }

    // #939: shared with EngagementLink, which uses the same "how many dark days still count as one
    // engagement" window to link the same production across DIFFERENT venues, and mirrored by
    // DuplicateContactGuard to pace how often Dan may contact one org. Deliberately NOT widened by #1558:
    // those are different questions, and nobody asked them.
    static let gapDays = 3

    // #1558: how far apart two nights of the SAME show at the SAME venue can be and still read as one
    // engagement. Dan's number, 2026-07-26, chosen over "any gap" and over the old three days.
    //
    // Three days was right when a run's whole SPAN was conflict-checked against his calendar, because
    // collapsing a weekly series then invented a clash on every dark day inside it. #1523 removed that: a
    // run is now judged on the nights it actually plays. So the window can follow how Dan really works,
    // which is that he pitches a run ONCE ("I'm not going to send them an email every week pitching the
    // show"), not once a week. His Neo-Futurists row was twelve cards for one weekly show.
    //
    // Bounded in practice by the scout's own four-month horizon, so this can never reach across a season.
    // A silence longer than this is a separate engagement and earns its own card, which is what keeps a
    // show returning after a break something he is still asked about.
    static let sameShowGapDays = 56

    // #1590: the venue bucket folds through VenueNormalization, the SAME reduction the natural key uses.
    // It used to be a bare lowercase, so grouping and identity disagreed about which shows are even at
    // the same place: a source that sometimes appends its street address ("The Cutting Room" versus "The
    // Cutting Room, 44 East 32nd Street, New York, NY", both live in the store) split one show's nights
    // into two buckets that could never be compared. Reusing the key's own fold rather than adding a
    // second one is the point; a venue reduction that two parts of the app spell differently is exactly
    // how the duplicates got in.
    private static func canon(_ s: String?) -> String {
        VenueNormalization.normalizeForKey(s ?? "")
            .lowercased()
            .collapsingWhitespaceRuns()
            .trimmingCharacters(in: .whitespaces)
    }

    // #369: among a run's member rows, the shortest (fewest tokens) groupName reads as the
    // general/parent title rather than a specific sub-event's, so it becomes the run's
    // displayed representative regardless of which night happens to be chronologically first.
    // Ties (equal token count, including the common case where every row in the run shares the
    // exact same title) keep the first row in chronological order, since `run` is already
    // date-sorted and Sequence.min(by:) returns the first minimal element on a tie.
    private static func representativeRow(_ run: [RunRow]) -> RunRow {
        run.min(by: { GroupNameMatch.tokens($0.groupName).count < GroupNameMatch.tokens($1.groupName).count }) ?? run[0]
    }

    // #4051: every production token a row carries, from its listing URL. `ProductionToken` allows only
    // hosts where the token was MEASURED to be stable across a run and to carry none of the title, so a
    // tixr slug (the title slugified plus a per performance integer) is correctly not one.
    private static func tokens(_ r: RunRow) -> [String] {
        (r.sourceListingURL.map { [$0] } ?? []).compactMap(ProductionToken.inURL)
    }

    // The one token this row may be clustered by, or nil. Nil where the row carries none, and nil where
    // every one it carries is poisoned, which is the season stamp case.
    private static func usableToken(_ r: RunRow, poisoned: Set<String>) -> String? {
        tokens(r).first { !poisoned.contains($0) }
    }

    static func group(_ rows: [RunRow]) -> [GroupedRun] {
        let undated = rows.filter { $0.performanceDate == nil }
        let dated = rows.filter { $0.performanceDate != nil }

        // #369: bucket by venue only now; title similarity (not exact equality) decides which
        // same-venue rows belong together, checked during the chronological walk below.
        var order: [String] = []
        var byVenue: [String: [RunRow]] = [:]
        for r in dated {
            let key = canon(r.venue)
            if byVenue[key] == nil { order.append(key); byVenue[key] = [] }
            byVenue[key]?.append(r)
        }

        var out: [GroupedRun] = []
        for key in order {
            let venueRows = (byVenue[key] ?? []).sorted { ($0.performanceDate ?? "") < ($1.performanceDate ?? "") }

            // #4051: the tokens this venue's rows may NOT be joined by, from `ShowLink`'s own rule rather
            // than a second copy of the judgement (L370). A venue stamping one token across its whole
            // season would otherwise fuse the season into a single card, and the discard costs nothing
            // while no venue does that: measured 2026-09-21, 0 of 228 distinct tokens are poisoned over
            // 1,273 stored rows.
            //
            // Asked per VENUE BUCKET, which is the scope `ShowLink.poisonedTokens` keys on and is correct
            // here for a second reason: this loop has already bucketed by venue, so every row that could
            // be joined by a token is in front of it.
            let poisonedAtVenue = ShowLink.poisonedTokens(venueRows.flatMap { r in
                // `ShowLink`'s OWN folds on both halves, not this file's `canon` and not a token join.
                // The ingest arm asks the identical question through `ShowLink.foldedTitle` and
                // `foldedVenue`, and two spellings of "the same title" would let the grouper and the
                // matcher disagree for ever about whether one token is trustworthy, each looking correct
                // alone (L263). Sharing the rule's DATA while re-spelling its inputs is not sharing it.
                tokens(r).map { (token: $0, title: ShowLink.foldedTitle(r.groupName),
                                 venue: ShowLink.foldedVenue(r.venue)) }
            })

            // #1174: a shared seriesId is authoritative, so those nights are grouped FIRST, by id, before
            // the gap-and-title walk ever sees them. Keying on the id (not adjacency) is deliberate: the
            // nights can be weeks apart and can have other shows between them in the date order, and a
            // sequential walk would strand a later night in its own run. `venueRows` is date-sorted, so
            // each id's rows stay date-sorted, and its representative is the earliest (opening) night.
            var seriesOrder: [String] = []
            var seriesClusters: [String: [RunRow]] = [:]
            var untaggedRows: [RunRow] = []
            for r in venueRows {
                // #4051: a feed production id the source publishes as `seriesId`, OR the venuetix one it
                // publishes inside the listing URL. They are the same kind of fact and this rule already
                // treats the first as authoritative, with no gap window, precisely because the nights of
                // one production can be weeks apart. The token was invisible to both paths, so two nights
                // of one production more than `sameShowGapDays` apart arriving in ONE sweep became two
                // rows. Live shape, measured 2026-09-20: `Operation Mincemeat: Mission Recast` at The
                // Green Room 42, 70 days apart under token `GWKuL2pmNJBPIkIkHB0h`.
                //
                // `seriesId` wins where a row carries both. Neither is more authoritative than the other,
                // and a row carrying both has them agreeing about one production, so the order only has to
                // be STATED rather than argued (L419).
                if let key = r.seriesId.flatMap({ $0.isEmpty ? nil : $0 })
                    ?? usableToken(r, poisoned: poisonedAtVenue) {
                    if seriesClusters[key] == nil { seriesOrder.append(key); seriesClusters[key] = [] }
                    seriesClusters[key]?.append(r)
                } else {
                    untaggedRows.append(r)
                }
            }

            // #1558: the remaining, id-less rows cluster by SHOW first, and only then walk dates inside
            // each show.
            //
            // The old walk scanned every row at the venue in date order and joined a row only to the one
            // immediately before it, so any OTHER show at that venue broke a run in half. Live proof at
            // Asylum NYC: Neo-Futurists 08-07, Marcus Monroe 08-08, Neo-Futurists 08-08. The two Neo
            // nights are one day apart and belong together; Marcus Monroe sitting between them in the sort
            // stranded each in a run of its own. That is exactly the failure the seriesId path above was
            // given its own clustering to avoid, and it went on happening to every source with no id,
            // which is all 36 of the duplicate cards Dan could actually see.
            //
            // Clustering by title first makes the result independent of who else plays that venue. Each
            // cluster stays date-sorted because `venueRows` was, and `showClusters` preserves that order.
            var showOrder: [[RunRow]] = []
            for r in untaggedRows {
                if let i = showOrder.firstIndex(where: {
                    GroupNameMatch.isConfident($0[0].groupName, r.groupName)
                }) {
                    showOrder[i].append(r)
                } else {
                    showOrder.append([r])
                }
            }

            var gapRuns: [[RunRow]] = []
            for show in showOrder {
                for r in show {
                    // The title check stays, and now also stops one show's cluster running into the next
                    // one's when a new cluster begins. The window is the same-show one (#1558), never the
                    // cross-venue engagement window.
                    if let last = gapRuns.last, let prev = last.last,
                       GroupNameMatch.isConfident(prev.groupName, r.groupName),
                       let gap = EasternDate.daysUntil(from: prev.performanceDate!, to: r.performanceDate!),
                       gap <= sameShowGapDays {
                        gapRuns[gapRuns.count - 1].append(r)
                    } else {
                        gapRuns.append([r])
                    }
                }
            }

            // Each run paired with its representative: an id-grouped run reads off its OPENING night (so
            // the collapsed prospect sorts and keys on the earliest date, even when the nights carry
            // different titles); a gap-walk run keeps the #369 shortest-title representative.
            let runs: [(rows: [RunRow], open: RunRow)] =
                seriesOrder.map { (rows: seriesClusters[$0]!, open: seriesClusters[$0]!.first!) }
                + gapRuns.map { (rows: $0, open: representativeRow($0)) }

            // #369: a run is "related" to another run at this same venue only when their representative
            // titles are the same act by GroupNameMatch, not merely "this venue produced more than one
            // run" (which would also flag two genuinely different, unrelated acts that happen to share a
            // venue). This generalizes the old exact-key behavior (same title, same venue, split by a date
            // gap) to the new similarity check.
            for (i, run) in runs.enumerated() {
                let related = runs.indices.contains { j in
                    j != i && GroupNameMatch.isConfident(run.open.groupName, runs[j].open.groupName)
                }
                out.append(GroupedRun(
                    row: run.open,
                    runEndDate: run.rows.count > 1 ? run.rows.last?.performanceDate : nil,
                    partOfRelatedRun: related,
                    runSourceURLs: run.rows.compactMap { $0.sourceListingURL },
                    memberIds: run.rows.map(\.id),
                    memberDates: run.rows.compactMap(\.performanceDate)
                ))
            }
        }
        for r in undated {
            out.append(GroupedRun(row: r, runEndDate: nil, partOfRelatedRun: false,
                                  runSourceURLs: r.sourceListingURL.map { [$0] } ?? [],
                                  memberIds: [r.id], memberDates: []))
        }
        return out
    }
}
