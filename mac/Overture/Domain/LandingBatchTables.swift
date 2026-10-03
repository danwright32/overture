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

        static let none = Contribution()
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

        fileprivate mutating func insert(_ entry: Entry, into key: String) {
            var list = entries[key] ?? []
            let at = list.firstIndex { $0.order > entry.order } ?? list.endIndex
            list.insert(entry, at: at)
            entries[key] = list
        }

        // The walk `ShowLink.addShows` makes, over this key's list alone.
        fileprivate mutating func rejudge(_ key: String) {
            let wasAmbiguous = (shows[key]?.count ?? 0) > 1
            var folded: [String] = []
            for e in entries[key] ?? [] { ShowLink.addShow(e.title, to: &folded) }
            shows[key] = folded.isEmpty ? nil : folded
            let isAmbiguous = folded.count > 1
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
                self[keyPath: scope].rejudge(k)
            }
        }
    }

    private mutating func deposit(_ row: Row, order: Int, _ value: Contribution) {
        for t in value.tokens { count(t, by: 1) }
        for s in value.spellings { spellingCounts[s.sourceId, default: [:]][s.venue, default: 0] += 1 }
        for u in value.urls where !u.url.isEmpty {
            for scope in Self.scopes {
                let k = self[keyPath: scope].key(u)
                self[keyPath: scope].insert(URLScope.Entry(order: order, row: row, title: u.title), into: k)
                self[keyPath: scope].rejudge(k)
            }
        }
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
    }

    func snapshot(naming name: (Row) -> String) -> Snapshot {
        func rows(_ s: URLScope) -> [String: [String]] {
            s.entries.mapValues { $0.map { name($0.row) + " " + $0.title } }
        }
        return Snapshot(titleCounts: titleCounts, poisonedTokens: poisonedTokens, spellingCounts: spellingCounts,
                        atAVenueRows: rows(atAVenue), anywhereRows: rows(anywhere),
                        atAVenueShows: atAVenue.shows, anywhereShows: anywhere.shows,
                        atAVenueAmbiguous: atAVenue.ambiguous, anywhereAmbiguous: anywhere.ambiguous)
    }
}
