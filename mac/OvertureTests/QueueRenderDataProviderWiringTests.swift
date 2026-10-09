import Testing
import Foundation

// #4106 Step V: the queue can be handed a RenderData by a provider, and production must hand it none.
//
// #4358 slice E4d re-aimed this: the app's queue draws the queue engine's published pass, and the memo provider that
// served nothing (so the body derived through its own memo) went with that memo. So production passes the ENGINE and
// no provider, the queue's provider defaults to none, and the app declares no provider at all.
//
// WHY THIS EXISTS. Step V gives `QueueView` a seam so Phase 0c.8 can time the body and its layout over a
// SERVED RenderData, with the derivation out of the measurement. A view given its state by a seam is
// proved only by the tests that supply it, never by the production caller doing so (L718): every hosted
// test of the served path would stay green while `RootView` handed the queue something other than the
// memo, and the app would then draw a pass nobody derived. So the production call site is asserted here,
// and so is the absence of any second provider in the app, since a second one is the only thing
// `RootView` could be switched to.
//
// A SOURCE SCAN, deliberately. `RootView` cannot be constructed in a unit test without its whole
// environment, and what is being asserted is which value one call site passes, which is a fact about the
// source (the `ReachedOutRowArchiveJumpGuardTests` shape, over the same call site).
@Suite("The queue's production call site draws the engine's pass (#4106 Step V, #4358)")
struct QueueRenderDataProviderWiringTests {
    private static let protocolName = "QueueRenderDataProvider"

    // The argument list of RootView's QueueView call, balanced by parentheses from its opening one, so an
    // argument written anywhere in it is found and nothing after the call is.
    static func queueViewArguments(inRootView source: String) -> String? {
        guard let call = source.range(of: "QueueView(engine:") else { return nil }
        var index = source.index(before: call.upperBound)
        while source[index] != "(" { index = source.index(before: index) }
        let open = index
        var depth = 0
        while index < source.endIndex {
            if source[index] == "(" { depth += 1 }
            if source[index] == ")" {
                depth -= 1
                if depth == 0 { return String(source[open...index]) }
            }
            index = source.index(after: index)
        }
        return nil
    }

    // Every type the app declares or extends as conforming to the provider protocol, read from the code
    // with comments stripped, so a sentence naming the protocol is not a conformance.
    static func conformingTypes(in files: [(name: String, text: String)]) -> [String] {
        let pattern = #"\b(?:struct|class|enum|actor|extension)\s+([A-Za-z_][A-Za-z0-9_.]*)\s*(?:<[^>{]*>)?\s*:([^{]*)\{"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        var found: [String] = []
        for file in files {
            let code = SourceGuardHelper.normalizedCode(file.text)
            let whole = NSRange(code.startIndex..., in: code)
            for match in regex.matches(in: code, range: whole) {
                guard let nameRange = Range(match.range(at: 1), in: code),
                      let listRange = Range(match.range(at: 2), in: code) else { continue }
                // A `where` clause is not part of the inheritance list, and its constraints hold commas too.
                let list = code[listRange].components(separatedBy: " where ")[0]
                let inherited = list.split(separator: ",").map {
                    $0.trimmingCharacters(in: .whitespaces)
                }
                if inherited.contains(protocolName) || inherited.contains("any \(protocolName)") {
                    found.append("\(code[nameRange]) (\(file.name))")
                }
            }
        }
        return found.sorted()
    }

    @Test func rootViewHandsTheQueueTheEngineAndNoProvider() throws {
        let rootView = SourceGuardHelper.source("Overture/App/RootView.swift")
        #expect(!rootView.isEmpty, "RootView.swift could not be read, so nothing below was measured")
        let arguments = try #require(Self.queueViewArguments(inRootView: rootView),
                                     "RootView's QueueView call site was not found")
        // Decided first, so a failure prints the reason rather than the whole argument list (L445).
        // The arguments run from the call's opening parenthesis, so the type's name is not in them.
        let passesTheEngine = SourceGuardHelper.containsCode("(engine: engine,", in: arguments)
        let passesAProvider = arguments.contains("renderDataProvider")
        #expect(passesTheEngine, "RootView no longer hands QueueView its queue engine (#4358 slice E4d)")
        #expect(!passesAProvider, Comment(rawValue:
            "RootView hands QueueView a RenderData provider, so the app may be drawing a pass the engine never "
            + "published. The seam exists for tests to serve one; production draws the engine's (L718)."))
    }

    // The default a caller that passes nothing gets is NO provider, so every queue that names none draws the engine's
    // pass, as the app's does.
    @Test func theQueueDefaultsToNoProvider() {
        let queueView = SourceGuardHelper.source("Overture/UI/QueueView.swift")
        #expect(SourceGuardHelper.containsCode(
            "var renderDataProvider: (any \(Self.protocolName))? = nil", in: queueView),
            "QueueView's provider no longer defaults to none")
    }

    @Test func theAppDeclaresNoProvider() {
        let files = AppSourceWalk.appFiles().map { (name: $0.name, text: $0.text) }
        let found = Self.conformingTypes(in: files)
        // THE POSITIVE CONTROL is `theScanFindsEveryShapeOfConformance` below: an empty list is also what a scan
        // that matched nothing returns, and that suite proves this one matches (L98).
        #expect(found.isEmpty, Comment(rawValue:
            "the app declares a RenderData provider: \(found.joined(separator: ", ")). A served RenderData is a "
            + "test seam, and one living in the app is one RootView can be switched to (L718). Put it in a test target."))
    }

    // The scanner itself, over fixtures, so a regex that stopped matching cannot pass the guard above by
    // finding nothing to object to.
    @Test func theScanFindsEveryShapeOfConformance() {
        let fixture = """
            // struct Commented: QueueRenderDataProvider {
            struct A: QueueRenderDataProvider { }
            final class B: NSObject, QueueRenderDataProvider {
            }
            extension C: QueueRenderDataProvider {}
            enum D:
                QueueRenderDataProvider { case x }
            struct E<T>: Equatable, QueueRenderDataProvider where T: Hashable { }
            struct NotOne: Equatable { }
            protocol QueueRenderDataProvider { }
            """
        let found = Self.conformingTypes(in: [(name: "F.swift", text: fixture)])
        #expect(found == ["A (F.swift)", "B (F.swift)", "C (F.swift)", "D (F.swift)", "E (F.swift)"])
    }
}
