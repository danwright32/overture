import Foundation
import Testing

// #2805: every handoff file a detached run touches is named in `docs/contracts.md`.
//
// That catalogue is the document anyone is told to read before changing a cross-boundary file shape, so
// a wrong or missing entry sends the next change at the wrong file. It went wrong in exactly the way a
// hand-written list does: #2763 split these files per RUN SLOT and #2760 moved the reachability check
// onto its own, and the catalogue went on naming `overture-prep-queue.json` and
// `overture-prep-results.json` as the check's files, which are the two the check had STOPPED writing.
//
// So the expected names are DERIVED from `RunSlot` itself rather than written out here (L41, L96). A
// second hand-written list would only ever check what somebody remembered, which is the same defect
// wearing this test's clothes, and the slot that gets forgotten is always the newer one.
@Suite("Every run slot's files are in the contracts catalogue (#2805)")
struct RunSlotFilesAreCataloguedTests {

    private static var document: String {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()      // OvertureTests
            .deletingLastPathComponent()      // mac
            .deletingLastPathComponent()      // repo root
            .appendingPathComponent("docs/contracts.md")
        return (try? String(contentsOf: url, encoding: .utf8)) ?? ""
    }

    // The CATALOGUE TABLE only, not the whole document, and that scoping is the guard (L135).
    //
    // Written first as a search over the whole file, and a mutation deleting `check-running` from the
    // table SURVIVED it: the prose further down describes the same files in a paragraph, so the name was
    // still present and the check passed while the table was wrong. That is precisely the defect #2805
    // fixed, from the same direction: the prose section had been correct about the check slot all along
    // and the catalogue had not, and the catalogue is what people are told to read.
    private static var catalogue: String {
        let text = document
        guard let start = text.range(of: "\n## Catalog") else { return "" }
        let rest = text[start.upperBound...]
        guard let end = rest.range(of: "\n## ") else { return String(rest) }
        return String(rest[..<end.lowerBound])
    }

    // Names built by asking RunSlot, against a neutral base, exactly as RunSlot's own `queueFileName`
    // does. Nothing here restates a filename pattern.
    private static func fileNames(for slot: RunSlot) -> [String] {
        let base = URL(fileURLWithPath: "/")
        return [
            slot.queueURL(in: base),
            slot.resultsURL(in: base),
            slot.progressURL(in: base),
            slot.markerURL(in: base),
            slot.cancelURL(in: base),
            slot.chunkDirectoryURL(in: base),
            slot.runLogURL(in: base),
            slot.eventsURL(in: base),
            slot.archivesDirectory(in: base),
        ].map(\.lastPathComponent)
    }

    @Test func theCatalogueNamesEveryFileEverySlotProduces() {
        let text = Self.catalogue
        #expect(!text.isEmpty,
                "the Catalog section of docs/contracts.md could not be read, so this checked nothing (L98)")
        // The section really is the table, rather than an empty slice a renamed heading would leave. A
        // scope that selects nothing passes every `contains` beneath it for the wrong reason.
        #expect(text.contains("| File (in app-support dir) |"),
                "the Catalog section no longer looks like the table this reads; the heading may have moved")

        for slot in RunSlot.allCases {
            for name in Self.fileNames(for: slot) {
                #expect(text.contains(name),
                        """
                        docs/contracts.md does not name \(name), which RunSlot.\(slot.rawValue) writes. \
                        That catalogue is what somebody reads before changing a cross-boundary file \
                        shape, so a file missing from it is a change aimed at the wrong place (#2805).
                        """)
            }
        }
    }

    // The guard above passes if the catalogue happens to mention a name anywhere. This is what stops it
    // passing for the WRONG reason: the two slots must be named as separate things, because the defect
    // #2805 fixed was one slot's files being described as the other's.
    @Test func bothSlotsAreNamedAsTheirOwn() {
        let text = Self.catalogue
        #expect(RunSlot.allCases.count == 2, "a third slot needs its own row and its own reading here")
        for slot in RunSlot.allCases {
            #expect(text.contains(slot.queueURL(in: URL(fileURLWithPath: "/")).lastPathComponent),
                    "each slot's own queue file is the one thing that cannot be shared between them")
        }
        // And the two are genuinely different names, which is the property the catalogue has to reflect.
        let queues = Set(RunSlot.allCases.map { $0.queueURL(in: URL(fileURLWithPath: "/")).lastPathComponent })
        #expect(queues.count == RunSlot.allCases.count)
    }
}
