import Testing
import Foundation
import SwiftData

// Milestone 61, #3453. The repair for the rows #3451 arrived too late to protect.
//
// #3451 (2026-09-01) stops a run that did not finish from writing off a show it answered with nothing.
// It changes two writers and nothing else, so the rows a dead run had ALREADY written off keep their
// verdict and their 90 day lockout. Measured 2026-09-01 against the archive at
// `check-run-archives/20260830-205244/`, whose `runCost` reads `recorded: false, streams: 10,
// streamsRecorded: 9`: that run answered 12 shows with no contacts at all, and 5 of the 12 are still
// live and locked out until late November.
//
// A ONE TIME repair on `ReachabilityVerdictRefresh`'s precedent, and it is a different question from
// that one. The refresh recomputes a verdict FROM WHAT THE ROW HOLDS, which cannot help here: these
// rows hold nothing, because the dead run never found anything. What this removes is a verdict the run
// never earned, so the show returns to the unanswered path #1724 and #2621 already built and becomes a
// check candidate again.
//
// WHICH RUNS ARE DEAD IS READ FROM THE ARCHIVES, through `PrepImporter.distrustedAnswerKeys`, which is
// the same predicate `markProbed` and `ingest` already refuse by. A hand written list of run stamps
// would check only what somebody remembered (L96), and a second definition of "this run finished" is
// exactly what #3443 removed (L263).
@MainActor
@Suite("Repair the shows a run that did not finish already wrote off (#3453)")
final class DeadRunWriteOffRepairTests {

    private let sandboxes = TemporarySandboxes()

    private func container() throws -> ModelContainer {
        try ModelContainer(for: Schema([Prospect.self, Recipient.self]),
                           configurations: [ModelConfiguration(isStoredInMemoryOnly: true)])
    }

    private func defaults() -> UserDefaults {
        UserDefaults(suiteName: "dead-run-repair-\(UUID().uuidString)")!
    }

    private let probedAt = Date(timeIntervalSince1970: 1_756_580_000)

    @discardableResult
    private func show(_ ctx: ModelContext, _ name: String,
                      stored: Reachability.ProbeResult? = .noEmailFound,
                      reason: Reachability.EmptyReason? = .noOneIdentified,
                      probed: Date? = nil,
                      status: ReviewStatus = .new,
                      email: String? = nil,
                      sentAt: Date? = nil) -> Prospect {
        let key = Prospect.makeNaturalKey(groupName: name, performanceDate: "2027-04-18",
                                          venue: "Rowan Hall")
        let p = Prospect(naturalKey: key, groupName: name, discipline: "music", venue: "Rowan Hall",
                         performanceDate: "2027-04-18", sourceListingURL: nil, priorRelationship: "none",
                         production: "unknown", profile: "strong", coverage: "likely_uncovered",
                         fitScore: 6, tier: "mid", fitReason: "r", matchedClientName: nil,
                         possibleMatchSource: nil, possibleMatchName: nil, status: status)
        ctx.insert(p)
        p.reachabilityResult = stored
        p.reachabilityEmptyReason = reason
        p.reachabilityProbedAt = probed ?? probedAt
        p.sentAt = sentAt
        if let email {
            let r = Recipient(id: "r-\(name)", email: email, name: name, role: nil,
                              provenance: .performer, contactMethodRaw: "generic_inbox",
                              contactConfidenceRaw: "medium", contactFormURL: nil,
                              contactSourceURL: nil)
            p.addRecipient(r)
        }
        try? ctx.save()
        return p
    }

