import Testing
import Foundation

// #2630. The prep run writes ONE shape of pitch (a subject line plus roughly four paragraphs) whatever
// route the pitch will actually travel. That is right for email and wrong for a direct message, which is
// read in a narrow column on a phone and stops being read long before paragraph three.
//
// Measured 2026-08-13 on the Song & Word card (Vivace Arts Collective, The Green Room 42, 2026-08-16):
// the run found only an Instagram profile for the presenter and still produced a 150 word body under the
// subject "Photographing Vivace Arts Collective's Song & Word at The Green Room 42."
//
// THE INSTRUCTION IS IN THE RUNBOOK AND THE SKILL, and this is the mechanism beside it, because a rule
// that lives only in a prompt is a hope (L27). It WARNS rather than blocking: how long a pitch should be
// is a judgment about wording, not a fact about the text, which is the bar #789 set for a blocker, and
// the cost of a wrong block is Dan's time on a draft that reads perfectly.
@Suite("A DM is drafted as a DM (#2630)")
struct ADmIsDraftedAsADmTests {

    // Roughly the measured body: 150 words on a show whose only route is a profile.
    private var emailLengthBody: String {
        (0..<30).map { "Sentence \($0) about the work and the room and the evening ahead." }
            .joined(separator: " ")
    }

    private let dmLengthBody = """
        Hello, my name is Dan and I'm an arts photographer in NYC. I'm writing about your show at \
        The Example Room next month. I've photographed at Carnegie Hall for nearly ten years, and \
        I'd love to talk about your photography plans for the night.

        danwrightphotography.com
        """

    @Test func anEmailLengthBodyOnADmOnlyShowIsFlagged() {
        #expect(DraftCheck.findings(in: emailLengthBody, routeIsHandDelivered: true)
            .contains(.tooLongForADirectMessage))
    }

    // The SAME body on a show with an address is not flagged, which is the whole discrimination: the body
    // is not too long, it is too long for where it is going.
    @Test func theSameBodyGoingToAnInboxIsNotFlagged() {
        #expect(!DraftCheck.findings(in: emailLengthBody, routeIsHandDelivered: false)
            .contains(.tooLongForADirectMessage))
    }

    @Test func aDmLengthBodyOnADmOnlyShowIsNotFlagged() {
        #expect(!DraftCheck.findings(in: dmLengthBody, routeIsHandDelivered: true)
            .contains(.tooLongForADirectMessage))
    }

    // Absent is the default and every existing call site keeps it, so nothing that has not been told the
    // route can ever be flagged. A draft judged against a route nobody established would be a warning
    // about a fact this check never measured (L98, L11).
    @Test func acallerThatSaysNothingAboutTheRouteFlagsNothing() {
        #expect(!DraftCheck.findings(in: emailLengthBody).contains(.tooLongForADirectMessage))
    }

    // ADVISORY, and this is the assertion that keeps it so. How long a pitch should be is a judgment
    // about wording rather than a fact about the text, which is the bar #789 set for a blocker, and a
    // wrong block costs Dan time on a draft that reads perfectly.
    @Test func itWarnsRatherThanBlockingTheSend() {
        #expect(!DraftIssue.tooLongForADirectMessage.isBlocking)
    }

    // The finding says what to DO about it, in the terms the brief uses, rather than naming a threshold.
    @Test func thelabelSaysWhatIsWrongInDansTerms() {
        #expect(DraftIssue.tooLongForADirectMessage.label
                == "Too long for a DM: this show has no address, so it is sent by hand")
    }

    // Wired, not merely built: the rule is pure and its own tests would stay green while nothing on any
    // screen ever told it the route (L3). Asserted on the source, because a SwiftUI view passing an
    // argument is the connection a runtime test of the rule cannot see.
    @Test func thereviewCardTellsTheLintWhichRouteThePitchTravels() {
        let view = SourceGuardHelper.source("Overture/UI/DraftReviewView.swift")
        #expect(!view.isEmpty)
        #expect(SourceGuardHelper.containsCode("routeIsHandDelivered: item.routeIsHandDelivered", in: view),
                Comment(rawValue: "the card lints the draft without saying how it will travel, so the "
                        + "finding can never fire"))
    }

    // And the row decides it through the SAME pair `FormPitch` is gated on, so the check that warns
    // about a body and the control that records the pitch cannot disagree about how it goes out (L16).
    @Test func theroutePredicateReadsTheSameVerdictTheDmPathDoes() {
        let model = SourceGuardHelper.source("Overture/UI/QueueView+Model.swift")
        #expect(!model.isEmpty)
        #expect(SourceGuardHelper.containsCode(
            "reachabilityResult == .contactFormOnly || reachabilityResult == .socialOnly", in: model),
                Comment(rawValue: "the route predicate is written some other way, so it can drift from "
                        + "the one that decides whether a DM can be recorded at all"))
    }

    // The boundary is stated once and read by the rule, so the brief and the check cannot come to mean
    // different numbers. 80 words is the top of the brief's range.
    @Test func theboundaryIsTheBriefsOwnNumber() {
        #expect(DraftCheck.directMessageWordCeiling == 80)
    }
}
