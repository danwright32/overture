import Testing
import Foundation

// What the review row should show for a found contact, derived purely so the SwiftUI row stays
// dumb. The key behavior (#368): a form-only contact (no email, just a contact form) must surface
// the form as a tappable link, NEVER read as "No contact found". Email is still preferred over a
// form when both exist (Dan's ladder: a real email beats a contact form).
@Suite("Contact display")
struct ContactDisplayTests {
    @Test func namedDecisionMakerShowsPerson() {
        let d = ContactDisplay.from(name: "Emma Robinson", role: "Marketing Manager",
                                    email: "emma@act.example", formURL: nil)
        #expect(d == .person(name: "Emma Robinson", role: "Marketing Manager", email: "emma@act.example"))
    }

    @Test func genericInboxWithNoNameShowsEmail() {
        let d = ContactDisplay.from(name: nil, role: nil, email: "info@act.example", formURL: nil)
        #expect(d == .email("info@act.example"))
    }

    @Test func formOnlyContactShowsTappableForm() {
        let d = ContactDisplay.from(name: nil, role: nil, email: nil,
                                    formURL: "https://www.ivalasquartet.com/contact")
        #expect(d == .form(URL(string: "https://www.ivalasquartet.com/contact")!))
    }

    @Test func emailIsPreferredOverFormWhenBothExist() {
        let d = ContactDisplay.from(name: nil, role: nil, email: "info@act.example",
                                    formURL: "https://act.example/contact")
        #expect(d == .email("info@act.example"))
    }

    @Test func nothingFoundShowsNone() {
        let d = ContactDisplay.from(name: nil, role: nil, email: nil, formURL: nil)
        #expect(d == .none)
    }

    @Test func unparseableFormURLFallsBackToNone() {
        let d = ContactDisplay.from(name: nil, role: nil, email: nil, formURL: "")
        #expect(d == .none)
    }
}
