import Testing
import Foundation

// #3516: `QueueRenderPassWorkUnitCostTests` pins how much self-booking work DRAWING THE SCREEN costs, and
// it has to ask the night index the questions the view asks, because a SwiftUI body cannot be evaluated
// in a unit test. That is a second expression of what `QueueView` does, and a second expression of one
// thing drifts from the first with nothing reporting it (L263, L26).
//
// So the mirror is checked against the code: every `QueueModel.selfBooking*` call `QueueView` makes is
// found by reading the source, and each one is either declared as a RENDER-path question the mirror asks
// or declared as an ACTION-path one it deliberately does not. A call belonging to neither list is the
// finding, because that is a question the screen now asks and the pinned number does not count.
//
// This is the check that stops the pinned figure going quietly stale. Without it, adding a fourth
// question to a row leaves the number where it is and nothing anywhere goes red (L63).
@Suite("The self-booking cost mirror still matches the screen (#3516)")
struct SelfBookingScreenWorkMirrorTests {

    private var queueView: String { SourceGuardHelper.source("Overture/UI/QueueView.swift") }

    // The questions the mirror asks, in `QueueRenderPassWorkUnitCostTests.askTheScreensSelfBookingQuestions`.
    static let askedByTheMirror = ["selfBookingNote", "selfBookingRowMarker", "selfBookingWorkableNote"]

    // The ones it deliberately does not, each with the reason. An action runs on a press, not while the
    // screen is being drawn, so it belongs to no per-render figure.
    struct NotOnTheRenderPath: Equatable, Sendable {
        let symbol: String
        let why: String
    }

    static let actionsOnly: [NotOnTheRenderPath] = [
        NotOnTheRenderPath(symbol: "selfBookingIndex",
                           why: "Builds an index rather than asking one. The render path takes the one "
                              + "the pass already built, on RenderData.selfBooking; these two call sites "
                              + "are inside the Prep confirm and the send confirm, which run on a press."),
        NotOnTheRenderPath(symbol: "selfBookingClash",
                           why: "Inside the Prep launch confirmation, raised by a press."),
        NotOnTheRenderPath(symbol: "sendSelfBookingWarning",
                           why: "Inside the send confirmation, raised by a press."),
    ]

    // Every `QueueModel.selfBooking...` or `QueueModel.sendSelfBooking...` symbol the file calls, read
    // from the source rather than listed, so a fourth question added next year is judged (L96).
    static func questionsAskedIn(_ source: String) -> Set<String> {
        var found: Set<String> = []
        let code = SourceGuardHelper.normalizedCode(source)
        for piece in code.components(separatedBy: "QueueModel.").dropFirst() {
            let symbol = piece.prefix { $0.isLetter || $0.isNumber }
            guard symbol.lowercased().contains("selfbooking") else { continue }
            found.insert(String(symbol))
        }
        return found
    }

    @Test("every self-booking question the queue asks is accounted for")
    func everyQuestionIsAccountedFor() {
        let asked = Self.questionsAskedIn(queueView)
        // A reader that stopped matching would report a clean file, which is the emptiest possible failure
        // reading as the cleanest possible pass (L98).
        #expect(asked.count >= 4,
                "read only \(asked.count) self-booking calls out of QueueView, so this checked nothing")

        let accounted = Set(Self.askedByTheMirror).union(Self.actionsOnly.map(\.symbol))
        let unaccounted = asked.subtracting(accounted).sorted()
        #expect(unaccounted.isEmpty,
                """
                QueueView asks \(unaccounted.joined(separator: ", ")) of the self-booking rule, and the \
                cost mirror in QueueRenderPassWorkUnitCostTests neither asks it nor records why it does \
                not. If it is on the render path, add it to askTheScreensSelfBookingQuestions and \
                re-derive allowedSelfBookingShowsExaminedOnScreen; if it runs on a press, add it to \
                actionsOnly with that reason (#3516).
                """)
    }

    @Test("every question the mirror asks is one the queue really asks")
    func theMirrorAsksNothingInvented() {
        let asked = Self.questionsAskedIn(queueView)
        for symbol in Self.askedByTheMirror {
            #expect(asked.contains(symbol),
                    """
                    The cost mirror asks \(symbol) and QueueView no longer does, so the pinned screen \
                    figure counts work the screen has stopped doing (#3516).
                    """)
        }
        for entry in Self.actionsOnly {
            #expect(asked.contains(entry.symbol),
                    "\(entry.symbol) is recorded as an action-path question and QueueView no longer calls it")
            #expect(entry.why.count > 40, "\(entry.symbol) is excused with no real reason written")
        }
    }

    // The gate that makes the Scout figure zero, asserted directly so a change that starts asking on Scout
    // is a red test rather than a number that quietly grows.
    @Test("the row marker and the date note are both gated off Scout")
    func bothScreenQuestionsAreGatedOffScout() {
        #expect(SourceGuardHelper.containsCode(
            "if focusedStage != .scout, let note = QueueModel.selfBookingNote(", in: queueView))
        #expect(SourceGuardHelper.containsCode("let selfBookingMarker = focusedStage != .scout", in: queueView))
    }
}
