import SwiftUI

// #361: the quiet reward a just-sent show becomes as it leaves the queue. A gold "Sent" seal
// springs in and a thin gold line draws once left to right (the "downbeat", tying to the app's
// musical naming); the queue then glides the row up and fades it out. Non-interactive: the work is
// done, this is only the farewell. Honors Reduced Motion via the timing plan (no drawn line, and
// the queue's exit is a plain fade). The phase timing lives in the tested SendDelightTiming.
struct SendDelightRow: View {
    let item: QueueItem
    let timing: SendDelightTiming

    @State private var sealShown = false
    @State private var lineDrawn = false

    var body: some View {
        HStack(alignment: .center, spacing: OVSpacing.md) {
            VStack(alignment: .leading, spacing: 2) {
                Text(item.groupName).font(OVType.groupName).foregroundStyle(OVColor.ink)
                if let venue = item.venue, !venue.isEmpty {
                    Text(venue).font(OVType.body).foregroundStyle(OVColor.inkSoft)
                }
            }
            Spacer(minLength: OVSpacing.md)
            seal
        }
        .padding(.vertical, OVSpacing.sm)
        .overlay(alignment: .bottomLeading) {
            if timing.lineDraw > 0 {
                Rectangle()
                    .fill(LinearGradient(colors: [OVColor.goldBright, OVColor.gold],
                                         startPoint: .leading, endPoint: .trailing))
                    .frame(height: 2)
                    .scaleEffect(x: lineDrawn ? 1 : 0, anchor: .leading)
            }
        }
        .onAppear {
            withAnimation(.spring(response: timing.sealIn, dampingFraction: 0.7)) { sealShown = true }
            if timing.lineDraw > 0 {
                withAnimation(.easeInOut(duration: timing.lineDraw)) { lineDrawn = true }
            }
        }
    }

    private var seal: some View {
        HStack(spacing: 6) {
            ZStack {
                Circle()
                    .fill(RadialGradient(colors: [OVColor.goldBright, OVColor.gold],
                                         center: .init(x: 0.6, y: 0.4), startRadius: 0, endRadius: 9))
                    .frame(width: 16, height: 16)
                Image(systemName: "checkmark")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(Color(.sRGB, red: 0.22, green: 0.16, blue: 0.02))
            }
            Text(SendConfirmCopy.sentSeal).font(OVType.meta).foregroundStyle(OVColor.gold)
        }
        .padding(.horizontal, 10).padding(.vertical, 5)
        .background(
            Capsule().fill(OVColor.gold.opacity(0.12))
                .overlay(Capsule().strokeBorder(OVColor.gold.opacity(0.5)))
        )
        .opacity(sealShown ? 1 : 0)
        .scaleEffect(sealShown ? 1 : 0.85)
    }
}
