import Testing
import Foundation

// #683: the lightweight reached-out row (#661) has no path to the reply text, the AI reply
// drafter, or the Mark… menu, all of which only render in the full card (ProspectRowFactory.row,
// still reachable from Archive since an in-play show keeps ArchiveStatus.active). Rather than
// duplicating that machinery here (Dan's own call on #661), the row gets a jump link that opens
// Archive with this exact prospect highlighted, reusing the existing #236/#308 highlight
// mechanism. Source-guarded since QueueView's row isn't directly invokable in a test.
@Suite("Reached-out row archive jump (#683)")
struct ReachedOutRowArchiveJumpGuardTests {
    private func source(_ relativeFromMac: String, file: StaticString = #filePath) -> String {
        SourceGuardHelper.source(relativeFromMac, file: file)
    }

    private var queueView: String { source("Overture/UI/QueueView.swift") }
    private var rootView: String { source("Overture/App/RootView.swift") }

    @Test func rowCallsOnOpenInArchiveWithTheProspectsNaturalKey() throws {
        #expect(!queueView.isEmpty)
        let body = try SourceGuard.functionBody(named: "reachedOutRow", in: queueView)
        // #685: also carries the specific recipient, so a multi-recipient show highlights that
        // one contact instead of just the whole card.
        #expect(body.contains("onOpenInArchive(p.naturalKey, r.id)"),
                "reachedOutRow doesn't offer a jump to the full card in Archive (#683).")
    }

    @Test func queueViewDeclaresTheCallback() {
        #expect(queueView.contains("var onOpenInArchive:"),
                "QueueView doesn't declare an onOpenInArchive callback for the reached-out row to call (#683).")
    }

    // Must reuse the existing archiveJumpKey/showArchive pair (the #236/#308 mechanism already
    // driving search picks and OmniFocus deep links), not a second one.
    @Test func rootViewWiresTheCallbackToTheExistingArchiveJumpMechanism() {
        #expect(!rootView.isEmpty)
        guard let callSite = rootView.range(of: "QueueView(deepLinkedKey:") else {
            Issue.record("QueueView call site not found in RootView")
            return
        }
        let wiring = rootView[callSite.lowerBound...].prefix(600)
        #expect(wiring.contains("onOpenInArchive:"),
                "RootView doesn't wire onOpenInArchive at the QueueView call site (#683).")
        #expect(wiring.contains("archiveJumpKey = "),
                "onOpenInArchive should set archiveJumpKey, reusing the existing jump mechanism (#683).")
        #expect(wiring.contains("showArchive = true"),
                "onOpenInArchive should set showArchive, reusing the existing jump mechanism (#683).")
    }
}
