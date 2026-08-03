import Testing

// #1598 (milestone 32 Phase 5.2): the identity of an ORGANISATION, which is a different question from
// the one VenueNormalization answers. A venue key may reduce a string to its first clause because every
// consumer of that key also carries the date; an organisation key is the first consumer that does not,
// so a collapse here is permanent and silent.
@Suite("OrgKey")
struct OrgKeyTests {

    @Test("two spellings of one organisation share a key")
    func spellingVariantsShareAKey() {
        #expect(OrgKey.of("Tenet Vocal Artists") == OrgKey.of("  TENET   Vocal Artists "))
    }

    // The reason this key exists at all. The venue rule keeps only the first clause, which would file
    // every Christ Church Cathedral in the world under one key and hand them all one contact. Both of
    // these strings are on the live store today.
    @Test("a trailing place name is part of the organisation's identity, not noise")
    func trailingPlaceNameIsKept() {
        #expect(OrgKey.of("Christ Church Cathedral, Oxford") != OrgKey.of("Christ Church Cathedral"))
    }

    @Test("a named pair is not collapsed to the first name")
    func aNamedPairSurvives() {
        #expect(OrgKey.of("Ann Hampton Callaway, Liz Callaway") != OrgKey.of("Ann Hampton Callaway"))
    }

    // The one clause that genuinely is noise: a street address a listing page baked into the name.
    @Test("an embedded street address is dropped")
    func embeddedAddressIsDropped() {
        #expect(OrgKey.of("The Cutting Room, 44 East 32nd Street, New York, NY")
                == OrgKey.of("The Cutting Room"))
    }

    @Test("a blank or missing name has no key", arguments: [nil, "", "   "])
    func blankHasNoKey(_ raw: String?) {
        #expect(OrgKey.of(raw) == nil)
    }

    // The stored key is namespaced so this ledger's key space can never collide with a future one keyed
    // on a venue or a performer, in a store where both would be plain strings in a column.
    @Test("the stored key is namespaced")
    func storedKeyIsNamespaced() {
        let stored = OrgKey.stored(for: "Tenet Vocal Artists")
        #expect(stored?.hasPrefix("presenter:") == true)
        #expect(stored != OrgKey.of("Tenet Vocal Artists"))
    }
}
