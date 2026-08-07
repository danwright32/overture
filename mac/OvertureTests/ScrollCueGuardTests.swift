import Testing
import Foundation

// #2160: nothing may ship a height-capped scrolling box that says nothing about what it is hiding.
//
// #2159 found one (the reply panel, 160pt over an email whose season dates continued below the fold) and
// swept the seven others alongside it. This is the durable half. The defect is invisible from inside the
// code, invisible in a screenshot of a short message, and invisible to a review, because a capped
// ScrollView is exactly what you would write if you had never thought about the question. It is found
// only when a long enough message happens to land in front of Dan, which is the detector being a person
// (L76, L49).
//
// So: every ScrollView whose own modifier chain carries a real `maxHeight` must be a `CappedScrollView`,
// which draws the cue, or must carry `// scroll-cue:exempt <why>` saying why its content provably cannot
// exceed the cap. Both halves are load-bearing. Without the marker the guard would be unfalsifiable and
// somebody would eventually delete it; with a marker that takes no reason it would be a rubber stamp.
@Suite("Every capped scroll box says what it hides (#2160)")
struct ScrollCueGuardTests {

    static let marker = "scroll-cue:exempt"

    // MARK: - The scanner

    struct CappedScroll: Equatable {
        var line: Int          // 1-indexed, so it reads like a compiler diagnostic
        var isExempt: Bool
        var exemptReason: String
    }

    // A line's code with any `//` comment removed, so the comments explaining this rule cannot trip the
    // guard that enforces it.
    private static func code(_ line: String) -> String {
        guard let range = line.range(of: "//") else { return line }
        return String(line[line.startIndex..<range.lowerBound])
    }

    /// Every bare `ScrollView` in the source whose own modifier chain caps its height.
    ///
    /// A view expression runs from the `ScrollView` token to the end of its modifier chain: braces and
    /// parentheses are counted, and the chain continues past a newline only while the next thing on the
    /// page is another `.modifier`. That is what lets one scanner see both shapes this codebase writes,
    /// the multi-line body with the frame underneath it and the one-liner with everything on one line,
    /// without either a line budget or a fixed lookahead standing in for the real region (L63).
    ///
    /// `maxHeight: .infinity` is not a cap. It is a fill: the box takes the height it is given, and
    /// whatever hands it that height is the thing that decides whether anything is hidden.
    static func cappedScrollViews(in source: String) -> [CappedScroll] {
        let rawLines = source.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let stripped = rawLines.map(code)
        var found: [CappedScroll] = []

        var lineIndex = 0
        while lineIndex < stripped.count {
            let line = stripped[lineIndex]
            guard let tokenRange = Self.bareScrollViewToken(in: line) else { lineIndex += 1; continue }

            // Walk forward from the token to the end of this view's modifier chain.
            var depth = 0
            var cursor = tokenRange.upperBound
            var endLine = lineIndex
            var chain = ""

            scan: while true {
                let current = stripped[endLine]
                var index = cursor
                while index < current.endIndex {
                    let char = current[index]
                    if char == "{" || char == "(" { depth += 1 }
                    if char == "}" || char == ")" { depth -= 1 }
                    chain.append(char)
                    index = current.index(after: index)
                }
                // End of line. The chain continues only while depth is still open, or while the next
                // non-blank line starts with a dot.
                if depth > 0 {
                    guard endLine + 1 < stripped.count else { break scan }
                    endLine += 1
                    cursor = stripped[endLine].startIndex
                    continue
                }
                var peek = endLine + 1
                while peek < stripped.count, stripped[peek].trimmingCharacters(in: .whitespaces).isEmpty {
                    peek += 1
                }
                guard peek < stripped.count,
                      stripped[peek].trimmingCharacters(in: .whitespaces).hasPrefix(".")
                else { break scan }
                endLine = peek
                cursor = stripped[endLine].startIndex
            }

            if Self.capsHeight(chain) {
                // The marker may sit anywhere the expression spans, or on the line above it, which is
                // where a reason about the whole box reads best.
                let markerSearch = rawLines[max(0, lineIndex - 1)...min(endLine, rawLines.count - 1)]
                let reason = Self.exemptReason(in: markerSearch.joined(separator: "\n"))
                found.append(CappedScroll(line: lineIndex + 1,
                                          isExempt: reason != nil,
                                          exemptReason: reason ?? ""))
            }
            lineIndex = max(endLine, lineIndex) + 1
        }
        return found
    }

