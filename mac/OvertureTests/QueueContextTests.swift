import Foundation
import Testing

// #4356 (plan v7 Phase 2): `TimeProbe` answers exactly what a plain comparison against `now` answers, and the
// instant it records is the EARLIEST at which any answer it gave would differ.
//
// Both halves matter, in opposite directions. An instant recorded too LATE is a retained row showing a stale
// answer until something unrelated rebuilds it; one recorded too EARLY is wasted rebuilds, harmless but the
// cost the engine exists to remove. So the property below checks the answers hold at every sampled instant
// before `validUntil` and that at least one of them has changed AT it.
@Suite("A time probe records exactly when its answers change (#4356)")
struct TimeProbeTests {

    /// A seeded generator, so a failure names the seed that reproduces it.
    struct Seeded: RandomNumberGenerator {
        var state: UInt64
        mutating func next() -> UInt64 {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return state
        }
    }

    enum Question {
        case passed(Date)
        case within(TimeInterval, Date)
        case today
    }

    static func ask(_ questions: [Question], at instant: Date) -> (answers: [String], probe: TimeProbe) {
        let probe = TimeProbe(now: instant)
        let answers = questions.map { question -> String in
            switch question {
            case .passed(let moment): return "\(probe.hasPassed(moment))"
            case .within(let interval, let start): return "\(probe.isWithin(interval, after: start))"
            case .today: return probe.today
            }
        }
        return (answers, probe)
    }

    @Test(arguments: Array(UInt64(1)...UInt64(40)))
    func everyAnswerHoldsUntilValidUntilAndOneChangesAtIt(seed: UInt64) {
        var random = Seeded(state: seed)
        let now = Date(timeIntervalSince1970: 1_790_000_000 + Double(random.next() % 10_000_000))
        var questions: [Question] = [.today]
        for _ in 0..<5 {
            let offset = Double(Int64(random.next() % 400_000) - 200_000)
            switch random.next() % 2 {
            case 0: questions.append(.passed(now.addingTimeInterval(offset)))
            default: questions.append(.within(Double(random.next() % 90_000), now.addingTimeInterval(offset)))
            }
        }
        let (answers, probe) = Self.ask(questions, at: now)
        guard let validUntil = probe.validUntil else {
            Issue.record("seed \(seed): a probe asked the day recorded no instant at all")
            return
        }
        #expect(validUntil > now, "seed \(seed): the recorded instant is not after the reading")
        // Sampled across the window, and one second before its end.
        let span = validUntil.timeIntervalSince(now)
        for fraction in [0.0, 0.25, 0.5, 0.75, 0.999] {
            let instant = now.addingTimeInterval(min(span * fraction, span - 1))
            #expect(Self.ask(questions, at: instant).answers == answers,
                    "seed \(seed): an answer changed before the instant the probe recorded")
        }
        #expect(Self.ask(questions, at: validUntil).answers != answers,
                "seed \(seed): nothing changed at the recorded instant, so it was recorded too early")
    }

    @Test func theAnswersAreThePlainComparisons() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let probe = TimeProbe(now: now)
        #expect(probe.hasPassed(now.addingTimeInterval(-1)) == true)
        #expect(probe.hasPassed(now) == true)
        #expect(probe.hasPassed(now.addingTimeInterval(1)) == false)
        #expect(probe.isWithin(60, after: now.addingTimeInterval(-30)) == true)
        #expect(probe.isWithin(60, after: now.addingTimeInterval(-90)) == false)
        #expect(probe.today == EasternDate.today(now))
    }

    // Overture's day is Eastern, and two days a year are not 24 hours long.
    @Test(arguments: [
        ("2026-11-01T01:30:00-04:00", "2026-11-02T00:00:00-05:00"),   // the night the clocks go back
        ("2027-03-14T01:30:00-05:00", "2027-03-15T00:00:00-04:00"),   // the night they go forward
        ("2026-10-01T23:59:59-04:00", "2026-10-02T00:00:00-04:00"),
    ])
    func theDayChangesAtTheNextEasternMidnight(reading: String, midnight: String) throws {
        let parse = ISO8601DateFormatter()
        let now = try #require(parse.date(from: reading))
        let expected = try #require(parse.date(from: midnight))
        let probe = TimeProbe(now: now)
        _ = probe.today
        #expect(probe.validUntil == expected)
        #expect(EasternDate.today(expected) != EasternDate.today(now))
        #expect(EasternDate.today(expected.addingTimeInterval(-1)) == EasternDate.today(now))
    }

    @Test func aProbeAskedNothingIsValidForever() {
        let probe = TimeProbe(now: Date(timeIntervalSince1970: 1_800_000_000))
        #expect(probe.validUntil == nil)
        #expect(!probe.readsContinuously)
        _ = probe.hasPassed(Date(timeIntervalSince1970: 1))   // a moment long gone flips nothing
        #expect(probe.validUntil == nil)
    }

    @Test func readingTheInstantItselfMakesTheEntryValidForNoTime() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let probe = TimeProbe(now: now)
        _ = probe.today
        #expect(!probe.readsContinuously)
        #expect(probe.readContinuously() == now)
        #expect(probe.readsContinuously)
        #expect(probe.validUntil == now)
    }
}

