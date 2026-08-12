import Testing
import Foundation

// #2306: a `TextField` with no submit handler is completely ordinary to read, and completely harmless
// until it is placed in a window carrying a `.keyboardShortcut(.defaultAction)` button, which is a
// property of a DIFFERENT file. Nobody editing either file alone can see the pair, and what the pair
// does is throw away whatever was typed: #2217 was reported when Return in the Sources sheet's search
// field pressed Done and took the search, the scroll position and an inline edit with it.
//
// #2217's sweep was done by hand over the two callers of one shared control, so nothing had ever looked
// at the rest. This finds every pair, and, as the issue asked, REPORTS rather than assumes: a field that
// genuinely wants Return to press the default button is a legitimate answer, so each pair is listed with
// what was decided about it, and a pair nobody has looked at fails.
@Suite("Return reaching a sheet's default button (#2306)")
struct ReturnReachesTheDefaultButtonTests {

    // One place a person can type, paired with the view whose default button Return would reach.
    struct Pair: Hashable, Comparable, CustomStringConvertible {
        let defaultButtonFile: String     // the file declaring .keyboardShortcut(.defaultAction)
        let fieldFile: String             // the file declaring the TextField
        let field: String                 // its first argument, which is the label a person sees

        var description: String { "\(defaultButtonFile) <- \(fieldFile): \(field)" }
        static func < (a: Pair, b: Pair) -> Bool { a.description < b.description }
    }

    // Every pair that exists today, each one looked at. The verdicts, in the order they appear below:
    //
    //   AddLeadSheet, InquiryIntakeSheet, ManualPrepSheet, DraftReviewView: these are presented as
    //   their OWN sheets, so the default button the scan pairs them with (RootView's, ProspectRowView's)
    //   is in a different window and cannot be reached from them at all. They are listed because the
    //   scan cannot tell a child view embedded inline from one presented as a sheet, and a scan that
    //   guessed would either hide a real pair or cry wolf on a dozen safe ones.
    //
    //   DayOffRangeFields' note field, in the block-these-days picker: Return blocks the days with the
    //   note as typed. Nothing is lost, and it is what a person pressing Return in the last field of a
    //   two-field form means. Left alone deliberately.
    //
    //   DayOffRangeFields' note field, in the Days off sheet: Return presses Done, which asks first
    //   whenever the add form was edited (#928's `closeNeedsConfirmation`). Protected already.
    //
    //   SourcesView's two add-a-source fields: THE DEFECT (#2308). Both now carry `.onSubmit`, so they
    //   no longer appear here at all. They are named in this comment rather than in the list for that
    //   reason: if either loses its handler, the pair comes back and this test fails.
    static let reviewed: Set<Pair> = [
        Pair(defaultButtonFile: "RootView.swift", fieldFile: "AddLeadSheet.swift", field: "Organization"),
        Pair(defaultButtonFile: "RootView.swift", fieldFile: "AddLeadSheet.swift", field: "Calendar page"),
        Pair(defaultButtonFile: "RootView.swift", fieldFile: "InquiryIntakeSheet.swift", field: "Their name"),
        Pair(defaultButtonFile: "RootView.swift", fieldFile: "InquiryIntakeSheet.swift", field: "Their email (optional)"),
        Pair(defaultButtonFile: "RootView.swift", fieldFile: "InquiryIntakeSheet.swift", field: "Event (optional)"),
        Pair(defaultButtonFile: "RootView.swift", fieldFile: "InquiryIntakeSheet.swift", field: "Venue (optional)"),
        Pair(defaultButtonFile: "RootView.swift", fieldFile: "InquiryIntakeSheet.swift", field: "Notes (optional)"),
        Pair(defaultButtonFile: "ProspectRowView.swift", fieldFile: "DraftReviewView.swift", field: "Subject"),
        Pair(defaultButtonFile: "ProspectRowView.swift", fieldFile: "DraftReviewView.swift", field: "Email"),
        Pair(defaultButtonFile: "ProspectRowView.swift", fieldFile: "DraftReviewView.swift", field: "Name (optional)"),
        Pair(defaultButtonFile: "ProspectRowView.swift", fieldFile: "ManualPrepSheet.swift", field: "Send to"),
        Pair(defaultButtonFile: "ProspectRowView.swift", fieldFile: "ManualPrepSheet.swift", field: "Subject"),
        Pair(defaultButtonFile: "BlockDaysSheet.swift", fieldFile: "DayOffRangeFields.swift",
             field: "Why (optional): vacation, family, anything"),
        Pair(defaultButtonFile: "DaysOffView.swift", fieldFile: "DayOffRangeFields.swift",
             field: "Why (optional): vacation, family, anything"),
    ]

