import Testing
import Foundation

// #3815: a stall record says how MANY render passes it spanned and never how LONG they took, so the
// field cannot answer the question this milestone is now asking of it.
//
// READ 2026-09-12 across the live log plus the archive, 1,040 records: the most passes any stall ever
// spanned is 2, and the three longest stalls (29.354s, 19.177s, 15.855s) each spanned exactly 1. That
// reading has two incompatible explanations and nothing in the record chooses between them:
//
//   1. one render pass ran for 29 seconds, so the pass IS the freeze and this milestone is aimed right;
//   2. one ordinary render pass ran and the other 29 seconds went somewhere else, so the pass is roughly
//      0.6 percent of the freeze and the milestone has been optimising a term that was never the problem.
//
// Those call for opposite work. `QueueRenderPassLiveStoreCostTests` prices a pass at roughly 172 ms on a
// read-only clone, but that is a HEALTHY pass on a quiet machine, and using it to turn a pass count into
// a share of a freeze is arithmetic performed on somebody else's measurement (L107).
//
// SO THE TWO ARE SEPARATE TERMS on the record, never a ratio: a ratio hides a zero-pass stall, and `0` is
// already the reading that needs care (#3783).
//
// WHAT THE DURATION CANNOT SAY, and it is the mirror of what the count cannot say. The cost is added when
// a pass RETURNS, and the count is bumped when it STARTS. A pass that never returns, which is the wedged
// main thread this whole instrument exists for, therefore contributes to `passes` and not to
// `passSeconds`. That difference is the signal rather than a gap: a 29s stall spanning one pass of 0.17s
// is explanation 2, and the same stall spanning one pass whose seconds never arrive is explanation 1.
@MainActor
@Suite("A stall says how long its render passes took (#3815)")
struct AStallSaysHowLongItsPassesTookTests {

    private final class Records: @unchecked Sendable {
        private let lock = NSLock()
        private var items: [StallRecord] = []
        func add(_ r: StallRecord) { lock.withLock { items.append(r) } }
        var all: [StallRecord] { lock.withLock { items } }
    }

    private static let interval = 0.05
    private static let freeze = 0.6

    // MARK: - the pure rule, where every outcome can be PRODUCED rather than waited for (L151)

    @Test func aspanIsTheDifferenceBetweenTwoReadings() {
        #expect(StallLog.passSecondsSpanned(from: 1.0, to: 1.75) == 0.75)
    }

    // NOTHING COUNTED YET is not zero seconds. A process where no pass has ever been timed must leave the
    // field absent, or "no pass ran during this stall" and "nobody was timing" become one claim (L98, L11).
    @Test func areadingTakenBeforeAnythingWasTimedIsAbsent() {
        #expect(StallLog.passSecondsSpanned(from: nil, to: nil) == nil)
    }

    // The first timed pass of a process: nothing before, something after. That is a real span from zero.
    @Test func afirstTimedPassSpansFromNothing() {
        #expect(StallLog.passSecondsSpanned(from: nil, to: 0.25) == 0.25)
    }

    // A reading that went BACKWARDS is a fault in the instrument, not a pass that un-ran, so it is
    // reported as unmeasured rather than as a negative duration (L11).
    @Test func areadingThatWentBackwardsIsUnmeasured() {
        #expect(StallLog.passSecondsSpanned(from: 2.0, to: 1.0) == nil)
    }

    // MARK: - the wiring, driven through the real watchdog

