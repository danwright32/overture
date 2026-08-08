import Testing
import Foundation
import SwiftUI
import ViewInspector
@testable import Overture

// #2217: the shared search field HANDLES Return itself, so the keypress can never fall through to
// whatever the host window has made its default button.
//
// The live fault was in the Sources sheet, whose default button is Done. Typing a source name and
// pressing Return, an ordinary reflex, dismissed the sheet and took the search, the scroll position
// and any inline edit in progress with it, with no warning and no undo. That is a property of the
// FIELD and the sheet it happens to sit in, not of the sheet alone, so the fix and this test both
// live with the field: the next sheet to host it inherits the fix rather than the bug.
//
// A field with no submit handler registered is the whole defect, so the assertions below are about
// the handler EXISTING and about it doing nothing to the query, not about the sheet, which SwiftUI
// will not let a test press a real Return key into.
@MainActor
@Suite("The shared search field handles its own Return (#2217)")
struct SearchFieldSubmitTests {

    // The Sources sheet's field, built the way that sheet builds it: no submit action, because the
    // list under it is already filtered as you type and there is nothing for a submit to do.
    //
    // `callOnSubmit` THROWS when no onSubmit modifier is present, which is exactly the shape of the
    // defect, so this passing is the claim: the field consumed the keypress rather than letting it
    // reach the window.
    @Test func aFieldWithNothingToSubmitStillHandlesReturn() throws {
        let query = Binding.constant("carnegie")
        let field = OVSearchField(query: query, placeholder: "Search sources", clearLabel: "Clear")
        try field.inspect().find(ViewType.TextField.self).callOnSubmit()
    }

    // Pressing Return must not empty the box either. Consuming the keypress and then throwing away
    // what was typed would read as the same loss to the person who pressed it.
    @Test func returnLeavesWhatWasTypedAlone() throws {
        var typed = "carnegie"
        let query = Binding(get: { typed }, set: { typed = $0 })
        let field = OVSearchField(query: query, placeholder: "Search sources", clearLabel: "Clear")
        try field.inspect().find(ViewType.TextField.self).callOnSubmit()
        #expect(typed == "carnegie")
    }

    // The toolbar's show search builds the same field with a focus binding, and it must be handled
    // there too. That field sits next to no default button today, so this is not a live fault, which
    // is precisely why it needs pinning: the reason the Sources sheet broke is that a field with no
    // submit handler is harmless right up until somebody puts it in a window that has one.
    @Test func theToolbarFlavourOfTheFieldHandlesReturnToo() throws {
        let query = Binding.constant("carnegie")
        let field = FocusedSearchFieldHost(query: query)
        try field.inspect().find(ViewType.TextField.self).callOnSubmit()
    }

    // OVSearchField's focus binding is a FocusState projection, which only exists inside a view, so
    // the toolbar's shape has to be built in one rather than constructed directly.
    private struct FocusedSearchFieldHost: View {
        @Binding var query: String
        @FocusState private var isFocused: Bool

        var body: some View {
            OVSearchField(query: $query,
                          placeholder: "Search shows",
                          clearLabel: "Clear",
                          focused: $isFocused)
        }
    }
}
