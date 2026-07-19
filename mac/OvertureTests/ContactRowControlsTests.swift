import Testing
@testable import Overture

// The draft-review contact row's chrome rules (#1137, #1139), pulled out of the SwiftUI view body so
// they are actually testable and can't quietly drift back (a repo lesson: a rule computed inside a
// view is invisible to the suite).
@Suite("Draft-review contact-row chrome (#1137, #1139)")
struct ContactRowControlsTests {
    // #1137: a still-pending contact's leading glyph IS the remove control (the X sits exactly where
    // the person icon used to be, and clicking it removes the contact). A sent contact keeps the plain,
    // non-interactive person icon.
    @Test func pendingRowLeadsWithTheRemoveX() {
        #expect(ContactRowControls.leadingIsRemove(sendState: .pending))
        #expect(ContactRowControls.leadingIcon(sendState: .pending) == "xmark.circle")
    }

    @Test func sentRowLeadsWithThePlainPersonIcon() {
        #expect(!ContactRowControls.leadingIsRemove(sendState: .sent))
        #expect(ContactRowControls.leadingIcon(sendState: .sent) == "person.crop.circle")
    }

    // #1139: the two replied-row controls set genuinely different things (record an OUTCOME vs note the
    // in-flight CONVERSATION STATE) and must never read as identical dropdowns. Their distinction is a
    // deliberate icon AND a deliberate, distinct accent, defined once here.
    @Test func outcomeAndConversationStateControlsAreVisuallyDistinct() {
        #expect(ContactRowControls.Kind.outcome.icon != ContactRowControls.Kind.conversationState.icon)
        #expect(ContactRowControls.Kind.outcome.accent != ContactRowControls.Kind.conversationState.accent)
    }
}
