import Testing
import Foundation

// #3760: a render pass the counter never hears about is a freeze nobody can attribute.
//
// WHY THIS IS A GUARD AND NOT A NOTE. The count is bumped by the surface that runs the pass, which makes
// it a behaviour every future call site has to OPT INTO, and a rule each site is asked to follow is
// enforced by nothing and reaches nothing in exactly the case it matters (L27, L621). A second surface
// that starts running the pass without bumping does not fail: it makes a freeze on THAT surface report
// zero passes, and a zero is read as the surface having been quiet. #3783 narrowed how far that may be
// taken, and this guard is what keeps the narrowing from growing: every surface outside it widens the
// population a zero cannot speak for, with nothing saying so (L11).
//
// DERIVED FROM THE SOURCE rather than from a list of the call sites somebody maintains, because a
// hand-written list only ever checks what its author remembered (L96).
//
// #3645 WIDENED IT FROM ONE PASS TO EVERY PASS, and the widening is what this issue cost. The guard named
// `QueueRenderPass.make(` literally, so it was a rule about the QUEUE rather than about render passes, and
// `SourcesRenderPass` arrived counted only because somebody happened to be holding this file open. That is
// the class rather than the instance (L30): the passes are ENUMERATED from the app's own declarations, so
// the third one joins the guard on the day it is declared.
@Suite("Every render pass is counted (#3760)")
struct EveryRenderPassIsCountedTests {

    // The call the counter is bumped through. One spelling, so this guard and the app cannot drift.
    private static let bump = "freezeWatch?.recordPass()"

    private static func appSources() -> [(name: String, text: String)] {
        AppSourceWalk.urls(under: RepoRoot.mac.appendingPathComponent("Overture"))
            .compactMap { url in
                guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
                return (url.lastPathComponent, text)
            }
    }

    // Every render pass the app DECLARES, read off the declaration rather than off a file name, so a pass
    // that lives somewhere unexpected is still enumerated and a file named like one but declaring nothing
    // is not.
    private static func declaredPasses(in sources: [(name: String, text: String)]) -> [String] {
        var names: Set<String> = []
        for file in sources {
            for line in file.text.components(separatedBy: "\n") {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                guard trimmed.hasPrefix("enum "), trimmed.hasSuffix("RenderPass {") else { continue }
                names.insert(String(trimmed.dropFirst("enum ".count).dropLast(" {".count)))
            }
        }
        return names.sorted()
    }

    // UNMEASURED is its own outcome. A walk that read nothing and an app with no render pass in it leave
    // the same empty result, and the emptiest possible failure must not read as the cleanest possible
    // pass (L98).
    @Test func theGuardActuallyReadsTheApp() {
        let sources = Self.appSources()
        #expect(sources.count > 50, "the walk read \(sources.count) app files, so nothing below was measured")
        let passes = Self.declaredPasses(in: sources)
        #expect(!passes.isEmpty, "no file declares a render pass, so this guard enumerated nothing")
        // And each declared pass has a caller. A pass nobody runs satisfies the check below vacuously,
        // which reads exactly like a pass that is properly counted.
        for pass in passes {
            let callers = sources.filter { $0.text.contains("\(pass).make(") }
            #expect(!callers.isEmpty, "no file calls \(pass).make(, so it was not measured below")
        }
    }

