import Testing
import Foundation

// #2885: the instruction sent to OmniFocus must be addressed by the same three things the decision
// was made over. `OmniFocusSync.reconcile` decides per (naturalKey, recipientId, dueDate), and the
// completion used to carry only the first two, so its AppleScript named EVERY open task for that
// show and contact: a family where the decision had named one member (L166). On a show with a live
// reply that had just re-anchored its follow-up, that is two tasks, and the plan "complete the stale
// one, keep today's" executed as "complete both". The only reason the live task survived on
// 2026-08-17 is that the loop crashed partway through, and which one survived was decided by the
// order OmniFocus happened to return them in.
//
// The AppleScript boundary itself cannot be unit-tested, so the guard sits on the two pure pieces:
// the note-matching clause `complete` builds, and the value `apply` hands it.
@Suite("OmniFocus completion is scoped to one task")
struct OmniFocusCompleteScopeTests {
    private let key = "an evening of song|2026-09-04|the corner room"
    private let recipientId = "booking@example.invalid"

    private func easternDue(_ day: String) -> Date {
        let parts = day.split(separator: "-").compactMap { Int($0) }
        var comps = DateComponents()
        comps.year = parts[0]; comps.month = parts[1]; comps.day = parts[2]
        comps.hour = OmniFocusSync.dueHour; comps.minute = 0; comps.second = 0
        return EasternDate.calendar.date(from: comps)!
    }

    // MARK: - The clause names all three

    @Test func theClauseNamesTheDueDaySoAStaleTaskAndTodaysLiveOneDoNotBothMatch() {
        let stale = AppleScriptOmniFocusClient.completionMatchClause(
            naturalKey: key, recipientId: recipientId, dueDate: easternDue("2026-08-19"))
        let live = AppleScriptOmniFocusClient.completionMatchClause(
            naturalKey: key, recipientId: recipientId, dueDate: easternDue("2026-08-17"))

        #expect(stale.contains("\(OmniFocusSync.dueNotePrefix)2026-08-19"))
        #expect(!stale.contains("2026-08-17"))
        #expect(live.contains("\(OmniFocusSync.dueNotePrefix)2026-08-17"))
        #expect(!live.contains("2026-08-19"))
        #expect(stale != live)   // two tasks differing ONLY by due date get different instructions
    }

    @Test func theClauseNamesTheShowAndTheContact() {
        let clause = AppleScriptOmniFocusClient.completionMatchClause(
            naturalKey: key, recipientId: recipientId, dueDate: easternDue("2026-08-19"))
        #expect(clause.contains("\(OmniFocusSync.notePrefix)\(key)"))
        #expect(clause.contains("\(OmniFocusSync.contactNotePrefix)\(recipientId)"))
    }

    // #653's one-time transition: a pre-#653 note carries no contact line at all, so it is matched by
    // that line's ABSENCE. It still has to be pinned to its own due day, for the same reason.
    @Test func theLegacyClauseMatchesTheAbsenceOfAContactLineAndStillNamesTheDueDay() {
        let clause = AppleScriptOmniFocusClient.completionMatchClause(
            naturalKey: key, recipientId: AppleScriptOmniFocusClient.legacyRecipientId,
            dueDate: easternDue("2026-08-19"))
        #expect(clause.contains("does not contain"))
        #expect(clause.contains(OmniFocusSync.contactNotePrefix))
        #expect(clause.contains("\(OmniFocusSync.dueNotePrefix)2026-08-19"))
        #expect(!clause.contains(AppleScriptOmniFocusClient.legacyRecipientId))   // sentinel is never in a real note
    }

    // MARK: - What apply actually hands the client

    private final class RecordingClient: OmniFocusClient {
        let existing: [OmniFocusSync.ExistingTask]
        var completed: [OmniFocusSync.ExistingTask] = []
        init(existing: [OmniFocusSync.ExistingTask]) { self.existing = existing }
        func existingOvertureTasks() throws -> [OmniFocusSync.ExistingTask] { existing }
        func create(_ task: OmniFocusSync.DesiredTask) throws {}
        func complete(_ task: OmniFocusSync.ExistingTask) throws { completed.append(task) }
    }

    // The live 2026-08-17 shape: one show, one contact, two open tasks that differ only by due date,
    // because a reply re-anchored the follow-up. Exactly one of them is stale.
    @Test func completingAStaleTaskCarriesItsOwnDueDateAndLeavesTodaysAlone() throws {
        let liveDue = easternDue("2026-08-17")
        let staleDue = easternDue("2026-08-19")
        let desired = [OmniFocusSync.DesiredTask(naturalKey: key, recipientId: recipientId,
                                                 title: "t", note: "n",
                                                 deferDate: liveDue, dueDate: liveDue)]
        let client = RecordingClient(existing: [
            OmniFocusSync.ExistingTask(naturalKey: key, recipientId: recipientId, dueDate: staleDue),
            OmniFocusSync.ExistingTask(naturalKey: key, recipientId: recipientId, dueDate: liveDue),
        ])

        _ = try OmniFocusSync.apply(desired: desired, client: client)

        #expect(client.completed.count == 1)
        #expect(client.completed.first?.dueDate == staleDue)
        #expect(client.completed.allSatisfy { $0.dueDate != liveDue })
    }

    // MARK: - Defect A: the loop must not iterate the live query it is mutating

    // AppleScript does not snapshot a `whose` result: it re-asks OmniFocus for item 1, item 2 on each
    // turn. The filter carries `completed is false`, so marking the first match complete shrinks the
    // list underneath the loop and the next index is refused ("Invalid index", live on 2026-08-17).
    // Scoped to `complete`'s own body: `existingOvertureTasks` legitimately iterates a whose-clause,
    // because it only reads (L135).
    @Test func completeDoesNotIterateAWhoseClauseItIsMutating() throws {
        let source = SourceGuardHelper.source("Overture/Integration/AppleScriptOmniFocusClient.swift")
        let body = try #require(SourceGuardHelper.bodyOfFunction(named: "complete", in: source))
        #expect(!body.contains("repeat with t in (tasks of"))
        #expect(body.contains("id of (tasks of"))   // the ids are read out as plain values first
    }
}
