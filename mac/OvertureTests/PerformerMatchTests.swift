import Testing
import Foundation

// Locked spec for the performer-name matcher (#749, plan #748, issue #585). Repeat-client
// detection used to match on the org/group name only, so a performance fronted by someone Dan had
// already shot scored cold whenever the group name was new. HistoryMatch.matchPerformer closes that
// at Prep time. See fixtures/performer-match/README.md for why each property below is load-bearing.
@Suite("Performer-name match locked fixture")
struct PerformerMatchTests {
    private struct Expectation: Decodable {
        let relationship: PriorRelationship
        let downbeatClientId: String?
        let matchedClientName: String?
        let matchedPerformerName: String?
        let emailCorroborated: Bool
    }

    private struct MatchCase: Decodable {
        let name: String
        let performerName: String
        let performerEmail: String
        let production: Production
        let expect: Expectation
    }

    private struct Fixture: Decodable {
        let clients: [DownbeatClient]
        let history: [HistoryRecord]
        let cases: [MatchCase]
    }

    private func fixtureDirectory() -> URL {
        RepoRoot.url
            .appendingPathComponent("fixtures/performer-match")
    }

    private func fixtureFileNames() throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: fixtureDirectory().path)
            .filter { $0.hasSuffix(".json") }
    }

    private func loadFixture(_ name: String = "v1.json") throws -> Fixture {
        let data = try Data(contentsOf: fixtureDirectory().appendingPathComponent(name))
        return try JSONDecoder().decode(Fixture.self, from: data)
    }

    // #491/#745: enumerates whatever is actually committed, so a new fixture file with no matching
    // decode case fails here instead of silently shipping with zero coverage on this side.
    @Test func decodesEveryCommittedFixtureWithoutThrowing() throws {
        let names = try fixtureFileNames()
        #expect(!names.isEmpty)
        for name in names {
            #expect(throws: Never.self) { try loadFixture(name) }
        }
    }

    @Test func matchesEveryFixtureCaseTheAgreedWay() throws {
        let fixture = try loadFixture()
        #expect(!fixture.cases.isEmpty)

        for c in fixture.cases {
            let verdict = HistoryMatch.matchPerformer(
                performerName: c.performerName,
                performerEmail: c.performerEmail,
                production: c.production,
                clients: fixture.clients,
                history: fixture.history
            )
            #expect(verdict.relationship == c.expect.relationship, "\(c.name): relationship")
            #expect(verdict.downbeatClientId == c.expect.downbeatClientId, "\(c.name): downbeatClientId")
            #expect(verdict.matchedClientName == c.expect.matchedClientName, "\(c.name): matchedClientName")
            #expect(verdict.matchedPerformerName == c.expect.matchedPerformerName, "\(c.name): matchedPerformerName")
            #expect(verdict.emailCorroborated == c.expect.emailCorroborated, "\(c.name): emailCorroborated")
        }
    }

    // A match Dan will be shown must be able to explain itself; a non-match must not invent a note.
    @Test func onlyAMatchCarriesANoteAndTheNoteNamesThePerformer() throws {
        let fixture = try loadFixture()
        for c in fixture.cases {
            let verdict = HistoryMatch.matchPerformer(
                performerName: c.performerName,
                performerEmail: c.performerEmail,
                production: c.production,
                clients: fixture.clients,
                history: fixture.history
            )
            if verdict.isMatch {
                let note = try #require(verdict.note, "\(c.name): a match must carry a note")
                #expect(note.contains(c.performerName), "\(c.name): the note must name the performer")
            } else {
                #expect(verdict.note == nil, "\(c.name): a non-match must not carry a note")
            }
        }
    }

    // #762: a booking-sheet cell really can hold two addresses, so either of them corroborates.
    @Test func eitherAddressInATwoEmailHistoryCellCorroborates() {
        let history = [HistoryRecord(groupName: "Duo Act Member", status: "booked",
                                     email: "a@example.com, b@example.com")]

        for address in ["a@example.com", "B@Example.com"] {
            let verdict = HistoryMatch.matchPerformer(
                performerName: "Duo Act Member", performerEmail: address,
                production: .selfProduced, clients: [], history: history)
            #expect(verdict.relationship == .booked)
            #expect(verdict.emailCorroborated)
        }
    }

    // #779, and the whole point of re-importing the real CSV before trusting this. The booking
    // sheet's Email column is a "how I contacted them" field, NOT an identity field: it routinely
    // holds an AGENT (Lisa Batiashvili's is her agent's), an ensemble address (Amandine Beyer's is
    // Gli Incogniti's), or no address at all ("DM on instagram").
    //
    // So a differing address there is weak evidence, not evidence against identity, and treating it
    // as fatal (as the client branch rightly does) would suppress REAL past leads the moment Prep
    // found the performer directly rather than through their agent. It corroborates, and nothing more.
    @Test func aDifferingHistoryAddressDoesNotSuppressTheMatch() {
        let viaAgent = [HistoryRecord(groupName: "Lisa Batiashvili, Violin", status: "lost_soft",
                                      email: "agent@impresariat.example")]

        let verdict = HistoryMatch.matchPerformer(
            performerName: "Lisa Batiashvili", performerEmail: "lisa@herownsite.example",
            production: .selfProduced, clients: [], history: viaAgent)

        #expect(verdict.relationship == .lostSoft)   // still found, not suppressed
        #expect(!verdict.emailCorroborated)          // but the address corroborated nothing
        #expect(verdict.note?.contains("email") != true)
    }

    // A conflicting address on a CLIENT is still fatal, unchanged (Dan's original call): there the
    // address genuinely is that client's own, so a mismatch really does say "different person".
    @Test func aDifferingClientAddressStillSuppressesTheMatch() {
        let client = DownbeatClient(id: "c", displayName: "Larkin Sable", shortName: nil,
                                    email: "larkin@sableviolin.example", contractEmail: "",
                                    phoneNumber: nil, isTaxExempt: nil, hasLeftReview: false,
                                    specialBehaviors: [], notes: nil, hostingSite: "")

        let verdict = HistoryMatch.matchPerformer(
            performerName: "Larkin Sable", performerEmail: "someone.else@example.com",
            production: .selfProduced, clients: [client], history: [])

        #expect(verdict == .noMatch)
    }

    // The column also holds things that are not addresses at all. They must corroborate nothing, and
    // (crucially) must not be mistaken for an address that then fails to match.
    @Test func aHistoryCellThatIsNotAnEmailIsSimplyNoSignal() {
        let notEmails = [
            HistoryRecord(groupName: "Toma Reyes, violin", status: "warm",
                          email: "DM on instagram\nhttps://www.instagram.com/tomarey39/?hl=en"),
        ]
        let verdict = HistoryMatch.matchPerformer(
            performerName: "Toma Reyes", performerEmail: "toma@example.com",
            production: .selfProduced, clients: [], history: notEmails)

        #expect(verdict.relationship == .warm)
        #expect(!verdict.emailCorroborated)
    }

    // The corroborating email is only worth surfacing when it actually corroborated something.
    @Test func aCorroboratedMatchSaysSoInItsNote() throws {
        let fixture = try loadFixture()
        let verdict = HistoryMatch.matchPerformer(
            performerName: "Larkin Sable",
            performerEmail: "larkin@sableviolin.example",
            production: .selfProduced,
            clients: fixture.clients,
            history: fixture.history
        )
        #expect(verdict.emailCorroborated)
        #expect(verdict.note?.lowercased().contains("email") == true)
    }

    // The whole point of the tightened rule: the ORG matcher accepts this pair via token
    // containment, and the PERSON matcher must not, or "Jane Doe" warms off "Jane Doe Ensemble".
    @Test func theOrgMatcherAcceptsContainmentThatThePersonMatcherRejects() {
        #expect(GroupNameMatch.isConfident("Jane Doe", "Jane Doe Ensemble"))
        #expect(!GroupNameMatch.isConfidentPersonName("Jane Doe", "Jane Doe Ensemble"))
    }

    // Tightening the person path must not have loosened or altered the org path (#585 scope).
    @Test func theOrgMatcherIsUnchanged() {
        #expect(GroupNameMatch.isConfident("New York Theatre Ballet", "New York Theatre Ballet"))
        #expect(GroupNameMatch.isConfident("Northside Chamber Orchestra", "Northside Chamber"))
        #expect(!GroupNameMatch.isConfident("New York", "New York Theatre Ballet"))
    }

    // The upgrade-only floor (#763), asserted directly against the matcher rather than only through
    // the fixture table. A history status at or below a cold lead must produce NO match: not a
    // zero-value match, not a flag, nothing. Anything above it must still come through.
    @Test func aHistoryStatusWorthNoMoreThanAColdLeadProducesNoMatchAtAll() {
        func verdict(status: String) -> PerformerMatchVerdict {
            HistoryMatch.matchPerformer(
                performerName: "Lena Whitfield",
                performerEmail: "",
                production: .selfProduced,
                clients: [],
                history: [HistoryRecord(groupName: "Lena Whitfield", status: status)]
            )
        }

        // Worth 0: a bare send that got silence (#70). Correcting it would move the score by nothing
        // while still locking the fields and flagging Dan.
        #expect(verdict(status: "contacted") == .noMatch)
        // Worth -20: this detector finds warm leads, it does not quietly downgrade cold ones.
        #expect(verdict(status: "lost_hard") == .noMatch)
        // An unrecognized status reads as `contacted` (neutral), so it must not match either.
        #expect(verdict(status: "who knows") == .noMatch)

        // Above the floor, matching is unaffected.
        #expect(verdict(status: "warm").relationship == .warm)
        #expect(verdict(status: "lost_soft").relationship == .lostSoft)
        #expect(verdict(status: "booked").relationship == .booked)
    }

    // Pinned against Ranker.priorPoints rather than a status list, so this fails loudly if the
    // ranker is ever retuned in a way that changes which relationships clear the floor.
    @Test func onlyARelationshipWorthMoreThanAColdLeadCountsAsAMatch() {
        #expect(Ranker.priorPoints(.contacted) == Ranker.priorPoints(PriorRelationship.none))
        #expect(Ranker.priorPoints(.lostHard) < Ranker.priorPoints(PriorRelationship.none))
        #expect(Ranker.priorPoints(.lostSoft) > Ranker.priorPoints(PriorRelationship.none))
        #expect(Ranker.priorPoints(.warm) > Ranker.priorPoints(PriorRelationship.none))
        #expect(Ranker.priorPoints(.booked) > Ranker.priorPoints(PriorRelationship.none))
    }

    // #755, found by running the matcher against Dan's REAL booking history: it matched only 2 of 13
    // known past performers, because almost every soloist is filed with their instrument.
    @Test func aTrailingInstrumentOrVoicePartIsNotPartOfAPersonsName() {
        #expect(GroupNameMatch.personNameTokens("Toma Reyes, violin") == ["toma", "reyes"])
        #expect(GroupNameMatch.personNameTokens("Rainer Crosett, Cello") == ["rainer", "crosett"])
        #expect(GroupNameMatch.personNameTokens("Jane Doe, mezzo soprano") == ["jane", "doe"])
        #expect(GroupNameMatch.isConfidentPersonName("Toma Reyes", "Toma Reyes, violin"))

        // Never strips below two tokens, so a name can't erode into a single word that would then
        // collide with half the world.
        #expect(GroupNameMatch.personNameTokens("Piano") == ["piano"])
        // And it is a CLOSED vocabulary, not "drop the last token": blindly dropping would turn the
        // org "Jane Doe Ensemble" into the person "Jane Doe", the exact false positive we prevent.
        #expect(GroupNameMatch.personNameTokens("Jane Doe Ensemble") == ["jane", "doe", "ensemble"])
        #expect(!GroupNameMatch.isConfidentPersonName("Jane Doe", "Jane Doe Ensemble"))
    }

    // #755, caught by the real-data check: normalize() strips everything outside a-z, so an accented
    // name shredded into junk tokens and could never match even itself. In classical music that is
    // most of the roster, not an edge case.
    @Test func anAccentedNameMatchesItsPlainSpelling() {
        #expect(GroupNameMatch.personNameTokens("Victor Santiago Asunción, Piano")
                == ["victor", "santiago", "asuncion"])
        #expect(GroupNameMatch.isConfidentPersonName("Victor Santiago Asuncion",
                                                     "Victor Santiago Asunción, Piano"))
        // And in both directions, since either side can carry the accent.
        #expect(GroupNameMatch.isConfidentPersonName("Antonín Dvořák", "Antonin Dvorak"))
        #expect(GroupNameMatch.isConfidentPersonName("Víkingur Ólafsson", "Vikingur Olafsson"))
    }

    // A history entry is messy free text and can list one performer per line, so the org path's
    // "read the org line" rule never sees the second soloist (#755).
    @Test func everyLineOfAMultiLineHistoryEntryIsACandidatePerson() {
        let entry = "Rainer Crosett, Cello\nVictor Santiago Asuncion, Piano\nThe American Recital Debut Award Concert"

        #expect(GroupNameMatch.isConfidentPersonName("Rainer Crosett", inEntry: entry))
        #expect(GroupNameMatch.isConfidentPersonName("Victor Santiago Asuncion", inEntry: entry))
        #expect(!GroupNameMatch.isConfidentPersonName("American Recital", inEntry: entry))

        // The trap that keeps the precision honest: an org merely NAMED AFTER a person is not that
        // person. It has a leftover token, so full token-set equality rejects it.
        #expect(!GroupNameMatch.isConfidentPersonName("Abby Whiteside", inEntry: "Abby Whiteside Foundation"))
        #expect(!GroupNameMatch.isConfidentPersonName("Sophia Rosoff", inEntry: "The Sophia Rosoff Concert Series 2026"))
    }

    @Test func personNameMatchingIgnoresTokenOrderButNotExtraTokens() {
        #expect(GroupNameMatch.isConfidentPersonName("Sable, Larkin", "Larkin Sable"))
        #expect(GroupNameMatch.isConfidentPersonName("larkin sable", "Larkin Sable"))
        #expect(!GroupNameMatch.isConfidentPersonName("Larkin Sable", "Larkin Sable Quartet"))
        #expect(!GroupNameMatch.isConfidentPersonName("", "Larkin Sable"))
        #expect(!GroupNameMatch.isConfidentPersonName("Larkin Sable", ""))
    }
}
