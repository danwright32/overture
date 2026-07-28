import Testing
import Foundation
import SwiftData
@testable import Overture

@Suite("Group name matching")
struct GroupNameMatchTests {
    @Test func normalizeStripsPresenterPunctuationAndCase() {
        #expect(GroupNameMatch.normalize("Presented by The Tallis Scholars!") == "the tallis scholars")
        #expect(GroupNameMatch.normalize("Brooklyn Youth Chorus\nProgram of Bach") == "brooklyn youth chorus")
    }

    // #138 parity: the presenter line is found wherever it sits, matching the TS engine.
    @Test func findsPresenterLineWhenNotFirst() {
        #expect(GroupNameMatch.normalize("Spring Gala Concert\nPresented by Every Voice Choirs") == "every voice choirs")
    }

    @Test func exactMatchIsConfident() {
        #expect(GroupNameMatch.isConfident("Brooklyn Youth Chorus", "brooklyn youth chorus"))
    }

    @Test func wholeTokenContainmentIsConfidentAboveFraction() {
        // "Tallis Scholars" sits as a contiguous run inside "The Tallis Scholars"
        // and is 2/3 of it, above the fraction guard.
        #expect(GroupNameMatch.isConfident("Tallis Scholars", "The Tallis Scholars") == true)
    }

    @Test func shortNameDoesNotConfidentlyMatchLargerUnrelated() {
        // The false positive we must avoid: "New York" inside "New York Theatre Ballet".
        #expect(GroupNameMatch.isConfident("New York", "New York Theatre Ballet") == false)
    }

    // #105: booking-sheet names are "Presenter - Program"; the venue lists just the presenter.
    @Test func stripsProgramSubtitleAfterSeparator() {
        #expect(GroupNameMatch.normalize("Every Voice Choirs - Earth Day Jazz") == "every voice choirs")
        #expect(GroupNameMatch.normalize("Every Voice Choirs — Earth Day Jazz") == "every voice choirs")
        #expect(GroupNameMatch.normalize("Every Voice Choirs: Spring Concert") == "every voice choirs")
    }

    @Test func doesNotStripSingleWordGenericPrefix() {
        #expect(GroupNameMatch.normalize("Jazz - Spring Gala") == "jazz spring gala")
    }

    @Test func bookingProgramMatchesShorterCalendarPresenter() {
        #expect(GroupNameMatch.isConfident("Every Voice Choirs - Earth Day Jazz", "Every Voice Choirs") == true)
        #expect(GroupNameMatch.isConfident("Every Voice Choirs: Earth Day Jazz", "Every Voice Choirs") == true)
    }

    @Test func twoProgramsSharingOneWordPrefixDoNotConfidentlyMatch() {
        #expect(GroupNameMatch.isConfident("Jazz - Spring Gala", "Jazz - Winter Gala") == false)
    }

    @Test func sharedTokensMakeAPossibleMatch() {
        #expect(GroupNameMatch.isPossible("Manhattan Chamber Players", "Manhattan Chamber Orchestra") == true)
        #expect(GroupNameMatch.isPossible("Brooklyn Youth Chorus", "Vienna Boys Choir") == false)
    }

