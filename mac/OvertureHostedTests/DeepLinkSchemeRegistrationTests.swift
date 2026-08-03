import Testing
import Foundation
@testable import Overture

// #1967: split out of OvertureDeepLinkTests, which is otherwise pure and now runs unhosted.
//
// This one test reads the RUNNING BUNDLE's own CFBundleURLTypes, so it can only mean anything when the
// app is the host: outside it, Bundle.main is xctest's own tool and the key is simply absent. That is
// exactly the distinction the split exists to draw, so it lives here with the other tests that need a
// real app around them, and the eight pure ones it used to sit beside no longer pay the launch risk.
@Suite("Deep link scheme registration (#568)")
struct DeepLinkSchemeRegistrationTests {
    // Guards against the Swift constant and the Info.plist's CFBundleURLTypes drifting apart, which
    // would silently reintroduce #568: the app would still build and run, but LaunchServices would
    // register a scheme this code never generates or recognizes.
    @Test func schemeMatchesTheAppsOwnInfoPlistRegistration() throws {
        let urlTypes = try #require(
            Bundle.main.object(forInfoDictionaryKey: "CFBundleURLTypes") as? [[String: Any]]
        )
        let registeredSchemes = urlTypes.flatMap { $0["CFBundleURLSchemes"] as? [String] ?? [] }
        #expect(registeredSchemes.contains(OvertureDeepLink.scheme))
    }
}
