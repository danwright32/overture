import Testing
import Foundation

// #685: the Reached Out row's (and Follow-ups sheet's) "View in Archive" link only carried the
// show's own key, so for a show with more than one contact, Archive highlighted the whole
// prospect's card and Dan still had to find the specific contact himself within it. Threads the
// recipient id through the same onOpenInArchive callback (mirroring #682's onShowFollowUpsFor
// mechanism) so the jump lands on and highlights that one contact's row inside the full card.
// Source-guarded since these views aren't directly invokable in a test.
@Suite("Archive View-in-Archive link targets a specific contact (#685)")
struct ArchiveContactDeepLinkGuardTests {
    private func source(_ relativeFromMac: String, file: StaticString = #filePath) -> String {
        SourceGuardHelper.source(relativeFromMac, file: file)
    }

    private var queueView: String { source("Overture/UI/QueueView.swift") }
    private var followUpsView: String { source("Overture/UI/FollowUpsView.swift") }
    private var rootView: String { source("Overture/App/RootView.swift") }
    private var archiveView: String { source("Overture/UI/ArchiveView.swift") }
    private var draftReviewView: String { source("Overture/UI/DraftReviewView.swift") }
    private var prospectRowFactory: String { source("Overture/UI/ProspectRowFactory.swift") }
    private var prospectRowView: String { source("Overture/UI/ProspectRowView.swift") }

    // #2154: QueueView has no open-in-Archive callback any more, because the row that called it no
    // longer offers the link. What #685 actually widened (a jump carrying the specific contact rather
    // than only the show) is still proved below on FollowUpsView, which does still offer one.
    @Test func queueViewNoLongerNeedsTheCallbackAtAll() {
        #expect(!queueView.contains("var onOpenInArchive:"))
    }

    // #2154: the reached-out row no longer offers this link at all (Dan: "I'm basically never going to
    // want to view it in the archive"), so what #685 widened is now proved on the Follow-ups rows below,
    // which still carry it. Asserted as an absence here so the row cannot quietly grow it back with the
    // narrow, whole-card-only call this issue was about.
    @Test func theReachedOutRowNoLongerCarriesTheLinkAtAll() throws {
        #expect(!queueView.isEmpty)
        let body = try SourceGuard.functionBody(named: "reachedOutRow", in: queueView)
        #expect(!body.contains("onOpenInArchive"))
    }

    @Test func followUpsViewDeclaresTheWidenedCallback() {
        #expect(followUpsView.contains("var onOpenInArchive: (_ key: String, _ recipientId: String?) -> Void"),
                "FollowUpsView's onOpenInArchive doesn't accept a recipient id (#685).")
    }

    @Test func bothFollowUpsRowsPassTheRecipient() throws {
        #expect(!followUpsView.isEmpty)
        for name in ["row", "postEventRow"] {
            let body = try SourceGuard.functionBody(named: name, in: followUpsView)
            #expect(body.contains("onOpenInArchive(d.prospect.naturalKey, r.id)"),
                    "FollowUpsView's \(name) View in Archive link doesn't pass the specific recipient (#685).")
        }
    }

    @Test func rootViewThreadsTheRecipientToArchiveView() {
        #expect(!rootView.isEmpty)
        #expect(rootView.contains("archiveJumpRecipientId"),
                "RootView doesn't track a recipient id alongside archiveJumpKey (#685).")
        guard let sheetSite = rootView.range(of: "ArchiveView(initialHighlightKey:") else {
            Issue.record("ArchiveView call site not found in RootView")
            return
        }
        let wiring = rootView[sheetSite.lowerBound...].prefix(200)
        #expect(wiring.contains("initialHighlightRecipientId: archiveJumpRecipientId"),
                "RootView doesn't pass the recipient id through to ArchiveView (#685).")
    }

    @Test func archiveViewDeclaresTheHighlightTarget() {
        #expect(archiveView.contains("var initialHighlightRecipientId:"),
                "ArchiveView doesn't accept an initial recipient to highlight (#685).")
        #expect(archiveView.contains("highlightedRecipientId"),
                "ArchiveView doesn't track the currently highlighted recipient (#685).")
    }

    @Test func archiveViewRevealAcceptsARecipient() throws {
        #expect(archiveView.contains("func reveal(_ key: String, recipientId: String? = nil)"),
                "ArchiveView's reveal() doesn't accept an optional recipient id (#685).")
        let body = try SourceGuard.functionBody(named: "reveal", in: archiveView)
        #expect(body.contains("highlightedRecipientId = recipientId"),
                "ArchiveView's reveal() doesn't set the recipient highlight (#685).")
    }

    @Test func prospectRowFactoryThreadsTheRecipientThrough() {
        #expect(prospectRowFactory.contains("highlightedRecipientId: String? = nil"),
                "ProspectRowFactory.row doesn't accept a recipient to highlight (#685).")
        #expect(prospectRowFactory.contains("highlightedRecipientId: highlightedRecipientId"),
                "ProspectRowFactory doesn't forward the recipient highlight to ProspectRowView (#685).")
    }

    @Test func prospectRowViewThreadsTheRecipientThrough() {
        #expect(prospectRowView.contains("var highlightedRecipientId: String? = nil"),
                "ProspectRowView doesn't accept a recipient to highlight (#685).")
        #expect(prospectRowView.contains("highlightedRecipientId: highlightedRecipientId"),
                "ProspectRowView doesn't forward the recipient highlight to DraftReviewView (#685).")
    }

    @Test func contactRowReflectsTheHighlight() throws {
        #expect(!draftReviewView.isEmpty)
        let body = try SourceGuard.functionBody(named: "contactRow", in: draftReviewView)
        #expect(body.contains("highlightedRecipientId == c.id"),
                "DraftReviewView's contactRow doesn't compare against the highlighted recipient (#685).")
        #expect(body.contains(".id(c.id)"),
                "DraftReviewView's contactRow doesn't tag itself with the recipient id (#685).")
    }
}
