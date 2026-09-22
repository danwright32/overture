import Foundation

// Milestone 62. Which stored rows are ONE SHOW, for the purposes of what a card SHOWS.
//
// WHY THIS EXISTS. One production is routinely stored as several Prospect rows: a venue publishes its
// own schedule page and then switches to per-performance ticketing links, a run is listed once as a
// span and again as its individual nights, a source drops a marketing subtitle and every re-key arm
// misses at once. Each of those rows then accrues feed misses ON ITS OWN, so the row the venue stopped
// listing crosses `FeedReconcile.goneThreshold` and renders struck through with "No longer in the feed,
// may be cancelled" while the show is playing (#3278). Measured on the live store 2026-09-19, 29 future
// rows carry that warning.
//
// WHAT IT IS AND IS NOT. Pure: no store, no I/O, no writes. It never re-keys, never merges and never
// deletes. The ingest matcher arms own IDENTITY, deciding what a row IS; this owns PRESENTATION,
// deciding what a card shows. Where the two disagree the matcher wins on storage and this still groups
// whatever rows remain. That precedence is the whole reason a wrong join here is cheap: it costs a
// re-render, never a row.
//
// THE RULE, and nothing else joins two rows automatically, ever:
//
//   Two rows are ONE SHOW when their folded titles are equal under the natural key's OWN fold, their
//   folded venues are equal under it, and EITHER their night sets intersect OR they share an opaque
//   stable production token.
//
// WHY A SHARED NIGHT AND NOT A GAP WINDOW. A gap window of any size fuses shows that are not the same:
// measured on the live store, "Tuudr Piano Competition Gala" at Weill Recital Hall is two genuinely
// different galas twenty days apart under one title, and a title-plus-venue-plus-gap rule destroys one
// of them. A shared night is the whole of the #1847 answer for a generic title, with one qualification
// worth stating because the plan for this milestone originally got it wrong (#3772, claim 5): two rows
// sharing a folded title, a venue and a night do NOT always collide on `naturalKey`, because the key's
// second field is the OPENING night rather than the night set. A run and a single night inside it, or
// two overlapping runs, share a night while holding different keys. So the unique index does not
// already forbid the generic-title case; what bounds it is that the join is presentation only and Dan
// reverses it in one press.
//
// WHY NOT GroupNameMatch.normalize. It strips a trailing subtitle after a colon or a spaced dash
// whenever the presenter is two or more words, which folds four different NY Philharmonic programmes
// onto one string. The natural key's own fold keeps the subtitle, so it can only ever fuse two titles
// that reduce to the same string. That is a canonical FUNCTION rather than a similarity judgement, and
// it is why this grouping can be applied with no human in the loop.
// WHICH MECHANISM COVERS WHICH KIND OF DUPLICATE (#4022). Several things in this app answer some
// version of "these two rows are the same show", no two of them overlap, and nothing said which was
// which, so the same question was re-derived three separate times in one session while #3282 was built.
// The natural next move on reading THIS file is to assume it also covers the launch merge's case. It
// does not, and it fails in the direction that reads as coverage.
//
//   shape of duplicate                        | what covers it        | when       | what it does
//   ----------------------------------------- | --------------------- | ---------- | -------------
//   same folded title and venue, a shared     | ShowLink (here)       | read time  | groups for
//   night or a shared production token        |                       |            | display only
//   same night, title plus or minus a         | SameNightTitleVariant | launch     | DELETES the
//   subtitle, venue NOT consulted (#1761)     | Merge                 |            | loser
//   one production whose opening night moved  | DriftedRunMerge       | launch     | DELETES the
//                                             |                       |            | loser
//   two rows that fold onto one venue key,    | NaturalKeyVenueMigration | launch  | RE-KEYS, and
//   and the collisions that re-keying makes   |                       |            | DELETES a
//                                             |                       |            | colliding loser
//   a stored row an incoming listing IS       | ScoutService's match  | ingest     | RE-KEYS the
//                                             | arms (upsertTarget)   |            | stored row
//   same show, the room spelled differently   | nothing yet (#4020)   |            |
//
// The one that is routinely mistaken for a duplicate mechanism and is not: `ContradictedCancellation`
// (#3921) decides whether a CANCELLATION WARNING is drawn, on a third and deliberately looser rule
// (folded venue, `runsOverlap`, `GroupNameMatch.isConfident`). It can afford to be loose because a wrong
// answer only withholds a warning. `FeedBreakEvent` (#4027) sits on top of it and is looser still: it
// names a whole SOURCE that stopped matching in one sweep, which is a statement about a venue's website
// rather than about any pair of rows.
//
// WHY #2 CANNOT BE SEEN FROM HERE, which is the specific trap. `SameNightTitleVariantMerge`'s worked
// example is `New York Percussion Series` against `New York Percussion Series (Featuring Percussion
// People)`. The natural key's fold KEEPS a subtitle, so those two fold DIFFERENTLY and land in different
// buckets, and this rule can never join them however many nights they share.

