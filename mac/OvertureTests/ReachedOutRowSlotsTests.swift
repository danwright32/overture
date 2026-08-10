import Testing
import Foundation

// #2167. Nothing decided what the reached-out row is allowed to show at once. Each control arrived by its
// own issue, each defensible alone, and no issue owned the combination.
//
// The premise the issue was filed on has since changed, and this is what it changed to. #2154 took two
// controls off the row (a second bare Confirm and the Archive jump) and #2166 made the timing label and
// Answer mutually exclusive. So the question is no longer "how do we get five down to something sane",
// it is "what is the rule, and what stops a sixth arriving without anyone deciding".
//
// The rule, stated once here rather than spread across four `if`s nobody reads together:
//
//   1. Exactly one TIMING slot, always. Either when the next touch is due, or the Answer control, which
//      says the same thing better when somebody is waiting.
//   2. At most one STATE slot: what Dan has said the conversation is, when there is a conversation.
//   3. At most one ACTION slot: the single thing that is actually due.
//
// Three slots, each answering a different question. That is not stacking, and the count is the thing
// worth protecting: a fourth is what turns a row into a menu.
@Suite("What the reached-out row may show at once (#2167)")
struct ReachedOutRowSlotsTests {

    // MARK: the rule

    // The timing question always has exactly one answer on screen. Neither both nor neither.
    @Test func thereIsAlwaysExactlyOneTimingSlot() {
        for replyOffered in [true, false] {
            for stateControl in [true, false] {
                for action in [nil, "Send a follow-up"] {
                    let slots = ReachedOutRowSlots.slots(replyOffered: replyOffered,
                                                         showsStateControl: stateControl,
                                                         dueActionLabel: action)
                    let timing = slots.filter { $0 == .timing || $0 == .answer }
                    #expect(timing.count == 1,
                            "replyOffered=\(replyOffered) produced \(timing.count) timing slots")
                }
            }
        }
    }

    @Test func somebodyWaitingGetsAnswerRatherThanACountdown() {
        let slots = ReachedOutRowSlots.slots(replyOffered: true, showsStateControl: true,
                                             dueActionLabel: nil)
        #expect(slots.contains(.answer))
        #expect(!slots.contains(.timing))
    }

    @Test func nobodyWaitingGetsTheCountdown() {
        let slots = ReachedOutRowSlots.slots(replyOffered: false, showsStateControl: false,
                                             dueActionLabel: nil)
        #expect(slots == [.timing, .closeOut])
    }

    // The ceiling. #2112/#2224 raised it from three to four, deliberately and once: the control that ENDS
    // a pitch had lived only on the Archive card, which Dan does not open, so the outcome was in practice
    // not recorded at all. This is the assertion that fails the day somebody adds a FIFTH without deciding
    // it belongs.
    @Test func theRowNeverShowsMoreThanFourThings() {
        for replyOffered in [true, false] {
            for showPassed in [true, false] {
                for stateControl in [true, false] {
                    for action in [nil, "Send a follow-up", "Send a closing note"] {
                        let slots = ReachedOutRowSlots.slots(replyOffered: replyOffered,
                                                             showPassed: showPassed,
                                                             showsStateControl: stateControl,
                                                             dueActionLabel: action)
                        #expect(slots.count <= 4, "the row showed \(slots.count) things at once")
                        #expect(Set(slots).count == slots.count, "the row showed the same slot twice")
                    }
                }
            }
        }
    }

    // #2112: the hint REPLACES the countdown rather than stacking on it. A row counting down to a
    // follow-up on a night that has already happened is a promise it cannot keep.
    @Test func apassedShowSaysSoInsteadOfCountingDown() {
        let slots = ReachedOutRowSlots.slots(replyOffered: false, showPassed: true,
                                             showsStateControl: false, dueActionLabel: nil)
        #expect(slots.contains(.passedHint))
        #expect(!slots.contains(.timing))
    }

    // And somebody actively waiting still outranks the date, because a person is a stronger claim on Dan
    // than a night that has gone.
    @Test func somebodyWaitingOutranksAPassedShow() {
        let slots = ReachedOutRowSlots.slots(replyOffered: true, showPassed: true,
                                             showsStateControl: false, dueActionLabel: nil)
        #expect(slots.contains(.answer))
        #expect(!slots.contains(.passedHint))
        #expect(!slots.contains(.timing))
    }

    // The busiest real row: answered, in a known state, with a nudge now due. Three different questions,
    // three answers, no duplication.
    @Test func theBusiestRowShowsFourDifferentThings() {
        let slots = ReachedOutRowSlots.slots(replyOffered: false, showsStateControl: true,
                                             dueActionLabel: "Send a follow-up")
        #expect(slots == [.timing, .conversationState, .closeOut, .dueAction])
    }

    // Order is part of the rule, not an accident of where the `if`s happen to sit. Timing leads, the
    // action Dan can take comes last, and reordering them is a visible change to a stated rule.
    @Test func theOrderIsFixedRegardlessOfWhichSlotsAppear() {
        let all = ReachedOutRowSlots.slots(replyOffered: true, showsStateControl: true,
                                           dueActionLabel: "Send a closing note")
        #expect(all == [.answer, .conversationState, .closeOut, .dueAction])
    }

    // A row can never be blank. Whatever else is missing, the timing slot is always filled, so there is
    // no state in which the trailing column renders as an empty gap.
    @Test func theRowIsNeverEmpty() {
        let slots = ReachedOutRowSlots.slots(replyOffered: false, showsStateControl: false,
                                             dueActionLabel: nil)
        #expect(!slots.isEmpty)
    }

    // MARK: the view actually obeys it

    // The rule is worth nothing if the view quietly grows a fourth control beside it. This counts the
    // view-producing constructs in the trailing column and pins them to the declared slots, so adding a
    // control fails here and forces whoever adds it to decide it belongs (#2167's whole point).
    //
    // A count, deliberately, because the count IS the quantity being protected rather than a stand-in for
    // it (L63): "how many things may this row show" is the question the issue asks.
    @Test func theTrailingColumnRendersExactlyTheDeclaredSlots() throws {
        let source = SourceGuardHelper.source("Overture/UI/QueueView.swift")
        #expect(!source.isEmpty)
        let body = try String(SourceGuard.functionBody(named: "reachedOutRow", in: source))
        let column = try #require(
            SourceGuardHelper.between("VStack(alignment: .trailing, spacing: 6) {", and: "\n        }",
                                      in: body),
            "the reached-out row's trailing column was not found where the guard expects it")

        for (token, slot) in Self.renderers {
            #expect(column.contains(token), "the \(slot) slot is no longer rendered by \(token)")
        }
        // Nothing else draws. Counted rather than listed, so a new control cannot hide behind a name the
        // guard was never told about.
        let drawn = column.components(separatedBy: "Text(").count - 1
            + column.components(separatedBy: "Button(").count - 1
            + column.components(separatedBy: "ConversationStateControl(").count - 1
            // #2112/#2224: a named view is one control to a person and one construct here. A Menu spelled
            // out inline would put its ITEMS' buttons in this count, so the guard would read four where
            // he sees one, which is why the close-out is its own view.
            + column.components(separatedBy: "CloseOutMenu(").count - 1
        #expect(drawn == ReachedOutRowSlots.Slot.allCases.count,
                """
                the trailing column draws \(drawn) things but \
                \(ReachedOutRowSlots.Slot.allCases.count) slots are declared. \
                Adding a control here is a decision about what the row may show at once (#2167): \
                add it to ReachedOutRowSlots.Slot and say where it sits in the order, or do not add it.
                """)
    }

    // The order half of the rule, which the check above does not cover. Without this, `Slot`'s declared
    // order is a comment: the view could draw the action above the timing line and every other assertion
    // here would still pass, because presence and count are both unchanged by reordering.
    //
    // Read from where each renderer actually sits in the source, since that IS the order a vertical stack
    // draws in. It does not pin pixels, and it is not meant to; it pins the sequence the rule states.
    @Test func theTrailingColumnDrawsTheSlotsInTheDeclaredOrder() throws {
        let source = SourceGuardHelper.source("Overture/UI/QueueView.swift")
        let body = try String(SourceGuard.functionBody(named: "reachedOutRow", in: source))
        let column = try #require(
            SourceGuardHelper.between("VStack(alignment: .trailing, spacing: 6) {", and: "\n        }",
                                      in: body))

        let positions: [(slot: ReachedOutRowSlots.Slot, at: Int)] = try ReachedOutRowSlots.Slot.allCases
            .map { slot in
                let token = try #require(Self.renderers.first { $0.value == slot }?.key,
                                         "no renderer is declared for \(slot)")
                let range = try #require(column.range(of: token), "\(slot) is not drawn at all")
                return (slot, column.distance(from: column.startIndex, to: range.lowerBound))
            }

        let drawnOrder = positions.sorted { $0.at < $1.at }.map(\.slot)
        #expect(drawnOrder == ReachedOutRowSlots.Slot.allCases,
                """
                the row draws its slots as \(drawnOrder) but the rule declares \
                \(ReachedOutRowSlots.Slot.allCases). Order is part of the rule (#2167): timing leads \
                because it answers "why am I looking at this", and the action comes last.
                """)
    }

    private static let renderers: [String: ReachedOutRowSlots.Slot] = [
        "Text(ReachedOutQueue.timingLabel": .timing,
        "Button(ReplyPanelCopy.answer": .answer,
        "ConversationStateControl(": .conversationState,
        "Button(label)": .dueAction,
        // #2112/#2224
        "Text(hint)": .passedHint,
        "CloseOutMenu(": .closeOut
    ]
}
