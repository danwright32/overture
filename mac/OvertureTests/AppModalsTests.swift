import Testing
import Foundation

// #2202 / #2200. macOS presents a SwiftUI alert and a SwiftUI sheet the same way, as a window sheet, and
// two of them on one window do not stack: the second queues behind the first and is not on screen at all.
// RootView carries four alerts and roughly fifteen sheets, so every one of those alerts could be raised
// into a window already presenting something.
//
// It surfaced on 2026-08-06 as the scout read-budget question queuing behind the progress takeover: all
// 68 sources fetched, the takeover froze at "68 of 68 done" and kept counting, and the sweep waited on an
// answer that could not be given. The generic "Something went wrong" alert has the same shape, which is
// the worse half: a real error raised during a scout or a Prep run vanishes silently, at the moment
// something has already gone wrong (L10, L13).
@MainActor
@Suite("Raising something Dan has to answer (#2202)")
struct AppModalsTests {
    // The ordering IS the fix. Setting the alert's state before closing what is presented is exactly what
    // produces a question queued behind a sheet, and the two orderings are indistinguishable from any
    // test that only checks the end state.
    @Test func whatIsPresentedIsClosedBeforeTheQuestionIsRaised() {
        let modals = AppModals()
        var order: [String] = []
        modals.closesSheetsWith { order.append("closed the sheets") }

        modals.raise { order.append("raised the question") }

        #expect(order == ["closed the sheets", "raised the question"])
    }

    @Test func raisingMarksSomethingAsWaitingOnHim() {
        let modals = AppModals()
        modals.closesSheetsWith {}
        #expect(!modals.isPresenting)
        modals.raise {}
        #expect(modals.isPresenting)
        modals.settled()
        #expect(!modals.isPresenting)
    }

    // The failure path that matters most: a presenter nobody wired up. It must still raise the question,
    // because an error Dan cannot see is worse than a sheet left open (L42, fail toward showing him).
    @Test func aPresenterWithNoSheetsToCloseStillRaises() {
        let modals = AppModals()
        var raised = false
        modals.raise { raised = true }
        #expect(raised)
        #expect(modals.isPresenting)
    }

    // Each raise closes again. A second question later in the session must not inherit the first one's
    // work: sheets reopen, and a stale "already closed" would put the second question behind one of them.
    @Test func everyRaiseClosesAgain() {
        let modals = AppModals()
        var closes = 0
        modals.closesSheetsWith { closes += 1 }
        modals.raise {}
        modals.settled()
        modals.raise {}
        #expect(closes == 2)
    }
}

// The wiring half, which is a separate claim from the mechanism being right (L3: built is not wired).
// These read RootView's own source, because the four alert states are `@State` on a SwiftUI view and
// nothing outside it can reach them (see the note in AGENTS.md on view logic).
@Suite("RootView raises every alert through the one presenter (#2202)")
struct RootViewModalGuardTests {
    private var source: String { SourceGuardHelper.source("Overture/App/RootView.swift") }

    // Every sheet RootView can present must be closed by `closeEveryPresentedSheet`. Derived from the
    // `.sheet(isPresented: $x)` modifiers rather than listed here, so a sheet added later fails this
    // instead of quietly becoming a place questions go to die (L41).
    @Test func everySheetItCanPresentIsOneItCanClose() throws {
        let body = try #require(
            SourceGuardHelper.bodyOfFunction(named: "closeEveryPresentedSheet", in: source))
        var found = 0
        for line in source.split(separator: "\n") {
            guard let range = line.range(of: ".sheet(isPresented: $") else { continue }
            let name = line[range.upperBound...].prefix { $0.isLetter || $0.isNumber }
            found += 1
            #expect(body.contains("\(name) = false"),
                    "the \(name) sheet can hide a question that has to be answered")
        }
        #expect(found >= 12, "the guard must actually be finding the sheets it claims to check")
        // The two that are not plain booleans, named because their shape means the loop cannot see them.
        #expect(body.contains("addLead.isPresented = false"))
        #expect(body.contains("dayOffOffer.pending = nil"))
    }

    // And nothing raises an alert around the presenter. Each state may be set to nil freely (that is
    // clearing it); setting it to anything else is a question raised, and there is exactly one place per
    // alert where that may happen.
    @Test func nothingSetsAnAlertStateOutsideItsOwnRaiser() {
        // Each raiser is found by NAME (#2784). It used to be found by its whole signature, which is a
        // pin on the parameters it happens to take today: add one and the marker matches nothing,
        // `propertyBody` returns nil, and the `?? ""` below turns every assertion under it false while
        // the suite stays green. The related trap the old comment here warned about is now refused for
        // everybody by `SourceGuardMarkerIntegrityTests`: a marker stopping at "(" counts braces from
        // inside the signature and returns the rest of the type, which agrees with itself (L70).
        let raisers = ["errorMessage": "reportError",
                       "gmailConnectError": "reportGmailConnectError",
                       "cancelledScoutRead": "askAboutCancelledRead",
                       "scoutReadAsk": "askReadBudget"]
        for (state, raiser) in raisers {
            let inside = SourceGuardHelper.bodyOfFunction(named: raiser, in: source) ?? ""
            #expect(inside.contains("modals.raise"),
                    "\(state) must be raised through the one presenter")
            for line in source.split(separator: "\n") {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                guard trimmed.hasPrefix("\(state) = ") || trimmed.contains(" \(state) = ") else { continue }
                guard !trimmed.hasPrefix("//") else { continue }
                #expect(trimmed.contains("\(state) = nil") || inside.contains(trimmed),
                        "\(state) is set outside \(raiser), so that question can be swallowed by a sheet")
            }
        }
    }

    // #2200: answering the read-budget question puts the takeover back, because the run is not over. Both
    // routes out, the buttons and the dismissal, or a scout answered with Escape carries on with nothing
    // on screen, which is the same invisibility from the other end.
    @Test func answeringTheReadBudgetQuestionPutsTheTakeoverBack() throws {
        let answered = try #require(SourceGuardHelper.bodyOfFunction(named: "answerReadAsk", in: source))
        #expect(answered.contains("if isScanning { scoutSheetShown = true }"))

        let binding = try #require(SourceGuardHelper.propertyBody(
            "private var scoutReadAskBinding: Binding<Bool> {", in: source))
        #expect(binding.contains("if isScanning { scoutSheetShown = true }"),
                "a question dismissed with Escape still answers the sweep, which still has work to report")
    }
}