enum ShowLink {

    // What a row contributes to the grouping. Deliberately plain values rather than a Prospect, so the
    // rule can be exercised without a store and so nothing here can write.
    struct Row: Equatable, Sendable {
        // The caller's own handle for this row, returned untouched. `Prospect.naturalKey` today.
        var id: String
        // The SCOUT-ANCHORED title and venue, which are `Prospect.makeNaturalKey`'s own inputs.
        // Folding the DISPLAY fields instead would split a group the moment Dan renames one member,
        // because `ProspectMutations.renameGroup` writes `groupName` on one row and leaves the key
        // alone (#1274), and #1846 lets a merged card take the room name he entered.
        var groupName: String
        var venue: String?
        var performanceDate: String?
        var runEndDate: String? = nil
        var runNights: [String] = []
        // Nights Dan DROPPED, which still count toward the night set. `runNights` is the KEPT list and
        // the scout rebuilds it on every run, so a group joined only through a night he then drops
        // would split back into fragments as a side effect of a per-night decision (constraint 7).
        var droppedNights: [String] = []
        var sourceURLs: [String] = []
        // Whether the FEED still lists this row, which is a fact about the feed and not about any
        // decision Dan has made. The grouping is deliberately blind to his decisions here.
        var isStillInFeed: Bool = true
    }

    // The two folds, composed exactly as `Prospect.makeNaturalKey` composes them, which is NOT the same
    // order on both sides: the title is canonicalized BEFORE folding, the venue AFTER. A helper written
    // from a description rather than from that function drops the outer `canonicalize` on the venue and
    // then disagrees with the stored key for any venue whose fold leaves characters `canonicalize`
    // touches (#3772, claim 6). `ShowLinkTests` asserts both against a real key rather than a value.
    static func foldedTitle(_ groupName: String) -> String {
        TitleNormalization.normalizeForKey(Prospect.canonicalize(groupName))
    }

    static func foldedVenue(_ venue: String?) -> String {
        Prospect.canonicalize(venue.map(VenueNormalization.normalizeForKey) ?? "")
    }

    // A pair this rule REFUSED to join, which is what Dan is asked about rather than told.
    struct NearMiss: Equatable, Hashable, Sendable {
        var a: String
        var b: String
    }

    // For each row id, the OTHER ids that are the same show (absent when it stands alone).
    static func group(_ rows: [Row]) -> [String: [String]] {
        var out: [String: [String]] = [:]
        for cluster in clusters(rows) where cluster.count > 1 {
            for member in cluster {
                out[member.id] = cluster.filter { $0.id != member.id }.map(\.id)
            }
        }
        return out
    }

    // MARK: the rule itself

    // The night set this row occupies: the nights the feed lists, UNITED with the ones Dan dropped.
    //
    // The union is constraint 7 and it is not defensive. `runNights` is the KEPT list and the scout
    // rebuilds it from the feed on every run, subtracting Dan's drops, so a group joined only through a
    // night he then drops would silently split back into fragments as a side effect of a per-night
    // decision. The dropped list is stored precisely so it survives that fold.
    //
    // Where both are empty the row is a span, and the inclusive performanceDate ... runEndDate is its
    // nights. A row with no date at all occupies no nights and can therefore join nothing, which is
    // correct: it has nothing to be the same night as.
    private static func nights(of row: Row) -> Set<String> {
        let listed = Set(row.runNights).union(row.droppedNights)
        if !listed.isEmpty { return listed }
        guard let opening = row.performanceDate else { return [] }
        guard let closing = row.runEndDate else { return [opening] }
        // Through `EasternDate.days`, which is the app's one span vocabulary: it already caps a runaway
        // range and already answers a backwards one with its opening night alone, so a second
        // implementation here would be a second set of those decisions to drift.
        return Set(EasternDate.days(from: opening, through: closing))
    }

