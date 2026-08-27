import Testing
import Foundation
import SwiftData

// #1685: cancelling a check stops the WAITING, not the SPENDING.
//
// Measured on the #1601 Phase 8 walk, 2026-07-28. Dan started a check on 5 shows and cancelled it as soon
// as the panel read "1 of 5 done". Its own recorded figures: five streams all reporting, 66 seconds,
// one usable answer. The four lookups killed mid-flight had already done most of their work and produced
// nothing, and were paid for anyway.
//
// Cancel reads as "stop this", and on a paid action a reasonable person hears "stop this before it costs
// me". Nothing said otherwise, and when the run settled it read like any other short run. Two things fix
// that honestly: the control says what it actually does, and the settled run says what it bought.
@Suite("What a cancelled check costs and says (#1685)")
struct CancelledCheckSpendTests {

    // Dan's own run, exactly as measured. A cancelled check must not report itself the way an ordinary
    // short run does: it has to name the cancel, and say the lookups already running were paid for.
    @Test func acancelledCheckSaysWhatItBoughtAndThatItWasPaidFor() {
        let report = ReachabilityRunReport(requested: 5, answered: 1, outcome: nil, cancelled: true)
        let message = try! #require(report.attentionMessage)

        #expect(message.contains("stopped"), "it must name the stop, not read as an ordinary short run")
        #expect(message.contains("1 of 5"), "it must say what the run actually bought")
        #expect(message.lowercased().contains("spent") || message.lowercased().contains("paid"),
                "it must say the lookups already running were paid for")
    }

    // The whole point of the sentence: it must not describe the cancelled shows as merely waiting, which
    // is what an uncancelled short run says about them.
    @Test func acancelledCheckDoesNotReuseTheOrdinaryShortfallSentence() {
        let cancelled = ReachabilityRunReport(requested: 5, answered: 1, outcome: nil, cancelled: true)
        let ordinary = ReachabilityRunReport(requested: 5, answered: 1, outcome: nil)

        #expect(cancelled.attentionMessage != ordinary.attentionMessage,
                "a cancelled run and a run that came home short are different facts")
        #expect(ordinary.attentionMessage?.contains("stopped") != true,
                "a run nobody cancelled must never claim it was stopped")
    }

    // A cancel that lands before any answer came back still has something to say, because the lookups
    // that were running were paid for regardless.
    @Test func acancelledCheckWithNoAnswersStillSaysItSpent() {
        let report = ReachabilityRunReport(requested: 4, answered: 0, outcome: nil, cancelled: true)
        let message = try! #require(report.attentionMessage)

        #expect(message.contains("4"), "it must say how many shows the check was given")
        #expect(message.lowercased().contains("before any"),
                "it must be honest that nothing came back, never phrased as though some did")
        #expect(!message.lowercased().contains(" after "),
                "\"after N got an answer\" is the sentence for a run that bought something")
        #expect(message.lowercased().contains("spent") || message.lowercased().contains("paid"))
    }

    // A cancel that arrives after everything was answered bought the lot. There is no shortfall and
    // nothing to warn about, so this slot stays silent rather than nagging about a complete run (L36).
    @Test func acancelledCheckThatStillAnsweredEverythingSaysNothing() {
        let report = ReachabilityRunReport(requested: 3, answered: 3, outcome: nil, cancelled: true)

        #expect(report.attentionMessage == nil)
    }

    // Never in dollars. Dan's standing rule on a Max plan (2026-07-27): the app talks about what a run
    // costs in plain terms, never a figure, because a dollar number on a plan he has already paid for is
    // both wrong and the wrong thing to think about.
    @Test func nocopyHerePutsAFigureOnIt() {
        let messages = [
            ReachabilityRunReport(requested: 5, answered: 1, outcome: nil, cancelled: true).attentionMessage,
            ReachabilityRunReport(requested: 4, answered: 0, outcome: nil, cancelled: true).attentionMessage,
            ReachabilityProbeCopy.cancelSpendCaveat
        ].compactMap { $0 }

        for message in messages {
            #expect(!message.contains("$"), "no dollar figure: \(message)")
            #expect(!message.contains("cost you"), "no price talk: \(message)")
        }
    }

    // The control itself. A person deciding whether to press Cancel has to know, before pressing it, that
    // it does not call back the lookups already running.
    @Test func thecancelControlSaysWhatItActuallyDoes() {
        let caveat = ReachabilityProbeCopy.cancelSpendCaveat

        #expect(caveat.lowercased().contains("under way") || caveat.lowercased().contains("already"),
                "it must name the lookups that are already running")
        #expect(!caveat.isEmpty)
    }

    // The rule and its WIRING are two claims (#887). Everything above is inert unless the settle actually
    // discovers that this run was stopped, and it learns that from the same cancel sentinel the runner
    // itself obeys, so the two can never disagree about whether a stop was requested.
    @MainActor
    @Test func thesettleReportsACheckAsCancelledWhenTheStopWasRequested() throws {
        let ctx = ModelContext(try ModelContainer(
            for: Schema([Prospect.self, Recipient.self, OrgReachabilityAnswer.self]),
            configurations: [ModelConfiguration(isStoredInMemoryOnly: true)]))
        let key = Prospect.makeNaturalKey(groupName: "Aurora Strings", performanceDate: "2026-09-12",
                                          venue: "Weill Recital Hall")
        ctx.insert(Prospect(naturalKey: key, groupName: "Aurora Strings", discipline: "music",
                            venue: "Weill Recital Hall", performanceDate: "2026-09-12",
                            sourceListingURL: nil, priorRelationship: "none",
                            production: "self", profile: "strong", coverage: "likely_uncovered",
                            fitScore: 5, tier: "mid", fitReason: "r", matchedClientName: nil,
                            possibleMatchSource: nil, possibleMatchName: nil))
        try ctx.save()

        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let markerURL = dir.appendingPathComponent("probe-run.json")
        let resultsURL = dir.appendingPathComponent("results.json")
        let cancelURL = dir.appendingPathComponent("prep-cancel")

        // Two shows asked for, neither answered, and the stop sentinel present: Dan pressed Cancel.
        let second = Prospect.makeNaturalKey(groupName: "Bellwether Quartet",
                                             performanceDate: "2026-09-12", venue: "Weill Recital Hall")
        try ReachabilityProbeMarker.write(ReachabilityProbeMarker(keys: [key, second], startedAt: "s"),
                                          to: markerURL)
        try JSONEncoder().encode(PrepResults(version: 2, generatedAt: "now", results: []))
            .write(to: resultsURL)
        try Data().write(to: cancelURL)

        let report = try #require(PrepQueueService.settleReachabilityProbe(slot: .check, 
            markerURL: markerURL, resultsURL: resultsURL,
            queueURL: dir.appendingPathComponent("queue.json"),
            downbeatURL: dir.appendingPathComponent("downbeat.json"),
            historyURL: dir.appendingPathComponent("history.json"),
            cancelURL: cancelURL,
            into: ctx, now: Date(timeIntervalSince1970: 1_780_000_000),
            defaults: UserDefaults(suiteName: UUID().uuidString)!))

        #expect(report.cancelled, "the settle must notice the stop the runner was obeying")
        #expect(report.attentionMessage?.contains("stopped") == true)
    }

    // The other half of the same wiring: with no stop requested, the run must never claim it was stopped.
    // A guard that answers the same way whatever it is given protects nothing.
    @MainActor
    @Test func thesettleDoesNotCallAnOrdinaryCheckCancelled() throws {
        let ctx = ModelContext(try ModelContainer(
            for: Schema([Prospect.self, Recipient.self, OrgReachabilityAnswer.self]),
            configurations: [ModelConfiguration(isStoredInMemoryOnly: true)]))
        let key = Prospect.makeNaturalKey(groupName: "Aurora Strings", performanceDate: "2026-09-12",
                                          venue: "Weill Recital Hall")
        ctx.insert(Prospect(naturalKey: key, groupName: "Aurora Strings", discipline: "music",
                            venue: "Weill Recital Hall", performanceDate: "2026-09-12",
                            sourceListingURL: nil, priorRelationship: "none",
                            production: "self", profile: "strong", coverage: "likely_uncovered",
                            fitScore: 5, tier: "mid", fitReason: "r", matchedClientName: nil,
                            possibleMatchSource: nil, possibleMatchName: nil))
        try ctx.save()

        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let markerURL = dir.appendingPathComponent("probe-run.json")
        let resultsURL = dir.appendingPathComponent("results.json")

        try ReachabilityProbeMarker.write(ReachabilityProbeMarker(keys: [key], startedAt: "s"),
                                          to: markerURL)
        try JSONEncoder().encode(PrepResults(version: 2, generatedAt: "now", results: []))
            .write(to: resultsURL)

        let report = try #require(PrepQueueService.settleReachabilityProbe(slot: .check, 
            markerURL: markerURL, resultsURL: resultsURL,
            queueURL: dir.appendingPathComponent("queue.json"),
            downbeatURL: dir.appendingPathComponent("downbeat.json"),
            historyURL: dir.appendingPathComponent("history.json"),
            cancelURL: dir.appendingPathComponent("prep-cancel"),
            into: ctx, now: Date(timeIntervalSince1970: 1_780_000_000),
            defaults: UserDefaults(suiteName: UUID().uuidString)!))

        #expect(!report.cancelled)
        #expect(report.attentionMessage?.contains("stopped") != true)
    }
}
