import Testing
import SwiftUI
import ImageIO
@testable import Overture

// The design score's wiring, on every run (#4691). `DesignScoreTests` only runs under
// scripts/design-score.sh, which needs Playwright and draws the design side first, so the parts of the
// route a score's VERDICT rests on are pinned here, where an ordinary suite run sees them: a theme that
// is really applied, a negative control that really moves a colour past the score's tolerance, and a
// fixture or capture folder that is missing being refused by name rather than drawn as nothing.
@MainActor
@Suite("The design score's wiring holds on every run (#4691)")
final class DesignScoreWiringTests {
    private let sandboxes = TemporarySandboxes()

    /// The score's tolerance: a pixel matches when no channel differs by more than this out of 255.
    private let tolerance = 8

    private func proofFixture() throws -> DesignScoreProof.Fixture {
        try DesignFixture.load(DesignScoreProof.Fixture.self, screen: "proof")
    }

    /// The red, green and blue of one pixel of `view` drawn the way the adapter draws a frame.
    private func pixel(_ view: AnyView, x: Int, y: Int) throws -> [Int] {
        let url = try sandboxes.make(named: "design-score-wiring").appendingPathComponent("frame.png")
        try DesignScoreCapture.render(view, width: 160, height: 80, to: url)
        let source = try #require(CGImageSourceCreateWithURL(url as CFURL, nil))
        let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        var bytes = [UInt8](repeating: 0, count: 4)
        let space = try #require(CGColorSpace(name: CGColorSpace.sRGB))
        let context = try #require(CGContext(data: &bytes, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                             space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        // One pixel, drawn so (x, y) from the top left lands on the context's only pixel.
        context.draw(image, in: CGRect(x: -x, y: y - image.height + 1, width: image.width, height: image.height))
        return bytes.prefix(3).map(Int.init)
    }

    private func near(_ got: [Int], _ want: [Int]) -> Bool {
        zip(got, want).allSatisfy { abs($0 - $1) <= tolerance }
    }

    @Test("Each frame is drawn in its own theme, whatever this Mac's appearance is")
    func eachFrameIsDrawnInItsOwnTheme() throws {
        let bands = DesignScoreProof.Bands(fixture: try proofFixture())
        let light = try pixel(DesignScreen.scored(bands, scheme: .light, perturbed: false), x: 10, y: 10)
        let dark = try pixel(DesignScreen.scored(bands, scheme: .dark, perturbed: false), x: 10, y: 10)
        // OVColor.forest in each theme, as fixtures/design/proof.design.html writes them.
        #expect(near(light, [0x2e, 0x52, 0x39]), "light forest drew as \(light)")
        #expect(near(dark, [0x38, 0x63, 0x46]), "dark forest drew as \(dark)")
    }

    @Test("The negative control moves every band past the score's tolerance")
    func theNegativeControlMovesPastTheTolerance() throws {
        let bands = DesignScoreProof.Bands(fixture: try proofFixture())
        for y in [10, 50] {
            let asBuilt = try pixel(DesignScreen.scored(bands, scheme: .light, perturbed: false), x: 10, y: y)
            let perturbed = try pixel(DesignScreen.scored(bands, scheme: .light, perturbed: true), x: 10, y: y)
            let moved = zip(asBuilt, perturbed).map { abs($0 - $1) }.max() ?? 0
            #expect(moved > tolerance, "at y \(y), \(asBuilt) moved only \(moved) to \(perturbed)")
        }
    }

    @Test("The proof's fixture names only tokens the app has")
    func theProofFixtureNamesRealTokens() throws {
        let fixture = try proofFixture()
        #expect(fixture.bands == ["forest", "gold"])
        #expect(fixture.colours?.count == 2)
    }

    @Test("A screen with no committed fixture is refused by name")
    func aMissingFixtureIsRefusedByName() throws {
        let root = try sandboxes.make(named: "design-score-root")
        do {
            _ = try DesignFixture.load(DesignScoreProof.Fixture.self, screen: "nowhere", root: root)
            Issue.record("a missing fixture loaded")
        } catch let error as DesignFixtureError {
            #expect(String(describing: error).contains("fixtures/design/nowhere.json"))
        }
    }

    @Test("A capture with no folder throws rather than drawing nowhere",
          .enabled(if: DesignScoreRun.captureFolder == nil, "only an ordinary run has no capture folder"))
    func aCaptureWithNoFolderThrows() {
        // Naming the script, which is how to give it one: the adapter would refuse too, further in, but
        // only by saying a capture.json was missing from a folder nobody named.
        let error = #expect(throws: DesignScoreCaptureError.self) {
            try DesignScreen.capture(build: "nothing", view: { _ in AnyView(EmptyView()) }, checks: { _ in [] })
        }
        #expect(error.map { String(describing: $0) }?.contains("scripts/design-score.sh") == true)
    }
}
