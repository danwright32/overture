import Foundation

// #2545: the ONE judgment about how an outgoing body opens, in one place because three different
// questions turn on it and they must never disagree:
//
//   - does the body greet at all (if not, the send is held, since nothing composes a greeting on top
//     of it any more and it would go out headless)
//   - does the greeting name a particular person (if so, it may only reach one)
//   - where does the real writing start (RecentOpeners compares openers, so it has to look past both
//     the greeting and the `Attn:` block above it)
//
// The greeting pattern is carried over unchanged from `DraftOpeningNotice`, which asked the same
// question for the opposite reason: it warned that the body greeted as WELL as the appended opening.
// Same judgment, inverted consequence, so keeping the pattern keeps every draft classified as it was.
enum DraftGreeting {

    // #2578: this file used to open an inventory ignore region here, purely so the opener alternation
    // below was not listed as a sentence Overture can say. The generator now recognises an
    // alternation itself, so the marker is gone: a marker is opt-in, and the next pattern nobody
    // remembers to mark is the one that lands in the list a person is supposed to read carefully.

    // Words that appear in a greeting WITHOUT being somebody's name. They are capitalised at the start
    // of a line by convention, not because they identify a person, so a capitalised word outside this set
    // is what marks a greeting as addressed to someone in particular.
    //
    // Deliberately covers the openings Dan writes as well as the drafter's ("Thanks for the quick reply,",
    // "Many thanks for the note,"), because reading one of those as a NAME would hold a send that is
    // perfectly fine, and a hold he has to override on ordinary wording is how the override stops meaning
    // anything.
    private static let notNames: Set<String> = [
        "hi", "hello", "hey", "dear", "good", "morning", "afternoon", "evening", "greetings",
        "there", "all", "everyone", "team", "folks", "again", "thanks", "thank", "many", "happy", "welcome",
    ]

    private static let openers = "hi|hello|hey|dear|good morning|good afternoon|good evening"

    // The `Attn: <name>, <role>` block a shared-inbox pitch opens with (#610), plus the blank line
    // under it. Written by the drafter now rather than composed at send, so it sits INSIDE the body
    // and every question below has to see past it first.
    private static let attnPattern = #"^\s*Attn:[^\n]*\n\s*"#

    private static var greetingPattern: String {
        #"^\s*("# + openers + #")\b[^,!\n]{0,40}([,!]|\n)"#
    }

    // A greeting that does NOT begin with an opener word, which is the shape Dan writes himself:
    // "Marcus, hello again," or "Morning Emma," or just "Sarah and Tom,". Recognised by SHAPE rather
    // than by vocabulary, because a closed list only ever covers the phrasings somebody thought of, and
    // the first version of this rule refused every one of the above (#2545, Dan's call 2026-08-12).
    //
    // A short FIRST LINE ending in a comma or bang, carrying no sentence-ending punctuation, and followed
    // by a line break. The three constraints together are what stop a real opening sentence matching:
    // "I photograph performing arts in New York, and I saw..." runs on past 40 characters and does not end
    // its line at the comma. Erring toward accepting is deliberate here, since this gate REFUSES a send.
    private static let greetingShapePattern = #"^[^\n.?!]{1,40}[,!]\s*(\n|$)"#

    // An opener followed by at least one word before the punctuation. "Hello," has nothing between
    // the opener and the comma, so it never matches; "Hi Emma," does.
    private static var namedPattern: String {
        #"^\s*("# + openers + #")\s+([^,!\n]{1,40})[,!]"#
    }

    static func opensWithAGreeting(_ body: String?) -> Bool {
        guard let body, !body.isEmpty else { return false }
        return greetingRange(in: withoutAttnBlock(body)) != nil
    }

