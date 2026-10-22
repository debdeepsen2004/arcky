import AppKit
import SwiftUI

/// Arc's Archive: closed and auto-archived tabs, grouped by day, searchable and restorable.
struct ArchiveView: View {
    @Environment(BrowserStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Text("Archive").font(.title2.weight(.semibold))
                Spacer()
                Picker("Archive tabs after", selection: Binding(get: { store.autoArchiveInterval }, set: { store.setAutoArchive($0) })) {
                    ForEach(AutoArchiveInterval.allCases) { Text($0.title).tag($0) }
                }
                .fixedSize()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            .padding(16)
            TextField("Search archived tabs", text: $query)
                .textFieldStyle(.roundedBorder)
                .padding(.horizontal, 16)
                .padding(.bottom, 10)
            Divider()
            if groups.isEmpty {
                ContentUnavailableView(
                    query.isEmpty ? "Nothing archived yet" : "No matches",
                    systemImage: "archivebox",
                    description: Text(query.isEmpty ? "Closed and auto-archived tabs show up here." : "")
                )
                .frame(maxHeight: .infinity)
            } else {
                List {
                    ForEach(groups, id: \.title) { group in
                        Section(group.title) {
                            ForEach(group.entries) { entry in
                                Button {
                                    store.restoreFromArchive(entry)
                                    dismiss()
                                } label: {
                                    ArchiveRow(entry: entry).contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                .contextMenu {
                                        Button("Open in New Tab") {
                                            store.restoreFromArchive(entry)
                                            dismiss()
                                        }
                                        Button("Remove from Archive") { store.removeFromArchive(entry.id) }
                                    }
                            }
                        }
                    }
                }
                .listStyle(.inset)
            }
            Divider()
            HStack {
                Text("\(store.archive.count) archived tabs").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Clear Archive", role: .destructive) { store.clearArchive() }
                    .disabled(store.archive.isEmpty)
            }
            .padding(12)
        }
        .frame(width: 620, height: 560)
    }

    private var groups: [(title: String, entries: [HistoryEntry])] {
        let needle = query.lowercased()
        let entries = needle.isEmpty ? store.archive : store.archive.filter {
            $0.title.lowercased().contains(needle) || $0.url.absoluteString.lowercased().contains(needle)
        }
        let calendar = Calendar.current
        var result: [(title: String, entries: [HistoryEntry])] = []
        for entry in entries {
            let title: String
            if calendar.isDateInToday(entry.date) {
                title = "Today"
            } else if calendar.isDateInYesterday(entry.date) {
                title = "Yesterday"
            } else {
                title = entry.date.formatted(date: .complete, time: .omitted)
            }
            if result.last?.title == title {
                result[result.count - 1].entries.append(entry)
            } else {
                result.append((title, [entry]))
            }
        }
        return result
    }
}

private struct ArchiveRow: View {
    let entry: HistoryEntry

    var body: some View {
        HStack(spacing: 10) {
            Favicon(tab: BrowserTab(url: entry.url), size: 16)
            VStack(alignment: .leading, spacing: 1) {
                Text(entry.title.isEmpty ? entry.url.absoluteString : entry.title).lineLimit(1)
                Text(entry.url.host()?.strippingWWW ?? entry.url.absoluteString)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            Text(entry.date.formatted(date: .omitted, time: .shortened))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 3)
    }
}
