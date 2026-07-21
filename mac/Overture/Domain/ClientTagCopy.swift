import Foundation

// #1209: the wording for the per-source "returning client" control on the Sources sheet, kept out of the
// SwiftUI view so it is testable (#863). A source treated as a returning client's has its calendar read a
// full year forward (ClientHorizon), so a client's next-season dates are surfaced early enough to pitch.
enum ClientTagCopy {
    // The line under a source stating whether it is treated as a returning client, and why. nil when there
    // is nothing worth saying: an ordinary source Dan has not tagged and no Downbeat client matches, which
    // is almost every source. `override` is the source's manual tag; `isClient` is the effective result.
    static func stateLabel(isClient: Bool, override: Bool?) -> String? {
        switch override {
        case .some(true): return "Tagged a returning client: shows surface up to a year ahead."
        case .some(false): return "Not treated as a returning client."
        case .none:
            return isClient ? "Matches a Downbeat client: shows surface up to a year ahead." : nil
        }
    }

    static let menuTitle = "Returning client"
    static let optionAutomatic = "Automatic (match Downbeat)"
    static let optionAlways = "Always a returning client"
    static let optionNever = "Never a returning client"
}
