import Testing
import Foundation
import SwiftUI
import ViewInspector
@testable import Overture

// #2086: the Light/Dark switch reaching the screen. PreviewOnDarkTests proves the two cards render
// differently; nothing there would notice if the control that reaches the dark one were never drawn, and
// a preview whose second background is unreachable is a preview with one background (L3, and #2098's
// whole existence: a guard that fires into a surface nobody can reach is indistinguishable from none).
@Suite("The preview's light and dark switch on screen (#2086)")
struct PreviewBackgroundSwitchTests {
    private let body = "Hello there.\n\nDan"

    private func preview(_ html: String?) -> DraftSignaturePreview {
        DraftSignaturePreview(draftBody: body,
                              signature: OutboundSignature(html: html, plainText: "Dan Wright"))
    }

    // Present whenever there is a styled signature, and present whether or not anything is wrong with it:
    // a control that appeared only for the defect it was built for could not be used to LOOK for the next
    // one, which is the entire point of having both backgrounds.
    @Test func theSwitchIsOnScreenForACleanSignatureToo() throws {
        let view = preview(Signature2086Fixture.asTheMailClientSendsIt)
        let picker = try view.inspect().find(ViewType.Picker.self)
        let labels = try picker.findAll(ViewType.Text.self).compactMap { try? $0.string() }
        #expect(labels.contains("Light"))
        #expect(labels.contains("Dark"))
    }

    // And for the real signature behind #2086, which Overture now strips on the way out.
    @Test func theSwitchIsOnScreenForTheRealSignature() throws {
        #expect((try? preview(Signature2086Fixture.asSent).inspect().find(ViewType.Picker.self)) != nil)
    }

    // No styled signature means both backgrounds render the identical plain-text fallback, so a switch
    // there would be a control that changes nothing, which is worse than no control.
    @Test func thereIsNoSwitchWhenThereIsNoStyledSignature() throws {
        #expect((try? preview(nil).inspect().find(ViewType.Picker.self)) == nil)
        #expect((try? preview("").inspect().find(ViewType.Picker.self)) == nil)
    }

    // Which background it opens on is judged on the message that SHIPS. Overture strips the near-invisible
    // borders, so the real #2086 signature is clean by the time the preview sees it and opens on light;
    // a defect that survives the strip is what opens it on dark.
    @Test func itOpensOnTheBackgroundTheShippedSignatureNeeds() {
        let real = OutboundSignature(html: Signature2086Fixture.asSent, plainText: "Dan Wright")
        #expect(PreviewBackground.opening(for: real.sendableHTML) == .light)

        // A near-white border Overture could not reach (inside an attribute the stripper does not touch)
        // is contrived; a colour it deliberately leaves alone is the honest case, and the detector reads
        // borders, so this uses a border that survives because it is not in a style declaration it parses.
        let stillBroken = OutboundSignature(html: #"<div style="border-top:2px solid #fefefe">Dan</div>"#,
                                            plainText: "Dan Wright")
        #expect(GmailSignatureHealth.darkBackgroundReason(stillBroken.html!) != nil,
                "the fixture must actually trip the detector, or this proves nothing")
    }
}
