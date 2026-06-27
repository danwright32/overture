import Foundation
import CoreServices
import AppKit

// #268 / Phase 4: the SILENT Automation-permission probe. Asks macOS whether this process may already
// drive OmniFocus via Apple events WITHOUT prompting (askUserIfNeeded:false), so the windowless
// resident process never posts a TCC consent dialog no one can answer. This is the one piece that
// can't be unit-tested (it reads live TCC state); the decision that consumes it lives in
// OmniFocusSyncRunner and IS tested.
//
// The AppleScript driver targets OmniFocus by friendly name (`tell application "OmniFocus"`), which
// macOS resolves to the installed app's REAL bundle id. So we resolve that same id dynamically and
// probe it first (#288); without this, an OmniFocus whose id isn't in the hardcoded list reads as
// notGranted and the unattended sync silently never fires even when permission was granted. The known
// ids stay as a fallback for when resolution can't find the app (e.g. it isn't running and name
// lookup fails). OmniFocus also ships under different ids (direct-sale vs Mac App Store, v3 vs v4);
// "granted under any probed id" counts as granted.
enum OmniFocusAutomationPermission {
    static let candidateBundleIDs = [
        "com.omnigroup.OmniFocus4",
        "com.omnigroup.OmniFocus4.MacAppStore",
        "com.omnigroup.OmniFocus3",
        "com.omnigroup.OmniFocus3.MacAppStore",
    ]

    static func current() -> AutomationAuthorization {
        for bundleID in bundleIDsToProbe(resolved: resolvedBundleID()) where probe(bundleID: bundleID) == noErr {
            return .granted
        }
        return .notGranted
    }

    // Pure ordering: probe the dynamically resolved id first (it's the app the AppleScript actually
    // drives), then the known candidates as a fallback, without ever probing the same id twice.
    static func bundleIDsToProbe(resolved: String?, candidates: [String] = candidateBundleIDs) -> [String] {
        guard let resolved, !resolved.isEmpty else { return candidates }
        return [resolved] + candidates.filter { $0 != resolved }
    }

    // Resolve the installed OmniFocus's real bundle id the same way `tell application "OmniFocus"`
    // does. Reads live system state, so (like probe) it can't be unit-tested. nil means "couldn't
    // find it" — callers fall back to the candidate list.
    static func resolvedBundleID(named name: String = "OmniFocus") -> String? {
        // A running instance is authoritative: it is literally the process Apple events reach.
        if let running = NSWorkspace.shared.runningApplications.lazy
            .compactMap({ $0.bundleIdentifier })
            .first(where: { $0.hasPrefix("com.omnigroup.OmniFocus") }) {
            return running
        }
        // Otherwise resolve the friendly name to the installed app's id, so a future/renamed bundle id
        // is covered without editing the hardcoded list. fullPath(forApplication:) is the only public
        // API that mirrors AppleScript's name resolution; deprecated but still the correct mapping.
        if let path = NSWorkspace.shared.fullPath(forApplication: name),
           let id = Bundle(path: path)?.bundleIdentifier {
            return id
        }
        return nil
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
