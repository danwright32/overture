import Testing
import Foundation

// #2547. The review card carried a "Skip" button. It did not skip: it set the show to `.dismissed`,
// filed the outcome as `.notAFit` (a judgement about the show Dan never made, and one the season
// report counts in the never-pitched split), and recorded no undo entry, so Cmd+Z did nothing after it.
// The same card's header offered "Dismiss", which asks for a reason and is fully reversible.
//
// Dan's call once he heard what it did, 2026-08-11: remove it entirely.
//
// This guards the CLASS rather than that one button: a cut a person makes must be a cut they can take
// back. Written against the source because the thing being asserted is what the call sites PASS, and a
// behavioural test can only ever exercise the call sites somebody remembered to wire into it (L96).
@Suite("Dismissing always records an undo (#2547)")
struct DismissAlwaysRecordsAnUndoTests {
    // Every file that can put a dismissal in front of Dan. Derived from the code rather than listed by
    // hand: anything under UI or App that names `.dismissed` in a mutation is in scope.
    private static let searchedDirectories = ["Overture/UI", "Overture/App"]

    private func swiftFiles(under relative: String) -> [String] {
        let dir = RepoRoot.mac.appendingPathComponent(relative)
        let found = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        return found.filter { $0.hasSuffix(".swift") }.map { "\(relative)/\($0)" }.sorted()
    }

    // A `setStatus(..., .dismissed, ...)` call that does not also hand over an undo stack leaves the row
    // gone with no way back. `dismissForReason` is the one sanctioned route and passes `undo:` itself.
    @Test func noCallSiteDismissesWithoutOfferingAWayBack() {
        var offenders: [String] = []
        var scanned = 0
        for relative in Self.searchedDirectories {
            for file in swiftFiles(under: relative) {
                let source = SourceGuardHelper.source(file)
                guard !source.isEmpty else { continue }
                scanned += 1
                // The setter is the only thing that can move a show to `.dismissed`, so its call sites are
                // the whole population. Statements are joined first: a call wrapped across lines would
                // otherwise be judged on whichever fragment held the word.
                for call in Self.calls(to: "setStatus", in: source) where call.contains(".dismissed") {
                    guard !call.contains("undo:") else { continue }
                    offenders.append("\(file): \(call.prefix(120))")
                }
            }
        }
        #expect(offenders.isEmpty,
                """
                a dismissal with no undo entry: \(offenders.joined(separator: "\n"))
                Route it through ProspectMutations.dismissForReason, or pass undo: and undoLabel:.
                """)
        // The sweep is worth nothing if it read nothing (L98/L100).
        #expect(scanned > 20, "only \(scanned) UI/App source files were read; the sweep found nothing to check")
    }

    // The button itself is gone, and so is every wire that reached it. Named individually because each
    // one left behind would be a control or a parameter nothing can call, which reads as alive to any
    // is-this-used check (L29).
    @Test func theSkipControlAndItsWiringAreGone() {
        let draft = SourceGuardHelper.source("Overture/UI/DraftReviewView.swift")
        let row = SourceGuardHelper.source("Overture/UI/ProspectRowView.swift")
        let factory = SourceGuardHelper.source("Overture/UI/ProspectRowFactory.swift")
        #expect(!draft.isEmpty && !row.isEmpty && !factory.isEmpty, "a source file read as empty")

        #expect(!draft.contains("Button(\"Skip\")"), "the review card still draws a Skip button")
        #expect(!draft.contains("onSkip"), "DraftReviewView still carries the onSkip closure")
        #expect(!row.contains("onSkipDraft"), "ProspectRowView still carries onSkipDraft")
        #expect(!factory.contains("onSkipDraft"), "the row factory still wires a skip")
    }

    // The whole statement containing each call to `name`, so a call broken across lines is judged as one
    // thing. Balanced on parentheses from the call's own open bracket.
    private static func calls(to name: String, in source: String) -> [String] {
        var found: [String] = []
        var searchFrom = source.startIndex
        while let hit = source.range(of: "\(name)(", range: searchFrom..<source.endIndex) {
            var depth = 0
            var index = source.index(before: hit.upperBound)   // the open bracket itself
            var end = source.endIndex
            while index < source.endIndex {
                if source[index] == "(" { depth += 1 }
                if source[index] == ")" {
                    depth -= 1
                    if depth == 0 { end = source.index(after: index); break }
                }
                index = source.index(after: index)
            }
            found.append(String(source[hit.lowerBound..<end]))
            searchFrom = hit.upperBound
        }
        return found
    }
}
