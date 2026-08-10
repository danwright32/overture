import Foundation

// #2210: where Overture's messages render, as a companion to the copy inventory.
//
// `docs/copy-inventory.md` lists every sentence the app can say and nothing about where it lands, and
// every defect found on 2026-08-06 lived in that gap. Three of the eight would have been visible in a
// diff showing the sentence and its container together: a question rendering as an OS alert while a
// sheet was already up (#2200), the status slot rendering into a toolbar item macOS may relocate
// (#2204), and a warning naming a venue rendering through a block commented "nothing to act on"
// (#2207).
//
// WHAT THIS CLAIMS, AND WHAT IT REFUSES TO. It reports the container kinds each FILE creates. It does
// NOT claim which container a given sentence ends up in, because that is not knowable by reading one
// file: a sentence declared in SourcesView can surface through the feedback banner, and a view
// presented inside a sheet declares its copy somewhere else entirely. A per-sentence label would be
// wrong often enough to be worse than none (L11: a message may claim only what its check measured).
//
// "This file renders into a toolbar item" is true, checkable, and enough. All three defects above sit
// in files that plainly create the container that hurt them.
enum CopySurfaces {

    // MARK: - The containers

    enum Container: String, CaseIterable, Comparable {
        case alert
        case sheet
        case popover
        case confirmationDialog
        case menu
        case toolbarItem
        case menuBarExtra
        case infoBlock

        // The source spelling that proves this container is being CREATED here. Matched against code
        // with comments stripped, so a comment discussing alerts does not mark a file as raising one.
        var marker: String {
            switch self {
            case .alert: return ".alert("
            case .sheet: return ".sheet("
            case .popover: return ".popover("
            case .confirmationDialog: return ".confirmationDialog("
            case .menu: return "Menu("
            case .toolbarItem: return "ToolbarItem"
            case .menuBarExtra: return "MenuBarExtra"
            case .infoBlock: return "infoBlock"
            }
        }

        var title: String {
            switch self {
            case .alert: return "OS alert"
            case .sheet: return "Sheet"
            case .popover: return "Popover"
            case .confirmationDialog: return "Confirmation dialog"
            case .menu: return "Menu"
            case .toolbarItem: return "Toolbar item"
            case .menuBarExtra: return "Menu bar"
            case .infoBlock: return "Info block"
            }
        }

        // What the PLATFORM can do to a message in this container, whatever the code does. nil means the
        // container shows what it is given, where it was put. Only the three that can genuinely take a
        // message away carry one: a risk list that includes everything tells nobody anything.
        var platformRisk: String? {
            switch self {
            case .toolbarItem:
                // #2204: a notice in a toolbar slot is not shipped until it has been seen at the window
                // size Dan actually uses.
                return "macOS may relocate this into the overflow menu or drop it entirely at a narrow window width, so a message here can be correct and never seen."
            case .menuBarExtra:
                // 2026-08-01: a crowded menu bar removed the status item, which terminates the app.
                return "A crowded menu bar can push this item off screen, and losing the status item terminates the app."
            case .alert:
                // #2200: an OS alert appears over whatever is already presented, including a sheet the
                // person was in the middle of.
                return "This appears over whatever is already on screen, including a sheet Dan is in the middle of, so it can interrupt an answer it has nothing to do with."
            case .infoBlock:
                // #2207: a warning that NAMED a venue rendered through this, whose own comment says
                // "nothing to act on". Not a platform risk: this one is the app's own doing, and it is
                // here because the failure is the same shape, a correct message that reaches Dan with
                // nowhere to go (L80).
                return "This container is informational by construction, so a message here that names a specific show, source or venue tells Dan what is wrong and gives him nothing to press."
            case .sheet, .popover, .confirmationDialog, .menu:
                return nil
            }
        }

        static func < (a: Container, b: Container) -> Bool { a.rawValue < b.rawValue }
    }

