import Testing
import Foundation
import SwiftData

// #2450 (Prospector milestone, phase P0.1): the free measurement, taken before anything is spent.
//
// Two rival plans disagreed by 3x about how many rooms Dan's shoot history could seed a discovery
// channel with, and a plan that sizes a channel on a wrong floor picks the wrong first channel. So the
// numbers every later phase sizes against are measured HERE, through the shipped folds, rather than by a
// bespoke tool that would be a second copy of the rule (L52) and a second hand-written refusal to open
// the live store.
//
// It reads Dan's real store ONLY through `LiveStoreClone` (a WAL-consistent SQLite online backup that
// refuses outright to hand back the live path), and the shoot history only from the RELEASE handoff file,
// read-only. It writes nothing anywhere.
//
// WHAT IT ASSERTS versus WHAT IT PRINTS, and the split is deliberate. The assertions are INVARIANTS: a
// spelling folds to a key, two spellings of one room fold together, the declared junk list still covers
// the junk shapes the data holds, a key a prospect row names is never reported as unseeded. The CENSUS
// (how many keys, how many clear each floor, which rooms) is printed as diagnostic output and pinned by
// nothing, because a pinned count stays green while the thing it stands for doubles, and that is exactly
// how the superseded "9 unseeded rooms at floor 2" figure survived long enough to be planned against
// (L63). If the numbers move, the census says so the next time somebody runs it.
@Suite("Seed table and candidate pool census, live store (#2450)")
struct SeedTableCensusLiveStoreTests {

    // MARK: - Reading the real inputs

    private static var liveStoreURL: URL {
        StoreLocation.storeURL(appSupport: StoreLocation.appSupport, isDebugBuild: false)
    }

    private static var liveStoreExists: Bool {
        FileManager.default.fileExists(atPath: liveStoreURL.path)
    }

    // The RELEASE handoff copy, named explicitly. The test bundle is always a Debug build, so
    // `ShootHistory.defaultURL` would resolve to the Debug folder, which on this Mac holds no export at
    // all: the measurement would then be taken over zero shoots and report a confident nothing (L98).
    private static var liveShootHistoryURL: URL {
        StoreLocation.handoffDirectory(appSupport: StoreLocation.appSupport, isDebugBuild: false)
            .appendingPathComponent("overture-shoot-history.json")
    }

    private static var liveInputsExist: Bool {
        liveStoreExists && FileManager.default.fileExists(atPath: liveShootHistoryURL.path)
    }

    private func liveShoots() -> [ShootRecord] {
        ShootHistory.loadWithHealth(from: Self.liveShootHistoryURL, now: Date(),
                                    staleAfter: .greatestFiniteMagnitude).shoots
    }

    private struct LiveStore {
        let prospects: [Prospect]
        let sources: [WatchedSource]
    }

