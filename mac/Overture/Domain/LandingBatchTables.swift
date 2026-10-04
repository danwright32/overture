import Foundation

// #4333 (step A4 of #4275's plan): the STORED rows' half of the three per source passes a landing makes over
// the whole store, held once per landing and kept current row by row, so each source pays for its own batch
// and for what was written since the source before it, never again for the rows nobody touched.
//
// The three passes, and why each takes the structure it does (discussion #4326, RC2):
//
//   - POISON (`ShowLink.poisonedTokens`) is order independent: a `token|venue` is poisoned when it holds more
//     than one distinct folded title. So it is a COUNT table, per `token|venue`, of how many rows hold each
//     title, which supports an exact add and an exact remove.
//   - SPELLINGS (`VenueSpellingLock.locked`) is order independent over a multiset: it counts spellings and
//     breaks ties by the spelling. So it is a count, per source id, of each venue spelling.
//   - AMBIGUITY (`ShowLink.addShows`) is ORDER DEPENDENT: a title joins the FIRST show `isSameShowTitle`
//     matches, and that test is not transitive (A matches C, B matches C, A does not match B), so the order the
//     titles arrive in decides how many shows a key holds. So it keeps, per key, the ORDERED list of the rows
//     on it (the landing's row order), and when a row's entry on a key changes the walk is redone over that
//     key's list alone.
//
// THE ANSWER FOR A BATCH is the stored answer plus whatever the batch's own keys add, and never a key alone:
// both rules strip the venue off the key before answering (the stripped-key trap), so a token poisoned at a
// venue only stored rows hold is still poisoned for a batch at another venue. The stored half is kept already
// stripped, so a key the batch does not touch is never re-judged.
//
// #4460: and the ROWS ON A KEY, for the per event match arms. Each arm a show reaches when it misses its natural
// key (the concert identity, any shared run URL, the production token, the stable source listing, and the
// arrival notes' lookalike and already pitched scans) used to walk every stored row for every such show, so a
// landing bringing N new shows walked the store several times N over. Every one of those arms only ever
// matches a row carrying one of the show's own keys: a folded URL, a production token, a series id, or its
// night. So the tables keep, per key, the ORDERED list of the rows carrying it (the landing's row order, the
// order the walk met them in), and an arm walks only the rows on its keys, its own predicate unchanged. The
// URL list is the `anywhere` scope's own (its key is the bare folded URL), so no second URL index is kept;
// tokens, series ids and nights get lists of their own, fed by the same change feed.
//
// Pure: the landing (`ScoutLandingStore`) says which rows joined, left or were written, and in what order.
struct LandingBatchTables {
    typealias Row = ObjectIdentifier

    // One row's part in each pass, as the rules read it.
    struct Contribution: Equatable {
        // Folded token, folded title, folded venue: one per distinct triple, so a row counts once per title.
        struct Token: Hashable { let token: String; let title: String; let venue: String }
        // Folded URL, the title AS WRITTEN (the ambiguity walk compares written titles), folded venue.
        struct Link: Hashable { let url: String; let title: String; let venue: String }
        // A source id this row carries, and the venue spelling it carries, once per occurrence of the id.
        struct Spelling: Hashable { let sourceId: String; let venue: String }

        var tokens: Set<Token> = []
        var urls: [Link] = []
        var spellings: [Spelling] = []
        // #4460: the row's series id and its night as stored, for the concert identity arm and the arrival
        // notes. nil when empty, since every arm asking by either refuses an empty one before it looks.
        var seriesId: String?
        var night: String?
        // #4475: every source id the row carries, for the reconcile, which can change only a row one of its
        // reports' sources owns, or one it lists by key or by link.
        var owners: Set<String> = []

        static let none = Contribution()
    }

    // MARK: the rows on a key (#4460)

