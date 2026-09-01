import Foundation
import SwiftData

// Milestone 61, #3453. A ONE TIME repair of the rows #3451 arrived too late to protect.
//
// #3451 (2026-09-01) stops a run that did not finish from writing off a show it answered with nothing:
// `PrepQueueService.markProbed` subtracts those keys from what it stamps and `PrepImporter.ingest`
// refuses the same rows. Both are writers, so both only ever govern the NEXT run. The rows a dead run
// had already written off keep their `.noEmailFound` and their 90 day lockout, and nothing in the app
// looks at them again.
//
// Measured 2026-09-01 against `check-run-archives/20260830-205244/`, whose `runCost` reads
// `recorded: false, streams: 10, streamsRecorded: 9`: that run was handed 97 shows, answered 90, and
// answered 12 of those with no contacts at all. Five of the 12 are still live and locked out until late
// November; the other seven were dismissed, most likely off a card saying nothing could be found.
//
// WHY THIS IS NOT `ReachabilityVerdictRefresh`'s job, since the two look alike and are not. That pass
// recomputes a verdict FROM WHAT THE ROW HOLDS, which cannot reach these rows: they hold nothing,
// because the dead run never found anything, so recomputing gives back the same `.noEmailFound`. What
// is wrong here is not the verdict's agreement with the row, it is that no run ever earned it.
//
// WHICH RUNS ARE DEAD IS READ FROM THE ARCHIVES, never from a list of run stamps. A hand written list
// checks only what somebody remembered (L96), and the question "did this run finish" already has one
// answer in this codebase since #3443, `webCalls.recorded`, which `PrepImporter.distrustedAnswerKeys`
// asks. Asking it again in a second way here is exactly the drift #3443 removed (L263).
enum DeadRunWriteOffRepair {

    // A UserDefaults key rather than a stored column, on `ReachabilityVerdictRefresh`'s precedent: the
    // fact is about this installation having done the work once, not about any row.
    static let hasRunKey = "deadRunWriteOffRepairCompletedAt"

    struct Report: Equatable, Sendable {
        var repaired: Int
        // A subset of `repaired`, not an addition to it. Reported on its own because it is the
        // population Dan judged on bad information, and folding it into the total would hide that a
        // dismissal was made against a claim the run never earned.
        var repairedDismissed: Int
        var skippedAnsweredSince: Int
        var skippedSentOrBooked: Int
        var skippedHoldsARoute: Int
        // How many archived runs could be READ, and how many of those did not finish. Both are here
        // because zero repairs from zero archives and zero repairs from a healthy history are the same
        // number and different facts (L98, L11): a fresh clone, a machine whose archives have rotated
        // away, and a machine that never wrote one off all report `repaired: 0`.
        var runsRead: Int
        var deadRunsFound: Int
    }

    // One archived run, reduced to the two things this pass decides on.
    private struct ArchivedRun {
        let stamp: String
        let answered: Set<String>
        let distrusted: Set<String>

        // A run is DEAD only where the evidence says so. `distrustedAnswerKeys` returns the empty set
        // both for a run that finished and for one whose results carry no `webCalls` record at all, and
        // those are different facts: every results file written before #1721 has none, so reading
        // silence as death would repair the whole store on the strength of a field that did not exist
        // yet (L98, L11).
        //
        // Collapsing them is safe HERE because the only thing a dead run's emptiness could do is cause
        // a repair, and an empty distrusted set causes none either way. The distinction is preserved
        // where it is read, in `deadRunsFound`, so a machine reporting zero dead runs is saying it
        // found none rather than that it could not tell.
        var isDead: Bool { !distrusted.isEmpty }
    }

