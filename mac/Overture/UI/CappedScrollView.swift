import SwiftUI

// #2159: a scrolling box with a height cap, that says so when it is hiding something.
//
// Every capped scroll box in this app was a bare `ScrollView` with a `.frame(maxHeight:)` under it, which
// is exactly what you write if the question never comes up. macOS hides scrollbars until a gesture starts,
// so at rest an overflowing panel and a complete one are pixel-identical, and the clip lands on a whole
// line as often as not, removing even the accidental hint of a half-cut word. Dan met that on the reply
// panel: the email he was answering carried a list of season dates below the fold and the panel read as a
// quotation that happened to end there. He found the rest by trying, not by being shown (L49, L76).
//
// So the cap and the cue are one type, and `ScrollCueGuardTests` refuses a bare capped ScrollView anywhere
// in the app. A cue nobody can forget to add is the only kind that survives the next panel.
//
// Two signals, because Dan asked for it to be unmissable and the fade alone is quiet: the last few points
// of content dissolve into the panel edge, and a small chevron sits under it. Both appear only when
// something really is below (a short reply that fits wears no cue at all, or the cue teaches him to
// disregard it on the panels that mean it), and both clear the moment the last line is on screen.
//
// The fade is a MASK rather than a gradient drawn on top, which is what makes it correct on any background
// and in both themes (L69): it dissolves the content towards whatever is behind this box, instead of
// towards a colour guessed here. These boxes sit on `surfaceSunk`, on `canvas`, and on a rounded sunk card
// at 60% opacity, and a painted gradient would have to be told which.
struct CappedScrollView<Content: View>: View {

    private let maxHeight: CGFloat
    private let content: Content

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    // The only two pieces of state, and deliberately the DECISION rather than the measurements behind it.
    // The offset changes on every frame of a flick, so holding it here would redraw this view sixty times
    // a second; holding the Bool it implies means SwiftUI sees a change only when the answer actually
    // flips, twice per panel. That distinction is what keeps a scroll off the expensive views these boxes
    // live inside (L59), and it is the same class of loop that froze the Sources sheet in #1440, which is
    // why nothing here writes back into layout or scroll position.
    @State private var viewportHeight: CGFloat = 0
    @State private var moreBelow = false

    init(maxHeight: CGFloat, @ViewBuilder content: () -> Content) {
        self.maxHeight = maxHeight
        self.content = content()
    }

    // The cue's geometry lives in ScrollOverflow.Cue, where the relationship its correctness depends on
    // (the clear strip has to be at least as tall as the glyph) is asserted. Without that strip the
    // chevron sits wherever the last line of text happens to be and reads as a mark inside a word,
    // which is how it first shipped and what looking at it caught.
    private static var spaceName: String { "CappedScrollView.viewport" }

    var body: some View {
        // scroll-cue:exempt this IS the capped box, and the two modifiers below are the cue it exists for
        ScrollView {
            content
                .background(
                    GeometryReader { inner in
                        Color.clear.preference(
                            key: MoreBelowPreference.self,
                            value: ScrollOverflow.showsMoreBelow(
                                contentHeight: inner.size.height,
                                visibleHeight: viewportHeight,
                                // The content's top sits at a negative offset once scrolled, so its
                                // distance above the box's top edge is how far down we have travelled.
                                scrolledBy: -inner.frame(in: .named(Self.spaceName)).minY))
                    }
                )
        }
        .coordinateSpace(name: Self.spaceName)
        .frame(maxHeight: maxHeight)
        // A background reader rather than a wrapping GeometryReader: a GeometryReader takes all the height
        // it is offered, which would open today's one-source watchlist as a mostly empty 460pt box. A
        // background measures without touching what it measures.
        .background(
            GeometryReader { outer in
                Color.clear.preference(key: ViewportHeightPreference.self, value: outer.size.height)
            }
        )
        .onPreferenceChange(ViewportHeightPreference.self) { height in
            MainActor.assumeIsolated { viewportHeight = height }
        }
        .onPreferenceChange(MoreBelowPreference.self) { hidden in
            MainActor.assumeIsolated { moreBelow = hidden }
        }
        .mask(fade)
        // After the mask, so the chevron itself is never faded by it.
        .overlay(alignment: .bottom) { chevron }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: moreBelow)
    }

    private var fade: some View {
        VStack(spacing: 0) {
            Color.black
            LinearGradient(colors: [.black, .black.opacity(0)], startPoint: .top, endPoint: .bottom)
                .frame(height: moreBelow ? ScrollOverflow.Cue.fadeHeight : 0)
            Color.clear.frame(height: moreBelow ? ScrollOverflow.Cue.clearStrip : 0)
        }
    }

    // Decorative on purpose, and hidden from VoiceOver rather than labelled: the clip is a visual limit,
    // not a limit on what is read. VoiceOver reaches every line inside the box whatever is on screen, so
    // announcing "more below" would describe a problem it does not have.
    private var chevron: some View {
        Image(systemName: "chevron.down")
            .font(.system(size: ScrollOverflow.Cue.glyphSize, weight: .semibold))
            .foregroundStyle(OVColor.inkSoft)
            .padding(.bottom, ScrollOverflow.Cue.glyphInset)
            .opacity(moreBelow ? 1 : 0)
            .accessibilityHidden(true)
    }
}

private struct MoreBelowPreference: PreferenceKey {
    static var defaultValue: Bool { false }
    static func reduce(value: inout Bool, nextValue: () -> Bool) { value = value || nextValue() }
}

private struct ViewportHeightPreference: PreferenceKey {
    static var defaultValue: CGFloat { 0 }
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}
