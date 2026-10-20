import Testing
import SwiftUI
@testable import Overture

// One snapshot test per settled design (#4691): each draws the BUILT side of its design's frames from
// the committed fixture, with the design's decision checks written in Swift. `scripts/design-score.sh
// <screen>` runs the one named `<screen>()` here, after drawing the design's side, and then scores the
// capture; run on their own, in an ordinary suite run, they are skipped, since there is nothing to draw
// into. A new settled screen adds a test here named exactly as its design file is
// (docs/design/<screen>.html, fixtures/design/<screen>.json), and the script finds it by that name.
//
// No screen of Overture is settled yet. `proof()` is the pipeline's own proof, scored against
// fixtures/design/proof.design.html, and it is what showed the route works both ways before anything
// relied on it.
@MainActor
@Suite("Each settled screen drawn for its design score (#4691)")
struct DesignScoreTests {

    @Test(.enabled(if: DesignScoreRun.captureFolder != nil, "scripts/design-score.sh runs it"))
    func proof() throws {
        let fixture = try DesignFixture.load(DesignScoreProof.Fixture.self, screen: "proof")
        try DesignScreen.capture(
            build: "DesignScoreProof.Bands",
            view: { frame in
                DesignScreen.scored(DesignScoreProof.Bands(fixture: fixture), scheme: try DesignScoreProof.scheme(frame))
            },
            checks: { _ in
                let names = fixture.bands
                return [DesignScoreCheck("D1", ok: names == ["forest", "gold"] && fixture.colours != nil,
                                         detail: names.joined(separator: " above "))]
            })
    }
}

/// The pipeline proof's build side: Overture's real forest and gold tokens, drawn as two bands.
enum DesignScoreProof {
    struct Fixture: Decodable {
        let bandHeight: Int
        let bands: [String]

        /// The bands' colours, each through the app's own token, or nil when the fixture names one
        /// the app does not have.
        var colours: [Color]? {
            let tokens: [String: Color] = ["forest": OVColor.forest, "gold": OVColor.gold]
            let found = bands.compactMap { tokens[$0] }
            return found.count == bands.count ? found : nil
        }
    }

    struct Bands: View {
        let fixture: Fixture

        var body: some View {
            VStack(spacing: 0) {
                ForEach(Array((fixture.colours ?? []).enumerated()), id: \.offset) { _, colour in
                    colour.frame(maxWidth: .infinity).frame(height: CGFloat(fixture.bandHeight))
                }
            }
            .frame(maxHeight: .infinity, alignment: .top)
        }
    }

    static func scheme(_ frame: String) throws -> ColorScheme {
        switch frame {
        case "light": return .light
        case "dark": return .dark
        default: throw DesignScoreCaptureError.unreadable("the proof design has no frame called \(frame)")
        }
    }
}
