import Testing
import Foundation
import SwiftData

// #3071: the four scout reads #2758 / #2999 scoped out.
//
// That issue fixed the ONE swallowed read that could destroy data (the exact-key lookup, where an
// unreadable store read as a free key and SwiftData silently merged two rows). Four more reads in the
// same file still folded "could not read" into "nothing there". None destroys anything, which is why the
// fix was scoped rather than swept, but each invents an emptiness that is itself a claim about Dan's data
// (L98, L11).
//
// The seam is the one `ScoutUpsertTargetTests` already uses and for the same reason: a healthy in-memory
// store never throws, so a fixture that only ever asks a real context proves nothing about the branch
// this whole thing is about (L140).
@MainActor
@Suite("What the scout does when a read of its own store fails (#3071)")
struct ScoutStoreReadTests {
    private struct StoreIsDown: Error {}

    private func healthy() throws -> [Int] { [1, 2, 3] }
    private func broken() throws -> [Int] { throw StoreIsDown() }

    // MARK: the reads the run cannot proceed without

    @Test func aRequiredReadThatAnswersIsSimplyTheAnswer() throws {
        let rows = try ScoutService.required(.sourceWatchlist, healthy)
        #expect(rows == [1, 2, 3])
    }

    // The whole point. An empty watchlist plans zero sources, so before this the scout scanned nothing
    // and reported an ordinary quiet run: a run that could not read its own watchlist was
    // indistinguishable from a night with no shows on it.
    @Test func aRequiredReadThatFailsThrowsRatherThanAnsweringEmpty() {
        #expect(throws: ScoutService.StoreReadFailure.self) {
            try ScoutService.required(.sourceWatchlist, broken)
        }
    }

    // And it says WHICH read, because "the scout failed" and "the scout could not read your watchlist"
    // send Dan to different places (L11). Asserted on the failure's own subject rather than on the mere
    // fact of a throw, which any error from the fixture would satisfy (L140).
    @Test func theFailureNamesTheReadThatCouldNotAnswer() throws {
        for read in ScoutService.StoreRead.allCases {
            do {
                _ = try ScoutService.required(read, broken)
                Issue.record("expected \(read) to refuse rather than answer")
            } catch let failure as ScoutService.StoreReadFailure {
                #expect(failure.read == read)
                #expect(failure.description.contains(read.label))
            }
        }
    }

    // MARK: the reads taken mid run, where throwing would discard work already done

    @Test func aRecordedReadThatAnswersRecordsNothing() {
        var degraded: [ScoutService.StoreRead] = []
        let rows = ScoutService.readOrRecord(.venueBrandCorpus, into: &degraded, healthy)
        #expect(rows == [1, 2, 3])
        #expect(degraded.isEmpty)
    }

    // nil, never an empty array: the caller is made to say what it met rather than proceeding on an
    // invented empty, which is the whole difference from `(try? fetch) ?? []`.
    @Test func aRecordedReadThatFailsAnswersNilAndNamesItself() {
        var degraded: [ScoutService.StoreRead] = []
        let rows = ScoutService.readOrRecord(.venueBrandCorpus, into: &degraded, broken)
        #expect(rows == nil)
        #expect(degraded == [.venueBrandCorpus])
    }

    // MARK: what the run then says

    // A recorded read reaches Dan. Without this the fix would be a field written and never read, which
    // looks alive to any is-this-used check while the purpose never happens (L46).
    @Test func aDegradedReadIsNamedInTheRunsWarning() throws {
        var outcome = ScoutService.Outcome(found: 1, inserted: 1, updated: 0, skipped: 0)
        #expect(outcome.warning == nil)

        outcome.degradedReads = [.venueBrandCorpus]
        let warning = try #require(outcome.warning)
        #expect(warning.contains(ScoutService.StoreRead.venueBrandCorpus.label))
    }

    // Every case has a distinct sentence of its own, so two different degradations can never read as one
    // (L11). Derived from `allCases`, so a case added later is covered without anybody remembering (L96).
    @Test func everyReadHasItsOwnWords() {
        let labels = Set(ScoutService.StoreRead.allCases.map(\.label))
        let blank = labels.filter(\.isEmpty)
        #expect(labels.count == ScoutService.StoreRead.allCases.count)
        #expect(blank.isEmpty)
    }

    // A merged run keeps what each half met. The scout merges one Outcome per source, so a degradation
    // recorded on the fifth source has to survive the fold or the run reports nothing wrong.
    @Test func mergingKeepsWhatEachHalfCouldNotRead() {
        var a = ScoutService.Outcome(found: 1, inserted: 1, updated: 0, skipped: 0)
        a.degradedReads = [.venueBrandCorpus]
        var b = ScoutService.Outcome(found: 1, inserted: 1, updated: 0, skipped: 0)
        b.degradedReads = [.reconcileStoredShows]

        a.merge(b)
        #expect(a.degradedReads == [.venueBrandCorpus, .reconcileStoredShows])
    }

    // MARK: the four sites themselves

    // The class, not the instance: the point of the issue is the four sites, and a hand-written list only
    // ever checks what somebody remembered (L96). This reads the file and fails on ANY surviving
    // `(try? context.fetch(...)) ?? []`, so a fifth one added later is caught too.
    @Test func noScoutReadInventsAnEmptyStore() {
        let source = SourceGuardHelper.source("Overture/Integration/ScoutService.swift")
        #expect(!source.isEmpty)   // a path that misses reads as "" and passes every contains guard on it
        let offenders = source
            .split(separator: "\n", omittingEmptySubsequences: false)
            .enumerated()
            .filter { $0.element.contains("try? context.fetch") }
            .map { "line \($0.offset + 1)" }
            .joined(separator: ", ")

        #expect(offenders.isEmpty, "scout reads still inventing an empty store: \(offenders)")
    }
}