    // A row with its two folds taken ONCE.
    //
    // Once rather than at each site that needs them, and it is worth the extra type. Measured on the
    // live store 2026-09-19, folding per site cost 100.7 ms a pass over 1,268 rows against 43.9 ms for
    // `ContradictedCancellation` built beside it in the same function, and `QueueModel.scope` runs this
    // on EVERY queue rebuild. The folds are the expensive part: `TitleNormalization.normalizeForKey`
    // and `VenueNormalization.normalizeForKey` each walk and rewrite a string, and they were running
    // twice a row, once to bucket and once to build the token discard map.
    private struct Folded {
        let row: Row
        let title: String
        let venue: String

        init(_ row: Row) {
            self.row = row
            self.title = foldedTitle(row.groupName)
            self.venue = foldedVenue(row.venue)
        }

        var bucketKey: String { title + "|" + venue }
    }

    // Rows sharing a folded title and a folded venue, in no particular order.
    private static func buckets(_ folded: [Folded]) -> [[Folded]] {
        var byFold: [String: [Folded]] = [:]
        for one in folded {
            byFold[one.bucketKey, default: []].append(one)
        }
        return Array(byFold.values)
    }

    // The tokens this row may be joined by, after the discard below has been applied.
    //
    // Over EVERY row, and an attempt to narrow it to the rows in contested buckets is recorded here
    // because it is the obvious optimisation and it is wrong. A token joins only inside a bucket, so it
    // reads as though a row alone under its folded title and venue cannot matter. It can: the DISCARD is
    // keyed on the token and the VENUE, not on the bucket, so a row sitting alone under its own title is
    // exactly how a venue stamping one token across its season reveals itself. Narrowing it made
    // `discardsATokenThatAppearsUnderTwoTitlesAtOneVenue` go red, which is the guard working. Measured
    // 2026-09-19 it also saved 0.6 ms of 67, so there was nothing to buy.
    private static func usableTokens(_ folded: [Folded]) -> [String: Set<String>] {
        var raw: [String: Set<String>] = [:]
        for one in folded {
            raw[one.row.id] = Set(one.row.sourceURLs.compactMap(ProductionToken.inURL))
        }
        // A venue that stamps ONE token across its whole season would otherwise fuse the season onto
        // one card. So a token appearing under more than one folded title at one venue key is discarded
        // outright, for every row holding it. Deliberately a cheap deterministic rule rather than a
        // judgement: measured on the live store 2026-09-19 it discards nothing (209 distinct tokens
        // over 211 venuetix rows), which is the point. It costs nothing now and refuses the failure on
        // the day a venue starts, rather than leaving it to be noticed.
        let poisoned = poisonedTokens(folded.flatMap { one in
            (raw[one.row.id] ?? []).map { (token: $0, title: one.title, venue: one.venue) }
        })
        guard !poisoned.isEmpty else { return raw }
        for one in folded {
            raw[one.row.id]?.subtract(poisoned)
        }
        return raw
    }

    // The discard itself, as its own function because #4029 gave it a SECOND caller: the ingest match
    // chain, which now joins two rows on a shared token and must refuse the same tokens this refuses.
    // Extracted rather than restated there, because sharing the data while copying the code that applies
    // it is not consolidation (L370), and because the two would then be free to disagree about which
    // tokens are safe while each read correctly on its own (L263).
    //
    // A token appearing under more than one folded title at ONE venue joins nothing, for every row
    // holding it. Deliberately a cheap deterministic rule rather than a judgement: measured on the live
    // store 2026-09-20 it discards nothing (228 distinct tokens over 230 venuetix rows), which is the
    // point. It costs nothing now and refuses the failure on the day a venue starts stamping one token
    // across its season, rather than leaving that to be noticed.
    static func poisonedTokens(_ seen: [(token: String, title: String, venue: String)]) -> Set<String> {
        var titlesPerToken: [String: Set<String>] = [:]
        for one in seen {
            titlesPerToken[one.token + "|" + one.venue, default: []].insert(one.title)
        }
        return Set(titlesPerToken.filter { $0.value.count > 1 }.keys.map {
            String($0.prefix(upTo: $0.range(of: "|", options: .backwards)?.lowerBound ?? $0.endIndex))
        })
    }

