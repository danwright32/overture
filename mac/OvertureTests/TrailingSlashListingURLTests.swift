import Testing
import Foundation
import SwiftData

// #4116: `ScoutService.matchByStableSource` joins a stored row to an incoming listing on the listing
// URL plus the date plus the folded venue, and it compares the two URLs as RAW STRINGS
// (`$0.sourceListingURL == url`). `matchByAnyRunURL` compares run URLs the same way, through a
// `Set<String>`. So one page addressed two ways is two pages to both arms, and the arm that exists
// precisely to recognise a second billing of one show misses the cheapest possible near miss.
//
// MEASURED ON THE LIVE STORE 2026-09-21, over a WAL inclusive clone of 1,333 rows, 1,312 of which carry
// a listing URL. Folding away ONE trailing slash newly joins four pairs that share a URL and a night,
// and every one of the four is one show billed two ways at Kaufman Music Center:
//
//   pk 598  / pk 1589  2026-10-06  Orli Shaham: In Clara's Hands        | Orli Shaham, piano
//   pk 606  / pk 1225  2026-10-04  Parlando: Die Stadt ohne Juden (...) | Parlando
//   pk 779  / pk 1588  2026-10-30  VOCES8 at Trinity Church             | VOCES8 at Trinity Church
//   pk 939  / pk 1228  2026-11-12  Kurt Weill, Bertolt Brecht & ... "Happy End" | Kurt Weill & ...
//
// WHAT WAS DELIBERATELY NOT FOLDED, and why, so a later pass does not rediscover the question (L308).
// The same measurement scored three further rules on the same corpus and each newly joins ZERO pairs on
// top of the trailing slash: lowercasing the host, forcing the scheme to https, and dropping a `www.`
// prefix. Each is a judgement with a cost (a path is case sensitive on some servers, two schemes can be
// two sites) and none of them buys a single join today, so the fold is the slash and nothing else, and
// this comment is the record of what was measured rather than overlooked.
//
// This drives the real `ScoutService.apply` rather than the private arm, because the claim is about what
// the PIPELINE does with an arriving listing, which is where the duplicate is minted.
// @MainActor because ScoutService is, and because a SwiftData container is main actor bound.
@MainActor
@Suite("A listing URL differing only by a trailing slash is one listing (#4116)")
struct TrailingSlashListingURLTests {

    private static let bare = "https://www.kaufmanmusiccenter.org/mch/event/orli-shaham-in-claras-hands"
    private static var slashed: String { bare + "/" }
    private static let parlandoBare =
        "https://www.kaufmanmusiccenter.org/mch/event/parlando-olga-neuwirth-the-city-without-jews"
    private static var parlandoSlashed: String { parlandoBare + "/" }
    private static let venue = "Merkin Hall"
    private static let night = "2026-10-04"

    private func context() throws -> ModelContext {
        let schema = Schema([Prospect.self, Recipient.self])
        return ModelContext(try ModelContainer(for: schema,
                            configurations: [ModelConfiguration(schema: schema,
                                                                isStoredInMemoryOnly: true)]))
    }

    @discardableResult
    private func stored(_ ctx: ModelContext, title: String, url: String,
                        runURLs: [String]? = nil) -> Prospect {
        let key = Prospect.makeNaturalKey(groupName: title, performanceDate: Self.night,
                                          venue: Self.venue)
        // Every non defaulted field is supplied because the initialiser demands it. None but the title,
        // the venue, the date and the URLs is read by the arms under test.
        let p = Prospect(naturalKey: key, groupName: title, discipline: "classical", venue: Self.venue,
                         performanceDate: Self.night, sourceListingURL: url,
                         priorRelationship: "none", production: "unknown", profile: "unknown",
                         coverage: "unknown", fitScore: 3, tier: "medium", fitReason: "",
                         matchedClientName: nil, possibleMatchSource: nil, possibleMatchName: nil,
                         runEndDate: nil, partOfRelatedRun: false, runSourceURLs: runURLs ?? [url],
                         runNights: [Self.night])
        ctx.insert(p)
        return p
    }

    private func ingest(_ ctx: ModelContext, title: String, url: String) {
        let incoming = ExtractedEvent(title: title, presenter: "Kaufman Music Center",
                                      venue: Self.venue, performanceDate: Self.night, sourceUrl: url)
        _ = ScoutService.apply(events: [incoming], clients: [], history: [], blocked: .empty,
                               today: "2026-09-21", sourceIds: ["kaufmanmusiccenter-org"], into: ctx)
    }