    // #1693: the fuzzy gate reads the WHOLE name, never the subtitle-stripped one. The strip is a
    // rule for booking-sheet names shaped "Presenter - Program", where the suffix is the throwaway
    // half. A scraped listing shaped "Series: Act" is the other way round, and stripping it deletes
    // the only part that says who is playing, leaving the series brand behind to match on. On the
    // live store that put ONE dismissed Madison Square Park show on all 18 Carnegie Hall cards:
    // "carnegie hall citywide" against "carnegie hall presents" is 2 shared of 4, landing exactly on
    // the 0.5 gate. Unstripped it is 2 of 6, and the act's name is back in the comparison where it
    // belongs. isConfident keeps the strip, so #105's booking-sheet match is untouched.
    @Test func fuzzyMatchNeverScoresASubtitleStrippedName() {
        #expect(GroupNameMatch.isPossible("Carnegie Hall Presents",
                                          "Carnegie Hall Citywide: Ivalas Quartet") == false)
    }

    // #1693 guard: the three possible matches that were live on the store when the Carnegie flag was
    // found, none of which is a false positive, all of which must survive the change above. Written
    // from the real rows (36, 180, 494) rather than invented pairs, because the risk of tightening a
    // fuzzy gate is silently killing the true positives along with the false ones.
    @Test func theRealPossibleMatchesStillFire() {
        #expect(GroupNameMatch.isPossible("Irvine School of Music", "Bay Ridge School of Music") == true)
        #expect(GroupNameMatch.isPossible("Tenet Vocal Artists & Philadelphia Bach Collective",
                                          "TENET Vocal Artists") == true)
        #expect(GroupNameMatch.isPossible("The Chain", "The Pushover (Chain Theatre)") == true)
    }

    // #1351: a single-token acronym confidently matches a multi-token name when its letters ARE that
    // name's word-initials, one letter per word, in order. A Downbeat client filed as "NYYS" must
    // recognise its watched source "New York Youth Symphony" so it auto-arms the client horizon.
    @Test func acronymConfidentlyMatchesItsSpelledOutName() {
        #expect(GroupNameMatch.isConfident("New York Youth Symphony", "NYYS") == true)
        #expect(GroupNameMatch.isConfident("Distinguished Concerts International New York", "DCINY") == true)
    }

    // The rule is symmetric: which side is the acronym is decided by token count, not argument order.
    @Test func acronymMatchIsOrderIndependent() {
        #expect(GroupNameMatch.isConfident("NYYS", "New York Youth Symphony") == true)
    }

    // Precision guard: the acronym must equal EVERY initial. One wrong letter (Orchestra vs Symphony)
    // is not a match, so a near-miss acronym never warms an unrelated org.
    @Test func acronymWithAWrongLetterDoesNotMatch() {
        #expect(GroupNameMatch.isConfident("New York Youth Orchestra", "NYYS") == false)
    }

    // Precision guard: the acronym length must equal the word count. "NYC" (3) must NOT match the
    // 4-word "New York City Ballet" on a prefix of its initials; this is the key false-positive lever.
    @Test func acronymShorterThanWordCountDoesNotMatch() {
        #expect(GroupNameMatch.isConfident("New York City Ballet", "NYC") == false)
    }

    // A single letter is not an acronym; it would collide with far too much.
    @Test func aSingleLetterIsNotAnAcronymMatch() {
        #expect(GroupNameMatch.isConfident("New York", "N") == false)
    }

    // #1351: TENET is the FIRST WORD of "TENET Vocal Artists", not its initials, so it is deliberately
    // NOT caught by the acronym rule (5 letters vs 3 words). This documents why TENET is fixed in the
    // Downbeat data (full displayName) rather than by loosening the matcher into risky leading-word land.
    @Test func aLeadingWordAbbreviationIsNotAnAcronymMatch() {
        #expect(GroupNameMatch.isConfident("TENET Vocal Artists", "TENET") == false)
    }
}

@Suite("Repeat-client match verdict")
struct HistoryMatchTests {
    private let clients = [
        DownbeatClient(id: "c1", displayName: "DCINY", shortName: nil, email: "a@b.org",
                       contractEmail: "a@b.org", phoneNumber: nil, isTaxExempt: nil,
                       hasLeftReview: false, specialBehaviors: [], notes: nil, hostingSite: "pixieset"),
        DownbeatClient(id: "c2", displayName: "Alaria Chamber Ensemble", shortName: "Alaria", email: "x@y.org",
                       contractEmail: "x@y.org", phoneNumber: nil, isTaxExempt: nil,
                       hasLeftReview: false, specialBehaviors: [], notes: nil, hostingSite: "pixieset"),
    ]

    @Test func confidentClientMatchIsBooked() {
        let v = HistoryMatch.matchRelationship(name: "DCINY", clients: clients, history: [])
        #expect(v.relationship == .booked)
        #expect(v.downbeatClientId == "c1")
        #expect(v.matchedClientName == "DCINY")
    }

    @Test func dncInHistorySuppresses() {
        let history = [HistoryRecord(groupName: "Loud Neighbors Choir", status: "dnc")]
        let v = HistoryMatch.matchRelationship(name: "Loud Neighbors Choir", clients: [], history: history)
        #expect(v.suppressed == true)
        #expect(v.relationship == .none)
    }

    @Test func priorColdContactIsContacted() {
        let history = [HistoryRecord(groupName: "Cold Outreach Quartet", status: "contacted")]
        let v = HistoryMatch.matchRelationship(name: "Cold Outreach Quartet", clients: [], history: history)
        #expect(v.relationship == .contacted)
    }

