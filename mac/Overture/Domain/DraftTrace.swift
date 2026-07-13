import Foundation

// #846: how a draft says what wrote it.
//
// #804 recorded the model behind every draft and displayed it nowhere, so the record existed and Dan
// could not read it. That record is the other half of a decision: he pinned drafting to the strong TIER
// rather than an exact version, so he picks up each new Opus as it ships and accepts that his email voice
// can shift with it. The trade is only reasonable BECAUSE the model is recorded, so that on the day an
// email reads wrong he can check whether the model changed underneath him rather than merely sensing that
// something did. Unread, that trade was not actually available to him.
//
// A pure function, deliberately not a computed property inside the SwiftUI body. #863 is the standing
// lesson: a rule stated in a comment and computed in a view drifted twice while the suite stayed green.
// The same reason RecipientSnapshot.contactSourceLinkURL decides purely and keeps the row dumb.
//
// ONE implementation for both the cold outreach draft and the reply draft. They are the same question
// asked of two surfaces, and #874 is what a forgotten second drafter costs: the reply run sat on the
// cheap model for months precisely because it was only ever thought of as the classify run.
enum DraftTrace {
    static func label(for model: String?) -> String? {
        guard let model else { return nil }
        let name = model.trimmingCharacters(in: .whitespacesAndNewlines)
        // A blank stamp is the same as no stamp: record_model degrades to writing nothing rather than
        // failing a run, so an empty value is a gap in the record, not a model called "". Never render
        // a half sentence naming nobody.
        guard !name.isEmpty else { return nil }
        return "Drafted by \(name)"
    }
}
