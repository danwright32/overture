import Foundation

// #2421: a "contact" whose only handle is a social profile is not a contact.
//
// Dan, on the live build 2026-08-10, looking at a prepped card with seven contacts and one address:
// "I removed all but one email and it's still showing me the 7 or so that it found." The run had
// researched, drafted to, counted and listed six people it has no way to reach, and gave him nothing to
// do about any of them until he was standing in front of the finished draft.
//
// The app had ALREADY decided most of them were dead ends and simply kept them anyway. `#1626` refuses to
// put an Instagram on the card as a link, in those words: "an Instagram is a dead end Dan will not use, so
// putting it on the card would hand him a control he cannot act on". Four of the six here were Instagram
// only. So the same rule, applied one step earlier, stops the contact existing rather than creating one
// every surface downstream then has to explain.
//
// Dan's call, 2026-08-10, shown the measured split: drop the social-only ones, keep the real forms. On his
// store that is 45 contacts dropped and 21 kept, and the 21 matter: 15 shows are reachable ONLY through a
// form on the act's own site, and the review panel has a working path for exactly that (copy the draft,
// open their form, mark it sent, recorded as real outreach).
//
// The rule is asked of the CONTACT, never of the show: a person with an address is unaffected whatever
// their social handle is, and a person with a real form is kept whatever anybody else on the bill has.
enum DeadEndContact {

    // True when this contact offers no way in at all: no address, and no form except one the app has
    // already ruled out.
    //
    // A press or venue form is deliberately NOT judged here. Those are refused for being the WRONG
    // desk (#635/#368), which is a different question from being unusable, and they are already refused
    // upstream by the runbook and downstream by the guards on the row; folding them in here would make
    // one rule answer two questions and quietly widen what this deletes.
    static func hasNoUsableRoute(email: String?, formURL: String?) -> Bool {
        let address = (email ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard address.isEmpty else { return false }
        let form = (formURL ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        // #2612: a social profile is a ROUTE again, so the only dead end left is a contact with no way
        // in at all. Dan reversed #2421's call on 2026-08-13 looking at the Song & Word card: "I'm going
        // to DM them on instagram". Nothing here judges WHICH kind of route it is any more; that is the
        // card's job now, and `Prospect.socialRouteURLs` is where the distinction lives.
        return form.isEmpty
    }
}