    // Whether the greeting addresses somebody by name. Nil-safe because both callers hold an optional
    // body, and a body that is absent greets nobody.
    // #2545: judged over BOTH greeting shapes, because the two halves of the rule disagreeing about what
    // a greeting is leaves the hole exactly where Dan's own writing is: "Marcus, hello again," counted as
    // a greeting but not as a NAMED one, so a two-contact show would have sent it to both of them.
    static func namesSomeone(_ body: String?) -> Bool {
        guard let body, !body.isEmpty else { return false }
        let text = withoutAttnBlock(body)
        guard let range = greetingRange(in: text) else { return false }
        let line = String(text[range]).split(separator: "\n").first.map(String.init) ?? ""
        // The opener-word form has its own token rule, which knows "Hi all," is a filler rather than a name.
        if text.range(of: namedPattern, options: [.regularExpression, .caseInsensitive]) != nil {
            return !isFiller(namedToken(in: line))
        }
        return line.split(whereSeparator: { !$0.isLetter && $0 != "'" && $0 != "-" })
            .contains { word in
                guard let first = word.first, first.isUppercase else { return false }
                return !notNames.contains(word.lowercased())
            }
    }

    // #2579: WHO the greeting names, when it names exactly one person and names them clearly.
    //
    // Before #2545 the greeting was composed from the contact record, so it could not name the wrong
    // person: the name came from the same row the email was addressed to. The drafter writes it now, and
    // nothing compared the two, so a draft opening "Hi Emma," on a show whose only contact is Tom sent
    // without complaint. `namesSomeone` already knew a greeting names SOMEBODY; this is who.
    //
    // Nil rather than a guess in every case it cannot read confidently, because the consequence of a
    // wrong answer here is holding a good send:
    //   - two people ("Hi Sarah and Tom,"), which is a greeting this cannot attribute
    //   - the shape form ("Marcus, hello again,"), whose name is not where `namedToken` looks
    //   - a filler ("Hi there,"), which names nobody
    //   - anything carrying a character a name does not
    static func greetedName(_ body: String?) -> String? {
        guard let body, !body.isEmpty else { return nil }
        let text = withoutAttnBlock(body)
        guard let range = greetingRange(in: text) else { return nil }
        let line = String(text[range]).split(separator: "\n").first.map(String.init) ?? ""
        let token = namedToken(in: line)
        guard !token.isEmpty, !isFiller(token) else { return nil }
        let words = token.split(separator: " ").map(String.init)
        guard words.count == 1, let only = words.first,
              only.allSatisfy({ $0.isLetter || $0 == "'" || $0 == "-" }) else { return nil }
        return only
    }

    // #2579: does the greeting name somebody who is clearly NOT this contact?
    //
    // Narrow on purpose, and every tolerance below exists to avoid holding a good send. It answers false
    // whenever it is not sure:
    //   - either half unknown (no readable greeting, or a contact with no name on record)
    //   - the greeted word matches ANY token of the contact's name, so a surname-first greeting
    //     ("Hi Wright,") and a middle name are fine
    //   - a prefix in EITHER direction, so Tom/Thomas, Dan/Daniel, Kate/Katherine and an initial
    //     ("Hi E,") all pass
    //   - accents and case folded, so "Hi Jose," reaches José
    //
    //   - a familiar form of the name, from the list below, because the commonest of those are not
    //     prefixes at all: Tom is not a prefix of Thomas (t-o-m against t-h-o), and neither is Bob of
    //     Robert. The first version of this rule relied on the prefix test alone and held "Hi Tom," to
    //     Thomas Fletcher, which its own test caught.
    //
    // The list only ever WIDENS tolerance, which is why it is safe to be incomplete: a pair nobody
    // thought of costs a hold Dan can wave through, never a wrong send. It is not a claim to cover every
    // name, and it is deliberately English-only, because a guessed equivalence in a language nobody here
    // reads would be the opposite trade.
    static func namesSomeoneElse(greeting body: String?, contactName: String?) -> Bool {
        guard let greeted = greetedName(body)?.folded(), let contactName else { return false }
        let known = contactName
            .split(whereSeparator: { !$0.isLetter && $0 != "'" && $0 != "-" })
            .map { String($0).folded() }
            .filter { !$0.isEmpty }
        guard !known.isEmpty, !greeted.isEmpty else { return false }
        return !known.contains { couldBeTheSamePerson($0, greeted) }
    }

