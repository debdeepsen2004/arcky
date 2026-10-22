import AppKit
import SwiftUI

/// Arc's Archive (closed and auto-archived tabs) and the History window (pages visited),
/// both for the active profile: grouped by day, searchable, and openable.
struct ArchiveView: View {
    enum Kind {
        case archive
        case history
    }

    var kind: Kind = .archive
    @Environment(BrowserStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var confirmingClear = false

    private var entries: [HistoryEntry] {
        kind == .archive ? store.activeArchive : store.activeHistory
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Text(kind == .archive ? "Archive" : "History").font(.title2.weight(.semibold))
                if store.profiles.count > 1 {
                    Text("\(store.activeProfile.emoji) \(store.activeProfile.name)")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .help("Each profile keeps its own \(kind == .archive ? "Archive" : "history")")
                }
                Spacer()
                if kind == .archive {
                    Picker("Archive tabs after", selection: Binding(get: { store.autoArchiveInterval }, set: { store.setAutoArchive($0) })) {
                        ForEach(AutoArchiveInterval.allCases) { Text($0.title).tag($0) }
                    }
                    .fixedSize()
                }
                Button("Done") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            .padding(16)
            TextField(kind == .archive ? "Search archived tabs" : "Search history", text: $query)
                .textFieldStyle(.roundedBorder)
                .padding(.horizontal, 16)
                .padding(.bottom, 10)
            Divider()
            if groups.isEmpty {
                ContentUnavailableView(
                    query.isEmpty ? (kind == .archive ? "Nothing archived yet" : "No history yet") : "No matches",
                    systemImage: kind == .archive ? "archivebox" : "clock",
                    description: Text(query.isEmpty && kind == .archive ? "Closed and auto-archived tabs show up here." : "")
                )
                .frame(maxHeight: .infinity)
            } else {
                List {
                    ForEach(groups, id: \.title) { group in
                        Section(group.title) {
                            ForEach(group.entries) { entry in
                                Button { open(entry) } label: {
                                    EntryRow(entry: entry).contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                .contextMenu {
                                    Button("Open in New Tab") { open(entry) }
                                    Button(kind == .archive ? "Remove from Archive" : "Remove from History") {
                                        if kind == .archive { store.removeFromArchive(entry.id) } else { store.removeFromHistory(entry.id) }
                                    }
                                }
                            }
                        }
                    }
                }
                .listStyle(.inset)
            }
            Divider()
            HStack {
                let count = entries.count
                Text(kind == .archive ? "\(count) archived tabs" : "\(count) pages").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button(kind == .archive ? "Clear Archive" : "Clear History…", role: .destructive) { confirmingClear = true }
                    .disabled(count == 0)
            }
            .padding(12)
        }
        .frame(width: 620, height: 560)
        .confirmationDialog(
            kind == .archive ? "Clear the Archive?" : "Clear history?",
            isPresented: $confirmingClear
        ) {
            Button(kind == .archive ? "Clear Archive" : "Clear History", role: .destructive) {
                if kind == .archive { store.clearArchive() } else { store.clearHistory() }
            }
        } message: {
            Text(store.profiles.count > 1 ? "Only \(store.activeProfile.name)'s are removed; other profiles keep theirs." : "This can't be undone.")
        }
    }

    private func open(_ entry: HistoryEntry) {
        if kind == .archive {
            store.restoreFromArchive(entry)
        } else {
            store.newTab(entry.url)
        }
        dismiss()
    }

    private var groups: [(title: String, entries: [HistoryEntry])] {
        let needle = query.lowercased()
        let matching = needle.isEmpty ? entries : entries.filter {
            $0.title.lowercased().contains(needle) || $0.url.absoluteString.lowercased().contains(needle)
        }
        let calendar = Calendar.current
        var result: [(title: String, entries: [HistoryEntry])] = []
        for entry in matching {
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

private struct EntryRow: View {
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
