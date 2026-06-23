import Foundation

// Resolves a venue from a listing's surrounding text (#34). Was a hardcoded match of four
// Carnegie halls inside the in-page extractor JS; pulled out here so it's pure/testable
// and broadened to off-site venues. Order: the known Carnegie halls (specific, common),
// a few named venues that lack an obvious venue word, then a general "Proper Name + venue
// word" pattern. Returns nil when nothing venue-like is present.
enum VenueParser {
    static let carnegieHalls = [
        "Stern Auditorium / Perelman Stage", "Zankel Hall", "Weill Recital Hall", "Resnick Education Wing",
    ]
    static let knownVenues = ["Wave Hill", "Thalia Spanish Theatre", "Bargemusic"]

    // Conservative venue words: common enough to catch real venues, but avoiding ones that
    // frequently appear in group names (e.g. "School", "Conservatory", "Stage").
    private static let venueWords = ["Hall", "Theatre", "Theater", "Center", "Centre",
                                     "Auditorium", "Church", "Cathedral", "Chapel", "Park",
                                     "Museum", "Library", "Playhouse"]

    static func parse(context: String) -> String? {
        for v in carnegieHalls + knownVenues where context.contains(v) { return v }
        return firstVenuePhrase(in: context)
    }

    // The first "Capitalized words + venue word" run, e.g. "Thalia Spanish Theatre",
    // "Central Park", "Saint Thomas Church".
    static func firstVenuePhrase(in text: String) -> String? {
        let words = "(" + venueWords.joined(separator: "|") + ")"
        let pattern = "\\b([A-Z][\\w.&'’-]+(?: [A-Z][\\w.&'’-]+){0,4}) " + words + "\\b"
        guard let re = try? NSRegularExpression(pattern: pattern),
              let m = re.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let r = Range(m.range, in: text) else { return nil }
        return String(text[r])
    }
}
