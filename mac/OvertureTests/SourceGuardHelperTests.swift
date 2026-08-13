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

// #2417: the helper that finds a function by NAME, so a guard about what a function does survives the
// function taking a different set of parameters. The whole reason it exists is the cases below: a
// signature that wraps across lines, and a signature that gains an argument. `propertyBody` reads both
// as the function having disappeared.
@Suite("SourceGuardHelper.bodyOfFunction (#2417)")
struct SourceGuardBodyOfFunctionTests {

    @Test func findsABodyThroughASignatureSplitAcrossLines() {
        let source = """
        struct V {
            @ViewBuilder private func prospectRow(_ item: QueueItem, data: RenderData,
                                                  departure: DepartureReason?) -> some View {
                Text("mine")
            }
        }
        """
        let body = SourceGuardHelper.bodyOfFunction(named: "prospectRow", in: source)
        #expect(body?.contains("Text(\"mine\")") == true)
    }

    // The same function with one more argument, which is the edit that broke five guards. The body it
    // returns must be identical, because nothing about what the function DOES has changed.
    @Test func theSameBodyComesBackWhenTheSignatureGainsAnArgument() {
        let before = """
        struct V {
            private func row(_ item: Item) -> some View {
                Text("mine")
            }
        }
        """
        let after = """
        struct V {
            private func row(_ item: Item, departure: Reason?) -> some View {
                Text("mine")
            }
        }
        """
        #expect(SourceGuardHelper.bodyOfFunction(named: "row", in: before)
                == SourceGuardHelper.bodyOfFunction(named: "row", in: after))
    }

    // A brace inside the parameter list is the signature's, not the body's. Walked by paren depth for
    // exactly this: stopping at the first "{" after the name would take a default closure's brace and
    // return a body that is one argument long.
    @Test func aBraceInsideTheParameterListIsNotTheBody() {
        let source = """
        struct V {
            private func row(_ item: Item, onTap: () -> Void = {}) -> some View {
                Text("mine")
            }
        }
        """
        let body = SourceGuardHelper.bodyOfFunction(named: "row", in: source)
        #expect(body?.contains("Text(\"mine\")") == true)
    }

    @Test func doesNotBleedIntoALaterSiblingsContents() {
        let source = """
        struct V {
            private func row(_ item: Item) -> some View {
                Text("mine")
            }
            private func other() -> some View {
                Circle()
            }
        }
        """
        let body = SourceGuardHelper.bodyOfFunction(named: "row", in: source)
        #expect(body?.contains("Circle()") == false)
    }

    // A CALL is not a declaration. Without the `func` in the search, the helper finds `row(` at the call
    // site and walks on to the NEXT brace, which belongs to whatever is declared after it, and hands back
    // a body nobody wrote for it.
    //
    // The unrelated function below is the whole fixture: with nothing after the call there is no brace to
    // find, the helper answers nil either way, and this passes without the rule it names being true. That
    // is what it did when it was first written, and it was caught only by breaking the helper on purpose
    // and watching it stay green (L1).
    @Test func aCallSiteIsNotADeclaration() {
        let source = """
        struct V {
            private var body: some View {
                row(item)
            }
            private func unrelated() -> some View {
                Circle()
            }
        }
        """
        #expect(SourceGuardHelper.bodyOfFunction(named: "row", in: source) == nil)
    }

    // Absent reads as nil, never as an empty body: every `contains` against "" is false, so a guard
    // standing on an empty string passes forever while asking nothing (L1).
    @Test func returnsNilWhenNoSuchFunctionIsDeclared() {
        let source = """
        struct V {
            private func somethingElse() -> some View {
                Text("nope")
            }
        }
        """
        #expect(SourceGuardHelper.bodyOfFunction(named: "row", in: source) == nil)
    }
}
