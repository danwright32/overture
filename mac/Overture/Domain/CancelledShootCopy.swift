import Foundation

// #2692: what the days off sheet says about a shoot Dan has waved through. In the domain rather than the
// view so the words are testable and land in `docs/copy-inventory.md` (#885).
enum CancelledShootCopy {
    static let unblockTitle = "Not happening"
    static let restoreTitle = "Put it back"

    static let unblockHelp =
        "Stop keeping this night clear for this shoot. It stays in Downbeat; Overture just stops protecting it."
    static let restoreHelp = "Keep this night clear for this shoot again."

    // The row after Dan has waved it through. It says WHO decided, which "From Downbeat" no longer covers:
    // the booking is still Downbeat's, and the decision not to protect it is his.
    static let unblockedLabel = "You said it isn't happening"

    // What is still holding the night, when cancelling one shoot did not free it. Dan's call was that the
    // override cancels ONE shoot and never the night, so this is the sentence that stops an unblock
    // reading as broken: he pressed it, it worked, and the night is still taken by something else.
    //
    // Names the shoots rather than counting them, because the count alone ("still blocked by 1 other")
    // sends him looking for which one, and the answer is right here.
    static func stillBlocked(by names: [String]) -> String {
        guard !names.isEmpty else { return "" }
        return names.count == 1
            ? "Still blocked by \(names[0])."
            : "Still blocked by \(names.dropLast().joined(separator: ", ")) and \(names[names.count - 1])."
    }

    // The acknowledgement, in the two directions.
    static func cancelled(_ name: String) -> String { "\(name) won't hold that night any more" }
    static func restored(_ name: String) -> String { "\(name) is holding that night again" }
}
