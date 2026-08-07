import Testing
import Foundation

// #2210: the copy inventory records WHAT Overture can say and nothing about WHERE it lands, and every
// defect found on 2026-08-06 lived in that gap. Three of the eight would have been visible in a diff
// that showed the sentence and its container side by side: a question rendering as an OS alert while a
// sheet was already up (#2200), the status slot rendering into a toolbar item macOS may relocate
// (#2204), and a warning naming a venue rendering through a block commented "nothing to act on"
// (#2207). Each is obvious once the two are together and invisible while they sit in different files.
//
// WHAT THIS MEASURES, AND WHAT IT DELIBERATELY DOES NOT. It reports the container kinds a FILE creates,
// not the container a given sentence ends up in. The second is not knowable by reading one file: a
// sentence declared in SourcesView can surface through the feedback banner, and a view presented in a
// sheet declares its copy somewhere else entirely. A label claiming "this sentence renders in an alert"
// would be wrong often enough to be worse than no label at all (L11: a message may claim only what its
// check actually measured). "This file renders into a toolbar item" is true, checkable, and enough:
// all three of the defects above sit in files that plainly create the container that hurt them.
@Suite("Where Overture's messages render (#2210)")
struct CopySurfacesTests {

    // MARK: - Reading the containers out of a file

    @Test("each container kind is recognised", arguments: [
        (".sheet(isPresented: $showing) { SourcesView() }", CopySurfaces.Container.sheet),
        (".alert(\"Title\", isPresented: $x) { }", CopySurfaces.Container.alert),
        ("ToolbarItem(placement: .status) { Text(\"x\") }", CopySurfaces.Container.toolbarItem),
        (".popover(isPresented: $p) { Detail() }", CopySurfaces.Container.popover),
        (".confirmationDialog(\"Sure?\", isPresented: $c) { }", CopySurfaces.Container.confirmationDialog),
        ("Menu(\"Dismiss\") { Button(\"x\") {} }", CopySurfaces.Container.menu),
        ("MenuBarExtra(\"Overture\", systemImage: \"music.note\") { }", CopySurfaces.Container.menuBarExtra),
    ])
    func aContainerIsRecognised(_ line: String, _ expected: CopySurfaces.Container) {
        #expect(CopySurfaces.containers(in: line).contains(expected))
    }

    @Test func aFileThatRendersNoContainerReportsNone() {
        #expect(CopySurfaces.containers(in: "struct Thing { var body: some View { Text(\"hello\") } }").isEmpty)
    }

    @Test func oneFileCanRenderIntoSeveral() {
        let source = """
        .sheet(isPresented: $a) { A() }
        ToolbarItem { Text("t") }
        """
        #expect(CopySurfaces.containers(in: source) == [.sheet, .toolbarItem])
    }

    // A mention inside a COMMENT is not a container. Comments in this codebase discuss containers
    // constantly ("rendering as an OS alert while a sheet is presented"), so counting them would mark
    // half the app at risk and the report would stop meaning anything.
    @Test func aContainerNamedOnlyInACommentDoesNotCount() {
        let source = """
        // #2200: this used to render as an .alert(, which covered the sheet underneath it.
        Text("Something")
        """
        #expect(CopySurfaces.containers(in: source).isEmpty)
    }

    // MARK: - Which containers the platform can take away

    // The whole point of separating these: a sentence in one of them can be correct, tested, and still
    // never reach Dan. #2204 was exactly that, a notice placed in a toolbar slot macOS may relocate or
    // collapse at the window size he actually uses.
    @Test func theContainersThePlatformCanCollapseOrCoverAreNamed() {
        #expect(CopySurfaces.Container.toolbarItem.platformRisk != nil)
        #expect(CopySurfaces.Container.menuBarExtra.platformRisk != nil)
        #expect(CopySurfaces.Container.alert.platformRisk != nil)
    }

    // #2207, the third of the three defects this issue was filed for, and the only one that is not the
    // platform's doing: a container that is informational by construction cannot carry an action, so a
    // message naming a specific record lands there with nowhere to press.
    @Test func anInformationalBlockIsFlaggedToo() {
        #expect(CopySurfaces.Container.infoBlock.platformRisk != nil)
        #expect(CopySurfaces.containers(in: "infoBlock { Text(\"x\") }").contains(.infoBlock))
    }

    // A sheet is presented deliberately and stays put, so it carries no platform risk and must not be
    // listed as one: a risk list that includes everything tells nobody anything.
    @Test func anOrdinarySheetCarriesNoPlatformRisk() {
        #expect(CopySurfaces.Container.sheet.platformRisk == nil)
        #expect(CopySurfaces.Container.popover.platformRisk == nil)
    }

    // Every risk names the actual failure, so the report says what could go wrong rather than merely
    // flagging the container as special.
    @Test func eachRiskSaysWhatCanHappen() {
        for container in CopySurfaces.Container.allCases {
            if let risk = container.platformRisk {
                #expect(risk.split(separator: " ").count >= 4, "\(container) risk should be a sentence")
            }
        }
    }

    // MARK: - The generated report

    // Same contract as the copy inventory: checked in, regenerated by the suite, and the suite fails
    // when it is stale, so a PR that puts a new sentence into a risky container shows that in its diff.
    @Test func theCheckedInReportIsUpToDate() throws {
        let built = try CopySurfaces.build()
        let rendered = built.render()
        let url = CopySurfaces.reportURL

        let existing = try? String(contentsOf: url, encoding: .utf8)
        if existing != rendered {
            try rendered.write(to: url, atomically: true, encoding: .utf8)
            Issue.record("""
                docs/copy-surfaces.md was out of date, so it has been regenerated in place.

                Read the diff (`git diff docs/copy-surfaces.md`). It shows which surfaces this branch \
                adds messages to. If a sentence has landed in a container the platform can collapse or \
                cover, that is the thing to look at before shipping it.
                """)
        }
    }

    // The report is worth nothing if it scans nothing, which is how #1967 failed silently.
    @Test func theReportActuallyScannedTheApp() throws {
        let built = try CopySurfaces.build()
        #expect(built.filesScanned > 100, "the app has far more than 100 source files")
        #expect(built.byFile.isEmpty == false, "no file renders any container, which cannot be true")
    }
}