    // #1672: through the ONE shared clone. Copying the .store, its -wal and its -shm one file at a time
    // races a live writer, and a clone whose -wal does not match the .store beside it makes whatever this
    // suite concludes a statement about a torn copy rather than about Dan's data.
    private func readLiveStore() throws -> (store: LiveStore, cleanup: () -> Void) {
        let fm = FileManager.default
        let scratch = fm.temporaryDirectory
            .appendingPathComponent("overture-2450-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: scratch, withIntermediateDirectories: true)
        guard let clone = try LiveStoreClone.makeClone(in: scratch) else {
            throw LiveStoreClone.Refusal.backupFailed("no live store on this machine")
        }
        let schema = Schema([Prospect.self, Recipient.self, WatchedSource.self])
        let context = ModelContext(try ModelContainer(
            for: schema,
            configurations: [ModelConfiguration(schema: schema, url: clone, cloudKitDatabase: .none)]))
        let store = LiveStore(prospects: try context.fetch(FetchDescriptor<Prospect>()),
                              sources: try context.fetch(FetchDescriptor<WatchedSource>()))
        return (store, { try? fm.removeItem(at: scratch) })
    }

    // MARK: - The seed table

    // One folded room, with every raw spelling that reached it and how many shoots each spelling carries.
    // The spellings are kept rather than counted away because a fold FAILURE is only visible as two keys
    // that should have been one, and a bare count cannot show it.
    private struct SeedKey {
        let key: String
        var shoots: Int
        var spellings: [String: Int]
    }

    private func seedTable(_ shoots: [ShootRecord]) -> [String: SeedKey] {
        var table: [String: SeedKey] = [:]
        for shoot in shoots {
            guard let key = VenuePlaces.canonicalKey(for: shoot.venue), !key.isEmpty else { continue }
            var entry = table[key] ?? SeedKey(key: key, shoots: 0, spellings: [:])
            entry.shoots += 1
            entry.spellings[shoot.venue, default: 0] += 1
            table[key] = entry
        }
        return table
    }

    private func prospectVenueKeys(_ prospects: [Prospect]) -> Set<String> {
        Set(prospects.compactMap { VenuePlaces.canonicalKey(for: $0.venue) })
    }

    private func sourceNameKeys(_ sources: [WatchedSource]) -> Set<String> {
        Set(sources.compactMap { VenuePlaces.canonicalKey(for: $0.orgName) })
    }

    // MARK: - Junk

    // The entries in Dan's Shoots calendar that are not rooms at all, so a seed channel can exclude
    // them.
    //
    // L96 / L41 decided the shape of this, and the first draft of it earned the lesson the hard way. An
    // earlier hand-written list of seven literal keys, measured at floor 2, was 27 keys short of the junk
    // this export actually holds at floor 1 (six Zoom links and twenty-five bare street addresses), and
    // one of its seven, `brasserie 8 1 / 2 and rosie o'grady`, is not a key at all: the calendar spells
    // that name with a curly apostrophe, and it splits four ways. A registry checks only what it
    // remembers, and what it remembers is exactly the junk somebody already noticed.
    //
    // So the junk is DERIVED where a rule can derive it (`hasJunkShape`), and declared by hand only for
    // the residue no rule can see. The test asserts both halves: a declared entry that has left the
    // export shows up as stale, and a declared entry the shape rule already catches shows up as
    // duplication. What neither half can catch, stated plainly rather than implied: a NEW junk entry of
    // an unforeseen shape ("Phone Call" was one) is invisible to both, and the printed census is the only
    // place a person will see it.
    // copy-inventory:ignore-start  Calendar entries MATCHED in Dan's own shoot history, never shown to him (#2450)
    static let declaredJunkKeys: Set<String> = [
        "stage",
        "phone call",
        "holy apostles soup kitchen 296 9th ave on",
    ]

    // The shape of a calendar entry that cannot be a room: a link, a key that is nothing but a street
    // address, or a key too short to name anything.
    //
    // Deliberately narrow at the address arm, because the obvious rule is wrong on real rooms. A leading
    // digit alone is not the tell: 54 Below, 48 Lounge and Theatre 71 are rooms with numbers in their
    // names, and "92nd Street Y" carries a street word too. The tell is a leading token that is ONLY
    // digits, followed by a street-type word.
    static func hasJunkShape(_ key: String) -> Bool {
        let links = ["http", "zoom", "google meet", "meet.google", "microsoft teams", "webex", "facetime"]
        if links.contains(where: { key.contains($0) }) { return true }
        let words = key.split(separator: " ").map(String.init)
        if key.count <= 2 { return true }
        let streetWords: Set<String> = ["st", "st.", "street", "ave", "ave.", "avenue", "av", "rd",
                                        "road", "dr", "drive", "blvd", "boulevard", "pl", "place",
                                        "terrace", "lane", "ln", "broadway", "plaza", "parkway",
                                        "court", "expy"]
        guard let first = words.first,
              first.allSatisfy({ $0.isNumber || $0 == "-" }) else { return false }
        return words.dropFirst().contains { streetWords.contains($0) }
    }
    // copy-inventory:ignore-end

    // MARK: - (a) and (b): the invariants, and the census they are measured beside

    // LIVE-STORE-CLAIM verified=2026-08-10 measure="the raw shoot venue spellings in overture-shoot-history.json folded through the shipped VenuePlaces.canonicalKey, and how many fold to a key with no prospect row and no watched-source name match"
    @Test(.enabled(if: liveInputsExist, "no live store or no shoot history on this machine"))
    func theSeedTableFoldsCleanlyAndItsCensusIsPrinted() async throws {
        await RealStoreTestLock.shared.acquire()
        do {
            let shoots = liveShoots()
            // L98: an empty read is its own failure, not a quiet pass. A run over zero shoots would
            // report every invariant satisfied and a census of nothing, which is byte-identical to a
            // store that genuinely has no history.
            #expect(shoots.count > 100, "the live shoot history still holds a real history to measure")

            let (store, cleanup) = try readLiveStore()
            defer { cleanup() }
            #expect(store.prospects.count > 100, "the live store still holds a real queue to measure")
            #expect(store.sources.count > 10, "the live store still holds a real watchlist to measure")

            let rawSpellings = Set(shoots.map(\.venue))
            let table = seedTable(shoots)
            let prospectKeys = prospectVenueKeys(store.prospects)
            let sourceKeys = sourceNameKeys(store.sources)

            // (a1) Every raw spelling folds to a non-empty key. A spelling that folds to nothing is a
            // shoot that can never seed anything and can never be counted against a room.
            let unfoldable = rawSpellings.filter {
                let key = VenuePlaces.canonicalKey(for: $0)
                return key == nil || key!.isEmpty
            }
            #expect(unfoldable.isEmpty,
                    "raw shoot spellings that fold to no key: \(unfoldable.sorted())")

            // (a2) A wrapping-quote spelling and its bare form are ONE room. Driven from a spelling the
            // real export actually holds, so the invariant cannot pass by testing a shape that no longer
            // arrives.
            let quoted = rawSpellings.filter { $0.hasPrefix("\"") && $0.hasSuffix("\"") && $0.count > 2 }
            #expect(!quoted.isEmpty, "the export still carries the wrapping-quote artifact the fold exists for")
            for spelling in quoted {
                let bare = String(spelling.dropFirst().dropLast())
                #expect(VenuePlaces.canonicalKey(for: spelling) == VenuePlaces.canonicalKey(for: bare),
                        "a wrapping quote changed the room: \(spelling)")
            }

            // (a3) A newline-address spelling and its bare form are ONE room.
            let withNewline = rawSpellings.filter { $0.contains("\n") }
            #expect(!withNewline.isEmpty, "the export still carries the newline-address artifact the fold exists for")
            for spelling in withNewline {
                let firstLine = String(spelling.split(separator: "\n")[0])
                #expect(VenuePlaces.canonicalKey(for: spelling) == VenuePlaces.canonicalKey(for: firstLine),
                        "an address after a newline changed the room: \(spelling.replacingOccurrences(of: "\n", with: "\\n"))")
            }

