import Testing
import Foundation
import SwiftUI
import ViewInspector
@testable import Overture

// #2188, the half only a rendered panel can answer.
//
// Deciding that a refused update is worth showing proves nothing about it reaching the screen: a rule and
// its wiring are two separate claims (L3), and the claim that failed on 2026-08-06 was the second one.
// The run refused, said why into a Terminal window, and the app displayed nothing at all.
@Suite("A refused update is on screen, in the words the run used (#2188)")
struct UpdateFailureOnScreenTests {
    private let refusal = "There is unsaved work in progress in the code folder, and updating would disturb it. Ask Claude to finish or put aside that work, then press Update again."

    private func texts(_ view: some View) throws -> [String] {
        try view.inspect().findAll(ViewType.Text.self).map { try $0.string() }
    }

    // Dan's case. The sentence on screen is the run's own, not a second copy written for the app.
    @Test func theReasonTheRunGaveIsWhatHeReads() throws {
        let sheet = UpdateFailureSheet(progress: .failed(reason: refusal), canRetry: true,
                                       onRetry: {}, onDismiss: {})
        let shown = try texts(sheet)

        #expect(shown.contains(UpdateAttemptCopy.title))
        #expect(shown.contains(refusal))
    }

    // A run that never started says that instead, because it is a different problem: nothing refused,
    // nothing ran at all.
    @Test func aRunThatNeverStartedSaysSoRatherThanBorrowingARefusal() throws {
        let sheet = UpdateFailureSheet(progress: .neverStarted, canRetry: true, onRetry: {}, onDismiss: {})
        let shown = try texts(sheet)

        #expect(shown.contains(UpdateAttemptCopy.body(.neverStarted)))
        #expect(shown.contains(refusal) == false)
    }

    // Both ways out are on screen. Try again is the whole point of showing this at all: the reason is
    // usually something that can be cleared in a minute, and he should not have to go looking for the
    // panel again afterwards.
    @Test func bothWaysOutAreOffered() throws {
        let sheet = UpdateFailureSheet(progress: .failed(reason: refusal), canRetry: true,
                                       onRetry: {}, onDismiss: {})
        let shown = try texts(sheet)

        #expect(shown.contains(UpdateAttemptCopy.tryAgain))
        #expect(shown.contains(UpdateAttemptCopy.dismiss))
    }

    // With no record of where the code lives there is nothing to run, so the button is not drawn. A
    // button that cannot act reads as an update that ran and did nothing (#1778).
    @Test func tryAgainIsWithheldWhenThereIsNothingToRun() throws {
        let sheet = UpdateFailureSheet(progress: .failed(reason: refusal), canRetry: false,
                                       onRetry: {}, onDismiss: {})
        let shown = try texts(sheet)

        #expect(shown.contains(UpdateAttemptCopy.tryAgain) == false)
        #expect(shown.contains(UpdateAttemptCopy.dismiss))
    }
}
