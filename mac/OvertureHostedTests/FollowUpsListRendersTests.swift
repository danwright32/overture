import Testing
import Foundation
import AppKit
import SwiftUI
import SwiftData
@testable import Overture

// #3437: something renders the Follow-ups LIST, at last.
//
// Every other test of this sheet reaches past its body and calls one of its row builders directly
// (`FollowUpsViewSendStateTests` calls `row`, `StoodDownShowNoteOnScreenTests` calls `postEventRow`,
// `ControlRefusalOnScreenTests` calls both), because the list derives from a `@Query` and a row does
// not. That is a reasonable shortcut for asking what a row says, and it left the surface the rows sit
// ON drawn by nothing at all.
//
// What that cost, measured: `FollowUpsView` carried a `ScrollViewReader` whose proxy nothing used, and
// a comment saying the scroll position was cleared when a reveal started, for a MONTH after #2138
// removed the reveal on 2026-08-05. No test could notice, because no test drew the thing. The plan for
// this phase then read that comment as a live constraint (#3437's own correction).
//
// So this is the guard the shortcut was standing in for: the sheet draws its list, and it draws its
// empty state, and which one it draws depends on whether there is work due.
@MainActor
@Suite("The Follow-ups sheet draws its list (#3437)")
struct FollowUpsListRendersTests {
    private let now = Date(timeIntervalSince1970: 1_780_000_000)   // 2026-06-27

    private func container() throws -> ModelContainer {
        try ModelContainer(for: Schema([Prospect.self, Recipient.self, Inquiry.self,
                                        WatchedSource.self]),
                           configurations: [ModelConfiguration(isStoredInMemoryOnly: true)])
    }

    // A show that has been and gone, pitched and sent, which is what `PostEventPrompt` asks about. The
    // shape is taken from `StoodDownShowNoteOnScreenTests.show()` rather than invented, so this renders
    // the same row that suite already asserts the wording of.
    @discardableResult
    private func seedDueWork(in ctx: ModelContext) -> Prospect {
        let p = Prospect(naturalKey: "aurora|2026-06-10|rivermill hall", groupName: "Aurora Strings",
                         discipline: "music", venue: "Rivermill Hall", performanceDate: "2026-06-10",
                         sourceListingURL: nil, priorRelationship: "none", production: "self",
                         profile: "strong", coverage: "likely_uncovered", fitScore: 8, tier: "high",
                         fitReason: "r", matchedClientName: nil, possibleMatchSource: nil,
                         possibleMatchName: nil, status: .contacted)
        let r = Recipient(id: "rowan@aurorastrings.example", email: "rowan@aurorastrings.example",
                          name: "Rowan", provenance: .act)
        r.sendState = .sent
        r.sentAt = Date(timeIntervalSince1970: 1_777_000_000)
        r.gmailMessageId = "m1"
        r.gmailThreadId = "t1"
        r.sendGroupId = "g"
        p.setRecipients([r])
        p.sentAt = r.sentAt
        ctx.insert(p)
        try? ctx.save()
        return p
    }

    // Hosted in a REAL window through NSHostingView, not inspected.
    //
    // ViewInspector cannot render this view at all, and that is documented rather than discovered:
    // `ArchiveView.swift:270` explains that its own `row` was made internal and handed its context and
    // feedback explicitly "so ArchiveViewSendStateTests can call this directly without needing a real
    // SwiftUI environment hosted around a bare ArchiveView instance". A view holding `@Query` properties
    // AND an `@Environment(ActionFeedback.self)` traps when ViewInspector evaluates its body, whatever
    // order the modifiers go in: measured 2026-09-03, `No Observable object of type ActionFeedback
    // found`, on both branches.
    //
    // So this uses the rig #3480 built for the scroll tests. AppKit really lays the view out, so what is
    // asserted is what SwiftUI actually produced: whether an NSScrollView exists under the hosting view.
    // That is a coarser question than ViewInspector would answer, and it is the exact question #3437 is
    // about.
    private func host(_ view: some View) -> (window: NSWindow, hosting: NSHostingView<AnyView>) {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 500, height: 560),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        // #3480: AppKit's default releases the window on close while this scope still holds it, which
        // crashed the shared app host and truncated the whole hosted target.
        window.isReleasedWhenClosed = false
        let hosting = NSHostingView(rootView: AnyView(view))
        hosting.frame = window.contentLayoutRect
        hosting.autoresizingMask = [.width, .height]
        window.contentView?.addSubview(hosting)
        window.layoutIfNeeded()
        hosting.layoutSubtreeIfNeeded()
        return (window, hosting)
    }

    private func firstScrollView(in view: NSView) -> NSScrollView? {
        if let scroll = view as? NSScrollView { return scroll }
        for sub in view.subviews {
            if let found = firstScrollView(in: sub) { return found }
        }
        return nil
    }

    private func sheet(_ container: ModelContainer) -> some View {
        FollowUpsView(gmailConnectedOverride: true, replyRunAliveOverride: false)
            .modelContainer(container)
            .environment(ActionFeedback())
    }

    // The state this suite exists for: there IS work due, so the sheet lays out a scrolling list.
    @Test func withWorkDueTheSheetDrawsAScrollingList() throws {
        let c = try container()
        seedDueWork(in: ModelContext(c))

        let (window, hosting) = host(sheet(c))
        defer { window.close() }

        #expect(firstScrollView(in: hosting) != nil,
                Comment(rawValue: "the Follow-ups sheet laid out no NSScrollView with work due, so its "
                        + "list cannot hold its scroll position across a rebuild (#976)"))
    }

    // The other branch, so the assertion above cannot be satisfied by a sheet that draws a list whatever
    // is in the store, which is what a single-state test would allow (L159).
    @Test func withNothingDueTheSheetDrawsNoListAtAll() throws {
        let c = try container()

        let (window, hosting) = host(sheet(c))
        defer { window.close() }

        #expect(firstScrollView(in: hosting) == nil,
                "the sheet laid out a scrolling list with nothing due, so the empty state is not drawn")
    }
}