            // (a4) The junk exclusion holds up in both directions: nothing declared has left the export,
            // and nothing declared is already derivable, which is what stops the hand-written half
            // growing back into the registry L96 warns about.
            let shapedJunk = table.keys.filter { Self.hasJunkShape($0) }
            #expect(!shapedJunk.isEmpty, "the shape rule still finds the junk this export is known to hold")
            let departed = Self.declaredJunkKeys.filter { table[$0] == nil }
            #expect(departed.isEmpty,
                    "declared junk keys no longer present in the export, so the list has gone stale: \(departed.sorted())")
            let alreadyDerived = Self.declaredJunkKeys.filter { Self.hasJunkShape($0) }
            #expect(alreadyDerived.isEmpty,
                    "declared by hand what the shape rule already catches: \(alreadyDerived.sorted())")
            // A room the shape rule calls junk must never be one a prospect row or a watched source
            // names, which is the failure that would matter: a real venue excluded from its own seed.
            let junkThatIsReal = shapedJunk.filter {
                prospectKeys.contains($0) || sourceKeys.contains($0)
            }
            #expect(junkThatIsReal.isEmpty,
                    "the junk shape rule fired on rooms Overture actually watches: \(junkThatIsReal.sorted())")

            let unseeded = table.keys.filter { !prospectKeys.contains($0) && !sourceKeys.contains($0) }

            // (a5) No unseeded key is also a prospect key. Re-derived by walking the prospect rows again
            // and folding each venue at the point of comparison, rather than by re-reading the set the
            // subtraction was built from, so the two sides of the check do not come from one lookup (L70).
            let contradictions = unseeded.filter { key in
                store.prospects.contains { VenuePlaces.canonicalKey(for: $0.venue) == key }
            }
            #expect(contradictions.isEmpty,
                    "keys reported unseeded that a prospect row names: \(contradictions.sorted())")

            printCensus(shoots: shoots, table: table, prospectKeys: prospectKeys,
                        sourceKeys: sourceKeys, prospects: store.prospects, sources: store.sources)
            await RealStoreTestLock.shared.release()
        } catch {
            await RealStoreTestLock.shared.release()
            throw error
        }
    }

    private func printCensus(shoots: [ShootRecord], table: [String: SeedKey],
                             prospectKeys: Set<String>, sourceKeys: Set<String>,
                             prospects: [Prospect], sources: [WatchedSource]) {
        func atFloor(_ n: Int, _ keys: [String]) -> [String] {
            keys.filter { (table[$0]?.shoots ?? 0) >= n }
        }
        let allKeys = Array(table.keys)
        let unseeded = allKeys.filter { !prospectKeys.contains($0) && !sourceKeys.contains($0) }
        let prospectMatched = allKeys.filter { prospectKeys.contains($0) }
        let sourceOnlyMatched = allKeys.filter { !prospectKeys.contains($0) && sourceKeys.contains($0) }

        var out: [String] = []
        out.append("")
        out.append("=== P0.1 SEED TABLE CENSUS (#2450), measured \(EasternDate.today()) ===")
        out.append("shoot history: \(shoots.count) shoots, \(Set(shoots.map(\.venue)).count) distinct raw venue spellings")
        out.append("store: \(prospects.count) prospects, \(sources.count) watched sources")
        out.append("")
        out.append("DISTINCT FOLDED KEYS: \(allKeys.count)")
        out.append("  floor 1 (1+ shoots): \(atFloor(1, allKeys).count)")
        out.append("  floor 2 (2+ shoots): \(atFloor(2, allKeys).count)")
        out.append("  floor 3 (3+ shoots): \(atFloor(3, allKeys).count)")
        out.append("SEEDED: \(prospectMatched.count) matched by a prospect row, "
                   + "\(sourceOnlyMatched.count) more matched by a watched-source name")
        out.append("UNSEEDED: \(unseeded.count)"
                   + "  (floor 2: \(atFloor(2, unseeded).count), floor 3: \(atFloor(3, unseeded).count))")
        out.append("")

        func describe(_ key: String) -> [String] {
            guard let entry = table[key] else { return [] }
            let status: String
            if prospectKeys.contains(key) { status = "SEEDED-prospect" }
            else if sourceKeys.contains(key) { status = "SEEDED-source-name" }
            else if Self.hasJunkShape(key) { status = "UNSEEDED-junk-by-shape" }
            else if Self.declaredJunkKeys.contains(key) { status = "UNSEEDED-junk-declared" }
            else { status = "UNSEEDED" }
            var lines = ["  \(entry.shoots)x  \(key)  [\(status)]"]
            for (spelling, count) in entry.spellings.sorted(by: { $0.key < $1.key }) {
                lines.append("        <- \(count)x \"\(spelling.replacingOccurrences(of: "\n", with: "\\n"))\"")
            }
            return lines
        }

        let byShoots: (String, String) -> Bool = { a, b in
            let sa = table[a]?.shoots ?? 0, sb = table[b]?.shoots ?? 0
            return sa == sb ? a < b : sa > sb
        }

        out.append("--- EVERY KEY, with the raw spellings that folded into it ---")
        for key in allKeys.sorted(by: byShoots) { out.append(contentsOf: describe(key)) }
        out.append("")
        out.append("--- SUBTRACTED LIST: no prospect row and no watched-source name match ---")
        out.append("(\(unseeded.count) keys; \(atFloor(2, unseeded).count) clear floor 2; "
                   + "\(atFloor(3, unseeded).count) clear floor 3)")
        for key in unseeded.sorted(by: byShoots) { out.append(contentsOf: describe(key)) }
        out.append("")
        let junk = allKeys.filter { Self.hasJunkShape($0) || Self.declaredJunkKeys.contains($0) }
        out.append("--- JUNK: entries that are not rooms at all ---")
        out.append("(\(junk.count) of \(allKeys.count) keys; \(atFloor(2, junk).count) clear floor 2)")
        for key in junk.sorted(by: byShoots) {
            let how = Self.hasJunkShape(key) ? "derived by shape" : "declared by hand"
            out.append("  \(table[key]?.shoots ?? 0)x  \(key)  [\(how)]")
        }
        out.append("")
        out.append("--- FILL RATES (the store this channel would draw on) ---")
        let withPresenter = prospects.filter { !($0.presenter ?? "").isEmpty }.count
        out.append("  presenter filled:  \(withPresenter) of \(prospects.count)")
        // #1640: the websiteURL fill rate stood here and read 0 of every row on every run, because
        // nothing ever wrote that field. The field is gone, and so is the line reporting on it.
        out.append("=== END SEED TABLE CENSUS ===")
        out.append("")
        print(out.joined(separator: "\n"))
    }

    // MARK: - (d) P4.2's two judgment filters, measured before either is built

    // Both filters drop candidates before Dan can ever see them, which makes their mistakes structurally
    // invisible to the only person who could correct them (L93). One is shipped and was measured at 4 of
    // 225; the other has never been measured at all, and a great many performing groups carry a founder's
    // or a conductor's name, so its drop list is the finding this test exists to produce.
    //
    // The bare-personal-name rule below is a CANDIDATE, written here to be measured, not a shipped
    // filter. It is stated in full so the drop list can be read against the rule that produced it.
    // copy-inventory:ignore-start  vocabulary matched inside organisation names, never Overture's voice (#2450)
    static let organisationWords: Set<String> = [
        "ensemble", "ensembles", "orchestra", "orchestras", "philharmonic", "symphony", "sinfonia",
        "sinfonietta", "quartet", "quintet", "trio", "duo", "octet", "consort", "collective",
        "company", "companies", "co", "theatre", "theater", "theatres", "theaters", "opera", "ballet",
        "dance", "chorus", "choir", "chorale", "singers", "voices", "society", "foundation", "festival",
        "project", "projects", "productions", "production", "players", "band", "arts", "art", "music",
        "musical", "musicians", "academy", "institute", "conservatory", "school", "studio", "studios",
        "center", "centre", "hall", "club", "series", "presents", "group", "works", "workshop",
        "association", "guild", "council", "trust", "inc", "llc", "ltd", "org", "nyc", "new", "york",
        "university", "college", "seminary", "ministries", "church", "chapel", "agency", "festival's",
        "chamber", "concerts", "concert", "recital", "camerata", "players'", "jazz", "gospel", "brass",
        "strings", "winds", "percussion", "records", "media", "entertainment", "artists", "artist",
    ]

    // A lowercase particle inside a person's name ("van Beethoven", "de la Rosa"), which must not make a
    // name stop looking like a person.
    static let nameParticles: Set<String> = ["van", "von", "de", "del", "della", "di", "da", "der",
                                             "den", "la", "le", "du", "dos", "das", "bin", "al"]

    static func looksLikeABarePersonalName(_ raw: String) -> Bool {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        // Anything with a connector is a list or a compound, not one person's bare name.
        for marker in ["&", " and ", "/", ",", ":", " - ", "\u{2013}", "\u{2014}"]
        where trimmed.lowercased().contains(marker) { return false }
        // A definite article names a group, never a person: nobody is called "The Klezmatics". Measured,
        // not assumed: the first version of this rule had no such arm and dropped The Klezmatics, The
        // Hollow Men, The Notey Boys, The Tom Prettys and THE ROYAL SCAM, five bands out of five.
        if trimmed.lowercased().hasPrefix("the ") { return false }
        let words = trimmed.split(separator: " ").map(String.init)
        guard (2...3).contains(words.count) else { return false }
        for word in words {
            if word.contains(where: { $0.isNumber }) { return false }
            let bare = word.lowercased().trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
            if Self.organisationWords.contains(bare) { return false }
            // A possessive says the name owns something else ("Bach's Circle"), which is an organisation
            // named after a person rather than the person.
            if word.hasSuffix("'s") || word.hasSuffix("\u{2019}s") { return false }
            guard let first = word.first else { return false }
            if !first.isUppercase && !Self.nameParticles.contains(bare) { return false }
        }
        return true
    }
    // copy-inventory:ignore-end

    // LIVE-STORE-CLAIM verified=2026-08-10 measure="presenters on live prospects that no watched source confidently matches, and how many of those each of P4.2's two judgment filters drops"
    @Test(.enabled(if: liveStoreExists, "no live store on this machine"))
    func theTwoJudgmentFiltersAreMeasuredBeforeEitherIsBuilt() async throws {
        await RealStoreTestLock.shared.acquire()
        do {
            let (store, cleanup) = try readLiveStore()
            defer { cleanup() }
            #expect(store.prospects.count > 100, "the live store still holds a real queue to measure")

            let presenters = Set(store.prospects.compactMap { name -> String? in
                guard let p = name.presenter, !p.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
                return p
            }).sorted()
            let sourceNames = store.sources.map(\.orgName)

            // The pool, sized through the SHIPPED fold rather than a string comparison: presenters no
            // watched source confidently matches.
            let pool = presenters.filter { presenter in
                !sourceNames.contains { GroupNameMatch.isConfident(presenter, $0) }
            }

            let venueKeys = Set(store.prospects.compactMap { ProducerGate.key($0.venue) })
            let index = ProducerGate.VenueKeyIndex(venueKeys)
            let brandDrops = pool.filter { presenter in
                guard let key = ProducerGate.key(presenter) else { return false }
                return ProducerGate.isVenueBrand(key, venues: index)
            }
            let afterBrand = pool.filter { !brandDrops.contains($0) }
            let personalDrops = afterBrand.filter { Self.looksLikeABarePersonalName($0) }
            let afterBoth = afterBrand.filter { !personalDrops.contains($0) }

            var out: [String] = []
            out.append("")
            out.append("=== P4.2 JUDGMENT FILTERS, MEASURED (#2450) ===")
            out.append("distinct presenters on live rows: \(presenters.count)")
            out.append("pool via GroupNameMatch.isConfident (no watched source matches): \(pool.count)")
            out.append("")
            out.append("FILTER 2, shipped ProducerGate.isVenueBrand: drops \(brandDrops.count) of \(pool.count)")
            for name in brandDrops { out.append("  DROP  \(name)") }
            out.append("  -> \(afterBrand.count) remain")
            out.append("")
            out.append("FILTER 4, CANDIDATE bare-personal-name rule (never measured before): "
                       + "drops \(personalDrops.count) of \(afterBrand.count)")
            for name in personalDrops { out.append("  DROP  \(name)") }
            out.append("  -> \(afterBoth.count) remain after both filters")
            out.append("")
            out.append("WHAT THE CANDIDATE RULE GETS WRONG, from this data: a group named for its founder or")
            out.append("conductor is indistinguishable from the person, so each DROP above is a candidate Dan")
            out.append("would never see. Names of 2 or 3 words KEPT only because they carry an organisation")
            out.append("word, for scale against the drops:")
            let keptOnlyByVocabulary = afterBrand.filter { name in
                let words = name.split(separator: " ")
                guard (2...3).contains(words.count) else { return false }
                return !Self.looksLikeABarePersonalName(name)
            }
            for name in keptOnlyByVocabulary { out.append("  KEEP  \(name)") }
            out.append("=== END JUDGMENT FILTERS ===")
            out.append("")
            print(out.joined(separator: "\n"))

            // The invariants. Not the drop counts, which are the census: what must hold is that the pool
            // exists and that its own filters do not empty the first shipping channel between them (L77:
            // an emptied channel and "you already watch everyone" are the same screen).
            #expect(!pool.isEmpty, "the store still holds presenters no watched source matches")
            #expect(!afterBoth.isEmpty,
                    "P4.2's filters removed the entire pool, which reads on screen exactly like having nobody left to propose")
            // A filter that fires on a name a watched source already matches would be judging rows that
            // never reach it, which is how a measured drop rate stops describing the shipped path.
            let dropsOutsideThePool = (brandDrops + personalDrops).filter { !pool.contains($0) }
            #expect(dropsOutsideThePool.isEmpty,
                    "filters dropped names that are not in the pool at all: \(dropsOutsideThePool)")
            await RealStoreTestLock.shared.release()
        } catch {
            await RealStoreTestLock.shared.release()
            throw error
        }
    }
}
