import Testing
import Foundation

// #569: SourceGuardHelper.propertyBody lets a guard scope its check to one property's own body
// instead of the whole file, so a coincidental match elsewhere in a large file can't produce a
// false positive, and a change hidden inside that one property can't slip past undetected.
// Exercised against synthetic snippets here, not a real production file, so this test doesn't
// depend on (or break when someone edits) QueueView.swift or any other real view.
@Suite("SourceGuardHelper.propertyBody")
struct SourceGuardHelperTests {
    @Test func extractsASimplePropertyBody() {
        let source = """
        struct V {
            private var masthead: some View {
                Text("hi")
            }
        }
        """
        let body = SourceGuardHelper.propertyBody("private var masthead: some View {", in: source)
        #expect(body?.contains("Text(\"hi\")") == true)
    }

    @Test func stopsAtTheMatchingCloseBraceEvenWithNestedBraces() {
        let source = """
        struct V {
            private var masthead: some View {
                if true {
                    Circle()
                }
                Text("after nesting")
            }
            private var other: some View {
                Circle()
            }
        }
        """
        let body = SourceGuardHelper.propertyBody("private var masthead: some View {", in: source)
        #expect(body?.contains("Text(\"after nesting\")") == true)
        // The sibling property's own Circle() must never leak into masthead's extracted body.
        #expect(body?.contains("private var other") == false)
    }

    @Test func doesNotBleedIntoALaterSiblingPropertysContents() {
        let source = """
        struct V {
            private var masthead: some View {
                Text("mine")
            }
            private var agentStrip: some View {
                Circle().frame(width: 6, height: 6)
            }
        }
        """
        let body = SourceGuardHelper.propertyBody("private var masthead: some View {", in: source)
        #expect(body?.contains("Circle()") == false)
    }

    @Test func returnsNilWhenTheMarkerIsNotFound() {
        let source = """
        struct V {
            private var somethingElse: some View {
                Text("nope")
            }
        }
        """
        let body = SourceGuardHelper.propertyBody("private var masthead: some View {", in: source)
        #expect(body == nil)
    }
}
