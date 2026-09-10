import Testing
import Foundation

// #3760: a render pass the counter never hears about is a freeze nobody can attribute.
//
// WHY THIS IS A GUARD AND NOT A NOTE. The count is bumped by the surface that runs the pass, which makes
// it a behaviour every future call site has to OPT INTO, and a rule each site is asked to follow is
// enforced by nothing and reaches nothing in exactly the case it matters (L27, L621). A second surface
// that starts running the pass without bumping does not fail: it makes a freeze on THAT surface report
// zero passes, which is the reading that means "the surface did not rebuild" and would send the next
// diagnosis in the wrong direction with nothing saying so (L11).
//
// DERIVED FROM THE SOURCE rather than from a list of the call sites somebody maintains, because a
// hand-written list only ever checks what its author remembered (L96).
@Suite("Every render pass is counted (#3760)")
struct EveryRenderPassIsCountedTests {

    // The call the counter is bumped through. One spelling, so this guard and the app cannot drift.
    private static let bump = "freezeWatch?.recordPass()"
    private static let pass = "QueueRenderPass.make("

    private static func appSources() -> [(name: String, text: String)] {
        AppSourceWalk.urls(under: RepoRoot.mac.appendingPathComponent("Overture"))
            .compactMap { url in
                guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
                return (url.lastPathComponent, text)
            }
    }

    // UNMEASURED is its own outcome. A walk that read nothing and an app with no render pass in it leave
    // the same empty result, and the emptiest possible failure must not read as the cleanest possible
    // pass (L98).
    @Test func theGuardActuallyReadsTheApp() {
        let sources = Self.appSources()
        #expect(sources.count > 50, "the walk read \(sources.count) app files, so nothing below was measured")
        let callers = sources.filter { $0.text.contains(Self.pass) }
        #expect(!callers.isEmpty, "no file calls \(Self.pass), so this guard measured nothing")
    }

    @Test func everyFileThatRunsTheRenderPassAlsoCountsIt() {
        let offenders = Self.appSources()
            .filter { $0.text.contains(Self.pass) }
            .filter { !$0.text.contains(Self.bump) }
            .map(\.name)
        #expect(offenders.isEmpty, """
            \(offenders.joined(separator: ", ")) runs the queue render pass and never calls \
            \(Self.bump). A freeze on that surface would report zero passes, which means "it did not \
            rebuild" rather than "nobody counted" (#3760).
            """)
    }

    // The other half, and it is the one that keeps this honest: the bump has to reach the watchdog. A
    // `recordPass()` that forwards nowhere would satisfy the guard above and count nothing.
    @Test func theBumpReachesTheWatchdogsCounter() {
        let watch = SourceGuardHelper.source("Overture/App/FreezeWatch.swift")
        // Bound to a Bool before the assertion, deliberately: a failing `#expect` renders its own
        // operands, so comparing against the whole file would print the file over the message saying
        // what went wrong (L445).
        let declares = watch.contains("func recordPass()")
        let forwards = watch.contains("passes.bump()")
        #expect(declares, "FreezeWatch declares no recordPass()")
        #expect(forwards, "FreezeWatch.recordPass() does not reach the watchdog's counter")
    }
}
