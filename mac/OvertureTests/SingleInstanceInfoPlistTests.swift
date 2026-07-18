import Testing
import Foundation
@testable import Overture

// 2026-07-18: `overture` (build-install.sh --launch) opened TWO copies of /Applications/Overture.app.
// The login agent starts one directly, then the `open overture://show` surface launched a SECOND
// through LaunchServices because the app declared no single-instance policy. The second copy lost the
// race for the store's single-writer lock and showed the "Overture's data is unavailable" screen (the
// two-copies clash Dan hit twice). LSMultipleInstancesProhibited makes LaunchServices refuse to launch
// a second copy and instead deliver overture:// to the running one, which is exactly what the launch
// wants. That flag is the only thing standing between the shipped app and the clash, and it lives in a
// plist no unit of logic exercises, so this pins it on the BUILT bundle (the test host is Overture.app),
// not just the source file.
@Suite("The app forbids a second running instance")
struct SingleInstanceInfoPlistTests {
    @Test func builtBundleProhibitsMultipleInstances() {
        let bundle = Bundle(for: AppDelegate.self)
        let flag = bundle.object(forInfoDictionaryKey: "LSMultipleInstancesProhibited") as? Bool
        #expect(
            flag == true,
            "Overture.app must set LSMultipleInstancesProhibited=true so `open overture://show` can never launch a second copy that then hits the store lock"
        )
    }
}