    // Per key, the rows carrying it, in the landing's order, each once however often it carries the key.
    struct KeyedRows: Equatable {
        struct Entry: Equatable { let order: Int; let row: Row }
        fileprivate(set) var entries: [String: [Entry]] = [:]
        // Which rows each key holds, so asking whether a row is already on a key costs nothing however many rows
        // the key holds (a source can own hundreds). Lessons review of #4482: a linear test and a linear insert
        // made building one key of N rows square in N.
        private var members: [String: Set<Row>] = [:]

        // Changed IN PLACE, never through a copy of the key's list, which would copy the whole list per row. The
        // common case, the build in order and a row joining at the end, appends; otherwise the place is found by
        // a binary search for the first entry ordered after it.
        fileprivate mutating func insert(_ row: Row, order: Int, into key: String) {
            guard members[key, default: []].insert(row).inserted else { return }
            _ = LandingBatchTables.insertInOrder(Entry(order: order, row: row), order: \.order, into: &entries[key])
        }

        fileprivate mutating func remove(_ row: Row, from key: String) {
            guard members[key]?.remove(row) != nil else { return }
            entries[key]?.removeAll { $0.row == row }
            if entries[key]?.isEmpty == true {
                entries[key] = nil
                members[key] = nil
            }
        }
    }

    private(set) var rowsByToken = KeyedRows()
    private(set) var rowsBySeries = KeyedRows()
    private(set) var rowsByNight = KeyedRows()
    private(set) var rowsByOwner = KeyedRows()

    // The keys a per event arm looks a show up by, already folded the way the arm's own predicate folds them.
    enum Lookup: Equatable {
        case sharingURL(Set<String>)
        case sharingToken(Set<String>)
        case series(String)
        case night(String)
        // #4475: the rows any of these source ids owns.
        case ownedBy(Set<String>)
    }

    // The rows carrying any of the lookup's keys, once each, in the landing's order: the rows a walk over every
    // stored row could find an arm's match among, in the order the walk met them. An empty key is on no row.
    func rows(_ lookup: Lookup) -> [Row] {
        var lists: [[(order: Int, row: Row)]]
        switch lookup {
        case .sharingURL(let urls):
            lists = urls.map { (anywhere.entries[$0] ?? []).map { (order: $0.order, row: $0.row) } }
        case .sharingToken(let tokens):
            lists = tokens.map { (rowsByToken.entries[$0] ?? []).map { (order: $0.order, row: $0.row) } }
        case .series(let id):
            lists = [(rowsBySeries.entries[id] ?? []).map { (order: $0.order, row: $0.row) }]
        case .night(let night):
            lists = [(rowsByNight.entries[night] ?? []).map { (order: $0.order, row: $0.row) }]
        case .ownedBy(let owners):
            lists = owners.map { (rowsByOwner.entries[$0] ?? []).map { (order: $0.order, row: $0.row) } }
        }
        if lists.count == 1 { return lists[0].map(\.row) }
        var seen: Set<Row> = []
        return lists.joined().sorted { $0.order < $1.order }.filter { seen.insert($0.row).inserted }.map(\.row)
    }

    // MARK: poison

    private var titleCounts: [String: [String: Int]] = [:]
    private var poisonedKeysPerToken: [String: Int] = [:]
    // The stored rows' poisoned tokens, stripped, kept as a set so a batch's answer starts from it uncopied.
    private(set) var poisonedTokens: Set<String> = []

    // MARK: spellings

    private(set) var spellingCounts: [String: [String: Int]] = [:]

    // MARK: ambiguity, in both scopes

    struct URLScope: Equatable {
        let scopedByVenue: Bool
        struct Entry: Equatable { let order: Int; let row: Row; let title: String }
        fileprivate(set) var entries: [String: [Entry]] = [:]
        fileprivate(set) var shows: [String: [String]] = [:]
        fileprivate var ambiguousKeysPerURL: [String: Int] = [:]
        fileprivate(set) var ambiguous: Set<String> = []

        init(scopedByVenue: Bool) { self.scopedByVenue = scopedByVenue }

        func key(_ e: Contribution.Link) -> String {
            ShowLink.showKey(url: e.url, venue: e.venue, scopedByVenue: scopedByVenue)
        }

