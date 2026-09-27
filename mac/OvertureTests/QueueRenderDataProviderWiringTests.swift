import Testing
import Foundation

// #4106 Step V: the queue takes its RenderData from a provider, and production must use the memo one.
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
@Suite("The queue's production call site derives its own RenderData (#4106 Step V)")
struct QueueRenderDataProviderWiringTests {

    private static let protocolName = "QueueRenderDataProvider"
    private static let memoProvider = "QueueMemoRenderData"

    // The argument list of RootView's QueueView call, balanced by parentheses from its opening one, so an
    // argument written anywhere in it is found and nothing after the call is.
    static func queueViewArguments(inRootView source: String) -> String? {
        guard let call = source.range(of: "QueueView(deepLinkedKey:") else { return nil }
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

    @Test func rootViewHandsTheQueueTheMemoProvider() throws {
        let rootView = SourceGuardHelper.source("Overture/App/RootView.swift")
        #expect(!rootView.isEmpty, "RootView.swift could not be read, so nothing below was measured")
        let arguments = try #require(Self.queueViewArguments(inRootView: rootView),
                                     "RootView's QueueView call site was not found")
        // Decided first, so a failure prints the reason rather than the whole argument list (L445).
        let passesTheMemo = SourceGuardHelper.containsCode("renderDataProvider: \(Self.memoProvider)()",
                                                           in: arguments)
        #expect(passesTheMemo, Comment(rawValue:
            "RootView no longer hands QueueView the memo provider, so the app may be drawing a RenderData "
            + "nobody derived. The seam exists for tests to serve one; production must derive (L718)."))
    }

    // The default a caller that passes nothing gets is the memo one too, so every hosted test that builds
    // a QueueView without naming a provider is still exercising the production path.
    @Test func theQueueDefaultsToTheMemoProvider() {
        let queueView = SourceGuardHelper.source("Overture/UI/QueueView.swift")
        let defaultsToTheMemo = SourceGuardHelper.containsCode(
            "var renderDataProvider: any \(Self.protocolName) = \(Self.memoProvider)()", in: queueView)
        #expect(defaultsToTheMemo, "QueueView's provider no longer defaults to the memo one")
    }

    // And the memo provider serves nothing, which is what makes it the memo PATH rather than a second
    // source of a RenderData: it hands the whole decision back to `makeRenderData`.
    @MainActor
    @Test func theMemoProviderServesNothing() {
        #expect(QueueMemoRenderData().servedRenderData() == nil)
    }

    @Test func theMemoProviderIsTheOnlyOneTheAppDeclares() {
        let files = AppSourceWalk.appFiles().map { (name: $0.name, text: $0.text) }
        let found = Self.conformingTypes(in: files)
        // THE POSITIVE CONTROL. An empty list is also what a scan that matched nothing returns, and it
        // would read as the cleanest possible app (L98).
        #expect(found.contains { $0.hasPrefix("\(Self.memoProvider) ") }, Comment(rawValue:
            "the scan did not find the memo provider's own conformance, so it measured nothing: "
            + "\(found)"))
        let others = found.filter { !$0.hasPrefix("\(Self.memoProvider) ") }
        #expect(others.isEmpty, Comment(rawValue:
            "the app declares another RenderData provider: \(others.joined(separator: ", ")). A served "
            + "RenderData is a test seam, and one living in the app is one RootView can be switched to "
            + "(L718). Put it in a test target."))
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