    // THE CLAIM UNDER TEST, and the shape is the live pair's rather than the tidy one. The tidy
    // fixture, one page addressed two ways under an IDENTICAL title, cannot test this at all: the two
    // rows then share a natural key, `storedByKey` answers on the first arm and no URL arm is reached.
    // It was written that way first and passed before any fix existed (L159 from the other direction: a
    // green the rule could not have produced). The URL arms exist to recognise a listing whose TITLE
    // drifted, so the title must differ for a URL comparison to be what decides.
    //
    // pk 606 / pk 1225 on the live store: `Parlando` and `Parlando: Die Stadt ohne Juden (The City
    // without Jews)`, 2026-10-04, Merkin Hall, one page with and without its trailing slash.
    //
    // WHICH ARM JOINS IT, measured by mutation rather than assumed, because the first version of this
    // comment named `matchByStableSource` and was wrong. BOTH URL arms fold, and on this fixture EITHER
    // ONE ALONE is enough, so this test asserts the pipeline's outcome and not any single arm:
    //
    //   `ListingURL.sameListing` stopped folding  -> this test stayed GREEN (the run URL arm joined it)
    //   `ListingURL.foldedSet` stopped folding    -> this test stayed GREEN (the stable source arm did)
    //
    // The redundancy is real and worth having, and each arm is proved separately rather than through
    // this one: the run URL arm by `aRunMemberURLDifferingOnlyByASlashIsTheSameMember` below, which
    // caught the `foldedSet` mutation, and `sameListing` by `twoAbsentAddressesAreNotOneListing`, which
    // caught the other. Saying this here is the difference between a test that measures a pipeline and a
    // comment that claims an arm nobody checked (L400).
    @Test func aDriftedTitleOnOnePageAddressedTwoWaysDoesNotMintASecondRow() throws {
        let ctx = try context()
        stored(ctx, title: "Parlando", url: Self.parlandoBare)
        try ctx.save()

        ingest(ctx, title: "Parlando: Die Stadt ohne Juden (The City without Jews)",
               url: Self.parlandoSlashed)
        try ctx.save()

        let rows = try ctx.fetch(FetchDescriptor<Prospect>())
        #expect(rows.count == 1,
                "one page addressed two ways is stored \(rows.count) times: \(rows.map { $0.sourceListingURL ?? "nil" }.sorted())")
    }

    // The precondition for the test above, asserted on its own so a red there can be told from a fixture
    // whose two titles the arm would have refused anyway (L159). `matchByStableSource` demands
    // `isSameShowTitle` since #4032, so the fold alone never decides.
    @Test func theArmsOwnTitleGuardAcceptsThatPair() {
        #expect(GroupNameMatch.isSameShowTitle("Parlando",
                                               "Parlando: Die Stadt ohne Juden (The City without Jews)"),
                "the fixture's two titles are not the same show by the arm's own predicate, so the test above could never have measured the URL fold")
    }

    // What the fold DOES and DOES NOT buy on the four live pairs, recorded rather than left as a claim in
    // a comment. The fold makes the arm SEE each pair; the arm's title guard then decides. A pair the
    // guard refuses stays two rows, which is the right direction to fail (#4032's own record) and is
    // stated here so nobody reads "four pairs" as "four joins".
    //
    // MEASURED 2026-09-21: THREE of the four. The one refused is the Kurt Weill pair, where one billing
    // drops a co-author ("Elisabeth Hauptmann") and the other uses curly quotation marks, so the two
    // titles are not the same show by `isSameShowTitle` however the URL is spelled. That pair therefore
    // stays two rows after this change, and saying so here is the difference between a measurement and a
    // claim (L107).
    @Test func theFourLivePairsAreScoredByTheTitleGuardRatherThanAssumed() {
        let pairs: [(String, String)] = [
            ("Orli Shaham: In Clara's Hands", "Orli Shaham, piano"),
            ("Parlando: Die Stadt ohne Juden (The City without Jews)", "Parlando"),
            ("VOCES8 at Trinity Church", "VOCES8 at Trinity Church"),
            ("Kurt Weill, Bertolt Brecht & Elisabeth Hauptmann's \"Happy End\"",
             "Kurt Weill & Bertolt Brecht's \u{201C}Happy End\u{201D}"),
        ]
        let admitted = pairs.filter { GroupNameMatch.isSameShowTitle($0.0, $0.1) }
        // Pinned to the measured verdict rather than to "all four", so a later change to the title
        // predicate that silently widens or narrows this set turns the suite red and has to be looked at.
        #expect(admitted.map(\.0).sorted() == [
                    "Orli Shaham: In Clara's Hands",
                    "Parlando: Die Stadt ohne Juden (The City without Jews)",
                    "VOCES8 at Trinity Church",
                ],
                "the title guard's verdict on the four live pairs has moved from the set measured on 2026-09-21: \(admitted.map(\.0).sorted())")
    }

    // The same question asked of the OTHER arm, which compares run member URLs through a Set. The stored
    // row carries the slashed spelling among its run URLs and the incoming listing the bare one, and the
    // two natural keys differ because the nights differ, so the run URL arm is the only thing that can
    // join them. Covering one arm and not the other is how a fix reaches half its class (L30).
    @Test func aRunMemberURLDifferingOnlyByASlashIsTheSameMember() throws {
        let ctx = try context()
        let other = "https://www.kaufmanmusiccenter.org/mch/event/orli-shaham-in-claras-hands/"
        let row = stored(ctx, title: "Orli Shaham, piano", url: other,
                         runURLs: [other, "https://www.kaufmanmusiccenter.org/mch/event/second-night/"])
        row.runNights = [Self.night, "2026-10-07"]
        row.runEndDate = "2026-10-07"
        row.partOfRelatedRun = true
        try ctx.save()

        // A later night of the same run, published without the slash, so no natural key can match.
        let incoming = ExtractedEvent(title: "Orli Shaham, piano", presenter: "Kaufman Music Center",
                                      venue: Self.venue, performanceDate: "2026-10-07",
                                      sourceUrl: "https://www.kaufmanmusiccenter.org/mch/event/second-night")
        _ = ScoutService.apply(events: [incoming], clients: [], history: [], blocked: .empty,
                               today: "2026-09-21", sourceIds: ["kaufmanmusiccenter-org"], into: ctx)
        try ctx.save()

        let rows = try ctx.fetch(FetchDescriptor<Prospect>())
        #expect(rows.count == 1,
                "one run member addressed two ways minted \(rows.count) rows: \(rows.map { "\($0.groupName) \($0.performanceDate ?? "-")" }.sorted())")
    }

    // WHAT MUST NOT BREAK (L104). Folding the slash must not make the arm join two GENUINELY DIFFERENT
    // shows that happen to sit on one page on one night. That is #797 and #4032's failure, and the thing
    // standing between this change and it is the arm's own title guard, which is asserted here rather
    // than assumed to still be in the way.
    @Test func twoDifferentShowsOnOnePageOnOneNightStayTwoRows() throws {
        let ctx = try context()
        let first = stored(ctx, title: "Orli Shaham, piano", url: Self.bare)
        first.statusRaw = ReviewStatus.dismissed.rawValue
        let firstKey = first.naturalKey
        try ctx.save()

        ingest(ctx, title: "Danish String Quartet", url: Self.slashed)
        try ctx.save()

        let rows = try ctx.fetch(FetchDescriptor<Prospect>())
        #expect(rows.count == 2,
                "two different shows on one page on one night are two shows: \(rows.map(\.groupName).sorted())")
        #expect(rows.contains { $0.naturalKey == firstKey && $0.groupName == "Orli Shaham, piano" },
                "the dismissed show must keep its own key and title: \(rows.map(\.groupName).sorted())")
    }

    // The precondition, asserted separately so a green above cannot come from a fixture whose two URLs
    // were the same string all along (L159).
    @Test func theFixtureReallyDoesHoldTwoDifferentStrings() {
        #expect(Self.bare != Self.slashed)
        #expect(Self.slashed.hasSuffix("/"))
        #expect(!Self.bare.hasSuffix("/"))
    }
}