        func answer(_ key: String) -> String { scopedByVenue ? ShowLink.unscoped(key) : key }

        fileprivate mutating func remove(_ row: Row, from key: String) {
            entries[key]?.removeAll { $0.row == row }
            if entries[key]?.isEmpty == true { entries[key] = nil }
        }

        // Changed IN PLACE through the one ordered insert (#4512: a copy of the key's list and a linear search
        // made building one key square in its rows). Returns whether the entry went on the END, the build's case
        // and a row joining, which is the case `extend` can answer without walking the key again.
        fileprivate mutating func insert(_ entry: Entry, into key: String) -> Bool {
            LandingBatchTables.insertInOrder(entry, order: \.order, into: &entries[key])
        }

        // An entry appended at the END of a key's list: the walk over the whole list is the walk over the list
        // before it, which `shows[key]` already holds, followed by this one title, so only that step is taken.
        // Identical to `rejudge` by construction; any other change re-walks the key. Returns the title steps
        // taken, which the tables count outside this compared state (#4512 review).
        fileprivate mutating func extend(_ key: String, with title: String) -> Int {
            let wasAmbiguous = (shows[key]?.count ?? 0) > 1
            ShowLink.addShow(title, to: &shows[key, default: []])
            noteAmbiguity(key, was: wasAmbiguous, is: (shows[key]?.count ?? 0) > 1)
            return 1
        }

        // The walk `ShowLink.addShows` makes, over this key's list alone. Returns the title steps taken.
        @discardableResult
        fileprivate mutating func rejudge(_ key: String) -> Int {
            let wasAmbiguous = (shows[key]?.count ?? 0) > 1
            var folded: [String] = []
            var steps = 0
            for e in entries[key] ?? [] {
                steps += 1
                ShowLink.addShow(e.title, to: &folded)
            }
            shows[key] = folded.isEmpty ? nil : folded
            noteAmbiguity(key, was: wasAmbiguous, is: folded.count > 1)
            return steps
        }

        private mutating func noteAmbiguity(_ key: String, was wasAmbiguous: Bool, is isAmbiguous: Bool) {
            guard wasAmbiguous != isAmbiguous else { return }
            let url = answer(key)
            let n = (ambiguousKeysPerURL[url] ?? 0) + (isAmbiguous ? 1 : -1)
            ambiguousKeysPerURL[url] = n > 0 ? n : nil
            if n > 0 { ambiguous.insert(url) } else { ambiguous.remove(url) }
        }

        // The stored shows on each key a batch touches, continued with the batch's titles in order, and the
        // stored answer with every key that ends up holding more than one show added to it.
        func answer(adding incoming: [Contribution.Link]) -> Set<String> {
            var touched: [String: [String]] = [:]
            for e in incoming where !e.url.isEmpty {
                let k = key(e)
                var folded = touched[k] ?? shows[k] ?? []
                ShowLink.addShow(e.title, to: &folded)
                touched[k] = folded
            }
            var out = ambiguous
            for (k, folded) in touched where folded.count > 1 { out.insert(answer(k)) }
            return out
        }
    }

    // #4512: every `ShowLink.addShow` step the two scopes have taken building and keeping their shows, so a test
    // can pin that building a key of N rows in order costs N steps rather than the square of N. Kept here, outside
    // the scopes' compared state, so two scopes holding the same entries and shows still compare equal.
    private(set) var titleSteps = 0

    // The ONE ordered insert every per key list here uses (`KeyedRows` and `URLScope`), changed in place through
    // the dictionary's own slot: the common case, the build in order and a row joining at the end, appends;
    // otherwise the place is found by a binary search for the first entry ordered after it. Returns whether the
    // entry went on the end.
    fileprivate static func insertInOrder<E>(_ entry: E, order: KeyPath<E, Int>, into list: inout [E]?) -> Bool {
        let at = entry[keyPath: order]
        guard let last = list?.last, last[keyPath: order] > at else {
            if list == nil { list = [entry] } else { list?.append(entry) }
            return true
        }
        var low = 0
        var high = list?.count ?? 0
        while low < high {
            let mid = (low + high) / 2
            if (list?[mid][keyPath: order] ?? .max) > at { high = mid } else { low = mid + 1 }
        }
        list?.insert(entry, at: low)
        return false
    }

