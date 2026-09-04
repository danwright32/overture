import Testing
import Foundation

// #2077: a Debug build told Dan, on every single launch, that it could not tell how old it was.
//
// A Debug build reads its own data folder (`Overture-Debug`), which never holds the installer's
// records, so `verdict` answered `cannotTell(.noInstalledRecord)` every time and the panel appeared on
// every debug launch. That matters beyond the nuisance: this panel is deliberately the one notice
// designed to be unmissable, and showing it every time trains whoever is testing to dismiss it unread,
// which is exactly the reflex that makes it useless on the Release copy where it is telling the truth
// (L36).
//
// A fourth answer rather than suppressing the panel, because the two are not the same thing. Suppressing
// would leave the verdict still saying something false about the copy in front of it, and a Debug build
// is not a copy that "did not come from the installer": it is a copy that was never meant to. A message
// may claim only what its check measured (L11).
@Suite("A build run from source knows what it is (#2077)")
struct DebugBuildKnowsWhatItIsTests {
    private func installed(_ commit: String, _ at: Date,
                           _ provenance: BuildFreshness.Provenance?) -> InstalledBuild {
        InstalledBuild(commit: commit, commitDate: at, repoPath: "/repo",
                                      provenance: provenance)
    }

    private func shipped(_ commit: String, _ at: Date) -> ShippedCommit {
        ShippedCommit(commit: commit, commitDate: at)
    }

    private let old = Date(timeIntervalSince1970: 1_780_000_000)
    private let recent = Date(timeIntervalSince1970: 1_790_000_000)

    @Test func aBuildRunFromSourceSaysSoRatherThanThatItCannotTell() {
        #expect(BuildFreshness.verdict(installed: nil, shipped: nil, isRunFromSource: true)
            == .runFromSource)
        #expect(BuildFreshness.verdict(installed: nil, shipped: shipped("a", recent),
                                       isRunFromSource: true) == .runFromSource)
    }

    // The whole point: the panel stops appearing on every debug launch.
    @Test func thePanelDoesNotInterruptEveryDebugLaunch() {
        #expect(BuildFreshnessPanel.shouldShow(.runFromSource, dismissedThisLaunch: false) == false)
    }

    // And the Release case is UNCHANGED, which is the half that must not be traded away. A missing
    // installed record on an installed copy is a real fault and still says so.
    @Test func anInstalledCopyWithNoRecordStillReportsIt() {
        #expect(BuildFreshness.verdict(installed: nil, shipped: shipped("a", recent),
                                       isRunFromSource: false) == .cannotTell(.noInstalledRecord))
        #expect(BuildFreshnessPanel.shouldShow(.cannotTell(.noInstalledRecord),
                                               dismissedThisLaunch: false))
    }

    // A build run from source outranks every other answer, because every one of them is a claim about an
    // INSTALLED copy and there is not one. Asserted across the states that could otherwise be reached,
    // so this is not a rule that happens to hold for the one input it was written against (L101).
    @Test func runFromSourceOutranksEveryVerdictAboutAnInstalledCopy() {
        let cases: [(InstalledBuild?, ShippedCommit?)] = [
            (installed("a", old, .main), shipped("b", recent)),        // would be behind
            (installed("a", recent, .branch), shipped("b", old)),      // would be builtFromABranch
            (installed("a", recent, nil), shipped("b", old)),          // would be provenanceNotRecorded
            (installed("a", recent, .unknown), shipped("b", old)),     // would be provenanceUnknown
            (installed("a", old, .main), shipped("a", old)),           // would be upToDate
        ]
        for (i, s) in cases {
            #expect(BuildFreshness.verdict(installed: i, shipped: s, isRunFromSource: true)
                == .runFromSource)
        }
    }

    // And each of those same inputs still answers as it did when the copy IS installed, so the flag
    // above is the only thing that changed anything (L159: the negative needs its positive).
    @Test func theSameInputsAreUnchangedForAnInstalledCopy() {
        #expect(BuildFreshness.verdict(installed: installed("a", old, .main),
                                       shipped: shipped("b", recent), isRunFromSource: false)
            == .behind(installedAt: old, shippedAt: recent))
        #expect(BuildFreshness.verdict(installed: installed("a", recent, .branch),
                                       shipped: shipped("b", old), isRunFromSource: false)
            == .builtFromABranch)
        #expect(BuildFreshness.verdict(installed: installed("a", old, .main),
                                       shipped: shipped("a", old), isRunFromSource: false)
            == .upToDate)
    }

    // The flag is not decided inside the pure function: it comes from the build configuration, through
    // the constant that already decides which data folder this copy reads. Two definitions of "is this
    // the Debug build" is how the panel and the store could come to disagree about which copy is
    // running (L263).
    @Test func theFlagComesFromTheSameConstantTheStorePathDoes() {
        let source = SourceGuardHelper.source("Overture/Domain/BuildFreshnessPanel.swift")
        #expect(source.contains("StoreLocation.isDebugBuild"))
    }
}
