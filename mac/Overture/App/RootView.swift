import SwiftUI
import SwiftData

struct RootView: View {
    @Environment(\.modelContext) private var context
    @State private var lastIngest: ResultsImporter.Outcome?
    @State private var ingestError: String?

    var body: some View {
        QueueView()
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        ingest()
                    } label: {
                        Label("Fetch latest scout", systemImage: "arrow.clockwise")
                    }
                    .help("Re-read the latest scout results (⌘R)")
                    .keyboardShortcut("r", modifiers: .command)
                }
            }
            .task { ingestIfEmpty() }
            .alert("Could not read scout results", isPresented: errorBinding) {
                Button("OK", role: .cancel) { ingestError = nil }
            } message: {
                Text(ingestError ?? "")
            }
    }

    private var errorBinding: Binding<Bool> {
        Binding(get: { ingestError != nil }, set: { if !$0 { ingestError = nil } })
    }

    private func ingestIfEmpty() {
        let count = (try? context.fetchCount(FetchDescriptor<Prospect>())) ?? 0
        if count == 0 { ingest() }
    }

    private func ingest() {
        let url = ResultsImporter.defaultResultsURL
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        do {
            lastIngest = try ResultsImporter.ingestFile(at: url, into: context)
        } catch {
            ingestError = String(describing: error)
        }
    }
}
