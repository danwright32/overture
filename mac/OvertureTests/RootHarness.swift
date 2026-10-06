import SwiftUI
import SwiftData
#if OVERTURE_HOSTED_TESTS
@testable import Overture
#endif

// Lifted out of BringingTheQueueUpTests unchanged (#4327), so the steps 0.2 and 0.9 probes host RootView the
// same way that suite does rather than through a second copy of this harness (L613).
//
// #4343 (E0): moved from OvertureHostedTests into OvertureTests, unchanged, and compiled into BOTH targets
// (mac/project.yml), the way Phase0Corpus.swift is: the landing acceptance rig mounts RootView's real body
// from the PURE target, because that is the target the release-like build compiles. The pure target reaches
// RootView by compiling the app's sources in; the hosted one through the import above, which only its
// OVERTURE_HOSTED_TESTS condition switches on.
//
// The half above the queue, which is where #1930's own finding says the extra derivations came from:
// four of its five reported `nothing this view reads`, meaning nothing the queue looks at had moved,
// so the invalidation arrived from the screen above it.
//
// Hosting `RootView` is how that becomes measurable at all. It is the view the app launches into, and
// its own launch work (the reattach passes, the roster load, the notices) runs here as it does there.
struct RootHarness: View {
    let container: ModelContainer
    @State private var addLead: AddLeadPresenter
    @State private var undoStack = QueueUndoStack()
    @State private var undoRequest = QueueUndoRequest()

    init(container: ModelContainer) {
        self.container = container
        // Built the way `OvertureApp` builds it, from the container, rather than from a default that
        // would put this harness in the degraded no-store state the real app is never in here.
        _addLead = State(initialValue: AddLeadPresenter(store: container))
    }

    var body: some View {
        RootView()
            .modelContainer(container)
            .environment(addLead)
            .environment(undoStack)
            .environment(undoRequest)
    }
}
