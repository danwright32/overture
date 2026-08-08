import Testing
import Foundation

// #630: a native macOS NSToolbar item cannot host or anchor a SwiftUI `.popover` AT ALL. Confirmed
// against the running app via accessibility queries showing zero AXPopover elements anywhere in the
// process.
//
// The reason this needs a guard rather than a note is the failure mode: nothing crashes, nothing
// logs, and the control itself renders perfectly. The popover simply never appears. That is how the
// show-search dropdown shipped broken and was only caught by someone noticing the results never came
// up. A code review will not reliably catch it either, because the code looks completely correct.
//
// The audit this closes found no OTHER live instance (RootView's and QueueView's toolbars carry only
// Menus, Buttons and Text, and every `.popover` in the app is anchored in an ordinary view body).
// This guard is the durable half: it stops the constraint being rediscovered the hard way a second
// time.
@Suite("Toolbar popover guard (#630)")
struct ToolbarPopoverGuardTests {
    private static var sourceRoot: URL {
        RepoRoot.mac
            .appendingPathComponent("Overture")
    }

    private static func swiftFiles(under root: URL) -> [URL] {
        guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil) else { return [] }
        return enumerator.compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" }
    }

    // A line's code, with any `//` comment stripped, so the very comment explaining this constraint
    // (RootView documents it in prose) can't trip the guard that enforces it.
    private static func code(_ line: String) -> String {
        guard let range = line.range(of: "//") else { return line }
        return String(line[line.startIndex..<range.lowerBound])
    }

    // Every `.popover` that sits inside a toolbar region, as "file:line". A toolbar region opens at a
    // `.toolbar`, `ToolbarItem`, `ToolbarItemGroup` or `@ToolbarContentBuilder`, and closes when brace
    // depth returns to where it started. Deliberately a plain source scan: it needs to hold for code
    // nobody has written yet, which no runtime test can do.
    static func toolbarAnchoredPopovers(in source: String) -> [Int] {
        var found: [Int] = []
        var depth = 0
        var toolbarDepth: Int?

        for (index, rawLine) in source.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
            let line = code(String(rawLine))

            if toolbarDepth == nil,
               line.contains(".toolbar") || line.contains("ToolbarItem") || line.contains("ToolbarContentBuilder") {
                toolbarDepth = depth
            }

            if toolbarDepth != nil, line.contains(".popover(") {
                found.append(index + 1)   // 1-indexed, to read like a compiler diagnostic
            }

            depth += line.filter { $0 == "{" }.count - line.filter { $0 == "}" }.count

            if let start = toolbarDepth, depth <= start {
                toolbarDepth = nil
            }
        }
        return found
    }

    @Test func noPopoverIsAnchoredInsideAToolbar() throws {
        var offenders: [String] = []
        for file in Self.swiftFiles(under: Self.sourceRoot) {
            let source = try String(contentsOf: file, encoding: .utf8)
            for line in Self.toolbarAnchoredPopovers(in: source) {
                offenders.append("\(file.lastPathComponent):\(line)")
            }
        }

        #expect(offenders.isEmpty, """
        A .popover is anchored inside a toolbar, where macOS will silently never show it: \
        \(offenders.joined(separator: ", ")). Nothing will crash or log; the control will render \
        and the popover simply won't appear (#630). Move the presentation into the window body and \
        have the toolbar control set the state that triggers it, as RootView does for the show-search \
        field and its sheets.
        """)
    }

    // The guard has to be able to FAIL, or it is decoration. These pin the exact shapes it must catch
    // and the exact shapes it must NOT, so a later "cleanup" of the scanner cannot quietly gut it.
    @Test func theGuardCatchesAPopoverAnchoredInAToolbarItem() {
        let bad = """
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("Add") { showAdd = true }
                    .popover(isPresented: $showAdd) { AddView() }
            }
        }
        """
        #expect(Self.toolbarAnchoredPopovers(in: bad) == [4])
    }

    @Test func theGuardCatchesAPopoverInAToolbarContentBuilderProperty() {
        let bad = """
        @ToolbarContentBuilder
        private var myToolbar: some ToolbarContent {
            ToolbarItem(placement: .status) {
                Button("Filter") { showFilter = true }
                    .popover(isPresented: $showFilter) { FilterView() }
            }
        }
        """
        #expect(Self.toolbarAnchoredPopovers(in: bad) == [5])
    }

    // A popover in an ordinary view body is entirely fine, and is what every real one in this app is.
    // A guard that flagged those would be worse than none: it would be ignored.
    @Test func theGuardAllowsAPopoverInAnOrdinaryViewBody() {
        let good = """
        var body: some View {
            VStack {
                SearchField()
                    .popover(isPresented: $showResults) { ResultsView() }
            }
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button("Scout") { runScout() }
                }
            }
        }
        """
        #expect(Self.toolbarAnchoredPopovers(in: good).isEmpty)
    }

    // A sheet triggered FROM a toolbar button but presented ON the body is the correct pattern, and
    // is exactly what RootView does. It must not be flagged.
    @Test func theGuardAllowsASheetPresentedOnTheBodyAndTriggeredFromTheToolbar() {
        let good = """
        var body: some View {
            queueContent
                .toolbar {
                    ToolbarItem(placement: .secondaryAction) {
                        Button("Follow-ups") { showFollowUps = true }
                    }
                }
                .sheet(isPresented: $showFollowUps) { FollowUpsView() }
        }
        """
        #expect(Self.toolbarAnchoredPopovers(in: good).isEmpty)
    }

    // The comment in RootView that EXPLAINS this constraint mentions ".popover" in prose. The guard
    // that enforces it must not be tripped by the note describing it.
    @Test func theGuardIgnoresPopoverMentionedInAComment() {
        let good = """
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                // A .popover(isPresented:) here would never appear; see #630.
                Button("Scout") { runScout() }
            }
        }
        """
        #expect(Self.toolbarAnchoredPopovers(in: good).isEmpty)
    }
}