    // `ScrollView` as its own token: not `CappedScrollView`, and not a longer identifier that happens to
    // end in it.
    private static func bareScrollViewToken(in line: String) -> Range<String.Index>? {
        var searchFrom = line.startIndex
        while let range = line.range(of: "ScrollView", range: searchFrom..<line.endIndex) {
            let before = range.lowerBound == line.startIndex ? nil : line[line.index(before: range.lowerBound)]
            let isWordStart = before.map { !$0.isLetter && !$0.isNumber && $0 != "_" } ?? true
            if isWordStart { return range }
            searchFrom = range.upperBound
        }
        return nil
    }

    private static func capsHeight(_ chain: String) -> Bool {
        var searchFrom = chain.startIndex
        while let range = chain.range(of: "maxHeight:", range: searchFrom..<chain.endIndex) {
            let rest = chain[range.upperBound...].trimmingCharacters(in: .whitespaces)
            if !rest.hasPrefix(".infinity") { return true }
            searchFrom = range.upperBound
        }
        return false
    }

    private static func exemptReason(in text: String) -> String? {
        guard let range = text.range(of: marker) else { return nil }
        let rest = text[range.upperBound...].prefix { $0 != "\n" }
        return String(rest).trimmingCharacters(in: .whitespaces)
    }

    // MARK: - The scanner, proven against both shapes before it is trusted on the app

    @Test func findsTheFrameUnderneathAMultiLineBody() {
        let source = """
        ScrollView {
            VStack { rows }
        }
        .frame(maxHeight: 460)
        .padding(8)
        """
        #expect(Self.cappedScrollViews(in: source) == [CappedScroll(line: 1, isExempt: false, exemptReason: "")])
    }

    @Test func findsTheOneLinerToo() {
        let source = "ScrollView { sectionStack }.frame(maxHeight: 460)"
        #expect(Self.cappedScrollViews(in: source).map(\.line) == [1])
    }

    // A fill is not a cap: whatever hands the box its height owns the question.
    @Test func aFillIsNotACap() {
        let source = """
        ScrollView {
            rows
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        """
        #expect(Self.cappedScrollViews(in: source).isEmpty)
    }

    // The wrapper's own name must not read as a bare ScrollView, or the guard would report the very view
    // that fixes it.
    @Test func theWrapperItselfIsNotAnOffender() {
        #expect(Self.cappedScrollViews(in: "CappedScrollView(maxHeight: 460) { rows }").isEmpty)
    }

    // A frame belonging to some LATER view in the same file is not this box's cap.
    @Test func aFrameOnAnUnrelatedViewIsNotThisBoxesCap() {
        let source = """
        ScrollView {
            rows
        }
        Text("after")
            .frame(maxHeight: 40)
        """
        #expect(Self.cappedScrollViews(in: source).isEmpty)
    }

    @Test func readsTheReasonOffAnExemptBox() {
        let source = """
        // scroll-cue:exempt three fixed rows, and the cap is taller than all three
        ScrollView { rows }.frame(maxHeight: 460)
        """
        let found = Self.cappedScrollViews(in: source)
        #expect(found.count == 1)
        #expect(found.first?.isExempt == true)
        #expect(found.first?.exemptReason == "three fixed rows, and the cap is taller than all three")
    }

    // MARK: - The app

    private static var appRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // OvertureTests/
            .deletingLastPathComponent()   // mac/
            .appendingPathComponent("Overture")
    }

    private static func swiftFiles(under root: URL) -> [URL] {
        guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)
        else { return [] }
        return enumerator.compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" }
    }

    @Test func noCappedScrollBoxHidesContentSilently() throws {
        let files = Self.swiftFiles(under: Self.appRoot)
        // A wrong path must not pass silently the way #887's guard did.
        #expect(files.count > 50)

        var offenders: [String] = []
        var unexplained: [String] = []
        for file in files {
            let source = try String(contentsOf: file, encoding: .utf8)
            for box in Self.cappedScrollViews(in: source) {
                let where_ = "\(file.lastPathComponent):\(box.line)"
                if !box.isExempt {
                    offenders.append(where_)
                } else if box.exemptReason.count < 12 {
                    unexplained.append(where_)
                }
            }
        }

        #expect(offenders.isEmpty, """
        A ScrollView caps its own height and draws nothing to say what is below the fold: \
        \(offenders.joined(separator: ", ")). macOS hides scrollbars until a gesture starts, so at rest \
        that panel is pixel-identical to one showing everything it has, and Dan answers what he can see \
        (#2159, L76). Use CappedScrollView(maxHeight:), which draws the cue and clears it at the bottom, \
        or mark the box `// \(Self.marker) <why its content cannot exceed the cap>`.
        """)

        #expect(unexplained.isEmpty, """
        A capped scroll box is marked \(Self.marker) with no real reason beside it: \
        \(unexplained.joined(separator: ", ")). The marker exists to record why that content provably \
        cannot exceed its cap; without one it is a rubber stamp, and the next person cannot tell a \
        considered exemption from a silenced guard.
        """)
    }
}