    // #4098: the same question asked of a URL, for the two arms that join on one.
    //
    // WHY THE URL ARMS NEED IT. `matchByProductionToken` refuses a token that appears under more than
    // one show at a venue, because a venue stamping one id across its season would otherwise fuse the
    // season into a single card. The two URL arms had no equivalent: `matchByAnyRunURL` joins on ANY
    // shared run URL with no venue test at all, and `matchByStableSource` joins on the listing URL plus
    // date plus venue. Neither could see how ambiguous the URL it matched on actually was, and #4032
    // happened for exactly that reason: on a single venue's season page the venue is constant across
    // every candidate and therefore removes nothing.
    //
    // WHY IT IS NOT A COUNT OF TITLE SPELLINGS, which is the obvious rule and is wrong here. Two rows
    // that are a DUPLICATE of one show carry the same URL under two spellings, so counting spellings
    // would mark a URL ambiguous precisely because of the pair the arm exists to join, and the rule
    // would refuse the case it was built for (#4129's Carnegie pair is the live example: one listing
    // page, two billings of one concert). So the titles at a URL are first folded into SHOWS by the same
    // predicate the arms themselves use, and a URL is ambiguous only when two of those shows remain.
    //
    // TWO SCOPES, deliberately not one constant shared for tidiness (L370). `matchByStableSource` tests
    // the venue, so its question is "more than one show under this URL AT THIS VENUE"; `matchByAnyRunURL`
    // does not, and the pages it is about are organisation level ones spanning several rooms, so scoping
    // by venue would under report exactly the case (#4078 says so and deliberately reports unscoped).
    static func ambiguousURLs(_ seen: [(url: String, title: String, venue: String)],
                              scopedByVenue: Bool) -> Set<String> {
        var showsPerKey: [String: [String]] = [:]
        for one in seen where !one.url.isEmpty {
            let key = scopedByVenue ? one.url + "|" + one.venue : one.url
            var shows = showsPerKey[key] ?? []
            // A title that is the same SHOW as one already seen here adds nothing: it is the duplicate
            // the arms are for. Only a title that is a different show makes the URL ambiguous.
            if !shows.contains(where: { GroupNameMatch.isSameShowTitle($0, one.title) }) {
                shows.append(one.title)
            }
            showsPerKey[key] = shows
        }
        return Set(showsPerKey.filter { $0.value.count > 1 }.keys.map { key in
            guard scopedByVenue,
                  let cut = key.range(of: "|", options: .backwards) else { return key }
            return String(key[key.startIndex..<cut.lowerBound])
        })
    }

    // Every group, including the rows that stand alone, so one walk answers both callers.
    private static func clusters(_ rows: [Row]) -> [[Row]] {
        let folded = rows.map(Folded.init)
        let tokens = usableTokens(folded)
        var out: [[Row]] = []
        for bucket in buckets(folded) {
            if bucket.count == 1 {
                out.append([bucket[0].row])
                continue
            }
            let members = bucket.map(\.row)
            // The night set is taken once a row too, for the same reason the folds are: the pairwise
            // walk below would otherwise rebuild it for each comparison, and a bucket of 15 rows is
            // over a hundred of them.
            let nightsByID = Dictionary(uniqueKeysWithValues: members.map { ($0.id, nights(of: $0)) })
            var find = DisjointSet(members.map(\.id))
            for (index, left) in members.enumerated() {
                for right in members[(index + 1)...] where joins(left, right, nightsByID, tokens) {
                    find.union(left.id, right.id)
                }
            }
            var byRoot: [String: [Row]] = [:]
            for row in members { byRoot[find.root(row.id), default: []].append(row) }
            out.append(contentsOf: byRoot.values)
        }
        return out
    }

    private static func joins(_ left: Row, _ right: Row,
                              _ nightsByID: [String: Set<String>],
                              _ tokens: [String: Set<String>]) -> Bool {
        if !(nightsByID[left.id] ?? []).isDisjoint(with: nightsByID[right.id] ?? []) { return true }
        return !(tokens[left.id] ?? []).isDisjoint(with: tokens[right.id] ?? [])
    }

    // Union-find, so a bucket's transitive closure is one pass rather than repeated merging. The
    // Infinite Wrench bucket is 15 rows on the live store and A joins C only through B.
    private struct DisjointSet {
        private var parent: [String: String]

        init(_ ids: [String]) {
            parent = Dictionary(uniqueKeysWithValues: ids.map { ($0, $0) })
        }

        mutating func root(_ id: String) -> String {
            var current = id
            while let up = parent[current], up != current {
                parent[current] = parent[up] ?? up
                current = parent[current] ?? current
            }
            return current
        }

        mutating func union(_ a: String, _ b: String) {
            let (ra, rb) = (root(a), root(b))
            if ra != rb { parent[ra] = rb }
        }
    }

