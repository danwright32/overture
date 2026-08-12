import Testing
import Foundation

// #2544: Dan, prepping Neyla Pekarek by hand on 2026-08-11, met a greyed out Save draft with the address
// filled, the body written, the Subject box empty, and nothing on screen saying which of those was the
// problem.
//
// The app had already worked it out. `ManualPrepEditing` computed the exact sentence on every keystroke,
// the sheet kept only the boolean, and the four sentences were reachable only through the save path that
// the disabled button opens, so they could never be spoken (L109). This pins the shape that fixes it: ONE
// predicate, two renderings of it, so the reason shown beside the button and the acknowledgement spoken
// after a press cannot name different things.
@Suite("Why Save draft is refused, said before the press (#2544)")
struct ManualPrepSaveReasonTests {

    // Every way the sheet can refuse, and the field each one is about. Enumerated here rather than
    // spot-checked, so a case added to Refusal later without a reason fails this rather than shipping
    // as a button that goes grey saying nothing.
    private static let refusedStates: [(name: String, email: String, subject: String, body: String)] = [
        ("no address at all", "  ", "s", "b"),
        ("an address that cannot be read", "olga@bargemusic.org, nope", "s", "b"),
        ("a blank between two separators", "a@x.org,,b@y.org", "s", "b"),
        ("no subject", "olga@bargemusic.org", "  \n", "b"),
        ("no body", "olga@bargemusic.org", "s", " ")
    ]

    @Test func everyRefusedStateHasAReasonToShow() {
        for state in Self.refusedStates {
            let reason = ManualPrepEditing.reasonSaveIsDisabled(email: state.email, subject: state.subject,
                                                                body: state.body)
            #expect(reason != nil, "\(state.name) disables Save draft with no reason to put beside it")
            #expect(!(reason ?? "").isEmpty, "\(state.name) has an empty reason")
        }
    }

    // The clause that is true after a press and false before one. "Nothing was saved" under a button
    // nobody has pressed reports on an event that has not happened.
    @Test func noReasonClaimsSomethingAboutASaveThatHasNotHappened() {
        for state in Self.refusedStates {
            let reason = ManualPrepEditing.reasonSaveIsDisabled(email: state.email, subject: state.subject,
                                                                body: state.body) ?? ""
            #expect(!reason.lowercased().contains("nothing was saved"),
                    "\(state.name): the standing reason talks about a save that has not happened: \(reason)")
        }
    }

    // The two renderings come from the one predicate. If a later edit gives the button its own wording,
    // this is what notices, because the acknowledgement would stop being the reason plus what became of
    // the press.
    @Test func theAcknowledgementIsTheSameReasonPlusWhatBecameOfThePress() {
        for state in Self.refusedStates {
            let reason = ManualPrepEditing.reasonSaveIsDisabled(email: state.email, subject: state.subject,
                                                                body: state.body)
            let ack = ManualPrepEditing.refusal(email: state.email, subject: state.subject, body: state.body)
            #expect(reason != nil && ack != nil, "\(state.name) is missing one of the two renderings")
            #expect(ack == "\(reason ?? ""). Nothing was saved",
                    "\(state.name): the reason and the acknowledgement have drifted apart: \(ack ?? "nil")")
        }
    }

    // A sheet that can be saved says nothing, so the line is the reason a control is refusing and never
    // a standing note beside a working button.
    @Test func aSaveableSheetHasNoReasonToShow() {
        #expect(ManualPrepEditing.reasonSaveIsDisabled(email: "olga@bargemusic.org", subject: "s",
                                                       body: "b") == nil)
        #expect(ManualPrepEditing.canSave(email: "olga@bargemusic.org", subject: "s", body: "b"))
    }

    // Dan's actual state on 2026-08-11: address filled, body written, subject empty.
    @Test func theSubjectCaseNamesTheSubject() {
        let reason = ManualPrepEditing.reasonSaveIsDisabled(email: "olga@bargemusic.org", subject: "",
                                                            body: "Hi Olga, I photograph concerts.")
        #expect(reason == "Add a subject line")
    }

    // Several fields missing at once names the first one he would look at, matching the order the fields
    // sit on the sheet, rather than the last rule that happened to run.
    @Test func anEmptySheetNamesTheAddressFirst() {
        let reason = ManualPrepEditing.reasonSaveIsDisabled(email: "", subject: "", body: "")
        #expect(reason == "Add an address to send to")
    }

    // The gate and the reason are one call, so a state that shows a reason is always a state where the
    // button is off, and a state with no reason is always one where it is on. A control that is refusing
    // for a reason nothing can say is the whole defect.
    @Test func aReasonAndADisabledButtonAlwaysAgree() {
        let fields = ["", "   ", "olga@bargemusic.org", "a@x.org,,b@y.org", "nope"]
        for email in fields {
            for subject in ["", "s"] {
                for body in ["", "b"] {
                    let canSave = ManualPrepEditing.canSave(email: email, subject: subject, body: body)
                    let reason = ManualPrepEditing.reasonSaveIsDisabled(email: email, subject: subject,
                                                                        body: body)
                    #expect(canSave == (reason == nil), """
                        email "\(email)" subject "\(subject)" body "\(body)": \
                        canSave \(canSave) but reason \(reason ?? "nil")
                        """)
                }
            }
        }
    }
}