    private(set) var atAVenue = URLScope(scopedByVenue: true)
    private(set) var anywhere = URLScope(scopedByVenue: false)
    private static var scopes: [WritableKeyPath<LandingBatchTables, URLScope>] { [\.atAVenue, \.anywhere] }

    // Every row's current contribution and its place in the landing's order.
    private var contributions: [Row: (order: Int, value: Contribution)] = [:]

    func order(of row: Row) -> Int? { contributions[row]?.order }

    // MARK: change

    // Sets one row's contribution, at its place in the landing's order: a row joining, or a row whose fields
    // were written. Returns whether anything changed.
    @discardableResult
    mutating func set(_ row: Row, order: Int, to value: Contribution) -> Bool {
        let old = contributions[row]
        if let old, old.order == order, old.value == value { return false }
        if let old { withdraw(row, old.value) }
        contributions[row] = (order, value)
        deposit(row, order: order, value)
        return true
    }

    // A row leaving the landing.
    mutating func remove(_ row: Row) {
        guard let old = contributions.removeValue(forKey: row) else { return }
        withdraw(row, old.value)
    }

    private mutating func withdraw(_ row: Row, _ value: Contribution) {
        for t in value.tokens { count(t, by: -1) }
        for s in value.spellings {
            let n = (spellingCounts[s.sourceId]?[s.venue] ?? 0) - 1
            spellingCounts[s.sourceId]?[s.venue] = n > 0 ? n : nil
            if spellingCounts[s.sourceId]?.isEmpty == true { spellingCounts[s.sourceId] = nil }
        }
        for u in value.urls where !u.url.isEmpty {
            for scope in Self.scopes {
                let k = self[keyPath: scope].key(u)
                self[keyPath: scope].remove(row, from: k)
                titleSteps += self[keyPath: scope].rejudge(k)
            }
        }
        for t in Set(value.tokens.map(\.token)) { rowsByToken.remove(row, from: t) }
        if let id = value.seriesId { rowsBySeries.remove(row, from: id) }
        if let night = value.night { rowsByNight.remove(row, from: night) }
        for owner in value.owners { rowsByOwner.remove(row, from: owner) }
    }

    private mutating func deposit(_ row: Row, order: Int, _ value: Contribution) {
        for t in value.tokens { count(t, by: 1) }
        for s in value.spellings { spellingCounts[s.sourceId, default: [:]][s.venue, default: 0] += 1 }
        for u in value.urls where !u.url.isEmpty {
            for scope in Self.scopes {
                let k = self[keyPath: scope].key(u)
                if self[keyPath: scope].insert(URLScope.Entry(order: order, row: row, title: u.title), into: k) {
                    titleSteps += self[keyPath: scope].extend(k, with: u.title)
                } else {
                    titleSteps += self[keyPath: scope].rejudge(k)
                }
            }
        }
        for t in Set(value.tokens.map(\.token)) { rowsByToken.insert(row, order: order, into: t) }
        if let id = value.seriesId { rowsBySeries.insert(row, order: order, into: id) }
        if let night = value.night { rowsByNight.insert(row, order: order, into: night) }
        for owner in value.owners { rowsByOwner.insert(row, order: order, into: owner) }
    }

