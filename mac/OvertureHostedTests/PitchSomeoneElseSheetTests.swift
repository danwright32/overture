import Testing
import Foundation
import SwiftUI
import SwiftData
import ViewInspector
@testable import Overture

// #4170: the panel that takes the new contact, rendered.
//
// Here rather than only in `APitchToSomebodyElseTests`, which drives the mutation, because a control
// nobody draws cannot be pressed and a sentence a view never renders says nothing (#1995). This drives
// the real `PitchSomeoneElseSheet`.
@MainActor
@Suite("The panel for pitching somebody else (#4170)")
struct PitchSomeoneElseSheetTests {
    private func show() throws -> Prospect {
        // Through the helper, never a container built here: a hosted suite's own container autosaves on
        // its main context and arms the timer that kills the test host between tests (#3874).
        let ctx = ModelContext(try TestModelContainer.inMemory([Prospect.self, Recipient.self]))
        let p = Prospect(naturalKey: "k", groupName: "Symphony in Motion", discipline: "choral",
                         venue: "Church of the Ascension", performanceDate: "2026-11-01",
                         sourceListingURL: nil, priorRelationship: "none", production: "self",
                         profile: "strong", coverage: "likely_uncovered", fitScore: 7,
                         tier: "high", fitReason: "r", matchedClientName: nil,
                         possibleMatchSource: nil, possibleMatchName: nil, status: .contacted)
        ctx.insert(p)
        return p
    }

    private func sheet(_ p: Prospect) -> PitchSomeoneElseSheet {
        PitchSomeoneElseSheet(prospect: p, onClose: {})
    }

    @Test func thepanelSaysWhatItIsAndWhichShowItIsAbout() throws {
        let p = try show()
        let texts = try sheet(p).inspect().findAll(ViewType.Text.self).map { try $0.string() }
        #expect(texts.contains { $0 == RePitchCopy.panelTitle })
        #expect(texts.contains { $0 == "Symphony in Motion" },
                "the panel covers the row it was opened from and does not say which show it is about")
        #expect(texts.contains { $0 == RePitchCopy.panelHelp })
    }

    // THE CONTROL CANNOT LOOK WILLING to take something the write then refuses, which is the rule every
    // other hand-added contact field in this app is gated by (L109, #2629). Asked through the same
    // `ManualContactRoute.parse` the mutation asks, rather than a second idea of what a route is.
    @Test func theaddButtonIsDeadUntilTheRouteIsOneOverturCanUse() throws {
        let p = try show()
        let button = try sheet(p).inspect().find(button: RePitchCopy.addAction)
        #expect(try button.isDisabled(), "an empty field offered a press that would be refused")

        #expect(ManualContactRoute.parse("not an address") == nil,
                "the fixture's bad route is one the parse accepts, so this test asserts nothing")
        #expect(ManualContactRoute.parse("ben.tucker@example.org") != nil)
    }

    @Test func itoffersBothTheRouteAndAnOptionalName() throws {
        let p = try show()
        let fields = try sheet(p).inspect().findAll(ViewType.TextField.self)
        let placeholders = try fields.map { try $0.labelView().text().string() }
        #expect(placeholders.contains(ContactFieldCopy.routePlaceholder))
        #expect(placeholders.contains(ContactFieldCopy.namePlaceholder))
    }

    // Both themes, for the same reason every other surface is checked in both (L606, L569).
    @Test(arguments: [ColorScheme.light, ColorScheme.dark])
    func thepanelRendersInBothThemes(_ scheme: ColorScheme) throws {
        let p = try show()
        let view = sheet(p).environment(\.colorScheme, scheme)
        let texts = try view.inspect().findAll(ViewType.Text.self).map { try $0.string() }
        #expect(texts.contains { $0 == RePitchCopy.panelTitle })
    }
}
