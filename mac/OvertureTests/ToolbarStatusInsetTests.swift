import Testing
import Foundation
@testable import Overture

// #1411: the scout's quiet warning in the toolbar sat flush against the rounded box macOS draws around
// it. Dan: "no text should ever come that close to the edge of the box."
//
// macOS sizes that capsule to the toolbar item's content, and every OTHER toolbar item looks right only
// because Buttons and Menus bring their own control insets. The status slot hands the system a bare Text
// (and a bare Label in its other branch), which brings none, so the box shrink-wraps the glyphs.
//
// The inset is a named value rather than two numbers typed at the view, so it can be pinned here (#863)
// and so the two branches of the slot cannot drift apart.
@Suite("The toolbar status slot is inset like every other pill (#1411)")
struct ToolbarStatusInsetTests {

    // It must match the app's existing pill exactly. The issue asked for "12 by 5", but every in-app pill
    // is really 12 by 4 (OVCapsuleButton), and inventing a fifth spacing value to satisfy a number in an
    // issue would make the toolbar the one place that is subtly different from everywhere else.
    @Test func theInsetIsTheOneTheAppAlreadyUses() {
        #expect(ToolbarStatusStyle.horizontalInset == OVSpacing.sm)
        #expect(ToolbarStatusStyle.verticalInset == OVSpacing.xxs)
    }

    // Breathing room is the whole point, so a zero here would be the bug coming back.
    @Test func thereIsActuallyBreathingRoom() {
        #expect(ToolbarStatusStyle.horizontalInset > 0)
        #expect(ToolbarStatusStyle.verticalInset > 0)
    }

    // MARK: - The wiring

    private var rootView: String { SourceGuardHelper.source("Overture/App/RootView.swift") }

    // BOTH branches, or the OmniFocus warning (the one that appears when something is actually wrong) is
    // the one left looking broken. A guard, because a view's layout has no behavioural surface a domain
    // test can reach (#887), and a guard plus the value test above is this project's pairing for that.
    @Test func bothBranchesOfTheStatusSlotAreInset() throws {
        let range = try #require(rootView.range(of: "ToolbarItem(placement: .status)"))
        let slot = rootView[range.lowerBound...].prefix(900)

        #expect(slot.contains("OmniFocus sync failing"), "the guard is anchored on the right slot")
        #expect(slot.components(separatedBy: "toolbarStatusInset()").count - 1 == 2,
                "each branch hands macOS its own bare view, so each needs the inset")
    }

    // #1411 was explicit (Dan's call): the capsule grows to fit the sentence. Truncating it would trade a
    // cramped warning for an unreadable one, and this slot is where the scout says the thing he can act on.
    @Test func theStatusIsNeverTruncated() throws {
        let range = try #require(rootView.range(of: "ToolbarItem(placement: .status)"))
        let slot = rootView[range.lowerBound...].prefix(900)

        #expect(!slot.contains("lineLimit"))
        #expect(!slot.contains("truncationMode"))
    }
}
