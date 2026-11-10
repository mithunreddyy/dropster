import SwiftUI
import DropsterCore

struct HistoryView: View {
    let store: HistoryStore?
    @State private var entries: [HistoryEntry] = []
    @State private var totals = HistoryTotals(files: 0, savedBytes: 0)
    @State private var confirmClear = false

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(Fmt.bytes(totals.savedBytes)).font(.title.weight(.semibold)).monospacedDigit()
                    Text("saved across \(totals.files) \(totals.files == 1 ? "file" : "files")").foregroundStyle(.secondary)
                }
                Spacer()
                Button("Clear History…") { confirmClear = true }.disabled(entries.isEmpty)
            }
            .padding(16)
            Divider()
            if entries.isEmpty {
                ContentUnavailableView("No History Yet", systemImage: "clock", description: Text("Finished files appear here. History is stored only on this Mac."))
            } else {
                Table(entries) {
                    TableColumn("File") { e in Text(URL(fileURLWithPath: e.source).lastPathComponent).lineLimit(1).truncationMode(.middle) }
                    TableColumn("Action", value: \.operation)
                    TableColumn("Size") { e in
                        Text(e.outcome == "written" ? "\(Fmt.bytes(e.inputBytes)) → \(Fmt.bytes(e.outputBytes))" : "Kept original")
                            .monospacedDigit().foregroundStyle(e.outcome == "written" ? .primary : .secondary)
                    }
                    TableColumn("Date") { e in Text(e.date, format: .dateTime.day().month().hour().minute()).foregroundStyle(.secondary) }
                }
            }
        }
        .task { reload() }
        .onReceive(Timer.publish(every: 2, on: .main, in: .common).autoconnect()) { _ in reload() }
        .confirmationDialog("Clear all history?", isPresented: $confirmClear) {
            Button("Clear History", role: .destructive) { store?.clear(); reload() }
        } message: { Text("This removes the record of processed files. Your files are not affected.") }
    }

    private func reload() {
        guard let store else { return }
        entries = store.recent()
        totals = store.totals()
    }
}
