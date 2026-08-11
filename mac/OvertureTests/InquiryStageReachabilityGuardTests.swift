import Testing
import Foundation
import SwiftData

// #1505. An inquiry was once parked in `.sendApproved`, a stage with no clickable pill, so it was
// saved and counted and completely unreachable. Every test was green; only walking the app caught it.
//
// The guard is deliberately NOT "assert stage(for:) returns .review or .reachedOut". That would be a
// test compared against its own definition: change the mapping and the test changes with it. Instead it
// DRIVES the real `stage(for:)` across the inquiry states that can occur, takes whatever stages come
// back, and asserts each one is genuinely reachable by tapping a pill.
//
// Reachable is checked the way Dan meets it, with inputs holding ONLY that inquiry and no prospects.
// That is the exact shape of the original bug: the Send pill reports whichever of five problems is most
// urgent, so `.sendApproved` only ever became a pill's focus when approved PROSPECTS put it there. An
// inquiry sitting alone in that stage had nothing to click, which a test seeded with prospects would
// have missed entirely.
@MainActor
@Suite("An inquiry may only be placed in a navigable stage (#1505)")
struct InquiryStageReachabilityGuardTests {
    private func inquiry(sent: Bool, replied: Bool, outcome: Outcome?) -> Inquiry {
        let inq = Inquiry(source: .contactForm, inquirerName: "Ada", inquirerEmail: "ada@x.org",
                          eventName: "Gala", performanceDate: "2026-05-01", venue: "Weill")
        if sent { inq.sentAt = Date(timeIntervalSince1970: 1_780_000_000); inq.gmailMessageId = "m-1" }
        inq.replied = replied
        if let outcome {
            inq.outcome = outcome
            inq.outcomeSourceRaw = OutcomeSource.manual.rawValue
        }
        return inq
    }

    // Every combination an inquiry can actually be in, so no reachable-looking mapping hides behind a
    // state this test forgot to build.
    private var everyInquiryState: [Inquiry] {
        var all: [Inquiry] = []
        for sent in [true, false] {
            for replied in [true, false] {
                for outcome in [nil] + Outcome.allCases.map(Optional.init) {
                    all.append(inquiry(sent: sent, replied: replied, outcome: outcome))
                }
            }
        }
        return all
    }

    private func statuses(for inquiry: Inquiry) -> [AgentStatus] {
        let inputs = AgentInputs.from(prospects: [], inquiries: [inquiry],
                                      context: .at("2026-06-01", now: Date(timeIntervalSince1970: 1_780_500_000)), gmailConnected: true,
                                      prepRunning: false, replyRunAlive: false)
        return AgentRoster.statuses(inputs)
    }

    @Test("every stage an inquiry can be placed in has a pill that navigates to it")
    func everyPlacedStageIsNavigable() {
        var checkedAtLeastOne = false

        for inq in everyInquiryState {
            guard let focus = StageNavigation.stage(for: inq) else { continue }
            checkedAtLeastOne = true

            let pills = statuses(for: inq)
            let matching = pills.filter { $0.focus == focus }

            #expect(!matching.isEmpty,
                    "an inquiry was placed in \(focus), which no pill points at, so it is unreachable")
            for pill in matching {
                #expect(AgentRoster.chipAction(for: pill) == .focusOnStage,
                        "the pill for \(focus) does not navigate to the stage (\(pill.name))")
            }
        }

        // If the state matrix ever stops producing any placed inquiry at all, the loop above would pass
        // vacuously and guard nothing.
        #expect(checkedAtLeastOne)
    }

    // The counterpart the original bug would have failed: an OPEN inquiry is always placed somewhere.
    // A nil stage for a live inquiry is the same disappearance by a different route.
    @Test("an open inquiry is always placed in some stage")
    func openInquiriesAreAlwaysPlaced() {
        for inq in everyInquiryState where inq.isOpen {
            #expect(StageNavigation.stage(for: inq) != nil,
                    "an open inquiry was placed nowhere, so it is absent from the queue")
        }
    }

    // And the reverse: a closed inquiry must leave, rather than lingering in a stage forever.
    @Test("a closed inquiry is placed nowhere")
    func closedInquiriesLeave() {
        for inq in everyInquiryState where !inq.isOpen {
            #expect(StageNavigation.stage(for: inq) == nil)
        }
    }
}
