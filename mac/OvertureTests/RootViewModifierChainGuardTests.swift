import Testing
import Foundation

// #2803: RootView's modifier chain stays split.
//
// It used to be ONE chain of about thirty modifiers hanging off `QueueView`, at the Swift type checker's
// practical limit: adding a single `.task` during #2760 made the whole expression fail with "unable to
// type-check this expression in reasonable time", which names no line worth reading, and that issue
// worked around it twice rather than fixing it.
//
// Splitting it is only worth anything if it STAYS split. Nothing about a re-collapsed chain looks wrong
// in review, and the cost is paid by whoever adds the next modifier, in a build failure that names
// nothing. So the property is guarded rather than left to hold by itself.
@Suite("RootView's modifier chain stays checkable (#2803)")
struct RootViewModifierChainGuardTests {
    private var source: String { SourceGuardHelper.source("Overture/App/RootView.swift") }

    // The five pieces, and the one place that composes them.
    private static let groups = ["queueSurface", "withLifecycle", "withAlerts", "withSheets",
                                 "withOutermostWrappers"]

    @Test func theChainIsComposedFromItsNamedGroups() {
        let text = source
        #expect(!text.isEmpty, "the guard read no source, so everything below passes on nothing")

        guard let composition = SourceGuardHelper.propertyBody("private var queueContent: some View {",
                                                               in: text) else {
            Issue.record("queueContent is gone, so the chain is composed somewhere this guard cannot read")
            return
        }
        for group in Self.groups {
            #expect(composition.contains(group),
                    Comment(rawValue: "queueContent no longer composes \(group), so either it was inlined "
                            + "back into one expression or a whole group of behaviour is gone"))
        }
    }

    // The number the split exists to hold down. Measured from the file as it stands rather than chosen:
    // the largest group is the sheets at 14, and the limit sits above it with room for a few more before
    // anybody has to think again. The failing case had about thirty in one expression.
    //
    // A limit at exactly the current maximum would fire on the next sheet, which is an ordinary change,
    // and a guard that fires on the ordinary case gets switched off (L93).
    private static let mostModifiersInOneExpression = 20

    @Test func noSingleExpressionCarriesTheWholeSurfaceAgain() {
        let text = source
        #expect(!text.isEmpty)

        for (name, count) in Self.chainLengths(in: text) {
            #expect(count <= Self.mostModifiersInOneExpression,
                    Comment(rawValue: "\(name) chains \(count) modifiers in one expression. That is the "
                            + "shape that stopped type-checking in #2760, and the failure names no line: "
                            + "split it the way queueContent is split."))
        }
    }

    // The guard's own reading, exercised on text where the answer is known, because a counter that
    // silently matched nothing would report every declaration as fine (L100).
    @Test func theCounterReadsAChainItIsGiven() {
        let sample = """
            private var thing: some View {
                Something()
                    .one()
                    .two()
            }
        """
        // Two modifiers at the chain's own indentation, whatever that indentation is.
        #expect(Self.chainLengths(in: sample.replacingOccurrences(of: "        ", with: "            "))
                .contains { $0.count == 2 })
        #expect(Self.chainLengths(in: "private var nothing: some View { EmptyView() }").isEmpty)
    }

    // One modifier per line at the chain's top level, which is how every chain in this file is written.
    // Deliberately counts the TOP level only: a modifier nested inside a closure belongs to some other
    // expression and is type-checked with it.
    static func chainLengths(in text: String) -> [(name: String, count: Int)] {
        var out: [(name: String, count: Int)] = []
        var current: String?
        var counts: [String: Int] = [:]
        var order: [String] = []
        for line in text.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("private var ") || trimmed.hasPrefix("var ")
                || trimmed.hasPrefix("private func ") || trimmed.hasPrefix("func ") {
                current = trimmed
                if counts[trimmed] == nil { order.append(trimmed) }
                counts[trimmed] = counts[trimmed] ?? 0
                continue
            }
            guard let current else { continue }
            // The chain's own level: twelve spaces in this file, which is one indent inside a property
            // whose content is indented once. Matched by shape rather than a fixed width so a
            // re-indented file still reads.
            let indent = line.prefix { $0 == " " }.count
            if trimmed.hasPrefix(".") && indent >= 12 && indent <= 16 {
                counts[current, default: 0] += 1
            }
        }
        for name in order where (counts[name] ?? 0) > 0 {
            out.append((name: name, count: counts[name] ?? 0))
        }
        return out
    }
}