    private static func couldBeTheSamePerson(_ known: String, _ greeted: String) -> Bool {
        if known == greeted || known.hasPrefix(greeted) || greeted.hasPrefix(known) { return true }
        return familiarForms[known]?.contains(greeted) == true
            || familiarForms[greeted]?.contains(known) == true
    }

    // Familiar forms that the prefix test cannot see. Keyed both ways round by the lookup above, so each
    // pair is written once.
    private static let familiarForms: [String: Set<String>] = [
        "thomas": ["tom", "tommy"], "robert": ["bob", "bobby", "rob"], "william": ["bill", "billy", "will"],
        "richard": ["dick", "rick", "rich"], "james": ["jim", "jimmy"], "john": ["jack", "johnny"],
        "henry": ["harry", "hank"], "margaret": ["peggy", "maggie", "meg"], "elizabeth": ["betty", "liz", "beth", "eliza"],
        "susan": ["sue", "suzy"], "edward": ["ted", "ned", "eddie"], "anthony": ["tony"],
        "michael": ["mike", "mick"], "david": ["dave"], "stephen": ["steve"], "steven": ["steve"],
        "nicholas": ["nick"], "gregory": ["greg"], "joseph": ["joe", "joey"], "charles": ["chuck", "charlie"],
        "katherine": ["kate", "kathy", "katie"], "catherine": ["kate", "cathy", "katie"],
        "mary": ["molly", "polly"], "sarah": ["sally"], "ann": ["nancy"], "christina": ["tina"],
        "patricia": ["pat", "patty", "trish"], "frances": ["fanny"], "francis": ["frank"],
        "lawrence": ["larry"], "eleanor": ["nell", "ellie"], "barbara": ["barb", "babs"],
    ]

    // Everything before the first real sentence: the `Attn:` block if there is one, then the greeting.
    // Leaves a body alone when it opens with neither, so it is safe to run over any text.
    static func withoutLeadingOpening(_ body: String) -> String {
        let afterAttn = withoutAttnBlock(body)
        guard let range = greetingRange(in: afterAttn) else { return afterAttn }
        return String(afterAttn[range.upperBound...])
    }

    private static func withoutAttnBlock(_ body: String) -> String {
        guard let range = body.range(of: attnPattern, options: [.regularExpression, .caseInsensitive])
        else { return body }
        return String(body[range.upperBound...])
    }

    // Either shape counts. The opener-word form is tried first because it is the one the drafter is told
    // to write and the one whose extent the strip below needs to know.
    private static func greetingRange(in body: String) -> Range<String.Index>? {
        body.range(of: greetingPattern, options: [.regularExpression, .caseInsensitive])
            ?? body.range(of: greetingShapePattern, options: [.regularExpression, .caseInsensitive])
    }

    // The words between the opener and the punctuation, e.g. "Emma" from "Hi Emma,".
    private static func namedToken(in match: String) -> String {
        let trimmed = match.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let openerRange = trimmed.range(of: #"^("# + openers + #")\s+"#,
                                              options: [.regularExpression, .caseInsensitive])
        else { return "" }
        return String(trimmed[openerRange.upperBound...])
            .trimmingCharacters(in: CharacterSet(charactersIn: ",! "))
    }

    // Judged against `notNames`, the one list of words that appear in a greeting without being a name, so
    // the two branches of `namesSomeone` cannot disagree: "Hello again," reads as naming nobody whichever
    // pattern matched it first. There was briefly a second, smaller list here and that was the bug.
    private static func isFiller(_ token: String) -> Bool {
        let words = token.split(separator: " ").map(String.init)
        return words.count == 1 && notNames.contains(words[0].lowercased())
    }
}

private extension String {
    // #2579: case and accents removed, so a greeting and a stored name are compared as the same word
    // whichever way each was typed.
    func folded() -> String {
        folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil)
    }
}
