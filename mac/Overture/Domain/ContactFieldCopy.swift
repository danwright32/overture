import Foundation

// #4170: the words on the fields that take a contact BY HAND, in one place, because there are now
// three of them: the review card's add-contact field (#399), the row's own field where the
// reachability advice asks for one (#3341), and the panel for pitching somebody else on a show
// already sent.
//
// They were literals at each site and said the same two things, which is how one vocabulary becomes
// three: a third site added its own spelling would leave "Email or link" and "Email or contact link"
// beside each other on two cards asking the identical question (L118, L605). The copy inventory lists
// a sentence per site, so the duplication was visible; this removes it rather than adding to it.
enum ContactFieldCopy {
    // A ROUTE, not an address, which is what every one of these fields has taken since #2629: an email,
    // a contact form, or a social profile, judged by `ManualContactRoute.parse`.
    static let routePlaceholder = "Email or link"
    // Optional in the placeholder because it genuinely is: a route with no name is a contact Overture
    // can still write to, and the name is what the greeting uses when there is one.
    static let namePlaceholder = "Name (optional)"
}
