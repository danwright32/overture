import Testing
import SwiftUI
import AppKit
import ViewInspector
@testable import Overture

// The eyes-on half of #3282's note, because the assertions beside it cannot do it.
//
// `ProspectRowViewStoredMoreThanOnceTests` proves the sentence is PRESENT in both themes, which is a
// different question from whether it reads well, sits in the right place, or is legible on the
// surface behind it. A colour token that clears the bar for an icon does not clear it for text, and
// nothing in a text assertion can see that (L606, L149, L569).
//
// So this writes the card out as a picture, in light and dark, and the pictures go in the PR. It is a
// rendered card rather than the running app, which is stated plainly rather than implied: what it
// cannot show is the note among a screen of other cards at the real count.
//
// Opt in, because writing files on every run of a 10,000 test suite is not something a guard should
// do. Set TEST_RUNNER_WRITE_CARD_IMAGES to a directory.
//
// The name differs on the two sides ON PURPOSE and it is the whole of what makes this work: xcodebuild
// forwards ONLY variables carrying the TEST_RUNNER_ prefix to the test process and STRIPS the prefix on
// the way in. So it is exported as TEST_RUNNER_WRITE_CARD_IMAGES and read here as WRITE_CARD_IMAGES.
// Reading the prefixed name is silently always nil, and the suite then reports one skipped case rather
// than a failure to configure, which is how this was got wrong twice before it was got right.
@MainActor
@Suite("What the stored-more-than-once note looks like (#3282)")
struct StoredMoreThanOnceLooksRightTests {
    nonisolated private static var outputDirectory: String? {
        ProcessInfo.processInfo.environment["WRITE_CARD_IMAGES"]
    }

    private func item(sameShowKeys: [String]) -> QueueItem {
        var item = QueueItem(id: "k", groupName: "We Are Happy To Serve You", discipline: "theater",
                             venue: "The Players Theatre", performanceDate: "2026-12-20",
                             sourceListingURL: nil, priorRelationship: "none", production: "self",
                             profile: "strong", coverage: "likely_uncovered", fitScore: 7,
                             tier: "high", fitReason: "A one-woman show, well reviewed, no photographer credited",
                             matchedClientName: nil, possibleMatchSource: nil,
                             possibleMatchName: nil, status: .new)
        item.sameShowKeys = sameShowKeys
        return item
    }

    @Test(.enabled(if: outputDirectory != nil, "set TEST_RUNNER_WRITE_CARD_IMAGES to write them"),
          arguments: [ColorScheme.light, ColorScheme.dark])
    func writeTheCardOut(_ scheme: ColorScheme) throws {
        let directory = try #require(Self.outputDirectory)
        let name = scheme == .light ? "light" : "dark"

        let card = VStack(alignment: .leading, spacing: 0) {
            ProspectRowView(item: item(sameShowKeys: ["other"]), today: "2026-09-19",
                            onKeep: {}, onDismiss: { _ in })
        }
        .padding(16)
        .frame(width: 820)
        .background(scheme == .light ? Color.white : Color.black)
        .environment(\.colorScheme, scheme)

        let renderer = ImageRenderer(content: card)
        renderer.scale = 2
        let image = try #require(renderer.nsImage, "the card did not render at all")
        let url = URL(fileURLWithPath: directory).appendingPathComponent("card-\(name).png")
        let data = try #require(image.tiffRepresentation
            .flatMap(NSBitmapImageRep.init(data:))?
            .representation(using: .png, properties: [:]))
        try data.write(to: url)
        print("Card image written: \(url.path)")
    }
}
