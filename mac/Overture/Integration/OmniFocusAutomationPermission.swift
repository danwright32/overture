import Foundation
import CoreServices

// #268 / Phase 4: the SILENT Automation-permission probe. Asks macOS whether this process may already
// drive OmniFocus via Apple events WITHOUT prompting (askUserIfNeeded:false), so the windowless
// resident process never posts a TCC consent dialog no one can answer. This is the one piece that
// can't be unit-tested (it reads live TCC state); the decision that consumes it lives in
// OmniFocusSyncRunner and IS tested.
//
// OmniFocus ships under different bundle ids (direct-sale vs Mac App Store, v3 vs v4), so probe each
// known id and treat "granted under any" as granted; the installed one returns the real verdict and
// the others return a not-found status, both of which collapse to notGranted.
enum OmniFocusAutomationPermission {
    static let candidateBundleIDs = [
        "com.omnigroup.OmniFocus4",
        "com.omnigroup.OmniFocus4.MacAppStore",
        "com.omnigroup.OmniFocus3",
        "com.omnigroup.OmniFocus3.MacAppStore",
    ]

    static func current() -> AutomationAuthorization {
        for bundleID in candidateBundleIDs where probe(bundleID: bundleID) == noErr {
            return .granted
        }
        return .notGranted
    }

    // noErr = already permitted; errAEEventNotPermitted(-1743) = denied; errAEEventWouldRequireUserConsent
    // (-1744) = not yet determined (would prompt); -600 = target not found. Only noErr means granted.
    private static func probe(bundleID: String) -> OSStatus {
        guard let data = bundleID.data(using: .utf8) else { return OSStatus(errAEEventNotPermitted) }
        var target = AEAddressDesc()
        let createErr = OSStatus(data.withUnsafeBytes { raw in
            AECreateDesc(typeApplicationBundleID, raw.baseAddress, data.count, &target)
        })
        guard createErr == noErr else { return createErr }
        defer { AEDisposeDesc(&target) }
        return AEDeterminePermissionToAutomateTarget(&target, typeWildCard, typeWildCard, false)
    }
}
