import Foundation
import Testing

// #2838: the three runner script paths derive from ONE root, so moving the checkout is one thing to
// correct rather than six, and the root comes from something that already knows where it is.
//
// The state this exists to end: six UserDefaults entries (three scripts across two bundle domains), each
// holding the same absolute checkout path with a different filename on the end, every one of them living
// OUTSIDE the repo where no code change, test or guard here can notice it has gone stale. Dan wants to
// move the checkout out of `Photography Assets`, and today that invalidates all six at once (L153).
@Suite("Runner script paths derive from one root (#2838)")
struct RunnerScriptsTests {

    private static func runnable(_ paths: Set<String>) -> (String) -> Bool {
        { paths.contains($0) }
    }

    private static let repo = "/Users/dan/Apps/Overture"

    // A configured path that still works is untouched. Pointing the app at a script in another checkout
    // is a real thing to do, and this change must not quietly override it.
    @Test func aWorkingConfiguredPathWins() {
        let configured = "/Users/dan/other-checkout/mac/scripts/prep-run.sh"
        let resolution = RunnerScripts.resolve(.prep,
                                               configuredPath: configured,
                                               installedRepoPath: Self.repo,
                                               isRunnable: Self.runnable([configured,
                                                                          RunnerScripts.derivedPath(for: .prep,
                                                                                                    repoPath: Self.repo)]))
        #expect(resolution == .configured(URL(fileURLWithPath: configured)))
    }

    // The whole point. The checkout moved, so every stored path names a script that is not there any
    // more, and the installed build's own record of where it was built from answers instead.
    @Test func aStaleConfiguredPathFallsBackToTheInstalledRepo() {
        let stale = "/Users/dan/Photography Assets/Overture/mac/scripts/prep-run.sh"
        let derived = RunnerScripts.derivedPath(for: .prep, repoPath: Self.repo)
        let resolution = RunnerScripts.resolve(.prep,
                                               configuredPath: stale,
                                               installedRepoPath: Self.repo,
                                               isRunnable: Self.runnable([derived]))
        #expect(resolution == .derivedFromInstalledRepo(URL(fileURLWithPath: derived)))
    }

    @Test func anUnsetConfiguredPathDerivesToo() {
        for configured in [nil, ""] as [String?] {
            let derived = RunnerScripts.derivedPath(for: .scoutExtract, repoPath: Self.repo)
            let resolution = RunnerScripts.resolve(.scoutExtract,
                                                   configuredPath: configured,
                                                   installedRepoPath: Self.repo,
                                                   isRunnable: Self.runnable([derived]))
            #expect(resolution == .derivedFromInstalledRepo(URL(fileURLWithPath: derived)),
                    "an empty string is as unset as nil; it is what `defaults write ... \"\"` leaves")
        }
    }

    // All three scripts come off ONE root, which is the property that makes the move one correction
    // rather than six. Derived from the case list rather than written out, so a fourth runner added later
    // cannot be left out of this (L96).
    @Test func everyRunnerDerivesFromTheSameRoot() {
        for runner in RunnerScripts.Runner.allCases {
            let derived = RunnerScripts.derivedPath(for: runner, repoPath: Self.repo)
            #expect(derived == "\(Self.repo)/mac/scripts/\(runner.scriptName)")
            #expect(derived.hasPrefix(Self.repo + "/"))
        }
        #expect(Set(RunnerScripts.Runner.allCases.map(\.scriptName)).count
                == RunnerScripts.Runner.allCases.count,
                "two runners sharing a script name would make one of them unreachable")
        #expect(Set(RunnerScripts.Runner.allCases.map(\.defaultsKey)).count
                == RunnerScripts.Runner.allCases.count,
                "and two sharing a defaults key would make one silently answer for the other")
    }

    // The keys are the ones already in Dan's defaults and in the runbooks, so nothing has to be migrated
    // for this to ship. Pinned because changing one silently un-configures a live install.
    @Test func theStoredKeysAreTheOnesAlreadyInUse() {
        #expect(RunnerScripts.Runner.prep.defaultsKey == "prepRunnerScriptPath")
        #expect(RunnerScripts.Runner.replyClassify.defaultsKey == "replyClassifyRunnerScriptPath")
        #expect(RunnerScripts.Runner.scoutExtract.defaultsKey == "scoutExtractRunnerScriptPath")
        #expect(RunnerScripts.Runner.prep.scriptName == "prep-run.sh")
        #expect(RunnerScripts.Runner.replyClassify.scriptName == "reply-classify-run.sh")
        #expect(RunnerScripts.Runner.scoutExtract.scriptName == "scout-extract-run.sh")
    }

    // Nothing runnable anywhere. It carries BOTH paths it tried, because the message has to name the
    // setting and what it points at, and the two ways to arrive here need different actions.
    @Test func neitherRouteWorkingCarriesWhatEachOneWas() {
        let stale = "/gone/mac/scripts/reply-classify-run.sh"
        let derived = RunnerScripts.derivedPath(for: .replyClassify, repoPath: Self.repo)
        let resolution = RunnerScripts.resolve(.replyClassify,
                                               configuredPath: stale,
                                               installedRepoPath: Self.repo,
                                               isRunnable: Self.runnable([]))
        #expect(resolution == .unavailable(configuredPath: stale, derivedPath: derived))
    }

    @Test func withNoInstalledRecordThereIsNowhereToDerive() {
        let resolution = RunnerScripts.resolve(.prep,
                                               configuredPath: nil,
                                               installedRepoPath: nil,
                                               isRunnable: Self.runnable([]))
        #expect(resolution == .unavailable(configuredPath: nil, derivedPath: nil))
    }

    // The three refusals say three different things, because the action differs: correct a stale setting,
    // reinstall from the checkout, or install at all. A generic "the runner is unavailable" is the state
    // #2838 asked to end (L11, L80).
    @Test func eachRefusalNamesWhatIsWrongAndWhatToDo() {
        let stale = "/gone/mac/scripts/prep-run.sh"
        let derived = RunnerScripts.derivedPath(for: .prep, repoPath: Self.repo)

        let staleMessage = RunnerScripts.unavailableMessage(.prep, configuredPath: stale, derivedPath: derived)
        #expect(staleMessage.contains("prepRunnerScriptPath"), "it names the setting")
        #expect(staleMessage.contains(stale), "and what that setting points at")
        #expect(staleMessage.contains("build-install.sh"), "and how to correct it")

        let unsetMessage = RunnerScripts.unavailableMessage(.prep, configuredPath: nil, derivedPath: derived)
        #expect(unsetMessage.contains(derived), "an unset setting names where it looked instead")
        #expect(!unsetMessage.contains(stale))

        let nothingMessage = RunnerScripts.unavailableMessage(.prep, configuredPath: nil, derivedPath: nil)
        #expect(nothingMessage.contains("no record of which checkout"),
                "and with no installed record it says there was nowhere to look")

        #expect(staleMessage != unsetMessage)
        #expect(unsetMessage != nothingMessage)
        #expect(staleMessage != nothingMessage)

        // Each runner says its own name, so a message about the reply run cannot read as one about Prep.
        for runner in RunnerScripts.Runner.allCases {
            let message = RunnerScripts.unavailableMessage(runner, configuredPath: stale, derivedPath: derived)
            #expect(message.contains(runner.displayName))
            #expect(message.contains(runner.defaultsKey))
        }
    }
}