// #4356 (plan v7 Phase 2): `ContextReader` reports a context change to exactly the rows that consulted the
// field that changed. Too few is a stale row; too many is the bulk rebuild the engine exists to avoid.
@Suite("A context reader names the reads a new context invalidates (#4356)")
struct ContextReaderTests {

    struct Shared: Equatable {
        var gmailConnected = false
        var replyRunAlive = false
        var towns: Set<String> = []
    }

    @Test func aChangeToAFieldTheRowReadIsReportedAndOneItDidNotReadIsNot() {
        let reader = ContextReader(Shared(gmailConnected: true, towns: ["Hudson"]))
        #expect(reader.read(\.gmailConnected) == true)

        var other = Shared(gmailConnected: true, towns: ["Hudson"])
        other.replyRunAlive = true
        other.towns = ["Beacon"]
        #expect(reader.changedReads(in: other).isEmpty,
                "a change to fields the row never read was reported as invalidating it")

        // The positive control in the same reader: the field it did read, changed.
        other.gmailConnected = false
        #expect(reader.changedReads(in: other) == [\Shared.gmailConnected])
    }

    @Test func eachReadIsComparedWithTheValueHandedOutAndNotALaterOne() {
        let reader = ContextReader(Shared(towns: ["Hudson"]))
        #expect(reader.read(\.towns) == ["Hudson"])
        #expect(reader.read(\.towns) == ["Hudson"])
        #expect(reader.consulted == [\Shared.towns])
        #expect(reader.changedReads(in: Shared(towns: ["Hudson"])).isEmpty)
        #expect(reader.changedReads(in: Shared(towns: ["Hudson", "Beacon"])) == [\Shared.towns])
    }

    @Test func aRowThatReadNothingIsInvalidatedByNothing() {
        let reader = ContextReader(Shared())
        #expect(reader.consulted.isEmpty)
        #expect(reader.changedReads(in: Shared(gmailConnected: true, replyRunAlive: true, towns: ["x"])).isEmpty)
    }

    // Over the app's own stage context: a row that asked only the geography is untouched by a change to the
    // client window, and reported by a change to the geography.
    @Test func overTheStageContextTheGeographyAndTheClientsAreSeparateReads() {
        let before = StageContext.at("2026-10-01", now: Date(timeIntervalSince1970: 1_790_000_000))
        let reader = ContextReader(before)
        _ = reader.read(\.geo)
        let clientsMoved = StageContext.at("2026-10-01", now: before.now, geo: before.geo,
                                           clients: ClientWindow(clientSourceIds: ["source-1"]))
        #expect(reader.changedReads(in: clientsMoved).isEmpty)
        let geoMoved = StageContext.at("2026-10-01", now: before.now,
                                       geo: GeoRefusals(userExcludedTowns: ["Hudson"], allowedSeedTowns: []))
        #expect(reader.changedReads(in: geoMoved) == [\StageContext.geo])
    }
}

// #4356 (plan v7 Phase 2, "each context source with a change signal"):
//
//   1. Every input of the render pass is classified, derived from `QueueRenderPass.Inputs` and the
//      `StageContext` inside it by `Mirror`, so a new input cannot arrive unclassified (L96).
//   2. Every input classified as reaching the pass through a signal HAS one: the set of signals
//      `QueueContextSignals.start` builds is exactly the set of `.signal` inputs, both ways.
//   3. Each signal fires when its source is flipped with no save at all, on an injected copy of the app
//      object that owns the fact, and does not fire for a write that changed nothing.
@Suite("Every pass input has a source, and every signal fires on its own (#4356)")
@MainActor
struct QueueInputSourceTests {

