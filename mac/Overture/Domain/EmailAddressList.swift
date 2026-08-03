import Foundation

// #2023: reading a typed "Send to" field that may name more than one person.
//
// This exists as one parser with its own tests rather than a split() at each call site because the string
// Dan types decides a Recipient's IDENTITY, and every rule downstream (reply detection, follow-ups,
// bounce handling, the booking match) keys off that identity. Before this, a field holding
// "a@x.org, b@y.org" became ONE contact whose id was that entire string: it looked like it worked, Gmail
// would very likely deliver to both, and a reply from either person could never be matched back.
//
// So a string that cannot be read as addresses is REFUSED by name rather than stored as one, and the two
// places Dan can type an address (the manual-prep editor and Add contact in Review) are held to the same
// rule instead of each deciding for itself what an address is.
enum EmailAddressList {
    enum Parsed: Equatable {
        case empty
        // The piece that could not be read, in the words Dan typed it, so a refusal can point at it.
        case invalid(piece: String)
        // As typed (trimmed, and unwrapped from any display name), NOT lowercased: the canonical form is
        // the Recipient's id, while `Recipient.email` keeps the spelling he entered.
        case addresses([String])
    }

    // Comma is the ordinary one; Outlook and Apple Mail both hand you semicolons when you copy a row of
    // recipients, and a person pasting one has not made a mistake worth refusing.
    private static let separators: CharacterSet = CharacterSet(charactersIn: ",;")

    static func parse(_ raw: String) -> Parsed {
        guard !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return .empty }

        var pieces = raw.components(separatedBy: separators)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }

        // A trailing separator is a typing artefact, not an empty recipient. One BETWEEN addresses is a
        // typo and still refused below, so only the tail is forgiven.
        while pieces.last?.isEmpty == true { pieces.removeLast() }
        guard !pieces.isEmpty else { return .empty }

        var addresses: [String] = []
        var seen: Set<String> = []
        for piece in pieces {
            let address = addressText(in: piece)
            guard isAddress(address) else { return .invalid(piece: piece) }
            // The same person twice is one email. Two Recipients could not both carry that identity
            // anyway, so collapsing here is what stops the second silently vanishing later.
            let canonical = ReplyDetection.email(from: address)
            guard seen.insert(canonical).inserted else { continue }
            addresses.append(address)
        }
        return .addresses(addresses)
    }

    // Exactly ONE address, for the controls that add a single contact (Add contact in Review). Nil when
    // the field is empty, unreadable, or names more than one person, which is exactly when those controls
    // refuse, so a button gated on this can never look enabled and then be refused.
    static func single(_ raw: String) -> String? {
        guard case .addresses(let addresses) = parse(raw), addresses.count == 1 else { return nil }
        return addresses[0]
    }

    // The address inside a pasted contact card ("Olga Bloom <olga@bargemusic.org>"). ReplyDetection reads
    // this same shape out of a From header, so refusing it here would refuse what the rest of the app
    // already understands.
    private static func addressText(in piece: String) -> String {
        guard let open = piece.firstIndex(of: "<"), let close = piece.firstIndex(of: ">"), open < close
        else { return piece }
        return String(piece[piece.index(after: open)..<close]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // Deliberately not a full RFC822 grammar: enough to be sure this is ONE address and not prose, a
    // half-typed address, or two addresses that were never separated. Anything stricter would start
    // refusing real addresses, and the cost of a wrong refusal here is Dan being unable to write to
    // somebody who exists.
    private static func isAddress(_ candidate: String) -> Bool {
        guard !candidate.isEmpty else { return false }
        guard candidate.rangeOfCharacter(from: .whitespacesAndNewlines) == nil else { return false }
        let halves = candidate.components(separatedBy: "@")
        guard halves.count == 2 else { return false }
        return !halves[0].isEmpty && !halves[1].isEmpty
    }
}
