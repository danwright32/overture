import SwiftUI
import SwiftData

// #799 slice 4b: "I found a show. Here's the link." Dan pastes it, Overture fetches the page itself,
// hands it to the extract run, and shows him what it found so he can confirm before anything is
// written into his store.
//
// The sheet STAYS OPEN while it works, showing a live counter (Dan's call). That is not decoration:
// CLAUDE.md's standing rule is that a slow action must make "working", "still alive" and "failed"
// visibly different states, and a bare spinner that looks the same whether the run is progressing,
// hung, or dead is a defect. LiveRunLabel already does exactly that (elapsed counter, real N-of-M from
// the run's progress file, and a stalled state with a retry), so it is reused rather than reinvented.
struct AddLeadSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context

    @State private var model = LeadIntakeModel()
    @FocusState private var urlFocused: Bool
    // #768: the watchlist as it stands, so the sheet can tell Dan that this org is already watched, or
    // that they asked him to stop. Only the view can supply these, so the model takes them as an input
    // rather than reaching for a context of its own.
    @Query private var watched: [WatchedSource]

    var body: some View {
        VStack(alignment: .leading, spacing: OVSpacing.md) {
            header

            switch model.phase {
            case .idle:
                entry
            case .working(let startedAt):
                working(startedAt: startedAt)
            case .review(let events, let note):
                review(events, note: note)
                    .onAppear { model.prepareWatchProposal(existing: watched) }
            case .problem(let message):
                problem(message)
            case .added(let count):
                added(count)
            }
        }
        .padding(OVSpacing.lg)
        .frame(width: 520)
        .onAppear { urlFocused = true }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Add a lead").font(.system(size: 15, weight: .semibold)).foregroundStyle(OVColor.ink)
            Text("Paste a link to the show, or to the organization's events page.")
                .font(OVType.meta).foregroundStyle(OVColor.inkSoft)
        }
    }

    private var entry: some View {
        VStack(alignment: .leading, spacing: OVSpacing.sm) {
            TextField("https://", text: $model.urlText)
                .textFieldStyle(.roundedBorder)
                .focused($urlFocused)
                .onSubmit(start)

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.buttonStyle(.plain).foregroundStyle(OVColor.inkSoft)
                Button(action: start) {
                    Text("Read this page")
                        .font(OVType.meta).foregroundStyle(OVColor.onForest)
                        .padding(.horizontal, OVSpacing.md).padding(.vertical, 5)
                        .background(Capsule().fill(OVColor.forest))
                }
                .buttonStyle(.plain)
                .disabled(model.urlText.trimmingCharacters(in: .whitespaces).isEmpty)
                .keyboardShortcut(.return, modifiers: [])
            }
        }
    }

    // Working, still-alive, and failed as three visibly different states, per CLAUDE.md. The counter
    // keeps ticking, the run's own progress file feeds the detail, and if it genuinely stalls the label
    // says so and offers a retry instead of spinning forever.
    private func working(startedAt: Date) -> some View {
        VStack(alignment: .leading, spacing: OVSpacing.sm) {
            LiveRunLabel(base: "Reading the page",
                         since: startedAt,
                         timeout: RunTimeouts.scoutExtract,
                         font: OVType.body,
                         color: OVColor.inkSoft,
                         onRetry: start,
                         progressDetail: model.progressDetail)
            Text("It fetches the page, then follows each show's own link to get the venue and date.")
                .font(OVType.meta).foregroundStyle(OVColor.inkFaint)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.buttonStyle(.plain).foregroundStyle(OVColor.inkSoft)
            }
        }
    }

    // #768: handing over a lead means "I care about these people, keep looking at them", so Overture
    // proposes to keep watching their calendar. Dan confirms, because the two things it cannot know are
    // exactly the ones that matter: whether this is a recurring calendar or a touring act's itinerary,
    // and whether the link is the org's calendar or just one show's page.
    @ViewBuilder
    private var watchProposal: some View {
        switch model.watchVerdict {
        case .propose:
            VStack(alignment: .leading, spacing: OVSpacing.xs) {
                Divider().overlay(OVColor.line)
                Toggle(isOn: $model.watchThisCalendar) {
                    Text("Keep watching this calendar")
                        .font(OVType.body).foregroundStyle(OVColor.ink)
                }
                .toggleStyle(.checkbox)

                Text("Every scout re-checks it, so their next show turns up on its own. Untick it for a touring act: an itinerary is mostly not in New York, and re-reading it buys nothing.")
                    .font(OVType.meta).foregroundStyle(OVColor.inkSoft)
                    .fixedSize(horizontal: false, vertical: true)

                if model.watchThisCalendar {
                    VStack(alignment: .leading, spacing: 4) {
                        TextField("Organization", text: $model.watchOrgName)
                            .textFieldStyle(.roundedBorder).font(OVType.meta)
                        TextField("Calendar page", text: $model.watchURL)
                            .textFieldStyle(.roundedBorder).font(OVType.meta)
                        Text("This should be their events or season page, not one show. A single show's page never changes again, so watching it would watch nothing.")
                            .font(OVType.meta).foregroundStyle(OVColor.inkFaint)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        case .alreadyWatching(let orgName):
            Text("Already watching \(orgName)'s calendar, so their shows turn up on their own.")
                .font(OVType.meta).foregroundStyle(OVColor.inkFaint)
                .fixedSize(horizontal: false, vertical: true)
        case .refused(let orgName):
            // He must SEE this. Silently declining to watch them would look identical to a bug.
            Text("\(orgName) asked not to be contacted, so Overture won't watch their calendar.")
                .font(OVType.meta).foregroundStyle(OVColor.rust)
                .fixedSize(horizontal: false, vertical: true)
        case .nothingToWatch, .none:
            EmptyView()
        }
    }

    private func review(_ events: [ExtractedEvent], note: String?) -> some View {
        VStack(alignment: .leading, spacing: OVSpacing.sm) {
            Text(events.count == 1 ? "Found 1 show" : "Found \(events.count) shows")
                .font(OVType.body).foregroundStyle(OVColor.ink)

            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(Array(events.enumerated()), id: \.offset) { _, event in
                        Toggle(isOn: binding(for: event)) {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(event.title).font(OVType.body).foregroundStyle(OVColor.ink)
                                    .lineLimit(2).fixedSize(horizontal: false, vertical: true)
                                Text([QueueModel.runDateLabel(start: event.performanceDate, end: nil),
                                      event.venue ?? ""]
                                        .filter { !$0.isEmpty }.joined(separator: "  ·  "))
                                    .font(OVType.meta).foregroundStyle(OVColor.inkSoft)
                            }
                        }
                        .toggleStyle(.checkbox)
                    }
                }
            }
            .frame(maxHeight: 260)

            if let note, !note.isEmpty {
                Text(note).font(OVType.meta).foregroundStyle(OVColor.inkFaint)
                    .fixedSize(horizontal: false, vertical: true)
            }

            watchProposal

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.buttonStyle(.plain).foregroundStyle(OVColor.inkSoft)
                Button {
                    model.confirm(into: context)
                } label: {
                    Text(model.selected.isEmpty ? "Add" : "Add \(model.selected.count)")
                        .font(OVType.meta).foregroundStyle(OVColor.onForest)
                        .padding(.horizontal, OVSpacing.md).padding(.vertical, 5)
                        .background(Capsule().fill(OVColor.forest))
                }
                .buttonStyle(.plain)
                .disabled(model.selected.isEmpty)
            }
        }
    }

    // Every unhappy ending is NAMED and actionable. An org between seasons reads as normal, not as a
    // failure; an unreadable page says what to paste instead. Never a spinner that ends in silence.
    private func problem(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: OVSpacing.sm) {
            Text(message).font(OVType.body).foregroundStyle(OVColor.inkSoft)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button("Close") { dismiss() }.buttonStyle(.plain).foregroundStyle(OVColor.inkSoft)
                Button("Try another link") { model.reset(); urlFocused = true }
                    .buttonStyle(.plain).foregroundStyle(OVColor.forest)
            }
        }
    }

    private func added(_ count: Int) -> some View {
        VStack(alignment: .leading, spacing: OVSpacing.sm) {
            Text(count == 1 ? "Added 1 show to the queue." : "Added \(count) shows to the queue.")
                .font(OVType.body).foregroundStyle(OVColor.ink)
            Text("They're ranked and waiting with everything else.")
                .font(OVType.meta).foregroundStyle(OVColor.inkSoft)
            HStack {
                Spacer()
                Button("Add another") { model.reset(); urlFocused = true }
                    .buttonStyle(.plain).foregroundStyle(OVColor.forest)
                Button {
                    dismiss()
                } label: {
                    Text("Done").font(OVType.meta).foregroundStyle(OVColor.onForest)
                        .padding(.horizontal, OVSpacing.md).padding(.vertical, 5)
                        .background(Capsule().fill(OVColor.forest))
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func binding(for event: ExtractedEvent) -> Binding<Bool> {
        let key = model.key(for: event)
        return Binding(get: { model.selected.contains(key) },
                       set: { on in
                           if on { model.selected.insert(key) } else { model.selected.remove(key) }
                       })
    }

    private func start() {
        Task { await model.start(now: Date()) }
    }
}
