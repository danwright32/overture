import Foundation

// #4027 / #3383: several rows at one source that stopped matching in the SAME sweep, which is a broken
// match rather than a set of cancellations.
//
// THE PROBLEM BOTH ISSUES DESCRIBE. `missedScoutCount` climbs with nothing watching it, and the flag it
// drives ("No longer in the feed, may be cancelled") is the only thing telling Dan a show may be off. A
// flag that can be silently wrong for weeks teaches him to ignore it, which is exactly when a real
// cancellation gets missed (L36). Measured on the live store 2026-09-20: eight rows at The Players
// Theatre have been accruing since the venue moved to OvationTix on 2026-08-09, and one of them
// (`You Go On (A New Musical)`, playing 2027-06-03) will go on accruing until June 2027.
//
// WHY THE SIGNATURE IS SAMENESS AND NOT SIZE. Both issues originally proposed a size test ("a count far
// past the threshold is a match failure"). The live store refuses it: Zankel Hall's three flagged rows
// carry 72, 58 and 57, which are the HIGHEST counts in the store and are three separate genuine
// departures, while the eight broken rows sit together on 33. What separates them is that a source which
// re-keys its calendar breaks every row it was publishing in one run, so those rows start missing on the
// same day and stay exactly level for ever. A genuine departure happens to one show at a time.
//
// Measured over the whole store on 2026-09-20, every group of flagged future rows sharing a venue and a
// count: The Players Theatre 8 at 33 (the event), Weill Recital Hall 3 at 19, The Green Room 42 2 at 11,
// Roulette 2 at 3, The Cutting Room 2 at 2. The last four are the reason `minimumMembers` is 3 and
// `goneThreshold` is the floor: at a count of 2 or 3 a shared value is arithmetic rather than evidence,
// and pairs are common. The Weill trio is the honest cost of the rule, named rather than tuned away: it
// is three different shows, each with its own listing URL, that left one feed together, and the app
// cannot tell that from a re-key without a twin. Which is why the event REPORTS its twin count instead of
// asserting a cause.
//
// WHAT IT DELIBERATELY DOES NOT DO. It never writes, never merges and never clears a count. #4027's own
// direction is to surface rather than merge, because these rows carry Dan's dismissals and in some cases
// outreach history, and collapsing two rows that each hold a decision is his call (`mustDefer`).
enum FeedBreakEvent {

    // Below this many rows a shared count is not evidence. Three because the live store holds four
    // two-row coincidences and one real eight-row event, so a floor of two would report four false
    // events beside the true one and a report that names correct pairs as faults gets ignored (L93, L36).
    static let minimumMembers = 3

    struct Event: Equatable, Sendable, Identifiable {
        var venue: String
        var missedScoutCount: Int
        // Keys rather than rows: this value is handed to a notice line the masthead diffs on every write,
        // so it has to be Equatable and Sendable, and the view resolves the rows when Dan acts (#2250).
        var memberKeys: [String]
        // How many members another card already covers, through `ContradictedCancellation.liveTwin`. It is
        // a COUNT and not a verdict: a member with a twin is one the source re-keyed, and one without is
        // either a show that really stopped or a re-key whose replacement has not arrived.
        var coveredByAnotherCard: Int

        var id: String { "\(venue)|\(missedScoutCount)" }

        // Written in the vocabulary of the VENUE and what it published, never of the scout and what it
        // matched (L604, L399): "stopped matching on a sweep" is Overture's own machinery, and the fact
        // Dan needs is that a whole venue's listings moved on one day, which is one change there rather
        // than a row of cancellations.
        var sentence: String {
            let count = memberKeys.count
            let head = "\(count) show\(count == 1 ? "" : "s") at \(venue) dropped out of its listings"
                + " on the same day, which is one change at the venue rather than \(count) cancellations."
            guard coveredByAnotherCard > 0 else { return head }
            return head + " \(coveredByAnotherCard) of them \(coveredByAnotherCard == 1 ? "is" : "are")"
                + " already on another card."
        }
    }

    /// Every source-wide break visible in `rows`, largest first.
    ///
    /// `asOf` is passed rather than read from the clock so the rule can be tested at a fixed date and so
    /// two callers in one render cannot disagree about what "future" means (L290, L74).
    /// `contradicted` is `ContradictedCancellation.contradictedKeys(among:)`, taken ONCE by the caller
    /// where a render pass already has it. Asking `liveTwin` per member is that member against the whole
    /// corpus, which is the cost that helper exists to remove (L91); the default keeps a test or a script
    /// honest without making every caller thread it through.
    static func events(among rows: [Prospect], asOf: String,
                       contradicted: Set<String>? = nil) -> [Event] {
        let covered = contradicted ?? ContradictedCancellation.contradictedKeys(among: rows)
        let flagged = rows.filter {
            $0.disappearedFromFeed
                && max($0.performanceDate ?? "", $0.runEndDate ?? "") >= asOf
        }
        var buckets: [String: [Prospect]] = [:]
        for row in flagged {
            buckets["\(canonicalVenue(row.venue))|\(row.missedScoutCount)", default: []].append(row)
        }
        return buckets.values
            .filter { $0.count >= minimumMembers }
            .map { members in
                Event(venue: members[0].venue ?? "",
                      missedScoutCount: members[0].missedScoutCount,
                      memberKeys: members.map(\.naturalKey).sorted(),
                      coveredByAnotherCard: members.filter { covered.contains($0.naturalKey) }.count)
            }
            // Deterministic, and never `first` on an unordered fetch: the venue breaks the tie so two
            // events of one size cannot swap places between renders (L343, L419).
            .sorted { ($0.memberKeys.count, $1.venue) > ($1.memberKeys.count, $0.venue) }
    }

    // The same fold the natural key uses, so two spellings of one room are one source here as well.
    private static func canonicalVenue(_ raw: String?) -> String {
        VenueNormalization.normalizeForKey(raw ?? "").lowercased()
    }
}
