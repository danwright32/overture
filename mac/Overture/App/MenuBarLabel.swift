import SwiftUI

// #2115: the menu bar item itself, the glyph plus the count of work due today.
//
// Its own view rather than a title string on the MenuBarExtra, because the count changes while the app
// sits there and a Scene cannot hold state that reacts. @AppStorage on the published count is what makes
// the item redraw the moment the reconcile tick writes a new one.
//
// The number is never composed here: DueBadge owns what a count looks like, so this and the Dock tile
// cannot state different numbers for one count. Empty string when nothing is due, so the glyph sits alone
// rather than beside a permanent zero.
struct MenuBarLabel: View {
    @AppStorage(DueBadge.countKey) private var dueCount: Int = 0

    var body: some View {
        // The image is the item's identity and is always present; only the count comes and goes.
        HStack(spacing: 3) {
            Image("MenuBarGlyph")
            let title = DueBadge.menuBarTitle(count: dueCount)
            if !title.isEmpty { Text(title) }
        }
        // Said in words for VoiceOver, since a bare number beside a glyph is not a sentence (L20).
        .accessibilityLabel(DueBadge.menuBarAccessibilityLabel(count: dueCount))
    }
}
