import Testing
import Foundation

// Regression guard for #499 (originally on DismissedView, moved here with the view): restore
// mutates a prospect on Dan's action and must never swallow a context.save() failure with a bare
// try?, so a restore could silently fail to persist while still telling Dan it worked.
@Suite("ArchiveView restore save guard")
struct ArchiveViewRestoreSaveGuardTests {
    private static let forbidden = "try? context.save()"

    @Test func restoreNeverRevertsToSilentSave() throws {
        let src = SourceGuardHelper.source("Overture/UI/ArchiveView.swift")
        #expect(!src.isEmpty)
        let body = try SourceGuard.functionBody(named: "restore", in: src)
        #expect(!body.contains(Self.forbidden),
                "restore reintroduced a bare try? context.save(): a save failure must surface via ActionFeedback, not fail silently (#499).")
        #expect(body.contains("saveOrWarn("),
                "restore no longer calls saveOrWarn(org:feedback:); a save failure path must go through the shared helper (#618).")
    }
}

// Regression guard: found in a final whole branch review that Archive's own embedded
// ShowSearchField only set highlightedKey directly, without widening activeStatuses, so picking
// a result whose status was outside the current filter chips silently did nothing (the row was
// filtered out before it could ever be scrolled to or highlighted). Both this screen's own search
// field and the initial jump from the global search bar must go through the same reveal(_:)
// helper so they can never drift apart again.
@Suite("ArchiveView search selection always reveals")
struct ArchiveViewSearchRevealGuardTests {
    private var archiveView: String { SourceGuardHelper.source("Overture/UI/ArchiveView.swift") }

    @Test func onAppearUsesTheSharedRevealHelper() {
        #expect(!archiveView.isEmpty)
        guard let onAppearRange = archiveView.range(of: ".onAppear {") else {
            Issue.record("onAppear block not found")
            return
        }
        let body = archiveView[onAppearRange.lowerBound...].prefix(200)
        #expect(body.contains("reveal(key)"))
    }

    @Test func internalSearchFieldSelectionUsesTheSharedRevealHelper() {
        #expect(!archiveView.isEmpty)
        guard let searchFieldRange = archiveView.range(of: "ShowSearchField(query: $query, allItems: items)") else {
            Issue.record("ShowSearchField call not found")
            return
        }
        let body = archiveView[searchFieldRange.lowerBound...].prefix(120)
        #expect(body.contains("reveal(result.id)"),
                "Archive's own search field must call reveal(_:), not set highlightedKey directly, or a result outside the active filter chips silently no-ops.")
    }

    @Test func revealWidensActiveStatusesAndSetsHighlightedKey() throws {
        let body = try SourceGuard.functionBody(named: "reveal", in: archiveView)
        #expect(body.contains("activeStatuses.insert("),
                "reveal must widen activeStatuses so the target's status is guaranteed visible.")
        #expect(body.contains("highlightedKey = key"))
    }
}