    private mutating func count(_ t: Contribution.Token, by delta: Int) {
        let key = ShowLink.poisonKey(token: t.token, venue: t.venue)
        let wasPoisoned = (titleCounts[key]?.count ?? 0) > 1
        let n = (titleCounts[key]?[t.title] ?? 0) + delta
        titleCounts[key, default: [:]][t.title] = n > 0 ? n : nil
        if titleCounts[key]?.isEmpty == true { titleCounts[key] = nil }
        let isPoisoned = (titleCounts[key]?.count ?? 0) > 1
        guard wasPoisoned != isPoisoned else { return }
        let token = ShowLink.unscoped(key)
        let keys = (poisonedKeysPerToken[token] ?? 0) + (isPoisoned ? 1 : -1)
        poisonedKeysPerToken[token] = keys > 0 ? keys : nil
        if keys > 0 { poisonedTokens.insert(token) } else { poisonedTokens.remove(token) }
    }

    // MARK: a batch's answers

    // `ShowLink.poisonedTokens` over the stored rows and then the batch.
    func poisoned(adding incoming: [Contribution.Token]) -> Set<String> {
        var touched: [String: Set<String>] = [:]
        for t in incoming {
            let key = ShowLink.poisonKey(token: t.token, venue: t.venue)
            var titles = touched[key] ?? Set(titleCounts[key]?.keys.map { $0 } ?? [])
            titles.insert(t.title)
            touched[key] = titles
        }
        var out = poisonedTokens
        for (key, titles) in touched where titles.count > 1 { out.insert(ShowLink.unscoped(key)) }
        return out
    }

    // The venue spellings the stored rows carry under these source ids, as the multiset
    // `VenueSpellingLock.locked` reads (it counts them and breaks ties by spelling, so order does not matter).
    func spellings(usedBy sourceIds: [String]) -> [String] {
        sourceIds.flatMap { id in
            (spellingCounts[id] ?? [:]).sorted { $0.key < $1.key }
                .flatMap { Array(repeating: $0.key, count: $0.value) }
        }
    }

    // MARK: a rebuild, for comparison

    // The tables a landing would hold had it built them now from these rows, in this order.
    static func rebuilt(_ rows: [(row: Row, contribution: Contribution)]) -> LandingBatchTables {
        var t = LandingBatchTables()
        for (i, r) in rows.enumerated() { t.set(r.row, order: i, to: r.contribution) }
        return t
    }

    // What two sets of tables must agree on to give every batch the same answers: every count, every key's
    // rows in order, every key's shows, and every stored answer. The order NUMBERS are left out, because a
    // landing's have gaps where a row left and a rebuild's do not; the order they put the rows in is kept.
    struct Snapshot: Equatable {
        let titleCounts: [String: [String: Int]]
        let poisonedTokens: Set<String>
        let spellingCounts: [String: [String: Int]]
        let atAVenueRows: [String: [String]]
        let anywhereRows: [String: [String]]
        let atAVenueShows: [String: [String]]
        let anywhereShows: [String: [String]]
        let atAVenueAmbiguous: Set<String>
        let anywhereAmbiguous: Set<String>
        // #4460: the rows on each token, series id and night, in order.
        let tokenRows: [String: [String]]
        let seriesRows: [String: [String]]
        let nightRows: [String: [String]]
        // #4475: the rows each source id owns, in order.
        let ownerRows: [String: [String]]
    }

    func snapshot(naming name: (Row) -> String) -> Snapshot {
        func rows(_ s: URLScope) -> [String: [String]] {
            s.entries.mapValues { $0.map { name($0.row) + " " + $0.title } }
        }
        func rows(_ k: KeyedRows) -> [String: [String]] { k.entries.mapValues { $0.map { name($0.row) } } }
        return Snapshot(titleCounts: titleCounts, poisonedTokens: poisonedTokens, spellingCounts: spellingCounts,
                        atAVenueRows: rows(atAVenue), anywhereRows: rows(anywhere),
                        atAVenueShows: atAVenue.shows, anywhereShows: anywhere.shows,
                        atAVenueAmbiguous: atAVenue.ambiguous, anywhereAmbiguous: anywhere.ambiguous,
                        tokenRows: rows(rowsByToken), seriesRows: rows(rowsBySeries), nightRows: rows(rowsByNight),
                        ownerRows: rows(rowsByOwner))
    }
}
