import Testing
import Foundation

// #3793: the housekeeping report reaches a surface.
//
// #3763 shipped `FreezeLog.housekeeping(at:now:)` and `FreezeHousekeepingCopy.notice(_:)`, and the launch
// call threw the report away with #3793 named beside it. So every sentence was written, tested and read
// cold, and none of them could ever be said: a value written and never read looks alive to every
// is-this-used check while the purpose it was added for silently never happens (L46, L3).
//
// WHAT THIS SUITE ADDS that the copy tests beside it cannot. Those construct `Housekeeping` values by hand
// and ask what the sentence says. This runs the real launch call against a real directory in the states
// that matter, the two FAILURE states most of all, and asks whether a line actually arrives on the
// masthead. A copy test and its wiring are two separate claims (#887), and the failure states are the ones
// that were silent: an archive that cannot be written means the live log is no longer bounded, and an
// archive holding lines nothing can decode means nothing will ever be removed from it.
@Suite("The freeze log's housekeeping reaches Dan (#3793)")
final class FreezeHousekeepingReachesDanTests {

    private let sandboxes = TemporarySandboxes()

    private func stall(_ seconds: Double, sequence: Int,
                       at: Date = Date(timeIntervalSince1970: 1_785_000_000)) -> StallRecord {
        StallRecord(session: "s", sequence: sequence, at: at, seconds: seconds,
                    surface: .queue, load: .baseline, loadAverage: 1.0, passes: nil)
    }

    // Written through `append`, the way the watchdog writes them, so this exercises the real file shape
    // rather than a string this test composed and therefore agrees with (L48).
    private func writeLog(_ records: [StallRecord], to url: URL) {
        for record in records { _ = FreezeLog.append(record, to: url) }
    }

    // The masthead's lines, exactly as `QueueView` is handed them, so this asserts about what Dan reads
    // rather than about a value on its way there.
    private func notices(_ done: FreezeLog.Housekeeping,
                         status: StatusLine = StatusLine()) -> [AppNotice] {
        AppNotices.current(freezeHousekeeping: done, status: status)
    }

    // THE SERIOUS ONE. The archive could not be written, so `compact` deliberately refuses to trim and the
    // live log keeps growing past its cap for as long as that lasts. Blocked by putting a DIRECTORY at the
    // archive's path, which is a real thing the filesystem hands back rather than an injected failure the
    // production code knows about.
    @Test("an archive that could not be written puts a line on the masthead")
    func aFailedArchiveIsSaidOnTheMasthead() throws {
        let dir = try sandboxes.make(named: "freeze-housekeeping-blocked")
        let log = FreezeLog.url(in: dir)
        writeLog((0..<10).map { stall(Double($0) * 0.1 + 0.2, sequence: $0 + 1) }, to: log)
        try FileManager.default.createDirectory(at: FreezeLog.archiveURL(besideLogAt: log),
                                                withIntermediateDirectories: false)

        let done = FreezeLog.housekeeping(at: log, now: Date(timeIntervalSince1970: 1_785_000_000), cap: 4)
        #expect(done.compaction == .archiveFailed,
                "this did not reach the failing archive, so it proves nothing either way")

