import Foundation

// What the review row should show for a found contact, decided purely so the SwiftUI row stays
// dumb and the choice is testable. Email is preferred over a contact form (Dan's ladder: a real
// email beats a form); a form-only contact surfaces as a tappable link instead of reading
// "No contact found" (#368, the Ivalas Quartet case).
enum ContactDisplay: Equatable {
    // #3078: `roleIsACharacterisation` says the role is the RUN'S summary rather than a phrase the page
    // it cited carries, so the row can keep the role (it is still useful context about who this person
    // is) and stop presenting it as something the page said.
    case person(name: String, role: String?, roleIsACharacterisation: Bool = false, email: String?)
    case email(String)
    case form(URL)
    case none

    // #3078: `roleQuoted` is the run's own declaration, LAST and DEFAULTED, so every existing call site
    // is unchanged and a caller that says nothing gets exactly what it got before.
    static func from(name: String?, role: String?, email: String?, formURL: String?,
                     roleQuoted: Bool? = nil) -> ContactDisplay {
        if let name, !name.isEmpty {
            return .person(name: name, role: role,
                           roleIsACharacterisation: ContactRoleClaim.isCharacterisation(
                               roleQuoted: roleQuoted, role: role),
                           email: email)
        }
        if let email, !email.isEmpty {
            return .email(email)
        }
        if let formURL, !formURL.isEmpty, let url = URL(string: formURL), url.scheme != nil {
            return .form(url)
        }
        return .none
    }
}
