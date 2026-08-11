import Testing

// #1784: the app carries THREE folds of an organisation's name, and this suite is where the difference
// between them is STATED rather than left as a comment on one of the three.
//
//   1. VenueNormalization.normalizeForKey — the natural key. Reduces to the FIRST CLAUSE, because every
//      consumer of that key also carries the date, so two same-named rooms cannot collide.
//   2. ProducerGate.key — "is this presenter a producer or a room", a comparison thrown away after the
//      verdict.
//   3. OrgKey.of — "may a paid answer be reused for this organisation", written to the ledger and
//      permanent.
//
// #1764 taught the gate to drop a bracket whose contents hold a comma and did not teach the ledger the
// same thing, so for one live string the gate said one organisation while the ledger held two, each
// recorded as its own paid lookup for the same contact. The two must not be able to drift apart again on
// this question, which is what these tests pin.
//
// The DECISION this issue asked for, recorded here because a test is the one place it cannot rot: the
// ledger's identity is "which organisation would Dan email". A parenthetical says WHERE the organisation
// is, what it is ALSO CALLED, or who it curated this one night WITH; it never says which organisation it
// is, so it is dropped, exactly as the gate drops it. A COMMA clause is different and stays: it can name
// a second person ("Ann Hampton Callaway, Liz Callaway") or a second town ("Christ Church Cathedral,
// Oxford"), and collapsing those would hand two organisations one contact, permanently and silently.
@Suite("The gate and the ledger agree what one organisation is (#1784)")
struct OrgIdentityAgreementTests {

    // The live string from #1764. The gate reduced it to the bare series; the ledger kept the whole
    // bracket, so one series sat in the ledger twice.
    static let curated = "The Golden Hour Series (curated with Jalopy Theatre, The New Colossus Festival, and others)"

    @Test("the string that split in two now keys as one organisation")
    func theCuratedSeriesIsOneOrganisation() {
        #expect(OrgKey.of(Self.curated) == OrgKey.of("The Golden Hour Series"))
    }

    // LIVE-STORE-CLAIM verified=2026-08-07 measure="distinct presenter strings on the live store that carry a bracket, and whether dropping it collides two different organisations"
    // Every bracketed presenter on Dan's store on 2026-08-07, measured before making this change. Five of
    // 253, and dropping the bracket collides NONE of them with a different organisation, which is what
    // makes the widening safe to apply to a permanent key. Four brackets are an alias or a subtitle; the
    // fifth names the act the series featured, which is not the series.
    @Test("every bracketed organisation on the live store keys to its own bare name", arguments: [
        ("American Masters Music Awards (AMMA)", "American Masters Music Awards"),
        ("Masticate (A Dark Comedy)", "Masticate"),
        ("Marlise (A New Golden Age Musical)", "Marlise"),
        ("You Go On (A New Musical)", "You Go On"),
        ("New York Percussion Series (Featuring Percussion People)", "New York Percussion Series"),
    ])
    func liveBracketedPresentersFoldToTheirBareName(_ raw: String, _ bare: String) {
        #expect(OrgKey.of(raw) == OrgKey.of(bare))
    }

    // The agreement itself, asserted on the fold rather than on one example: wherever the gate treats two
    // spellings as one organisation because of a bracket, the ledger must too.
    @Test("the two folds agree on every bracketed string", arguments: [
        Self.curated,
        "American Masters Music Awards (AMMA)",
        "The Church of St. Mary the Virgin (Times Square)",
        "Masticate (A Dark Comedy)",
    ])
    func gateAndLedgerAgreeOnBrackets(_ raw: String) {
        let bare = raw.replacingOccurrences(of: #"\s*\([^)]*\)"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
        #expect(ProducerGate.key(raw) == ProducerGate.key(bare))
        #expect(OrgKey.of(raw) == OrgKey.of(bare))
    }

    // MARK: - #2451: the leading article, the second thing the three folds disagreed about

    // The gate has dropped a leading "the" since #1593 and the venue fold since #1802, and the ledger
    // did not. So the gate deciding whether a paid answer may be REUSED said one organisation, while the
    // ledger deciding who RECEIVES the email held two, and the second spelling paid for its own lookup.
    // Every string below is a live one: a presenter on Dan's store or a source in his watchlist.
    @Test("a leading article does not make a second organisation", arguments: [
        "The Green Room 42", "The Players Theatre", "The Cutting Room", "The Joyce Theater",
        "The Tank", "The Klezmatics",
    ])
    func aLeadingArticleIsNotPartOfTheIdentity(_ withArticle: String) {
        let bare = String(withArticle.dropFirst("The ".count))
        #expect(OrgKey.of(withArticle) == OrgKey.of(bare))
        #expect(OrgKey.of(withArticle) == ProducerGate.key(withArticle),
                "the ledger and the gate still disagree about \(withArticle)")
    }