    @Test func fuzzyClientMatchBecomesPossibleNotScored() {
        // Shares "alaria" + "chamber" with "Alaria Chamber Ensemble" (half the tokens):
        // a possible match to confirm, not a confident booked one.
        let v = HistoryMatch.matchRelationship(name: "Alaria Chamber Players", clients: clients, history: [])
        #expect(v.relationship == .none)
        #expect(v.possible?.source == "downbeat_client")
        #expect(v.possible?.name == "Alaria Chamber Ensemble")
    }

    @Test func noMatchIsNone() {
        let v = HistoryMatch.matchRelationship(name: "Totally Unknown Group", clients: clients, history: [])
        #expect(v.relationship == .none)
        #expect(v.possible == nil)
    }

    @Test func warmHistoryIsWarm() {
        let v = HistoryMatch.matchRelationship(name: "Referral Choir", clients: [],
                                               history: [HistoryRecord(groupName: "Referral Choir", status: "warm")])
        #expect(v.relationship == .warm)
    }

    @Test func declinedHistoryIsDeclinedByYou() {
        let v = HistoryMatch.matchRelationship(name: "Date Clash Opera", clients: [],
                                               history: [HistoryRecord(groupName: "Date Clash Opera", status: "declined")])
        #expect(v.relationship == .declinedByYou)
    }

    @Test func lostSoftHistoryIsLostSoft() {
        let v = HistoryMatch.matchRelationship(name: "Keep In Mind Band", clients: [],
                                               history: [HistoryRecord(groupName: "Keep In Mind Band", status: "lost_soft")])
        #expect(v.relationship == .lostSoft)
    }

    @Test func lostHardHistoryIsLostHard() {
        let v = HistoryMatch.matchRelationship(name: "Never Again Quartet", clients: [],
                                               history: [HistoryRecord(groupName: "Never Again Quartet", status: "lost_hard")])
        #expect(v.relationship == .lostHard)
    }

    @Test func relationshipBeatsOutcomeWhenBothPresent() {
        // A warm relationship plus a lost record on the same org reads warm: relationship wins.
        let history = [HistoryRecord(groupName: "Mixed Signals Ensemble", status: "warm"),
                       HistoryRecord(groupName: "Mixed Signals Ensemble", status: "lost_soft")]
        let v = HistoryMatch.matchRelationship(name: "Mixed Signals Ensemble", clients: [], history: history)
        #expect(v.relationship == .warm)
    }

    // #1216: the ensemble identity lives in the presenter field, not the title. Every Voice Choirs
    // is a 3x-booked client, but their upcoming show's title is "The Pumpkin Singalong at Sakura
    // Park", which carries none of the org name. Matching on the title alone reads it cold; the
    // presenter must be considered too.
    @Test func matchesHistoryOnPresenterWhenTitleLacksIt() {
        let history = [HistoryRecord(groupName: "Every Voice Choirs", status: "booked")]
        let v = HistoryMatch.matchRelationship(
            name: "The Pumpkin Singalong at Sakura Park",
            presenter: "Every Voice Choirs",
            clients: [], history: history)
        #expect(v.relationship == .booked)
    }

    // A do-not-contact org named in the presenter field must still suppress: broadening the match to
    // the presenter must broaden suppression with it, never leave a DNC org through the back door.
    @Test func dncOnPresenterSuppresses() {
        let history = [HistoryRecord(groupName: "Loud Neighbors Choir", status: "dnc")]
        let v = HistoryMatch.matchRelationship(
            name: "Winter Songs at the Firehouse",
            presenter: "Loud Neighbors Choir",
            clients: [], history: history)
        #expect(v.suppressed == true)
    }

    // The title path is not replaced by the presenter: when the title carries the org and the
    // presenter is unrelated (or empty), the title match still resolves.
    @Test func titleStillMatchesWhenPresenterUnrelated() {
        let history = [HistoryRecord(groupName: "Referral Choir", status: "warm")]
        let v = HistoryMatch.matchRelationship(
            name: "Referral Choir - Spring Concert",
            presenter: "Merkin Concert Hall",
            clients: [], history: history)
        #expect(v.relationship == .warm)
    }