    @Test func everyFileThatRunsARenderPassAlsoCountsIt() {
        let sources = Self.appSources()
        var offenders: [String] = []
        for pass in Self.declaredPasses(in: sources) {
            for file in sources
            where file.text.contains("\(pass).make(") && !file.text.contains(Self.bump) {
                offenders.append("\(file.name) (\(pass))")
            }
        }
        #expect(offenders.isEmpty, """
            \(offenders.joined(separator: ", ")) runs a render pass and never calls \
            \(Self.bump). A freeze on that surface would report zero passes, which reads as "nothing \
            bumped it" rather than "nobody counted", and widens the population a zero cannot speak \
            for (#3760, #3645, #3783).
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

    // MARK: - #3762: every surface a stall can be ATTRIBUTED to, not only the queue.

    // The queue was the only surface that bumped, so a stall recorded while the Archive, Follow-ups,
    // the Sources sheet, the Organisations list or the OmniFocus sync sheet was on top read `passes: 0`.
    // Under that field's own documented meaning `0` is not a blank: it says the surface did not rebuild,
    // which is the reading that REFUTES "a burst of store changes did this" and sends the next diagnosis
    // somewhere else. Saying that on five surfaces nobody had measured made the instrument most
    // misleading exactly where nobody had looked (L11, L98).
    //
    // WHERE THE ENUMERATION COMES FROM, and this is the half that matters. A surface can be written into
    // a stall record only because `RootView.presentedSurface` can return it, and the `.sheet` beside it
    // is what says which view draws it. Both are read out of the source, so a surface added next year is
    // enumerated by the same code that attributes stalls to it rather than by a list somebody has to
    // remember to extend (L96). The guard above keys on `QueueRenderPass.make(`, which none of these five
    // call, so it could never have seen them.
    private static let attributingView = "Overture/App/RootView.swift"

    // (flag, surface) for every case `presentedSurface` returns behind a sheet flag. `.queue` is its
    // fallback and has no flag, which is why the guard above covers the queue separately.
    static func surfaceFlags(in rootView: String) -> [(flag: String, surface: String)] {
        let pattern = #"if\s+(show\w+)\s*\{\s*return\s+\.(\w+)\s*\}"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(rootView.startIndex..., in: rootView)
        return regex.matches(in: rootView, range: range).compactMap { match in
            guard let flag = Range(match.range(at: 1), in: rootView),
                  let surface = Range(match.range(at: 2), in: rootView) else { return nil }
            return (String(rootView[flag]), String(rootView[surface]))
        }
    }

    // The view a flag presents: the first TYPE named inside its own `.sheet` closure. Comment lines are
    // dropped first, because prose in the window can hold a capitalised word before a bracket and the
    // guard would then chase a type that does not exist.
    static func sheetRootView(flag: String, in rootView: String) -> String? {
        guard let anchor = rootView.range(of: ".sheet(isPresented: $\(flag))") else { return nil }
        let window = rootView[anchor.upperBound...].prefix(600)
        let code = window.split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")
        guard let regex = try? NSRegularExpression(pattern: #"\b([A-Z][A-Za-z0-9]*)\s*\("#),
              let match = regex.firstMatch(in: code, range: NSRange(code.startIndex..., in: code)),
              let name = Range(match.range(at: 1), in: code) else { return nil }
        return String(code[name])
    }

    static func fileDeclaring(_ type: String, in sources: [(name: String, text: String)]) -> (name: String, text: String)? {
        sources.first { $0.text.contains("struct \(type): View") }
    }

    // UNMEASURED is its own outcome here as well. A regex that stops matching leaves an empty list of
    // surfaces, and a guard with nothing to check is the emptiest possible failure reading as the
    // cleanest possible pass (L98). Held against the enum rather than against a number, so a case added
    // to `StallSurface` and wired into `presentedSurface` arrives here on its own.
    @Test func everyAttributableSurfaceIsEnumeratedFromTheCodeThatAttributesStalls() {
        let rootView = SourceGuardHelper.source(Self.attributingView)
        let found = Set(Self.surfaceFlags(in: rootView).map(\.surface))
        // `.queue` is `presentedSurface`'s fallback, so it carries no flag; `.notRecorded` is the
        // watchdog's own starting value and no screen can be it.
        let attributable = Set(StallSurface.allCases.map(\.rawValue))
            .subtracting([StallSurface.queue.rawValue, StallSurface.notRecorded.rawValue])
        #expect(found == attributable, """
            presentedSurface enumerates \(found.sorted().joined(separator: ", ")) and the surfaces a \
            stall can be attributed to are \(attributable.sorted().joined(separator: ", ")). A case \
            missing from the left is a surface this guard cannot see; one missing from the right is a \
            flag the enum has no case for (#3762).
            """)
    }

    @Test func everySurfaceAStallCanBeAttributedToCountsItsRenderPasses() {
        let rootView = SourceGuardHelper.source(Self.attributingView)
        let sources = Self.appSources()
        var unresolved: [String] = []
        var offenders: [String] = []
        for entry in Self.surfaceFlags(in: rootView) {
            guard let type = Self.sheetRootView(flag: entry.flag, in: rootView),
                  let file = Self.fileDeclaring(type, in: sources) else {
                unresolved.append(entry.surface)
                continue
            }
            if !file.text.contains(Self.bump) { offenders.append("\(entry.surface) (\(file.name))") }
        }
        // Separated from the finding below, deliberately: a surface whose view this guard could not
        // find is not a surface that passed (L98, L11).
        #expect(unresolved.isEmpty, """
            \(unresolved.joined(separator: ", ")) could not be resolved to the view that draws it, so \
            nothing below was checked for it (#3762).
            """)
        #expect(offenders.isEmpty, """
            \(offenders.joined(separator: ", ")) rebuilds without calling \(Self.bump). A freeze while \
            that surface is on top would report zero passes, which means "it did not rebuild" rather \
            than "nobody counted" (#3762).
            """)
    }
}
