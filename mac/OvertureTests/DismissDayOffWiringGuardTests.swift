import Testing
import Foundation

// #924: the behaviour (which reasons offer, single-tap vs picker, that a run raises a request) is proven
// in DayOffOfferTests and DismissDayOffMutationTests. What those can't see is the last wire: that RootView
// actually PRESENTS the picker when a request is raised, and that the dismiss button is routed through the
// offer path at all rather than the plain status change. Cutting either wire leaves every behaviour test
// green while the feature does nothing, so this pins the wires themselves (the #887 lesson).
@Suite("Dismiss-to-day-off wiring (#924)")
struct DismissDayOffWiringGuardTests {
    private func source(_ rel: String, file: StaticString = #filePath) -> String {
        SourceGuardHelper.source(rel, file: file)
    }

    @Test func rootViewPresentsThePickerFromTheOfferRequest() {
        let rootView = source("Overture/App/RootView.swift")
        #expect(!rootView.isEmpty)
        #expect(rootView.contains("BlockDaysSheet(pending:"))            // the picker is presented
        #expect(rootView.contains("Bindable(dayOffOffer).pending"))      // keyed on the raised request
        #expect(rootView.contains(".environment(dayOffOffer)"))          // injected so rows can raise it
    }

    @Test func theDismissButtonRoutesThroughTheOfferPath() {
        let factory = source("Overture/UI/ProspectRowFactory.swift")
        #expect(!factory.isEmpty)
        // onDismiss must go through dismissForReason (which offers the day off), not the bare status change
        // that recorded a dismissal and touched the calendar not at all.
        #expect(factory.contains("dismissForReason("))
        #expect(factory.contains("onDismiss: { reason in ProspectMutations.dismissForReason"))
    }
}
