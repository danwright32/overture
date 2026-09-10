import Testing
import Foundation

// #3496: the two live-store duplicate suites assert an invariant that a SCHEDULED repair restores, so
// between two launches the violated state is the store's ORDINARY one and the suite reports the interval
// rather than a defect (L385). They go red on any day the scout ran before a launch, on the mandatory
// pre-push gate, which is the only thing that verifies the Mac app at all: a standing red for a known
// unrelated reason makes every genuinely new failure in the same list unreadable (L538).
//
// The fix is to replay what a LAUNCH does before asserting, and assert what is LEFT. Dan's call,
// 2026-09-10 (this session, in chat): the suites replay the WHOLE launch sequence through
// `LaunchMigrations.run`, rather than naming the duplicate-clearing passes by hand. That is deliberate
// and it is the whole of this guard's point. A hand written list of passes beside the real one is a
// second definition that drifts silently (L41, L263), and it already has: `OneVenueIdentityLiveStoreTests`
// ran `NaturalKeyVenueMigration` alone while `LaunchMigrations` runs `DriftedRunMerge` and
// `SameNightTitleVariantMerge` AFTER it, and those two are the passes that actually clear a same-night
// duplicate. So the suite asserted "no duplicates" having replayed none of the work that removes them.
//
// A source-text guard rather than a behavioural one because the defect has no behavioural surface: both
// suites pass on a converged store and fail on a busy one, so nothing that runs them can tell a correct
// version from the broken one. What is checkable is which sequence they replay.
@Suite("Live-store duplicate suites replay a whole launch (#3496)")
struct LiveStoreDuplicateInvariantGuardTests {

    // The consecutive `//` lines beginning with the one carrying `marker`. Stops at the first line that
    // is not a comment, so a reason can never be satisfied by an issue number in the code beneath it.
    private static func commentBlock(openedBy marker: String, in chunk: String) -> String {
        let lines = chunk.components(separatedBy: "\n")
        guard let start = lines.firstIndex(where: { $0.contains(marker) }) else { return "" }
        var block: [String] = []
        for line in lines[start...] {
            guard line.trimmingCharacters(in: .whitespaces).hasPrefix("//") else { break }
            block.append(line)
        }
        return block.joined(separator: "\n")
    }

    // Derived from the directory rather than listed, so a third live-store suite asserting the same
    // invariant cannot be exempt from the rule by never being added to a list somebody maintains (L96).
    private static let suites = [
        "OvertureTests/OneVenueIdentityLiveStoreTests.swift",
        "OvertureTests/ParentheticalVenueMergeLiveStoreTests.swift",
        "OvertureTests/SameNightRoomVariantMergeLiveStoreTests.swift",
    ]

    @Test(arguments: suites)
    func eachLiveStoreDuplicateSuiteReplaysTheWholeLaunch(path: String) {
        let source = SourceGuardHelper.source(path)
        #expect(!source.isEmpty, "\(path) could not be read, so this guard measured nothing")
        // The boolean, never the source, because a failing #expect renders its own operands and this one
        // would print the whole file over the sentence explaining what went wrong (L445, milestone 83).
        let replaysAWholeLaunch = source.contains("LaunchReplay.run(in:")
        #expect(replaysAWholeLaunch,
                "\(path) does not replay a launch before asserting (#3496, L385)")
    }

    // The other end of the chain. The suites above are checked for calling the helper, so the helper is
    // checked for actually replaying a launch: without this, renaming what `LaunchReplay` does inside
    // would leave three green guards standing over nothing (L3).
    @Test func theReplayHelperRunsTheRealLaunchSequence() {
        let source = SourceGuardHelper.source("OvertureTests/LaunchReplay.swift")
        #expect(!source.isEmpty, "LaunchReplay.swift could not be read, so this guard measured nothing")
        let runsTheLaunch = source.contains("LaunchMigrations.run(in: context,")
        #expect(runsTheLaunch, "LaunchReplay does not call the app's own launch sequence (#3496)")
        // The isolation is the other half of #3496's fix and is load bearing: replaying with the real
        // settings store has PresenterWithheldRecheck stamp a boundary into the LIVE app's settings from
        // inside a test (L2).
        // Built rather than written whole, so this file does not itself hold the literal string that
        // `TestsCannotReachSharedStateTests.everyDefaultsSuiteIsScoped` scans for. That guard cannot tell
        // a line USING the API from a line ABOUT it, which is the guard working correctly, and it is the
        // same trap the style gate has with an em dash. Splitting the needle is preferred over adding
        // this file to that guard's exemption map: an exemption is a hole in a net, and there is a clean
        // way not to need one (AGENTS.md, "write it as an escape, never override the gate").
        let needle = "UserDefaults(suiteName" + ":"
        let isolatesSettings = source.contains(needle)
        #expect(isolatesSettings, "LaunchReplay does not isolate the settings store (#3496, L2)")
    }

    // The other half, and the one that stops the fix being quietly undone: replaying a launch is only
    // worth anything if a test is not ALSO running one pass by hand and asserting against that instead.
    //
    // Judged PER TEST rather than per file, because a suite legitimately holds both kinds. A test asserting
    // what REMAINS is asserting an invariant a launch restores and must replay a launch. A test asserting
    // one pass's own safety contract ("this merge never deletes a row that reached the outside world")
    // is about that pass and must run it alone: replaying a launch there would attribute damage done by
    // any of twenty five passes to this one. A rule that forced those to change would fire on the correct
    // case and be switched off within a day (L93).
    //
    // So the second kind DECLARES itself, in the same shape as this repo's other declared exemptions, and
    // must name an issue so it is a decision somebody made rather than a permanent hole (L233, L523).
    @Test(arguments: suites)
    func aTestRunningOneRepairPassByHandSaysWhy(path: String) {
        let source = SourceGuardHelper.source(path)
        #expect(!source.isEmpty, "\(path) could not be read, so this guard measured nothing")

        // Split on the attribute rather than brace matching: every test in these suites is declared with
        // it at one indentation, and a chunk that over-reaches can only ever make this guard STRICTER,
        // never blind, because the exemption has to sit in the same chunk as the call it excuses.
        let chunks = source.components(separatedBy: "@Test").dropFirst()
        #expect(!chunks.isEmpty, "\(path) declares no tests, so this guard measured nothing")

        let passes = ["NaturalKeyVenueMigration.run(in:",
                      "DriftedRunMerge.run(in:",
                      "SameNightTitleVariantMerge.run(in:"]
        for chunk in chunks {
            guard let pass = passes.first(where: { chunk.contains($0) }) else { continue }
            let declared = chunk.contains("launch-replay-exempt:")
            // The issue number is looked for across the whole COMMENT BLOCK the marker opens, not on the
            // marker's own line. A reason worth writing runs to several lines and puts its refs at the
            // end, so a same-line rule refuses every real exemption and passes only a terse one, which is
            // the opposite of what this asks for. Seen to do exactly that on the first run.
            let namesAnIssue = Self.commentBlock(openedBy: "launch-replay-exempt:", in: String(chunk))
                .range(of: "#[0-9]+", options: .regularExpression) != nil
            #expect(declared,
                    "\(path) runs \(pass) by hand with no declared reason (#3496, L41, L263)")
            #expect(namesAnIssue,
                    "\(path) declares a launch-replay exemption that names no issue (#3496, L523)")
        }
    }
}