    static func inputs() -> QueueRenderPass.Inputs {
        QueueRenderPass.Inputs(allProspects: QueueRenderPass.Corpus([]), inquiries: [], orgAnswers: [],
                               context: StageContext.at("2026-10-01", now: Date(timeIntervalSince1970: 0)))
    }

    /// Every stored property of the inputs, with the stage context's own fields as `context.<field>`.
    static func inputPaths() -> Set<String> {
        let inputs = inputs()
        var paths: Set<String> = []
        for child in Mirror(reflecting: inputs).children {
            guard let label = child.label else { continue }
            if label == "context" {
                for inner in Mirror(reflecting: inputs.context).children {
                    if let innerLabel = inner.label { paths.insert("context.\(innerLabel)") }
                }
            } else {
                paths.insert(label)
            }
        }
        return paths
    }

    @Test func everyInputIsClassifiedAndNothingElseIs() {
        let paths = Self.inputPaths()
        #expect(paths.count > 15 && paths.contains("context.geo"),
                "the walk of the pass's inputs found too little to have checked anything")
        let classified = Set(QueueInputSource.byInput.keys)
        let missing = paths.subtracting(classified).sorted()
        let extra = classified.subtracting(paths).sorted()
        #expect(missing.isEmpty, Comment(rawValue: "the pass reads these and nothing says where they come from "
            + "or how a change reaches it: " + missing.joined(separator: ", ")))
        #expect(extra.isEmpty, Comment(rawValue: "classified but not an input of the pass: "
            + extra.joined(separator: ", ")))
        let reasonless = QueueInputSource.byInput.compactMap { entry -> String? in
            if case .notAnInput(let reason) = entry.value, reason.first?.isLetter != true { return entry.key }
            return nil
        }
        #expect(reasonless.isEmpty, Comment(rawValue: "not an input, with no reason: "
            + reasonless.sorted().joined(separator: ", ")))
    }

    final class Flips: @unchecked Sendable {
        var connected = false
        var clients: [DownbeatClient] = []
        var prepLive = false
        var checkLive = false
        var replyLive = false
        var lookups: Int? = nil
        /// Each read of the lookup count, and whether a check was live when it was taken.
        var lookupReads: [Bool] = []
    }

    struct Rig {
        let flips: Flips
        let gmail: GmailConnection
        let roster: ClientRoster
        let prep: DetachedRunActivity
        let check: DetachedRunActivity
        let reply: DetachedRunActivity
        let fired: Fired
        let signals: [String: ContextSignal]
    }

    @MainActor final class Fired {
        var inputs: [String] = []
    }

    static func rig() -> Rig {
        let flips = Flips()
        let gmail = GmailConnection(load: { flips.connected })
        let roster = ClientRoster(load: { _ in (flips.clients, .ok) })
        // A sleep that yields rather than waits, so a followed run is noticed in milliseconds.
        let quick: @MainActor (TimeInterval) async -> Void = { _ in await Task.yield() }
        let prep = DetachedRunActivity(liveness: { _ in flips.prepLive }, sleep: quick)
        let check = DetachedRunActivity(liveness: { _ in flips.checkLive }, sleep: quick)
        let reply = DetachedRunActivity(liveness: { _ in flips.replyLive }, sleep: quick)
        let fired = Fired()
        let signals = QueueContextSignals.start(
            QueueContextSignals.Sources(gmail: gmail, roster: roster, prep: prep, check: check, reply: reply,
                                        checkLookups: {
                                            flips.lookupReads.append(flips.checkLive)
                                            return flips.lookups
                                        },
                                        sleep: { _ in try? await Task.sleep(for: .milliseconds(5)) }),
            onChange: { fired.inputs.append($0) })
        return Rig(flips: flips, gmail: gmail, roster: roster, prep: prep, check: check, reply: reply,
                   fired: fired, signals: signals)
    }

    @Test func thereIsASignalForExactlyTheInputsClassifiedAsArrivingByOne() {
        let rig = Self.rig()
        defer { rig.signals.values.forEach { $0.cancel() } }
        let wanted = Set(QueueInputSource.byInput.filter { $0.value == .signal }.keys)
        #expect(!wanted.isEmpty, "no input is classified as arriving by a signal, so nothing was compared")
        #expect(Set(rig.signals.keys) == wanted)
    }

    @Test func gmailDisconnectingFiresItsSignalWithNoSave() async {
        let rig = Self.rig()
        defer { rig.signals.values.forEach { $0.cancel() } }
        let signal = rig.signals["gmailConnected"]
        // Two writes that end where they started, before the signal looks: a write happened, nothing changed,
        // and the signal must look and fire nothing.
        rig.flips.connected = true
        rig.gmail.refresh()
        rig.flips.connected = false
        rig.gmail.refresh()
        let looked = await waitUntil("the Gmail signal looks at the round trip") { (signal?.looks ?? 0) >= 1 }
        #expect(looked)
        #expect(!rig.fired.inputs.contains("gmailConnected"), "a round trip that changed nothing fired the signal")
        // And a real change fires it, once.
        rig.flips.connected = true
        rig.gmail.refresh()
        let fired = await waitUntil("the Gmail signal fires") { rig.fired.inputs.contains("gmailConnected") }
        #expect(fired)
        #expect(rig.fired.inputs.filter { $0 == "gmailConnected" }.count == 1)
    }

    @Test func theRosterReloadingWithNewClientsFiresTheClientWindowSignal() async {
        let rig = Self.rig()
        defer { rig.signals.values.forEach { $0.cancel() } }
        rig.roster.reload(now: Date(timeIntervalSince1970: 1_790_000_000))
        rig.flips.clients = [DownbeatClient(id: "client-1", displayName: "An Invented Ensemble", shortName: nil,
                                            email: "", contractEmail: "", phoneNumber: nil, isTaxExempt: nil,
                                            hasLeftReview: false, specialBehaviors: [], notes: nil,
                                            hostingSite: "")]
        rig.roster.reload(now: Date(timeIntervalSince1970: 1_790_000_100))
        let fired = await waitUntil("the client window signal fires") {
            rig.fired.inputs.contains("context.clients")
        }
        #expect(fired)
        #expect(rig.fired.inputs.filter { $0 == "context.clients" }.count == 1,
                "a reload that read the same clients fired the signal as well")
    }

    @Test func aRunStartingAndEndingFiresEachSlotsSignals() async {
        let rig = Self.rig()
        defer { rig.signals.values.forEach { $0.cancel() } }
        rig.flips.checkLive = true
        rig.check.runStarted()
        let started = await waitUntil("the check slot's signals fire on its start") {
            Set(rig.fired.inputs).isSuperset(of: ["checkSlotRunning", "runInFlight", "checkRunSince"])
        }
        #expect(started)
        #expect(!rig.fired.inputs.contains("prepSlotRunning"), "the prep slot fired for a check starting")

        rig.flips.checkLive = false
        let followed = Task { await rig.check.followUntilFinished() }
        _ = await followed.value
        let ended = await waitUntil("the check slot's signal fires on its end") {
            rig.fired.inputs.filter { $0 == "checkSlotRunning" }.count == 2
        }
        #expect(ended)

        rig.flips.prepLive = true
        rig.prep.runStarted()
        rig.flips.replyLive = true
        rig.reply.runStarted()
        let others = await waitUntil("the prep and reply signals fire") {
            Set(rig.fired.inputs).isSuperset(of: ["prepSlotRunning", "replyRunAlive"])
        }
        #expect(others)
    }

    @Test func theLookupCountIsReadOnlyWhileACheckRunsAndFiresWhenItMoves() async {
        let rig = Self.rig()
        defer { rig.signals.values.forEach { $0.cancel() } }
        rig.flips.lookups = 3
        rig.flips.checkLive = true
        rig.check.runStarted()
        rig.flips.lookups = 7
        let fired = await waitUntil("the lookup count signal fires during a check") {
            rig.fired.inputs.contains("checkLookups")
        }
        #expect(fired)
        // Every read after the signal's first, which takes the starting value, came while a check was live:
        // an idle queue pays nothing for this count (#1923's rule).
        let idleReads = rig.flips.lookupReads.dropFirst().filter { !$0 }.count
        #expect(idleReads == 0, "the lookup count was read while no check was running")
        #expect(rig.flips.lookupReads.dropFirst().contains(true), "no read was taken during the check")

        // When the check ends, the polling stops rather than reading the marker for ever.
        rig.flips.checkLive = false
        _ = await rig.check.followUntilFinished()
        let stopped = await waitUntil("the lookup count stops being polled once the check ends") {
            rig.signals["checkLookups"]?.isPolling == false
        }
        #expect(stopped)
    }
}