    // Writes one archived run folder holding a real queue and a real results file, so the reader under
    // test parses the shapes the app actually writes rather than a stub of them (L52).
    private func archive(_ directory: URL, stamp: String, slot: RunSlot,
                         answered: [(key: String, contacts: Int)],
                         recorded: Bool) throws {
        let folder = slot.archivesDirectory(in: directory).appendingPathComponent(stamp,
                                                                                 isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        let items = answered.map { #"{"naturalKey":"\#($0.key)","groupName":"g","venue":"v","performanceDate":"2027-04-18"}"# }
        let queue = #"{"version":13,"generatedAt":"2026-08-30T20:52:44Z","items":[\#(items.joined(separator: ","))]}"#
        try Data(queue.utf8).write(to: folder.appendingPathComponent(slot.queueFileName))

        let results = answered.map { entry -> String in
            let contacts = (0..<entry.contacts).map {
                #"{"email":"someone\#($0)@rowanhall.example","name":"Someone","provenance":"performer"}"#
            }
            return #"{"naturalKey":"\#(entry.key)","contacts":[\#(contacts.joined(separator: ","))]}"#
        }
        // `items`, `capPerItem` and `allowance` are non-optional Ints on `PrepResults.WebCalls`, and
        // Swift's synthesized decoder does NOT fall back to a property's default value for a missing
        // key: it throws. Omitting them made the whole results file unreadable, which reads here exactly
        // like a run that answered nobody, so every repair silently did nothing while the "left alone"
        // tests all passed. Supply what the type actually requires.
        let counts = #""items":\#(answered.count),"capPerItem":15,"allowance":\#(answered.count * 15)"#
        let webCalls = recorded
            ? #""webCalls":{"recorded":true,"total":12,\#(counts),"overCap":false}"#
            : #""webCalls":{"recorded":false,\#(counts)}"#
        let body = #"{"version":11,"generatedAt":"2026-08-30T20:52:44Z","results":[\#(results.joined(separator: ","))],\#(webCalls)}"#
        try Data(body.utf8).write(to: folder.appendingPathComponent(slot.resultsFileName))
    }

    // THE DEFECT. A dead run answered this show with nothing, the settle wrote the floor and stamped the
    // 90 day clock, and nothing since has looked at it again.
    @Test func aShowADeadRunAnsweredWithNothingIsReturnedToTheUnansweredPath() throws {
        let ctx = ModelContext(try container())
        let dir = try sandboxes.make(named: "dead-run-repair")
        let p = show(ctx, "Written Off By A Dead Run")
        try archive(dir, stamp: "20260830-205244", slot: .check,
                    answered: [(p.naturalKey, 0)], recorded: false)

        let report = try #require(DeadRunWriteOffRepair.run(in: ctx, handoffDirectory: dir,
                                                            defaults: defaults()))

        #expect(p.reachabilityResult == nil)
        #expect(p.reachabilityEmptyReason == nil)
        #expect(p.reachabilityProbedAt == nil)
        // The mark carries the moment the check came home, which is what the row already recorded, so
        // the offer ages on the clock the lockout would have rather than on a fresh 90 days.
        #expect(p.reachabilityUnansweredAt == probedAt)
        #expect(Reachability.wasMissedByACheck(probedAt: p.reachabilityProbedAt,
                                               unansweredAt: p.reachabilityUnansweredAt,
                                               now: probedAt.addingTimeInterval(86_400)))
        #expect(report.repaired == 1)
    }

    // The boundary that decides everything: the SAME empty answer from a run that FINISHED is an earned
    // negative and must be left exactly as it is.
    @Test func aShowAFinishedRunAnsweredWithNothingIsLeftAlone() throws {
        let ctx = ModelContext(try container())
        let dir = try sandboxes.make(named: "dead-run-repair")
        let p = show(ctx, "Honestly Written Off")
        try archive(dir, stamp: "20260830-205244", slot: .check,
                    answered: [(p.naturalKey, 0)], recorded: true)

        let report = try #require(DeadRunWriteOffRepair.run(in: ctx, handoffDirectory: dir,
                                                            defaults: defaults()))

        #expect(p.reachabilityResult == .noEmailFound)
        #expect(p.reachabilityProbedAt == probedAt)
        #expect(report.repaired == 0)
    }

    // A later run that DID finish and answered the same show settles it, whatever the dead one did.
    // Keyed on the LATEST archived run that answered the key, so this needs no timestamp arithmetic.
    @Test func aLaterFinishedRunsAnswerWins() throws {
        let ctx = ModelContext(try container())
        let dir = try sandboxes.make(named: "dead-run-repair")
        let p = show(ctx, "Answered Again Since")
        try archive(dir, stamp: "20260830-205244", slot: .check,
                    answered: [(p.naturalKey, 0)], recorded: false)
        try archive(dir, stamp: "20260831-090000", slot: .check,
                    answered: [(p.naturalKey, 0)], recorded: true)

        let report = try #require(DeadRunWriteOffRepair.run(in: ctx, handoffDirectory: dir,
                                                            defaults: defaults()))

        #expect(p.reachabilityResult == .noEmailFound)
        #expect(report.repaired == 0)
        #expect(report.skippedAnsweredSince == 1)
    }

    // And the other order: a dead run AFTER a good one is still the last word, because it is the run
    // whose answer the row is carrying.
    @Test func anEarlierFinishedRunDoesNotExcuseALaterDeadOne() throws {
        let ctx = ModelContext(try container())
        let dir = try sandboxes.make(named: "dead-run-repair")
        let p = show(ctx, "Good Then Dead")
        try archive(dir, stamp: "20260829-090000", slot: .check,
                    answered: [(p.naturalKey, 0)], recorded: true)
        try archive(dir, stamp: "20260830-205244", slot: .check,
                    answered: [(p.naturalKey, 0)], recorded: false)

        let report = try #require(DeadRunWriteOffRepair.run(in: ctx, handoffDirectory: dir,
                                                            defaults: defaults()))

        #expect(p.reachabilityResult == nil)
        #expect(report.repaired == 1)
    }

    // A dead run that DID find contacts for a show established something, which is the boundary Dan drew
    // on 2026-09-01 and which #3451 already writes by: the contacts are evidence the run reached it.
    @Test func aShowADeadRunAnsweredWithContactsIsLeftAlone() throws {
        let ctx = ModelContext(try container())
        let dir = try sandboxes.make(named: "dead-run-repair")
        let p = show(ctx, "Dead Run Found Someone", stored: .emailFound, reason: nil,
                     email: "office@rowanhall.example")
        try archive(dir, stamp: "20260830-205244", slot: .check,
                    answered: [(p.naturalKey, 1)], recorded: false)

        let report = try #require(DeadRunWriteOffRepair.run(in: ctx, handoffDirectory: dir,
                                                            defaults: defaults()))

        #expect(p.reachabilityResult == .emailFound)
        #expect(report.repaired == 0)
    }

    // A row that HOLDS a route is the contradiction class, which is `ReachabilityVerdictRefresh`'s
    // subject and not this pass's. Counted rather than silently passed over, so the two passes cannot
    // both believe the other is handling it (L98).
    @Test func aRowThatHoldsARouteIsLeftToTheVerdictRefresh() throws {
        let ctx = ModelContext(try container())
        let dir = try sandboxes.make(named: "dead-run-repair")
        let p = show(ctx, "Holds A Route Anyway", email: "office@rowanhall.example")
        try archive(dir, stamp: "20260830-205244", slot: .check,
                    answered: [(p.naturalKey, 0)], recorded: false)

        let report = try #require(DeadRunWriteOffRepair.run(in: ctx, handoffDirectory: dir,
                                                            defaults: defaults()))

        #expect(p.reachabilityResult == .noEmailFound)
        #expect(report.repaired == 0)
        #expect(report.skippedHoldsARoute == 1)
    }

    // History is history, the same rule `ReachabilityVerdictRefresh` follows: what was true when Dan
    // wrote to them is not drift.
    @Test func aShowAlreadyPitchedKeepsTheVerdictItWentOutUnder() throws {
        let ctx = ModelContext(try container())
        let dir = try sandboxes.make(named: "dead-run-repair")
        let p = show(ctx, "Already Pitched", sentAt: probedAt)
        try archive(dir, stamp: "20260830-205244", slot: .check,
                    answered: [(p.naturalKey, 0)], recorded: false)

        let report = try #require(DeadRunWriteOffRepair.run(in: ctx, handoffDirectory: dir,
                                                            defaults: defaults()))

        #expect(p.reachabilityResult == .noEmailFound)
        #expect(report.repaired == 0)
        #expect(report.skippedSentOrBooked == 1)
    }

    // A DISMISSED row gets the same verdict repair and its dismissal is untouched. Both halves matter.
    // Dan's decision 7 of 2026-08-31 is that the stored answer should be accurate; undoing a dismissal
    // would be overruling him, and clearing a verdict he was shown falsely is not the same act. It is
    // counted separately so the population he judged on bad information is visible rather than folded
    // into the total.
    @Test func aDismissedRowIsRepairedWithoutBeingUndismissed() throws {
        let ctx = ModelContext(try container())
        let dir = try sandboxes.make(named: "dead-run-repair")
        let p = show(ctx, "Dismissed On A Lie", status: .dismissed)
        try archive(dir, stamp: "20260830-205244", slot: .check,
                    answered: [(p.naturalKey, 0)], recorded: false)

        let report = try #require(DeadRunWriteOffRepair.run(in: ctx, handoffDirectory: dir,
                                                            defaults: defaults()))

        #expect(p.reachabilityResult == nil)
        #expect(p.status == .dismissed)
        #expect(report.repaired == 1)
        #expect(report.repairedDismissed == 1)
    }

    // The PREP slot is read too. Nothing today is known to write a reachability floor from a prep run,
    // but the rule is about a dead run's empty answer rather than about which slot produced it, and a
    // rule scoped to one spelling exempts whatever reaches the same state by another route (L247, L30).
    @Test func thePrepSlotsArchivesAreReadAsWell() throws {
        let ctx = ModelContext(try container())
        let dir = try sandboxes.make(named: "dead-run-repair")
        let p = show(ctx, "Written Off By A Dead Prep Run")
        try archive(dir, stamp: "20260830-205244", slot: .prep,
                    answered: [(p.naturalKey, 0)], recorded: false)

        let report = try #require(DeadRunWriteOffRepair.run(in: ctx, handoffDirectory: dir,
                                                            defaults: defaults()))

        #expect(p.reachabilityResult == nil)
        #expect(report.repaired == 1)
    }

    // ONE TIME, on `ReachabilityVerdictRefresh`'s precedent. A second call must be able to say it did
    // nothing because it was not asked to, which is a different answer from doing nothing because there
    // was nothing to do (L98).
    @Test func itRunsOnceAndThenDeclinesRatherThanFindingNothing() throws {
        let ctx = ModelContext(try container())
        let dir = try sandboxes.make(named: "dead-run-repair")
        let d = defaults()
        show(ctx, "Written Off By A Dead Run")
        try archive(dir, stamp: "20260830-205244", slot: .check,
                    answered: [(Prospect.makeNaturalKey(groupName: "Written Off By A Dead Run",
                                                        performanceDate: "2027-04-18",
                                                        venue: "Rowan Hall"), 0)],
                    recorded: false)

        #expect(DeadRunWriteOffRepair.run(in: ctx, handoffDirectory: dir, defaults: d)?.repaired == 1)
        #expect(DeadRunWriteOffRepair.run(in: ctx, handoffDirectory: dir, defaults: d) == nil)
    }

    // NO ARCHIVES AT ALL is not a clean bill of health, and it must not read as one. A fresh clone, a
    // machine whose archives have rotated away, and a machine where nothing was ever written off leave
    // the same empty result, so the report says how many runs it could read (L98, L11).
    @Test func aRunWithNoArchivesToReadSaysSoRatherThanReportingNothingToDo() throws {
        let ctx = ModelContext(try container())
        let dir = try sandboxes.make(named: "dead-run-repair")
        show(ctx, "Never Looked At")

        let report = try #require(DeadRunWriteOffRepair.run(in: ctx, handoffDirectory: dir,
                                                            defaults: defaults()))

        #expect(report.runsRead == 0)
        #expect(report.deadRunsFound == 0)
        #expect(report.repaired == 0)
    }

    // THE SHAPE ON DISK. `check-run-archives/20260830-205244` claims `webCalls.recorded: true` and
    // `runCost.recorded: false` about one run, because before #3443 the two recorders disagreed about
    // what a finished stream was and only `runCost` used the terminal envelope. Every archive predating
    // that fix can lie this way, and they are the only archives this repair has to read.
    @Test func aRunWhoseWebCallsClaimItFinishedIsStillDeadWhenItsCostSaysOtherwise() throws {
        let ctx = ModelContext(try container())
        let dir = try sandboxes.make(named: "dead-run-repair")
        let p = show(ctx, "Archived Before The Definitions Agreed")
        let folder = RunSlot.check.archivesDirectory(in: dir)
            .appendingPathComponent("20260830-205244", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data(#"{"version":13,"generatedAt":"2026-08-30T20:52:44Z","items":[]}"#.utf8)
            .write(to: folder.appendingPathComponent(RunSlot.check.queueFileName))
        try Data(#"""
        {"version":11,"generatedAt":"2026-08-30T20:52:44Z",
         "results":[{"naturalKey":"\#(p.naturalKey)","contacts":[]}],
         "webCalls":{"recorded":true,"total":692,"items":90,"capPerItem":15,"allowance":1620,"overCap":false},
         "runCost":{"recorded":false,"streams":10,"streamsRecorded":9}}
        """#.utf8).write(to: folder.appendingPathComponent(RunSlot.check.resultsFileName))

        let report = try #require(DeadRunWriteOffRepair.run(in: ctx, handoffDirectory: dir,
                                                            defaults: defaults()))

        #expect(p.reachabilityResult == nil)
        #expect(report.repaired == 1)
        #expect(report.deadRunsFound == 1)
    }

    // The other direction, so the rule above cannot quietly become "any run with a runCost is dead":
    // a cost that RECORDED, beside web calls that recorded, is a run that finished.
    @Test func aRunWhoseCostRecordedIsNotDead() throws {
        let ctx = ModelContext(try container())
        let dir = try sandboxes.make(named: "dead-run-repair")
        let p = show(ctx, "Finished And Said So Twice")
        let folder = RunSlot.check.archivesDirectory(in: dir)
            .appendingPathComponent("20260830-155709", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data(#"{"version":13,"generatedAt":"2026-08-30T15:57:09Z","items":[]}"#.utf8)
            .write(to: folder.appendingPathComponent(RunSlot.check.queueFileName))
        try Data(#"""
        {"version":11,"generatedAt":"2026-08-30T15:57:09Z",
         "results":[{"naturalKey":"\#(p.naturalKey)","contacts":[]}],
         "webCalls":{"recorded":true,"total":353,"items":24,"capPerItem":15,"allowance":1245,"overCap":false},
         "runCost":{"recorded":true,"streams":10}}
        """#.utf8).write(to: folder.appendingPathComponent(RunSlot.check.resultsFileName))

        let report = try #require(DeadRunWriteOffRepair.run(in: ctx, handoffDirectory: dir,
                                                            defaults: defaults()))

        #expect(p.reachabilityResult == .noEmailFound)
        #expect(report.repaired == 0)
        #expect(report.deadRunsFound == 0)
    }

    // A results file this build cannot read says NOTHING about the run, and must never read as death.
    // Same rule #3451 speaks by: every results file written before #1721 carries no `webCalls` at all.
    @Test func anArchiveWithNoWebCallsRecordIsNotTreatedAsADeadRun() throws {
        let ctx = ModelContext(try container())
        let dir = try sandboxes.make(named: "dead-run-repair")
        let p = show(ctx, "Archived Before webCalls Existed")
        let folder = RunSlot.check.archivesDirectory(in: dir)
            .appendingPathComponent("20260830-205244", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data(#"{"version":13,"generatedAt":"2026-08-30T20:52:44Z","items":[]}"#.utf8)
            .write(to: folder.appendingPathComponent(RunSlot.check.queueFileName))
        try Data(#"{"version":11,"generatedAt":"2026-08-30T20:52:44Z","results":[{"naturalKey":"\#(p.naturalKey)","contacts":[]}]}"#.utf8)
            .write(to: folder.appendingPathComponent(RunSlot.check.resultsFileName))

        let report = try #require(DeadRunWriteOffRepair.run(in: ctx, handoffDirectory: dir,
                                                            defaults: defaults()))

        #expect(p.reachabilityResult == .noEmailFound)
        #expect(report.repaired == 0)
        #expect(report.runsRead == 1)
        #expect(report.deadRunsFound == 0)
    }
}