        let lines = notices(done)
        #expect(lines.map(\.text).contains(FreezeHousekeepingCopy.archiveFailed),
                Comment(rawValue: "the log is growing unbounded and the masthead says nothing about it: "
                        + "\(lines.map(\.text))"))
        #expect(lines.first(where: { $0.text == FreezeHousekeepingCopy.archiveFailed })?.tone == .warning,
                "a log nobody is bounding was drawn as a receipt, which is safe to miss")
    }

    // The other failure. The archive holds lines that could not be decoded, so the prune refuses rather
    // than destroying them in its rewrite, and nothing will ever be removed until somebody looks.
    @Test("an archive holding lines nothing can read puts a line on the masthead")
    func aRefusedPruneIsSaidOnTheMasthead() throws {
        let dir = try sandboxes.make(named: "freeze-housekeeping-unreadable")
        let log = FreezeLog.url(in: dir)
        writeLog([stall(0.3, sequence: 1)], to: log)
        try "not json at all\nnor is this\n".write(to: FreezeLog.archiveURL(besideLogAt: log),
                                                   atomically: true, encoding: .utf8)

        let done = FreezeLog.housekeeping(at: log, now: Date(timeIntervalSince1970: 1_785_000_000))
        #expect(done.prune == .refused(unreadableLines: 2),
                "this did not reach the refusal, so it proves nothing either way")

        let texts = notices(done).map(\.text)
        #expect(texts.contains(FreezeHousekeepingCopy.pruneRefused(lines: 2)),
                Comment(rawValue: "a damaged archive nothing can prune said nothing: \(texts)"))
    }

    // The destructive one. A prune permanently deletes records, so it accounts for itself with the span
    // they covered: a retention policy that deletes in silence is indistinguishable from a quiet month
    // (L9, L98).
    @Test("records the month prune deleted are accounted for on the masthead")
    func aPruneIsAccountedForOnTheMasthead() throws {
        let dir = try sandboxes.make(named: "freeze-housekeeping-pruned")
        let log = FreezeLog.url(in: dir)
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let day: TimeInterval = 60 * 60 * 24
        let window = Double(FreezeLog.archiveRetentionDays) * day
        // Derived from the retention constant rather than written as a literal beside it, so the day that
        // constant moves these fixtures still mean what their names say (L401).
        let old = [stall(0.5, sequence: 1, at: now.addingTimeInterval(-window - day)),
                   stall(0.6, sequence: 2, at: now.addingTimeInterval(-window - 90 * day))]
        writeLog([stall(0.3, sequence: 3)], to: log)
        _ = FreezeLog.archive(old, besideLogAt: log)

        let done = FreezeLog.housekeeping(at: log, now: now)
        let texts = notices(done).map(\.text)
        #expect(texts.contains(where: { $0.contains("2 freeze records were deleted") }),
                Comment(rawValue: "two records were permanently deleted and nothing said so: \(texts)"))
        #expect(texts.contains(where: { $0.contains(FreezeHousekeepingCopy.keepsAMonth) }),
                Comment(rawValue: "the deletion was reported without saying what the rule is: \(texts)"))
    }

    // A launch that lost nothing and refused nothing adds NO row. A notice that speaks on every launch is
    // the noise that teaches a person to stop reading notices.
    @Test("an ordinary launch adds no line at all")
    func anOrdinaryLaunchIsSilent() throws {
        let dir = try sandboxes.make(named: "freeze-housekeeping-quiet")
        let log = FreezeLog.url(in: dir)
        writeLog([stall(0.3, sequence: 1)], to: log)

        let done = FreezeLog.housekeeping(at: log, now: Date(timeIntervalSince1970: 1_785_000_000))
        #expect(done == FreezeLog.Housekeeping(),
                "this did not exercise the quiet launch, so it proves nothing either way")
        #expect(notices(done).isEmpty,
                "a launch that lost nothing still added a row to the masthead")
    }

    // WHY THIS IS NOT WRITTEN INTO THE STATUS SLOT, pinned so the reason cannot be lost to a later
    // simplification. That slot holds ONE message, and `StatusLine.set` lets an equal priority write
    // replace what is there, so a housekeeping warning written into it would either destroy the freeze
    // report or be destroyed by it. The freeze report is said ONCE per record and remembers in defaults
    // what it has said, so one it loses can never be said again, and a prune's sentence is the only
    // account of a permanent deletion. Both have to survive the same launch (L11, #2204's own finding
    // about one slot hiding another).
    @Test("the housekeeping line never displaces what the freeze report had to say")
    func theHousekeepingLineDoesNotDisplaceTheFreezeReport() {
        var status = StatusLine()
        let freeze = "Overture stopped responding twice in the last session."
        status.set(freeze, priority: .warning)

        let texts = notices(FreezeLog.Housekeeping(compaction: .archiveFailed), status: status)
            .map(\.text)

        #expect(texts.contains(freeze),
                Comment(rawValue: "the freeze report was erased by the line about its own log: \(texts)"))
        #expect(texts.contains(FreezeHousekeepingCopy.archiveFailed),
                Comment(rawValue: "the housekeeping line lost the slot to the freeze report: \(texts)"))
        // ORDER: the freezes themselves before the bookkeeping about the record of them, which is what the
        // cold read asked for. Reversed, the masthead opens by saying the oldest freeze records could not
        // be set aside, before anything has said there were any.
        #expect(texts.firstIndex(of: freeze) ?? 0 < texts.firstIndex(of: FreezeHousekeepingCopy.archiveFailed) ?? 0,
                Comment(rawValue: "the bookkeeping is read before its own subject: \(texts)"))
    }

    // THE WIRING, which no behavioural test above can see: the launch call has to stop discarding the
    // report and hand it to the masthead. Its whole absence was this issue.
    // Each answer is reduced to a Bool BEFORE it is asserted on. A failing expectation renders its
    // operands, so `#expect(rootView.contains(...))` prints the whole of RootView.swift and buries the
    // sentence explaining what went wrong (L445). Measured on this suite's own first red run.
    @Test("the launch call no longer discards the housekeeping report")
    func theLaunchCallKeepsTheReport() {
        let rootView = SourceGuardHelper.source("Overture/App/RootView.swift")
        let wasRead = !rootView.isEmpty
        let stillDiscarded = rootView.contains("_ = FreezeLog.housekeeping")
        let kept = rootView.contains("freezeHousekeeping = FreezeLog.kept(")
        let handedOn = rootView.contains("freezeHousekeeping: freezeHousekeeping")

        #expect(wasRead, "RootView.swift could not be read, so these guards protect nothing")
        #expect(!stillDiscarded,
                "the launch call still throws the report away, so none of these sentences can be said")
        #expect(kept, "nothing keeps what the housekeeping did")
        #expect(handedOn,
                "the report is kept and never handed to the masthead, which is the same silence")
    }

    // MARK: - what a LATER run may do to an earlier report

    // #3796 made housekeeping run hourly as well as at launch, and #3793 keeps what it reports. Those two
    // compose into a hazard neither carries alone: a quiet run replacing a report that had something to
    // say. A quiet run is the overwhelmingly common one, so without this rule the launch report that
    // recorded a permanent deletion would be wiped an hour later, unread. That is #3830's defect arriving
    // as a side effect of fixing a different issue (L387).
    private var quiet: FreezeLog.Housekeeping { FreezeLog.Housekeeping() }

    private var loud: FreezeLog.Housekeeping {
        FreezeLog.Housekeeping(compaction: .nothingToArchive,
                               prune: .removed(count: 2,
                                               earliest: Date(timeIntervalSince1970: 1_700_000_000),
                                               latest: Date(timeIntervalSince1970: 1_700_086_400)))
    }

    @Test("a quiet run does not wipe a report that had something to say")
    func aQuietRunKeepsTheEarlierReport() {
        #expect(FreezeLog.kept(loud, after: quiet) == loud,
                "an hourly run with nothing to say erased the record of a permanent deletion")
    }

    @Test("a run with something to say replaces what was held")
    func aLoudRunReplacesIt() {
        #expect(FreezeLog.kept(quiet, after: loud) == loud)
        #expect(FreezeLog.kept(nil, after: loud) == loud, "the first thing to say never reached the state")
    }

    // The other direction, asserted in the SAME fixture: a rule that kept the current value whatever
    // arrived would satisfy the case above perfectly and never show Dan anything at all (L159).
    @Test("a quiet run over nothing stays nothing, rather than inventing a notice")
    func aQuietRunOverNothingIsStillNothing() {
        #expect(FreezeLog.kept(nil, after: quiet) == nil)
        #expect(quiet.isQuiet)
        #expect(!loud.isQuiet, "a permanent deletion read as nothing worth saying")
    }
}