    // Returns nil when the repair has already run on this Mac, so a caller can tell "did nothing because
    // there was nothing to do" from "did nothing because it was not asked to" (L98).
    @discardableResult
    static func run(in context: ModelContext,
                    handoffDirectory: URL,
                    defaults: UserDefaults = .standard,
                    now: Date = Date(),
                    fileManager: FileManager = .default) -> Report? {
        guard defaults.object(forKey: hasRunKey) == nil else { return nil }

        let runs = archivedRuns(in: handoffDirectory, fileManager: fileManager)
        var report = Report(repaired: 0, repairedDismissed: 0, skippedAnsweredSince: 0,
                            skippedSentOrBooked: 0, skippedHoldsARoute: 0,
                            runsRead: runs.count, deadRunsFound: runs.filter(\.isDead).count)

        // The LATEST archived run that answered each key, which is the run whose answer the row is
        // carrying. Keying on that rather than on the row's `reachabilityProbedAt` is what removes the
        // timestamp arithmetic entirely: a show re-checked since is answered by a later run, and no
        // window has to be guessed at. Rotation keeps the NEWEST folders, so a run later than every
        // archived one cannot exist.
        var lastAnswer: [String: ArchivedRun] = [:]
        var everWrittenOffByADeadRun: Set<String> = []
        for run in runs.sorted(by: { $0.stamp < $1.stamp }) {
            for key in run.answered { lastAnswer[key] = run }
            everWrittenOffByADeadRun.formUnion(run.distrusted)
        }
        let toRepair = Set(lastAnswer.compactMap { key, run in
            run.isDead && run.distrusted.contains(key) ? key : nil
        })
        // Written off by a dead run at some point, and then answered again by a later run. That later
        // answer is the row's, so there is nothing to repair. Counted rather than passed over, because
        // it is the difference between "no damage here" and "the damage was already overtaken".
        let supersededSince = everWrittenOffByADeadRun.subtracting(toRepair)
        // Deliberately NO early return on an empty `toRepair`. One was here and it was a defect: it
        // skipped the loop, which is also where `skippedAnsweredSince` is counted, so a store whose
        // damage had already been overtaken by a later run reported zero of everything and read exactly
        // like a store that never had any. A guard standing in front of a loop has to cover everything
        // the loop REPORTS, not just what it changes (L98), and the cheapest way to keep the two from
        // drifting is not to have two.
        let prospects = (try? context.fetch(FetchDescriptor<Prospect>())) ?? []
        for p in prospects {
            guard toRepair.contains(p.naturalKey) else {
                if supersededSince.contains(p.naturalKey) { report.skippedAnsweredSince += 1 }
                continue
            }
            // Nothing to clear: this row is not carrying a write-off at all.
            guard p.reachabilityProbedAt != nil, p.reachabilityResult == .noEmailFound else { continue }
            // A show already pitched or booked keeps the verdict it went out under, the same rule
            // `ReachabilityVerdictRefresh` and `reachabilityResultAsHeld` both follow. What was true
            // when Dan wrote to them is history, not damage.
            guard p.sentAt == nil, !p.isBooked else {
                report.skippedSentOrBooked += 1
                continue
            }
            // A row that HOLDS a route is the contradiction class, which is `ReachabilityVerdictRefresh`'s
            // subject. Counted rather than passed over silently, so neither pass can leave a row on the
            // assumption that the other has it.
            guard !p.hasAnyRoute else {
                report.skippedHoldsARoute += 1
                continue
            }

            // The mark carries the moment the check came home, which the row already recorded, rather
            // than `now`. Otherwise the repair would hand every one of these a fresh 90 day offer window
            // dated by when the repair happened, which is a fact about this pass rather than about the
            // check (L37).
            p.reachabilityUnansweredAt = p.reachabilityProbedAt
            p.reachabilityProbedAt = nil
            p.reachabilityResult = nil
            p.reachabilityEmptyReason = nil
            report.repaired += 1
            // The DISMISSAL is deliberately untouched. Clearing a verdict Dan was shown falsely is a
            // repair; undoing the decision he made after seeing it would be overruling him, and a
            // dismissed show is already never a check candidate (`OpenForDecision.isOpen`), so nothing
            // is being withheld from him by leaving it.
            if p.status == .dismissed { report.repairedDismissed += 1 }
        }

        defaults.set(now, forKey: hasRunKey)
        return report
    }

    // Both slots, because the rule is about a dead run's empty answer rather than about which slot
    // produced it. Nothing today is known to write a reachability floor from a prep run, and scoping to
    // the one spelling that produced the measured damage is what exempts whatever reaches the same state
    // by another route (L247, L30). A slot with no archives contributes nothing and costs one directory
    // read.
    private static func archivedRuns(in handoffDirectory: URL,
                                     fileManager: FileManager) -> [ArchivedRun] {
        RunSlot.allCases.flatMap { slot -> [ArchivedRun] in
            let archives = slot.archivesDirectory(in: handoffDirectory)
            let folders = (try? fileManager.contentsOfDirectory(atPath: archives.path)) ?? []
            return folders
                .filter(PrepRunArchive.isArchivedRunFolder)
                .compactMap { name -> ArchivedRun? in
                    let folder = archives.appendingPathComponent(name, isDirectory: true)
                    let results = folder.appendingPathComponent(PrepRunArchive.resultsFilename(for: slot))
                    let queue = folder.appendingPathComponent(PrepRunArchive.queueFilename(for: slot))
                    // A folder holding no readable results is a run that left none, which says nothing
                    // about any show and is not counted as a run this pass could read.
                    let answered = PrepImporter.answeredKeys(at: results, queueURL: queue)
                    guard !answered.isEmpty else { return nil }
                    return ArchivedRun(
                        stamp: name,
                        answered: answered,
                        distrusted: PrepImporter.distrustedAnswerKeys(at: results, queueURL: queue))
                }
        }
    }
}