// The fold itself, asked directly. The suite above proves the PIPELINE joins the pair; this one pins
// what the fold may and may not do, because an over eager normalisation joins two pages that are not one
// and the pipeline test cannot see the difference (L104: test what it must PRESERVE, not only what it
// must catch).
@Suite("Folding a listing URL (#4116)")
struct ListingURLFoldTests {

    @Test func oneTrailingSlashIsRemoved() {
        #expect(ListingURL.fold("https://example.org/mch/event/a/") == "https://example.org/mch/event/a")
    }

    @Test func anAddressWithNoTrailingSlashIsUnchanged() {
        let u = "https://example.org/mch/event/a"
        #expect(ListingURL.fold(u) == u)
    }

    // The query is the identity of a night on OvationTix (`performanceId`), so the fold must reach the
    // path in front of it and must not touch the query itself.
    @Test func theSlashBeforeAQueryIsFoldedAndTheQuerySurvives() {
        #expect(ListingURL.fold("https://ci.ovationtix.com/277/production/1/?performanceId=9")
                    == "https://ci.ovationtix.com/277/production/1?performanceId=9")
        #expect(ListingURL.fold("https://ci.ovationtix.com/277/production/1?performanceId=9/")
                    == "https://ci.ovationtix.com/277/production/1?performanceId=9/",
                "a slash inside the query is part of the query and is not a trailing slash")
    }

    @Test func theSlashBeforeAFragmentIsFolded() {
        #expect(ListingURL.fold("https://example.org/a/#tickets") == "https://example.org/a#tickets")
    }

    // THE GUARD. A structural slash is not a trailing one, and folding it names a different thing. This
    // is the assertion that says the refusal in `fold` is load bearing rather than decorative.
    @Test func aStructuralSlashIsNeverFolded() {
        #expect(ListingURL.fold("https://") == "https://")
        #expect(ListingURL.fold("//") == "//")
        #expect(ListingURL.fold("/") == "/")
    }

    // A DOUBLED slash is refused outright rather than reduced by one, which is what the structural guard
    // above does when it meets `/a//`. That is the conservative direction and it is deliberate: `/a//`
    // and `/a/` are different paths to some servers, nothing measured says they are one page, and the
    // cost of refusing is two rows Dan can see rather than a silent join of two shows (#797).
    @Test func aDoubledTrailingSlashIsRefusedRatherThanReducedByOne() {
        #expect(ListingURL.fold("https://example.org/a//") == "https://example.org/a//")
    }

    @Test func aValueThatIsNotAURLComesBackUnchanged() {
        #expect(ListingURL.fold("") == "")
        #expect(ListingURL.fold("not a url") == "not a url")
    }

    // `sameListing` answers nil as NOT the same listing rather than as agreement, because two rows that
    // both lack an address share nothing and joining them would be the #797 failure with no URL at all.
    @Test func twoAbsentAddressesAreNotOneListing() {
        #expect(!ListingURL.sameListing(nil, nil))
        #expect(!ListingURL.sameListing("https://example.org/a", nil))
        #expect(ListingURL.sameListing("https://example.org/a", "https://example.org/a/"))
    }
}