    @Test func afreezeSpanningATimedPassRecordsHowLongItTook() async {
        let records = Records()
        let watchdog = MainThreadWatchdog(session: "pass-cost", interval: Self.interval,
                                          loadReading: { (.baseline, 0) },
                                          record: { records.add($0) })
        // One timed pass BEFORE the watchdog starts, so the figure under test is a DIFFERENCE rather than
        // a process total: a reading that returned the total would pass a test that started at nothing.
        watchdog.passCost.add(seconds: 5.0)
        watchdog.start()

        let cost = watchdog.passCost
        let passes = watchdog.passes
        let freeze = Self.freeze
        DispatchQueue.main.async {
            // The main thread occupied by a pass that takes most of the freeze, which is explanation 1.
            let started = Date()
            Thread.sleep(forTimeInterval: freeze)
            passes.bump()
            cost.add(seconds: Date().timeIntervalSince(started))
        }

        await waitUntil("a stall to be recorded", timeout: .seconds(20)) { !records.all.isEmpty }
        watchdog.stop()

        let seconds = records.all.map(\.passSeconds)
        #expect(seconds.allSatisfy { $0 != nil },
                "a record carried no pass duration at all, so the field is unwired (#3815)")
        #expect(seconds.contains { ($0 ?? 0) > 0 },
                Comment(rawValue: "no record carried any pass time, though a pass of about "
                        + "\(Self.freeze)s ran inside the freeze (#3815)"))
        // Never the process TOTAL, which is what a reading that forgot to subtract would give: 5 seconds
        // were added before the watchdog started and no freeze here is that long.
        #expect(seconds.allSatisfy { ($0 ?? 0) < 5.0 },
                "a record carried the process total rather than the span of this stall")
    }

    @Test func afreezeInAProcessThatNeverTimedAPassRecordsNothingRatherThanZero() async {
        let records = Records()
        let watchdog = MainThreadWatchdog(session: "no-pass-cost", interval: Self.interval,
                                          loadReading: { (.baseline, 0) },
                                          record: { records.add($0) })
        watchdog.start()
        DispatchQueue.main.async { Thread.sleep(forTimeInterval: Self.freeze) }

        await waitUntil("a stall to be recorded", timeout: .seconds(20)) { !records.all.isEmpty }
        watchdog.stop()

        #expect(records.all.allSatisfy { $0.passSeconds == nil },
                Comment(rawValue: "a process that never timed a pass recorded a duration, so "
                        + "\"no pass ran\" and \"nobody was timing\" are one reading (#3815, L98)."))
    }

    // MARK: - the call sites, enumerated from the source rather than from memory

    // The call that reports a pass's cost. One spelling, so this guard and the app cannot drift.
    private static let report = "freezeWatch?.recordPassCost("

    // Every file that RUNS a lifted render pass, derived from the `enum *RenderPass` declarations the app
    // holds rather than from a list somebody maintains (L96). Its own enumeration rather than a share of
    // `EveryRenderPassIsCountedTests`': that suite asks whether a pass is COUNTED, this one asks whether
    // it is TIMED, and a helper shared between them would make one change answer both questions.
    private static func filesRunningAPass() -> [(name: String, text: String)] {
        let sources = AppSourceWalk.urls(under: RepoRoot.mac.appendingPathComponent("Overture"))
            .compactMap { url -> (name: String, text: String)? in
                guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
                return (url.lastPathComponent, text)
            }
        var passes: Set<String> = []
        for file in sources {
            for line in file.text.components(separatedBy: "\n") {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                guard trimmed.hasPrefix("enum "), trimmed.hasSuffix("RenderPass {") else { continue }
                passes.insert(String(trimmed.dropFirst("enum ".count).dropLast(" {".count)))
            }
        }
        return sources.filter { file in passes.contains { file.text.contains("\($0).make(") } }
    }

    // A pass that is counted and not timed puts a record into the log carrying a count this field cannot
    // speak for, and the whole point of the pair is that the two terms describe the same passes. A rule
    // each call site has to opt into reaches nothing in exactly the case it matters (L27, L621), so it is
    // a guard rather than a comment.
    @Test func everyfileThatRunsAPassAlsoReportsHowLongItTook() {
        let files = Self.filesRunningAPass()
        // UNMEASURED is its own outcome: an enumeration that resolved nothing reads exactly like an app
        // where every pass is timed (L98).
        #expect(files.count >= 2, """
            this guard found \(files.count) file(s) running a render pass, which is fewer than the app \
            has, so nothing below was measured (#3815, L98).
            """)
        let untimed = files.filter { !$0.text.contains(Self.report) }.map(\.name)
        #expect(untimed.isEmpty, """
            \(untimed.joined(separator: ", ")) runs a render pass and never calls \(Self.report). Its \
            passes are COUNTED on a stall record and not timed, so a stall spanning them says how many \
            ran and nothing about whether they account for the freeze, which is the question this field \
            exists to answer (#3815).
            """)
    }

    // MARK: - what the timing itself costs, measured before it ships (L353)

    // This adds work to the path the milestone is trying to SHORTEN, so an estimate will not do: a
    // comment saying it is surely negligible is a measurement nobody took.
    //
    // Judged as a SHARE of the pass it sits inside, in the same run, never against a fixed millisecond
    // figure, which would measure what else this Mac is running (L224). The comparison arm is a real
    // derivation over a corpus rather than an empty loop, so the denominator is a pass rather than a
    // number chosen to flatter the result.
    private static let allowedShareOfAPass = 0.01

    @Test func timingApassCostsAlmostNothingOfThePass() {
        let watch = FreezeWatch()
        let rounds = 2_000

        // The report path exactly as a pass runs it: two uptime readings and the lock-protected add.
        // Stood down (no watchdog), which is the CHEAPER arm, so this is measured with the watch running
        // below as well; a figure taken only while the work is switched off measures the short circuit
        // (L102).
        let timingStart = Date()
        for _ in 0..<rounds {
            let began = DispatchTime.now().uptimeNanoseconds
            watch.recordPassCost(
                seconds: Double(DispatchTime.now().uptimeNanoseconds - began) / 1_000_000_000)
        }
        let timing = Date().timeIntervalSince(timingStart) / Double(rounds)

        // The denominator: one pass's worth of real work, taken in the same run on the same machine so
        // the two are comparable whatever else is going on (L224). Still far SMALLER than a real pass,
        // which makes the share an OVERSTATEMENT: the live-store pass is about 172 ms and this arm is
        // about 0.2 ms, so the timing looks roughly a thousand times more expensive here than it is in
        // the app, and the ceiling is met with room to spare anyway.
        //
        // Sized up from 200 inner iterations after the first reading came out at 0.90% against a 1.0%
        // ceiling: a threshold that a healthy run sits on the edge of is noise rather than a guard
        // (L172). At this size the same work reads about a tenth of that.
        let passStart = Date()
        var sink = 0
        for _ in 0..<rounds {
            for n in 0..<2_000 { sink &+= n * n }
        }
        let pass = Date().timeIntervalSince(passStart) / Double(rounds)
        #expect(sink != 0, "the comparison arm was optimised away, so there is no denominator")

        let share = timing / pass
        print("""
        pass-timing-cost (#3815)
          one report          \(String(format: "%.3f", timing * 1_000_000)) us
          one comparison pass \(String(format: "%.3f", pass * 1_000_000)) us
          share               \(String(format: "%.4f", share * 100))%
          ceiling             \(Self.allowedShareOfAPass * 100)% of a pass this size
        """)
        #expect(share < Self.allowedShareOfAPass,
                Comment(rawValue: "timing a pass costs \(String(format: "%.2f", share * 100))% of one, "
                        + "against a ceiling of \(Self.allowedShareOfAPass * 100)%. This runs on the "
                        + "path milestone 80 exists to shorten, so it has to be a rounding error on it "
                        + "(#3815, L353)."))
    }

    // MARK: - a record written before this field existed still decodes

    // Dan's log holds a thousand records with no `passSeconds` key, and they are milestone 80's own
    // "before" half, so a decode that rejected them would destroy the comparison this field exists to
    // enable (L133).
    @Test func arecordWrittenBeforeThisFieldDecodes() throws {
        let json = """
        {"session":"s","sequence":1,"at":768000000,"seconds":1.5,"surface":"queue",\
        "load":"baseline","loadAverage":2.0,"passes":1}
        """
        let decoder = JSONDecoder()
        let record = try decoder.decode(StallRecord.self, from: Data(json.utf8))
        #expect(record.passSeconds == nil, "an absent duration decoded as something other than absent")
        #expect(record.passes == 1, "the rest of the record did not survive the decode")
    }
}
