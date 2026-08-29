import Testing
import Foundation
import SwiftData

// #1693: `possibleMatchName` is STORED, and only rewritten when the hash-gated scout re-emits that row.
// So tightening the matcher clears nothing already on screen: on the live store 18 Carnegie Hall cards
// were asking Dan about an act he has never worked with, and would have gone on asking for as long as
// carnegiehall.org went unscouted. This pass re-runs the verdict over the rows that already carry a flag.
//
// It can only clear or replace a flag, never invent one, which is what makes it safe to run every launch.
@MainActor
@Suite("Possible-match recheck (#1693)")
struct PossibleMatchRecheckTests {
    private func context() throws -> ModelContext {
        ModelContext(try ModelContainer(for: Schema([Prospect.self, Recipient.self, DayOff.self]),
                                        configurations: [ModelConfiguration(isStoredInMemoryOnly: true)]))
    }

    private func flagged(_ ctx: ModelContext, key: String, groupName: String, presenter: String?,
                         venue: String, source: String?, name: String?) -> Prospect {
        let p = Prospect(naturalKey: key, groupName: groupName, discipline: "music", venue: venue,
                         performanceDate: "2026-10-08", sourceListingURL: nil,
                         priorRelationship: "none", production: "self", profile: "strong",
                         coverage: "likely_uncovered", fitScore: 5, tier: "mid", fitReason: "r",
                         matchedClientName: nil, possibleMatchSource: source, possibleMatchName: name,
                         status: .new)
        p.presenter = presenter
        ctx.insert(p)
        try? ctx.save()
        return p
    }

    private let bayRidge = DownbeatClient(
        id: "c3", displayName: "Bay Ridge School of Music", shortName: nil, email: "a@b.org",
        contractEmail: "a@b.org", phoneNumber: nil, isTaxExempt: nil, hasLeftReview: false,
        specialBehaviors: [], notes: nil, hostingSite: "pixieset")

    // The record behind all 18: a Madison Square Park show Dan dismissed as a date conflict, which
    // LocalHistory files as "declined" and so feeds back into every match.
    private let citywide = HistoryRecord(groupName: "Carnegie Hall Citywide: Ivalas Quartet",
                                         status: "declined")

    private func inputs(clients: [DownbeatClient] = [], history: [HistoryRecord] = [])
        -> ([Prospect]) -> PossibleMatchRecheck.Inputs? {
        { _ in PossibleMatchRecheck.Inputs(clients: clients, history: history) }
    }

    @Test func theStaleFlagIsCleared() throws {
        let ctx = try context()
        let nyo2 = flagged(ctx, key: "a", groupName: "NYO2", presenter: "Carnegie Hall Presents",
                           venue: "Stern Auditorium / Perelman Stage",
                           source: "history", name: "Carnegie Hall Citywide: Ivalas Quartet")

        let changed = PossibleMatchRecheck.run(in: ctx, loadInputs: inputs(history: [citywide]))

        #expect(changed == 1)
        #expect(nyo2.possibleMatchName == nil)
        #expect(nyo2.possibleMatchSource == nil)
    }

    @Test func aFlagThatIsStillRealSurvives() throws {
        let ctx = try context()
        let irvine = flagged(ctx, key: "b", groupName: "Irvine School of Music Student Recital",
                             presenter: "Irvine School of Music", venue: "Weill Recital Hall",
                             source: "downbeat_client", name: "Bay Ridge School of Music")

        let changed = PossibleMatchRecheck.run(in: ctx, loadInputs: inputs(clients: [bayRidge]))

        #expect(changed == 0)
        #expect(irvine.possibleMatchName == "Bay Ridge School of Music")
        #expect(irvine.possibleMatchSource == "downbeat_client")
    }

    // The failure path, and the reason this pass takes its inputs as a seam at all. Both sides it
    // judges against are FILES that can be missing or corrupt: the Downbeat export and the imported
    // booking history. Judged against an empty client list every real flag looks stale, so a pass that
    // read on regardless would quietly delete Dan's genuine ones the first morning Downbeat had not
    // written its export yet. Unable to judge means touch nothing.
    @Test func itClearsNothingWhenItCannotJudge() throws {
        let ctx = try context()
        let irvine = flagged(ctx, key: "c", groupName: "Irvine School of Music Student Recital",
                             presenter: "Irvine School of Music", venue: "Weill Recital Hall",
                             source: "downbeat_client", name: "Bay Ridge School of Music")
        let nyo2 = flagged(ctx, key: "d", groupName: "NYO2", presenter: "Carnegie Hall Presents",
                           venue: "Zankel Hall",
                           source: "history", name: "Carnegie Hall Citywide: Ivalas Quartet")

        let changed = PossibleMatchRecheck.run(in: ctx, loadInputs: { _ in nil })

        #expect(changed == 0)
        #expect(irvine.possibleMatchName == "Bay Ridge School of Music")
        #expect(nyo2.possibleMatchName == "Carnegie Hall Citywide: Ivalas Quartet")
    }

    // A row with no flag is never given one, however fuzzily it matches. This pass exists to retire
    // stale answers, not to hand out new ones: flagging is the scout's job, on a row it has just read,
    // and a launch pass that could also SET a flag would put a question on Dan's screen with no run
    // behind it.
    @Test func itNeverInventsAFlag() throws {
        let ctx = try context()
        let unflagged = flagged(ctx, key: "e", groupName: "Irvine School of Music Student Recital",
                                presenter: "Irvine School of Music", venue: "Weill Recital Hall",
                                source: nil, name: nil)

        let changed = PossibleMatchRecheck.run(in: ctx, loadInputs: inputs(clients: [bayRidge]))

        #expect(changed == 0)
        #expect(unflagged.possibleMatchName == nil)
    }

    @Test func aSecondPassChangesNothing() throws {
        let ctx = try context()
        _ = flagged(ctx, key: "f", groupName: "NYO2", presenter: "Carnegie Hall Presents",
                    venue: "Zankel Hall", source: "history",
                    name: "Carnegie Hall Citywide: Ivalas Quartet")

        _ = PossibleMatchRecheck.run(in: ctx, loadInputs: inputs(history: [citywide]))
        let second = PossibleMatchRecheck.run(in: ctx, loadInputs: inputs(history: [citywide]))

        #expect(second == 0)
    }

    // A flag can also be REPLACED rather than cleared: the row still fuzzily matches something, but a
    // different record. Dan is then asked the current question, not last month's.
    @Test func aFlagPointingAtTheWrongRecordIsReplaced() throws {
        let ctx = try context()
        let irvine = flagged(ctx, key: "g", groupName: "Irvine School of Music Student Recital",
                             presenter: "Irvine School of Music", venue: "Weill Recital Hall",
                             source: "history", name: "Carnegie Hall Citywide: Ivalas Quartet")

        let changed = PossibleMatchRecheck.run(in: ctx,
                                               loadInputs: inputs(clients: [bayRidge], history: [citywide]))

        #expect(changed == 1)
        #expect(irvine.possibleMatchSource == "downbeat_client")
        #expect(irvine.possibleMatchName == "Bay Ridge School of Music")
    }
}