// #4116: the fold is implemented twice, in Swift for the arms and in Python for
// `scripts/derive-showlink-shape.sh`'s ambiguity report, which has to count the same addresses the
// same way or #4098's reachable population is measured against a rule the arms do not use. Neither
// reads the other, so both read one committed fixture (L26). See `fixtures/listing-url-fold/README.md`.
@Suite("The listing URL fold agrees with its committed fixture (#4116)")
struct ListingURLFoldContractTests {

    private struct FoldCase: Decodable {
        let input: String
        let expected: String
        let why: String
    }

    private struct Fixture: Decodable {
        let fold: [FoldCase]
    }

    private func loadFixture() throws -> Fixture {
        let data = try Data(contentsOf: RepoRoot.url
            .appendingPathComponent("fixtures/listing-url-fold/v1.json"))
        return try JSONDecoder().decode(Fixture.self, from: data)
    }

    @Test func foldsEveryFixtureCaseTheAgreedWay() throws {
        let fixture = try loadFixture()
        // The fixture is the SPEC, so an empty one would make this pass having asserted nothing, which
        // is the shape a contract guard fails in most quietly (L98).
        #expect(fixture.fold.count >= 10,
                "the fold fixture holds \(fixture.fold.count) cases, too few to be the spec it is quoted as")
        for c in fixture.fold {
            #expect(ListingURL.fold(c.input) == c.expected,
                    "\(c.input) folded to \(ListingURL.fold(c.input)), and the fixture says \(c.expected) because \(c.why)")
        }
    }
}