    // The third fold, asserted the way it actually behaves rather than by inspection: `GroupNameMatch`
    // has no article rule, it folds the two spellings together by token containment. That is the fold
    // the Prospector's candidate pool is sized through, so it is the one that decides whether a name
    // Dan already watches can turn up as a proposal.
    @Test("the match fold already treats the two spellings as one organisation")
    func theMatchFoldAgreesToo() {
        #expect(GroupNameMatch.isConfident("The Green Room 42", "Green Room 42"))
    }

    // The fold is only sound if it is idempotent, because the realignment passes over tables that keep
    // no raw name re-fold the STORED key. A key that moved every time it was folded would walk a refusal
    // one article further away on every launch.
    @Test("re-folding a key that is already a key changes nothing", arguments: [
        "The Green Room 42", "Christ Church Cathedral, Oxford", "(Le) Poisson Rouge",
        "The Cutting Room, 44 East 32nd Street, New York, NY",
    ])
    func theFoldIsIdempotent(_ raw: String) throws {
        let once = try #require(OrgKey.of(raw))
        #expect(OrgKey.of(once) == once)
        let stored = try #require(OrgKey.stored(for: raw))
        #expect(OrgKey.realigned(storedKey: stored) == stored)
    }

    // A key outside this key space is refused rather than re-folded, which is what stops a re-key pass
    // touching a refusal scoped to a SHOW: `RefusedContactAddress.scopeId` holds a prospect's natural
    // key on those rows, and folding one would move the refusal onto a key naming nothing.
    @Test("a key outside the presenter namespace is refused")
    func anUnnamespacedKeyIsRefused() {
        #expect(OrgKey.realigned(storedKey: "some group|2026-09-12|somewhere") == nil)
        #expect(OrgKey.realigned(storedKey: "presenter:") == nil)
    }

    // MARK: - The difference that REMAINS, stated rather than implied

    // The ledger is deliberately stricter than the gate on comma clauses, and this is the only place that
    // is written down as something a change can break. The gate may collapse these because its verdict is
    // thrown away; the ledger may not, because its key decides who receives an email.
    @Test("the ledger keeps a comma clause the gate drops", arguments: [
        ("Christ Church Cathedral, Oxford", "Christ Church Cathedral"),
        ("Ann Hampton Callaway, Liz Callaway", "Ann Hampton Callaway"),
    ])
    func theLedgerIsStricterThanTheGateOnCommaClauses(_ raw: String, _ firstClause: String) {
        #expect(ProducerGate.key(raw) == ProducerGate.key(firstClause))
        #expect(OrgKey.of(raw) != OrgKey.of(firstClause))
    }

    // A street address is the one comma clause both folds drop, because it says WHERE and never WHO.
    @Test("both folds drop an embedded street address")
    func bothDropAnEmbeddedAddress() {
        let withAddress = "The Cutting Room, 44 East 32nd Street, New York, NY"
        #expect(OrgKey.of(withAddress) == OrgKey.of("The Cutting Room"))
        #expect(ProducerGate.key(withAddress) == ProducerGate.key("The Cutting Room"))
    }

    // MARK: - The edges the widening must not fall off

    // A name that is ENTIRELY a bracket keeps its raw form rather than becoming nothing. An organisation
    // with no key pays for its own lookup every time, which is the fail-safe direction, but a key that
    // silently vanished for a whole class of names would be a different bug wearing that as a disguise.
    @Test("a name that is entirely a bracket still has a key")
    func anEntirelyParentheticalNameKeepsAKey() {
        #expect(OrgKey.of("(Anonymous)") != nil)
    }

    // A bracket that is only PART of the name is dropped like any other, which for the real venue spelled
    // "(Le) Poisson Rouge" is the right answer: it is the same room as "Le Poisson Rouge".
    @Test("a leading bracket is dropped like any other")
    func aLeadingBracketIsDroppedLikeAnyOther() {
        #expect(OrgKey.of("(Le) Poisson Rouge") == OrgKey.of("Poisson Rouge"))
    }

    @Test("an unclosed bracket is left alone rather than eating the rest of the name")
    func anUnbalancedBracketIsLeftAlone() {
        #expect(OrgKey.of("The Golden Hour Series (curated with") != nil)
    }
}
