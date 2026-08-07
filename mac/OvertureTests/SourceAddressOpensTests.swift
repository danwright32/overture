import Testing
import Foundation

// #2209. Dan, looking at the sources sheet: clicking a source's URL did nothing. The only way to look at
// the page a source is watching was to select the text, copy it, and paste it into a browser by hand,
// while the scout summary and the queue card both already made the same kind of address a link.
//
// The appearance is deliberately unchanged (his call, 2026-08-06): same faint grey, same 11pt, same
// single-line truncation. A click target only.
@Suite("A source's address opens when it can (#2209)")
struct SourceAddressOpensTests {
    @Test func anordinaryAddressIsOpenable() {
        #expect(SourcesView.opens("https://theplayerstheatre.com/show-schedule.html")?.absoluteString
                == "https://theplayerstheatre.com/show-schedule.html")
    }

    @Test func anaddressWithAQueryAndAPortStillOpens() {
        #expect(SourcesView.opens("https://web.ovationtix.com:443/trs/cal/277?view=list") != nil)
    }

    // THE failure path. A string that will not parse must stay inert rather than become a link that
    // silently does nothing when clicked: an address that cannot be opened has to say so by not looking
    // openable, which is the substitution L75 forbids.
    @Test func astringThatIsNotAnAddressIsNotOpenable() {
        #expect(SourcesView.opens("not a url at all") == nil)
        #expect(SourcesView.opens("theplayerstheatre.com/shows") == nil,
                "no scheme means nothing to open it with")
    }

    @Test func nothingAtAllIsNotOpenable() {
        #expect(SourcesView.opens(nil) == nil)
        #expect(SourcesView.opens("") == nil)
    }
}

// The wiring, which is a separate claim from the rule being right (L3).
@Suite("The sources sheet draws the address as a click target (#2209)")
struct SourceAddressWiringTests {
    private var source: String { SourceGuardHelper.source("Overture/UI/SourcesView.swift") }

    @Test func theaddressIsALinkWhenItOpensAndPlainTextWhenItDoesNot() {
        #expect(source.contains("if let target = SourcesView.opens(url) {"))
        #expect(source.contains("Link(destination: target) { SourcesView.addressText(url) }"))
        // Both branches draw through ONE appearance, so an openable address and an unopenable one are
        // pixel-identical and the only difference is whether clicking does anything.
        #expect(source.components(separatedBy: "SourcesView.addressText(url)").count - 1 == 2)
    }

    // The appearance Dan asked to keep, pinned. A link that quietly grew link styling would be the change
    // he specifically ruled out.
    @Test func theappearanceIsUnchanged() throws {
        let body = try #require(SourceGuardHelper.propertyBody(
            "static func addressText(_ url: String) -> some View {", in: source))
        #expect(body.contains("font(.system(size: 11))"))
        #expect(body.contains("foregroundStyle(OVColor.inkFaint)"))
        #expect(body.contains("lineLimit(1)"))
        #expect(!body.contains("underline"))
        #expect(!body.contains("OVColor.forest"), "no link colouring: this is a click target, not a link")
    }

    // One fix covers the whole sheet, because every section draws its rows through the same builder.
    @Test func onerowBuilderCoversEverySection() {
        #expect(source.components(separatedBy: "if let url = source.listingsURL {").count - 1 == 1,
                "a second place drawing the address is a second place that can stop opening")
    }
}