    // The pairs that shared a folded title and a folded venue and were still refused, because they
    // share no night and no token. Returned rather than discarded: a refused pair is EITHER a
    // fragmented production or two real shows under one name, and only Dan can tell which (#3282).
    //
    // Per PAIR and never one per bucket, because a bucket of three rows none of which intersect is
    // three separate questions: on the live store, Gross Prophets at Asylum NYC is exactly that.
    static func nearMisses(_ rows: [Row]) -> [NearMiss] {
        let folded = rows.map(Folded.init)
        let tokens = usableTokens(folded)
        var out: [NearMiss] = []
        for bucket in buckets(folded) where bucket.count > 1 {
            let members = bucket.map(\.row)
            let nightsByID = Dictionary(uniqueKeysWithValues: members.map { ($0.id, nights(of: $0)) })
            var find = DisjointSet(members.map(\.id))
            var refused: [(Row, Row)] = []
            for (index, left) in members.enumerated() {
                for right in members[(index + 1)...] {
                    if joins(left, right, nightsByID, tokens) {
                        find.union(left.id, right.id)
                    } else {
                        refused.append((left, right))
                    }
                }
            }
            // Only the pairs the CLOSURE left apart. A pair joined through a third row is already on
            // one card, and asking Dan whether two rows he is looking at as one show are the same show
            // is the fastest way to teach him to skip the surface (#3772, correction 1: counting the
            // raw failing pairs instead of these gave 18 where the reviewable number is 9).
            out.append(contentsOf: refused
                .filter { find.root($0.0.id) != find.root($0.1.id) }
                .map { NearMiss(a: $0.0.id, b: $0.1.id) })
        }
        return out
    }
}

extension ShowLink.Row {
    // The SCOUT-ANCHORED fields, which are `Prospect.scoutAnchoredNaturalKey`'s own inputs, and not the
    // display ones. Two shipped features deliberately make the two disagree: `renameGroup` writes
    // `groupName` and leaves the key alone (#1274), and #1846 lets a merged card take the room name Dan
    // entered. Folding the display fields would split a group the moment he renames ONE member, because
    // that rename writes one row.
    init(_ p: Prospect) {
        self.init(id: p.naturalKey,
                  groupName: p.scoutGroupName ?? p.groupName,
                  venue: p.scoutVenue ?? p.venue,
                  performanceDate: p.performanceDate,
                  runEndDate: p.runEndDate,
                  runNights: p.runNights,
                  // Through `DroppedNight.all`, never by parsing `droppedRunNights` here: those entries
                  // are self-describing "night|reason|epoch" records and the one place that reads them
                  // is that function (#3324's rule).
                  droppedNights: DroppedNight.all(on: p).map(\.night),
                  sourceURLs: (p.sourceListingURL.map { [$0] } ?? []) + p.runSourceURLs,
                  isStillInFeed: p.missedScoutCount == 0)
    }
}

// The opaque stable production token, read at query time from a URL already stored. No new field, no
// writer, no backfill and no recurring cost.
//
// #4029 made it INTERNAL rather than file private, because the ingest match chain now reads the same
// token to decide two rows are one show. There is one reader of the rule and one allowlist, rather than
// a second copy of the same judgement in `ScoutService`: sharing the data while copying the code that
// applies it is not consolidation (L370). The measurement below is the licence for BOTH uses, and at
// ingest a wrong join costs a row rather than a re-render, so `ShowLink.poisonedTokens` guards the
// ingest arm too.
enum ProductionToken {
    // The hosts where the token was MEASURED to be stable across every night of a run and opaque. An
    // allowlist rather than a pattern, because the measurement is the licence: on tixr the same-looking
    // segment is the title slugified plus a per-performance integer (10 of 10 multi-night tixr rows
    // differ only in digits), so admitting it by shape would let open-mic-8814 and open-mic-9102 join
    // two different shows. On venuetix, 18 of 18 multi-night rows carry exactly one distinct first
    // token and it carries none of the title.
    private static let hosts = ["venuetix.com"]

    static func inURL(_ raw: String) -> String? {
        guard let url = URL(string: raw), let host = url.host()?.lowercased() else { return nil }
        guard hosts.contains(where: { host == $0 || host.hasSuffix("." + $0) }) else { return nil }
        let parts = url.pathComponents.filter { $0 != "/" }
        guard let marker = parts.firstIndex(of: "showdetails"), marker + 1 < parts.count else {
            return nil
        }
        let token = parts[marker + 1]
        return token.isEmpty ? nil : token
    }
}
