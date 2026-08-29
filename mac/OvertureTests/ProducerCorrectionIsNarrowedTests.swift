import Testing
import Foundation

// #1732: the classification line and its correction were on EVERY row whose presenter the gate can key.
//
// Dan, on the post-merge check for #1719: it should show "only where it looks uncertain". Measured
// 2026-07-29 it was on 618 of 724 rows, 85%, across only 156 organisations. #1763 took that to 306 by
// removing the rows where a correction was applied, stored and then ignored by the gate, which was the
// better half of the fix because what it removed was not merely noisy, it was untrue.
//
// Dan's call, 2026-08-28, choosing this over putting corrections back on the Presenters sheet: the
// correction lives on the shaky rows only. The bar is the one the shortlist already uses, an organisation
// carrying enough rows that a correction is worth something (`shortlistMinimumRows`), so the row menu and
// the sheet that surfaces the same candidates cannot drift apart on what "worth correcting" means.
//
// The counter-risk he named is real and is why the ORDER of the rules matters: a correction already in
// force keeps its control whatever the row count, or Dan could set one on a small organisation and then
// have no way back, which is #1679's shape arriving by a new route.
@Suite("The producer correction is offered only where it is worth something (#1732)")
struct ProducerCorrectionIsNarrowedTests {
    private let noBrands = ProducerGate.VenueBrands.none

    // The rows this issue is about: an organisation carrying one or two shows. A correction there saves
    // nothing and protects nothing, and it was on every one of them.
    @Test func aSmallOrganisationNoLongerCarriesTheControl() {
        #expect(QueueModel.correctableOrganisation("Two Show Company", venueBrands: noBrands,
                                                   standing: .none, rowCount: 2) == nil)
    }

    // And an organisation carrying enough of them still does, or the control would be gone entirely.
    @Test func anOrganisationWorthCorrectingKeepsIt() {
        #expect(QueueModel.correctableOrganisation("FRIGID New York", venueBrands: noBrands,
                                                   standing: .none,
                                                   rowCount: OrganisationListing.shortlistMinimumRows)
                == "FRIGID New York")
    }

    // The bar is the SHORTLIST's own, not a number picked here, so the row menu and the Presenters sheet
    // cannot disagree about which organisations are worth correcting (L16, #1702).
    @Test func theBarIsTheShortlistsOwn() {
        let bar = OrganisationListing.shortlistMinimumRows
        #expect(QueueModel.correctableOrganisation("X", venueBrands: noBrands,
                                                   standing: .none, rowCount: bar - 1) == nil)
        #expect(QueueModel.correctableOrganisation("X", venueBrands: noBrands,
                                                   standing: .none, rowCount: bar) == "X")
    }

    // The counter-risk, and the reason the row-count rule is LAST. A correction Dan has already made keeps
    // its way back however few rows the organisation carries. Without this he could set one on a small
    // organisation and be stranded with a verdict he cannot revisit, which is exactly #1679.
    @Test func aCorrectionAlreadyInForceKeepsItsWayBackOnAnySizeOfOrganisation() {
        for standing in [ProducerOverrideEditing.Standing.promoted, .demoted] {
            #expect(QueueModel.correctableOrganisation("One Show Company", venueBrands: noBrands,
                                                      standing: standing, rowCount: 1)
                    == "One Show Company",
                    "a \(standing) correction on a single-row organisation must still be reversible")
        }
    }

    // #1763's rule is unchanged and still runs FIRST among the automatic cases: a presenter spelled
    // exactly like a room is refused by the gate before it reads any override, so promoting it would store
    // a key the gate ignores. A big row count must not resurrect that.
    @Test func aRoomNameIsStillRefusedHoweverManyRowsItCarries() {
        // Built from a corpus rather than injected, so the room-name verdict is the gate's own and
        // not this test's opinion of it: "Carnegie Hall" as a presenter is spelled exactly like the room
        // it plays, which is the EQUALITY arm promotion can never relax (#1763).
        let brands = ProducerGate.VenueBrands(shows: [
            ProducerGate.Show(presenter: "Carnegie Hall", venue: "Carnegie Hall"),
        ])
        #expect(QueueModel.correctableOrganisation("Carnegie Hall", venueBrands: brands,
                                                   standing: .none, rowCount: 100) == nil)
    }

    // And a name the gate cannot key at all is still nothing to correct, whatever else is true.
    @Test func aNameTheGateCannotKeyIsStillNothingToCorrect() {
        #expect(QueueModel.correctableOrganisation(nil, venueBrands: noBrands,
                                                   standing: .none, rowCount: 100) == nil)
        #expect(QueueModel.correctableOrganisation("", venueBrands: noBrands,
                                                   standing: .none, rowCount: 100) == nil)
    }
}
