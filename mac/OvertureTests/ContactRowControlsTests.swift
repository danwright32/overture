import Testing

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

    // #2392 follow-up: the triage card's per-address strike follows the SAME rule as the review panel's
    // leading X, rather than inventing a looser one. The panel deliberately withholds the one-click
    // remove from a contact Dan has already written to (its removal is the destructive item inside the
    // "Mark…" menu), and the first cut of the triage control offered it on every address on every card,
    // including shows already pitched. One action, two surfaces, two different levels of exposure.
    @Test func theTriageStrikeIsOfferedOnlyWhereTheReviewPanelWouldOfferIt() {
        // Still pending, on a live card: offered, and it agrees with the panel's own rule.
        #expect(ContactRowControls.strikeIsOffered(sendState: .pending, showIsResolved: false))
        #expect(ContactRowControls.strikeIsOffered(sendState: .pending, showIsResolved: false)
                == ContactRowControls.leadingIsRemove(sendState: .pending))

        // Already written to: withheld, exactly as the panel withholds it.
        #expect(ContactRowControls.strikeIsOffered(sendState: .sent, showIsResolved: false) == false)
        #expect(ContactRowControls.strikeIsOffered(sendState: .sent, showIsResolved: false)
                == ContactRowControls.leadingIsRemove(sendState: .sent))
        #expect(ContactRowControls.strikeIsOffered(sendState: .suppressed, showIsResolved: false) == false)
    }

    // An INHERITED address has no contact behind it at all, so there is no send state to judge, and the
    // card itself is the only thing that can say whether striking it still means anything. A resolved
    // show is past the decision this control exists to serve.
    @Test func anInheritedAddressIsJudgedByTheCardBecauseItHasNoContact() {
        #expect(ContactRowControls.strikeIsOffered(sendState: nil, showIsResolved: false))
        #expect(ContactRowControls.strikeIsOffered(sendState: nil, showIsResolved: true) == false)
    }

    // The card-level gate holds even for a contact that is still pending: on a show already sent or
    // booked, a pending sibling is not somebody Dan is about to be asked to pitch.
    @Test func aResolvedShowOffersNoStrikeAtAll() {
        #expect(ContactRowControls.strikeIsOffered(sendState: .pending, showIsResolved: true) == false)
    }
}

