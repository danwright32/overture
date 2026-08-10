import Testing
import Foundation
import SwiftData

// #1695: a possible-match flag used to call every non-client record "the booking log". That one phrase
// covered two genuinely different lists: the 46 records imported from Dan's booking CSV, and Overture's
// OWN activity, which `LocalHistory.records` derives live and which includes shows he merely swiped away
// and never contacted.
//
// In #1693 the flag pointed at a card he had dismissed a month earlier as a date clash. Never sent, no
// reply, no business of any kind. Calling that "the booking log" reads as real past business, and he
// could not tell what he was being asked without opening the database. A flag whose answer requires
// reading the store is not a flag.
@MainActor
@Suite("Where a possible match came from (#1695)")
struct PossibleMatchOriginTests {

    // --- the origin survives the match -----------------------------------------------------------------

    // The exact pair from #1693, which is the one measured to land in the fuzzy band: two shared tokens
    // out of four, a Jaccard of 0.50, sitting right on the gate. A prettier invented pair does not fire at
    // all, so every assertion below would pass against a nil verdict and prove nothing.
    private static let candidate = "Carnegie Hall Presents"
    private static let recordName = "Carnegie Hall Citywide"

    private func verdict(history: [HistoryRecord]) -> MatchVerdict {
        HistoryMatch.matchRelationship(name: Self.candidate, presenter: nil, venue: "A Hall",
                                       clients: [], history: history)
    }

    @Test func aBookingFromTheImportedSheetIsNotConfusedWithOvertureSOwnActivity() {
        let imported = verdict(history: [HistoryRecord(groupName: Self.recordName,
                                                       status: "booked", origin: .bookingImport)])
        let ownActivity = verdict(history: [HistoryRecord(groupName: Self.recordName,
                                                          status: "booked", origin: .overtureActivity)])

        #expect(imported.possible?.source == "booking_import")
        #expect(ownActivity.possible?.source == "overture_booked")
        #expect(imported.possible?.source != ownActivity.possible?.source)
    }

    // The #1693 record itself: a scheduling dismissal, which LocalHistory files as "declined". This is the
    // one that most needed its own words, because it is the one that is not business at all.
    @Test func aShowDanSwipedAwayReportsItselfAsThat() {
        let v = verdict(history: [HistoryRecord(groupName: Self.recordName,
                                                status: "declined", origin: .overtureActivity)])

        #expect(v.possible?.source == "overture_dismissed")
    }

    @Test func overtureSOwnActivityKeepsWhatHappenedWithIt() {
        let cases: [(String, String)] = [
            ("contacted", "overture_contacted"),
            ("warm", "overture_replied"),
            ("lost_soft", "overture_other"),
        ]
        for (status, expected) in cases {
            let v = verdict(history: [HistoryRecord(groupName: Self.recordName,
                                                    status: status, origin: .overtureActivity)])
            #expect(v.possible?.source == expected, "status \(status)")
        }
    }

    // A confident client match is untouched by any of this: it was never ambiguous about where it came
    // from, and its copy is the one sentence here that was already right.
    @Test func aClientPossibleIsStillAClientPossible() {
        let client = DownbeatClient(id: "c1", displayName: Self.recordName, shortName: nil,
                                    email: "a@b.org", contractEmail: "a@b.org", phoneNumber: nil,
                                    isTaxExempt: nil, hasLeftReview: false, specialBehaviors: [],
                                    notes: nil, hostingSite: "pixieset")
        let v = HistoryMatch.matchRelationship(name: Self.candidate, presenter: nil,
                                               venue: "A Hall", clients: [client], history: [])

        #expect(v.possible?.source == "downbeat_client")
    }

    // --- the two lists are stamped where they are built ------------------------------------------------

    @Test func recordsDerivedFromOvertureSOwnProspectsAreStampedAsSuch() throws {
        let ctx = ModelContext(try ModelContainer(
            for: Schema([Prospect.self, Recipient.self, DayOff.self]),
            configurations: [ModelConfiguration(isStoredInMemoryOnly: true)]))
        let p = Prospect(naturalKey: "k", groupName: "Aurora Strings", discipline: "music",
                         venue: "A Hall", performanceDate: "2026-10-08", sourceListingURL: nil,
                         websiteURL: nil, priorRelationship: "none", production: "self",
                         profile: "strong", coverage: "likely_uncovered", fitScore: 5, tier: "mid",
                         fitReason: "r", matchedClientName: nil, possibleMatchSource: nil,
                         possibleMatchName: nil, status: .dismissed)
        p.showOutcomeRaw = ShowOutcome.dateConflict.rawValue
        ctx.insert(p)

        let records = LocalHistory.records(from: [p])

        #expect(records.map(\.origin) == [.overtureActivity])
    }

    // The imported file predates this field entirely, so it decodes without one. It must land as the
    // booking import it literally is, never as Overture's own activity, which would put the softest
    // words on Dan's realest business.
    @Test func theImportedFileIsStampedAsTheBookingLogEvenThoughItSaysNothing() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("history-origin-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("overture-history.json")
        try Data(#"[{"groupName":"Aurora Strings","status":"booked"}]"#.utf8).write(to: url)

        let records = LocalHistory.imported(from: url)

        #expect(records.map(\.origin) == [.bookingImport])
    }

    // --- what Dan reads --------------------------------------------------------------------------------

    private func item(source: String?, name: String?) -> QueueItem {
        QueueItem(id: "a", groupName: "Aurora Strings", discipline: "music", venue: "A Hall",
                  performanceDate: "2026-08-01", sourceListingURL: nil, websiteURL: nil,
                  priorRelationship: "none", production: "self", profile: "strong",
                  coverage: "likely_uncovered", fitScore: 4, tier: "mid", fitReason: "r",
                  matchedClientName: nil, possibleMatchSource: source, possibleMatchName: name,
                  status: .new)
    }

    @Test func eachOriginGetsItsOwnSentence() {
        let sentences = [
            "downbeat_client", "booking_import", "overture_dismissed",
            "overture_contacted", "overture_replied", "overture_booked", "overture_other",
        ].map { QueueModel.possibleMatchQuestion(item(source: $0, name: "Aurora Strings Summer Series")) }

        #expect(sentences.allSatisfy { $0 != nil })
        #expect(Set(sentences).count == sentences.count, "two origins share a sentence: \(sentences)")
    }

    @Test func theShowDanSwipedAwayNeverClaimsToBeBusiness() {
        let flag = QueueModel.possibleMatchQuestion(item(source: "overture_dismissed",
                                                        name: "Carnegie Hall Citywide: Ivalas Quartet"))

        #expect(flag == "Possible match to a show you dismissed in Overture: "
                + "Carnegie Hall Citywide: Ivalas Quartet?")
        #expect(flag?.contains("booking log") == false)
    }

    // A row stored before this shipped still says "history", and the launch recheck only rewrites it on
    // the next launch. Until then it must read as something true rather than as a blank or as the
    // booking log it might not be.
    @Test func aRowStoredBeforeThisShippedStillReadsHonestly() {
        let flag = QueueModel.possibleMatchQuestion(item(source: "history", name: "Aurora Strings Summer Series"))

        #expect(flag == "Possible match to something Overture has seen before: "
                + "Aurora Strings Summer Series?")
        #expect(flag?.contains("booking log") == false)
    }
}