    @Test func everyPairThatExistsHasBeenLookedAt() {
        let found = ReturnPairScan.pairs()
        #expect(!found.isEmpty, "the scan found nothing at all, which means it stopped working")
        let unreviewed = found.subtracting(Self.reviewed).sorted()
        #expect(unreviewed.isEmpty, """
            A text field with no submit handler now sits in a view whose default button Return would \
            press. Decide what Return should do there, then either give the field an .onSubmit (or \
            .submitScope()) or add it to `reviewed` above with the reason:
            \(unreviewed.map(\.description).joined(separator: "\n"))
            """)
    }

    // The other direction, which is what keeps the list honest: a pair listed as reviewed that no longer
    // exists is a note about code that has gone, and leaving it would let a real one hide behind it.
    @Test func nothingIsReviewedThatNoLongerExists() {
        let stale = Self.reviewed.subtracting(ReturnPairScan.pairs()).sorted()
        #expect(stale.isEmpty, """
            These pairs are listed as reviewed but the scan no longer finds them. Delete them:
            \(stale.map(\.description).joined(separator: "\n"))
            """)
    }

    // The scan must be able to SEE the shape it exists to find, or the empty list above proves nothing
    // (L1). The defect #2308 fixed is the fixture: the Sources sheet's two add-a-source fields, whose
    // handlers are what keeps them off the list.
    @Test func theScanFindsAFieldWhoseSubmitHandlerIsRemoved() {
        let sources = SourceGuardHelper.source("Overture/UI/SourcesView.swift")
        #expect(sources.contains("TextField(\"Organization\", text: $newOrgName)"))
        let withoutHandler = sources.replacingOccurrences(of: ".onSubmit { addSource() }", with: "")

        let fields = ReturnPairScan.unhandledFields(in: withoutHandler)

        #expect(fields.contains("Organization"))
        #expect(fields.contains("Their events or season page"))
    }

    // And the live file, as it stands: neither add-a-source field is on the list, which is #2308.
    @Test func theSourcesAddFormNoLongerLetsReturnReachDone() {
        let fields = ReturnPairScan.unhandledFields(
            in: SourceGuardHelper.source("Overture/UI/SourcesView.swift"))
        #expect(!fields.contains("Organization"))
        #expect(!fields.contains("Their events or season page"))
    }
}

// The scan itself, kept beside the guard rather than in the shared helpers: it is one test's reading of
// SwiftUI source, not a general fact about Swift, and a second caller would want a different definition
// of "reachable".
enum ReturnPairScan {
    // #2311's shared walk, never a private enumerator: a guard with its own walker does not inherit the
    // refusal, so it reports a clean app when its path resolves to nothing.
    private static var appFiles: [AppSourceWalk.File] { AppSourceWalk.appFiles() }

    // A TextField's label, for every field in this source that handles neither Return nor the submit
    // scope. Read off the source text with comments stripped, so a commented-out example cannot count.
    static func unhandledFields(in source: String) -> [String] {
        let lines = SwiftSource.scannableLines(in: source, skipping: .scaffolding)
        var out: [String] = []
        for (index, entry) in lines.enumerated() {
            guard let label = firstStringArgument(after: "TextField(", in: entry.code) else { continue }
            // The modifier chain runs on from the call, so the window is the next few lines rather than
            // the one the call sits on. Fifteen covers every multi-line binding in this codebase.
            let window = lines[index..<min(index + 15, lines.count)].map(\.code).joined(separator: "\n")
            if window.contains(".onSubmit") || window.contains(".submitScope") { continue }
            out.append(label)
        }
        return out
    }

    // Every (default button, field) pair: for each view file declaring a default action, itself plus the
    // view types it names, since a field one level down is in the same window whenever that child is
    // embedded rather than presented.
    static func pairs() -> Set<ReturnReachesTheDefaultButtonTests.Pair> {
        let files = appFiles
        var declaringViews: [String: (name: String, source: String)] = [:]
        for file in files {
            for match in file.text.ranges(ofPattern: #"\bstruct\s+([A-Za-z0-9_]+)\s*:[^{\n]*\bView\b"#) {
                declaringViews[match] = (name: file.name, source: file.text)
            }
        }

        var pairs: Set<ReturnReachesTheDefaultButtonTests.Pair> = []
        for file in files where file.text.contains(".keyboardShortcut(.defaultAction)") {
            var reachable: [(name: String, source: String)] = [(file.name, file.text)]
            for (type, declared) in declaringViews where declared.name != file.name {
                if file.text.range(of: "\\b\(type)\\s*\\(", options: .regularExpression) != nil {
                    reachable.append(declared)
                }
            }
            for target in reachable {
                for label in unhandledFields(in: target.source) {
                    pairs.insert(.init(defaultButtonFile: file.name, fieldFile: target.name, field: label))
                }
            }
        }
        return pairs
    }

    // The first string literal argument of a call, e.g. `TextField("Subject", text: $s)` -> "Subject".
    // Nil for a field labelled by a constant, which this guard cannot name and deliberately skips
    // rather than reporting under a name nobody could search for.
    private static func firstStringArgument(after call: String, in line: String) -> String? {
        guard let callRange = line.range(of: call) else { return nil }
        let rest = line[callRange.upperBound...]
        guard rest.first == "\"" else { return nil }
        let afterQuote = rest.dropFirst()
        guard let closing = afterQuote.firstIndex(of: "\"") else { return nil }
        return String(afterQuote[afterQuote.startIndex..<closing])
    }
}

private extension String {
    // The first capture group of every match, which is all this scan wants out of a regex.
    func ranges(ofPattern pattern: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let full = NSRange(startIndex..<endIndex, in: self)
        return regex.matches(in: self, range: full).compactMap { match in
            guard let range = Range(match.range(at: 1), in: self) else { return nil }
            return String(self[range])
        }
    }
}