    // #1693: the exact shape that flagged 18 Carnegie Hall cards. The record is Overture's OWN
    // dismissal: a Madison Square Park show Dan swiped away as a date conflict, which LocalHistory
    // files as "declined" and so puts into the history every scout matches against. Its name carries
    // the act after a colon; the show being scouted carries the hall's own brand in its presenter.
    // Nothing here is a real relationship, so nothing may be flagged.
    @Test func aColonSeparatedActDoesNotFlagEveryShowSharingItsSeriesBrand() {
        let history = [HistoryRecord(groupName: "Carnegie Hall Citywide: Ivalas Quartet", status: "declined")]
        let v = HistoryMatch.matchRelationship(
            name: "NYO2",
            presenter: "Carnegie Hall Presents",
            venue: "Stern Auditorium / Perelman Stage",
            clients: [], history: history)
        #expect(v.relationship == .none)
        #expect(v.possible == nil)
    }

    // #1693 guard, the other direction: a real fuzzy match reached through the PRESENTER still has to
    // fire. Row 36 on the live store, a client near-miss worth Dan's glance.
    @Test func aGenuineFuzzyClientMatchOnThePresenterStillFlags() {
        let bayRidge = [DownbeatClient(id: "c3", displayName: "Bay Ridge School of Music", shortName: nil,
                                       email: "a@b.org", contractEmail: "a@b.org", phoneNumber: nil,
                                       isTaxExempt: nil, hasLeftReview: false, specialBehaviors: [],
                                       notes: nil, hostingSite: "pixieset")]
        let v = HistoryMatch.matchRelationship(
            name: "Irvine School of Music Student Recital",
            presenter: "Irvine School of Music",
            venue: "Weill Recital Hall",
            clients: bayRidge, history: [])
        #expect(v.possible?.source == "downbeat_client")
        #expect(v.possible?.name == "Bay Ridge School of Music")
    }

    // Precision: a presenter that only shares a generic word with an unrelated past org must not
    // confidently warm the lead. The presenter is a specific identity, but sharing one common token
    // is not that identity.
    @Test func presenterSharingOneGenericWordDoesNotWarm() {
        let history = [HistoryRecord(groupName: "Every Nation Church", status: "booked")]
        let v = HistoryMatch.matchRelationship(
            name: "The Pumpkin Singalong at Sakura Park",
            presenter: "Every Voice Choirs",
            clients: [], history: history)
        #expect(v.relationship == .none)
        #expect(v.possible == nil)
    }
}

@Suite("Ingest persistence")
@MainActor
struct IngestPersistenceTests {
    @Test func ingestPersistsDownbeatClientId() throws {
        let context = try ModelContext(ModelContainer(for: Prospect.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)))
        let client = DownbeatClient(id: "CID-1", displayName: "Every Voice Choirs",
            shortName: nil, email: "a@x.org", contractEmail: "a@x.org",
            phoneNumber: nil, isTaxExempt: nil, hasLeftReview: false,
            specialBehaviors: [], notes: nil, hostingSite: "x.org")
        let event = ExtractedEvent(title: "Every Voice Choirs", presenter: nil,
            venue: "Merkin Hall", performanceDate: "2026-03-11", sourceUrl: "https://x")
        _ = ScoutService.apply(events: [event], clients: [client], history: [],
                               blocked: .empty, today: ScoutTestClock.beforeAllFixtures, into: context)
        let saved = try context.fetch(FetchDescriptor<Prospect>())
        #expect(saved.first?.downbeatClientId == "CID-1")
    }
}

@Suite("Downbeat export decoding")
struct DownbeatExportTests {
    @Test func decodesAndVersionGates() throws {
        let json = """
        {"version":1,"clients":[{"id":"c1","displayName":"DCINY","email":"a@b.org","contractEmail":"a@b.org","hasLeftReview":false,"specialBehaviors":[],"hostingSite":"pixieset"}],"venues":[]}
        """
        let export = try DownbeatBridge.decode(Data(json.utf8))
        #expect(export.clients.count == 1)
        #expect(export.clients[0].displayName == "DCINY")

        let bad = Data(#"{"version":9,"clients":[],"venues":[]}"#.utf8)
        #expect(throws: DownbeatExportError.unsupportedVersion(9)) {
            try DownbeatBridge.decode(bad)
        }
    }
}