    // Every container kind CREATED in this source, ignoring any named only in a comment. Comments in
    // this codebase discuss containers constantly, so counting them would mark half the app at risk.
    static func containers(in source: String) -> Set<Container> {
        let code = strippingComments(source)
        return Set(Container.allCases.filter { code.contains($0.marker) })
    }

    // Line comments only. Block comments are rare here and a stray `/*` swallowing real code would be a
    // silent under-report, which is the worse direction for a report about things going unseen.
    private static func strippingComments(_ source: String) -> String {
        source.split(separator: "\n", omittingEmptySubsequences: false).map { line -> Substring in
            guard let range = line.range(of: "//") else { return line }
            return line[line.startIndex..<range.lowerBound]
        }.joined(separator: "\n")
    }

    // MARK: - The report

    struct Report {
        var byFile: [String: Set<Container>] = [:]
        var filesScanned = 0

        // Files that render into a container the platform can take away, most-exposed first.
        func filesAtRisk(_ container: Container) -> [String] {
            byFile.filter { $0.value.contains(container) }.keys.sorted()
        }
    }

    static func build(root: URL = CopyInventory.appRoot) throws -> Report {
        var report = Report()
        let files = try swiftFiles(under: root)
        report.filesScanned = files.count
        for file in files {
            let source = try String(contentsOf: file, encoding: .utf8)
            let found = containers(in: source)
            guard !found.isEmpty else { continue }
            report.byFile[CopyInventory.relativePath(of: file, under: root)] = found
        }
        return report
    }

    // #2311: through the shared walk, for the same reason the inventory does. A report of where the
    // app's messages render, built from no files, says every message renders nowhere.
    private static func swiftFiles(under root: URL) throws -> [URL] {
        AppSourceWalk.urls(under: root, floor: 50)
    }

    static var reportURL: URL {
        CopyInventory.inventoryURL.deletingLastPathComponent()
            .appendingPathComponent("copy-surfaces.md")
    }
}

extension CopySurfaces.Report {
    // #2349: the scanned-file count is deliberately NOT printed, for the same reason it left the copy
    // inventory's header. It moves whenever any Swift file is added anywhere in the app, including one
    // that renders nothing, so two branches open at once each recorded their own and the second went red
    // on main purely because the number had drifted underneath it. `filesScanned` still exists on this
    // value and is still asserted in CopySurfacesTests, so what proves the scan ran is the test, never a
    // number in a checked-in file. What remains is the count of files that DO render a container, which
    // moves only when one starts or stops doing so.
    func render() -> String {
        var out = """
        # Where Overture's messages render

        A companion to `copy-inventory.md`, which lists every sentence the app can say and nothing about
        where it lands. This says which SURFACES each file renders into, so a review of new copy is also
        a review of where that copy goes.

        Generated, do not edit by hand. The test suite regenerates it and fails when it is stale, so a
        PR that puts a message into a surface the platform can take away shows that in its diff.

        **What this claims:** the container kinds each file CREATES, read from the code with comments
        stripped. **What it deliberately does not claim:** which container a given sentence ends up in.
        That is not knowable from one file, since a sentence declared in one view routinely surfaces
        through another, and a wrong label would be worse than none.

        \(byFile.count) files render at least one container.

        ## Surfaces where a message can go astray

        A message here can be correct, tested, and still fail to do its job: taken away by the platform
        before Dan sees it, or delivered somewhere he cannot act on it. These are the ones to look at
        when new copy lands in them.

        """

        for container in CopySurfaces.Container.allCases.sorted() {
            guard let risk = container.platformRisk else { continue }
            let files = filesAtRisk(container)
            out += "\n### \(container.title) (\(files.count) file\(files.count == 1 ? "" : "s"))\n\n"
            out += "\(risk)\n\n"
            for file in files { out += "- `\(file)`\n" }
        }

        out += "\n## Every file, by surface\n\n"
        for file in byFile.keys.sorted() {
            let kinds = byFile[file, default: []].sorted().map(\.title).joined(separator: ", ")
            out += "`\(file)`\n    \(kinds)\n"
        }
        return out
    }
}
