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

    // #2154 replaces what this guarded. The row USED to jump to the full card in Archive (#683/#685),
    // and Dan asked for it back off: "I'm basically never going to want to view it in the archive so we
    // can remove that." The row's job is one decision, and a third control competing for the eye was
    // working against it.
    //
    // Kept as a guard on the REMOVAL rather than deleted, so putting the link back is a visible change to
    // a test that states why it went, instead of a silent re-add nobody remembers deciding against.
    @Test func theRowNoLongerSendsHimToTheArchive() throws {
        #expect(!queueView.isEmpty)
        let body = try SourceGuard.functionBody(named: "reachedOutRow", in: queueView)
        #expect(!body.contains("onOpenInArchive"),
                "the reached-out row must not offer a jump to Archive (#2154).")
        #expect(!body.contains("View in Archive"),
                "the reached-out row must not offer a jump to Archive (#2154).")
    }

    // And the closure went with it, rather than being left as a prop RootView writes and nothing reads.
    @Test func queueViewNoLongerDeclaresACallbackNothingCalls() {
        #expect(!queueView.contains("var onOpenInArchive:"),
                "QueueView keeps an open-in-Archive callback that nothing on it calls (#2154, L46).")
    }

    // #2154: nothing is wired at the QueueView call site any more, since the row it fed is gone. The one
    // way Archive opens (the #236/#308 mechanism gathered into openArchive by #1580) is unchanged and
    // still reached from Follow-ups and search; this asserts only that RootView stopped handing QueueView
    // a closure it cannot call.
    @Test func rootViewNoLongerHandsQueueViewAnArchiveJump() {
        #expect(!rootView.isEmpty)
        guard let callSite = rootView.range(of: "QueueView(deepLinkedKey:") else {
            Issue.record("QueueView call site not found in RootView")
            return
        }
        let wiring = rootView[callSite.lowerBound...].prefix(600)
        #expect(!wiring.contains("onOpenInArchive:"),
                "RootView still wires an Archive jump into QueueView, which nothing there calls (#2154).")
        // The mechanism itself is untouched and still used by the surfaces that DO offer the jump.
        #expect(rootView.contains("openArchive(key:"),
                "openArchive is the one way Archive opens and must survive (#1580).")
    }
}
