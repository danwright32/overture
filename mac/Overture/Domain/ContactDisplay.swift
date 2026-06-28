import Foundation

// What the review row should show for a found contact, decided purely so the SwiftUI row stays
// dumb and the choice is testable. Email is preferred over a contact form (Dan's ladder: a real
// email beats a form); a form-only contact surfaces as a tappable link instead of reading
// "No contact found" (#368, the Ivalas Quartet case).
enum ContactDisplay: Equatable {
    case person(name: String, role: String?, email: String?)
    case email(String)
    case form(URL)
    case none

    static func from(name: String?, role: String?, email: String?, formURL: String?) -> ContactDisplay {
        if let name, !name.isEmpty {
            return .person(name: name, role: role, email: email)
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
