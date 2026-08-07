import Foundation

// #2259: the producing company a show's own listing page credits in front of its title.
//
// The contact run is handed the listing text already (#1824) and was told, in the same breath, that "this
// listing named no producing organisation at all" whenever the stored presenter field was empty. Those are
// different claims, and on ICB Productions' "Summer Lovin'" the second was false: the page's own title line
// read "ICB Productions' Summer Lovin'". The run chased two individuals across eleven web calls and the
// card reached Dan reading "No email found".
//
// A rule that lives only in a prompt is a hope (L27), so the app reads the credit itself and hands the
// answer over as a field. This is deliberately the NARROW half: the possessive credit standing immediately
// in front of the show's title, which is how a rental room's ticketing page bills a producer. The wide half
// (a founder's company named in a bio, "presented by" inside a paragraph) stays an instruction to the run,
// because that same page is full of past credits ("produced by Moore Productions", "Jean Doumanian
// Productions (Intern)") that no parse can tell from the company putting THIS show on, and a wrong answer
// here becomes a pitch to a stranger.
enum ListingOrganiser {

    // Lowercase words that sit INSIDE a name and would otherwise stop the walk back ("Acting Up
    // Entertainment", "New York Theatre Barn"). Never the first word taken: that one carries the possessive
    // and must look like a name on its own.
    // copy-inventory:ignore-start  parser tokens matched against ticketing pages, never Overture's voice
    private static let nameInternalWords: Set<String> = ["and", "of", "the", "for", "&", "de", "la", "van",
                                                         "von", "du", "le"]
    // copy-inventory:ignore-end

    static func producerNamed(inListingText text: String?, showTitle: String, venue: String?) -> String? {
        guard let text else { return nil }
        let title = showTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }

        // Curly and straight apostrophes are the same apostrophe here. Normalised for the SEARCH only, and
        // the name is taken from the ORIGINAL text so it comes back spelled the way the page spelled it.
        let normalisedText = normalisingApostrophes(text)
        guard let titleRange = normalisedText.range(of: normalisingApostrophes(title),
                                                    options: [.caseInsensitive]) else { return nil }

        let prefixWords = normalisedText[..<titleRange.lowerBound]
            .split(whereSeparator: { $0.isWhitespace })
        guard let credited = prefixWords.last, endsPossessive(String(credited)),
              startsLikeAName(String(credited)) else { return nil }

        var take = 1
        while take < 5, prefixWords.count > take {
            let word = String(prefixWords[prefixWords.count - take - 1])
            guard startsLikeAName(word) || nameInternalWords.contains(word.lowercased()) else { break }
            take += 1
        }

        // Same word boundaries in the original, since normalising apostrophes replaces one character with
        // one character and so moves nothing.
        let titleOffset = normalisedText.distance(from: normalisedText.startIndex,
                                                  to: titleRange.lowerBound)
        let originalTitleStart = text.index(text.startIndex, offsetBy: min(titleOffset, text.count))
        let originalPrefixWords = text[..<originalTitleStart].split(whereSeparator: { $0.isWhitespace })
        guard originalPrefixWords.count >= take else { return nil }
        let candidate = originalPrefixWords.suffix(take).joined(separator: " ")

        guard let name = ProducerShapedName.from(candidate) else { return nil }

        // The room is never the producer, whatever its page says. Overture already drains a presenter that
        // is only the room's own name (#1787), and this parse must not be the door that lets it back in.
        // Folded through the one shared key so "The Green Room 42" and "Green Room 42" are the same room.
        if let venueKey = ProducerGate.key(venue), ProducerGate.key(name) == venueKey { return nil }
        // Nor is the show's own title an organisation, which is the whole reason this route exists.
        if ProducerGate.key(name) == ProducerGate.key(title) { return nil }
        return name
    }

    private static func normalisingApostrophes(_ s: String) -> String {
        s.replacingOccurrences(of: "\u{2019}", with: "'")
    }

    private static func endsPossessive(_ word: String) -> Bool {
        ["'s", "s'", "'"].contains { word.hasSuffix($0) }
    }

    // A name starts with a capital. Page chrome that is a bare number ("0", the cart count every one of
    // these ticketing pages carries) and ordinary prose both fail this, which is what keeps a navigation bar
    // and a sentence fragment out of a pitch.
    private static func startsLikeAName(_ word: String) -> Bool {
        guard let first = word.first else { return false }
        return first.isUppercase
    }
}
