import AppKit
import SwiftUI

/// Sidebar button showing download progress; opens the downloads popover.
struct DownloadsButton: View {
    @Environment(BrowserStore.self) private var store
    @Environment(\.spaceTheme) private var theme

    var body: some View {
        @Bindable var store = store
        let progress = store.downloads.overallProgress(for: store.activeProfileID)
        IconButton(systemName: "arrow.down.circle", help: "Downloads (⇧⌘J)") { store.showingDownloads.toggle() }
            .foregroundStyle(progress == nil ? theme.secondaryText : theme.accent)
            .overlay {
                if let progress {
                    Circle()
                        .trim(from: 0, to: progress)
                        .stroke(theme.accent, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                        .frame(width: 20, height: 20)
                        .allowsHitTesting(false)
                }
            }
            .popover(isPresented: $store.showingDownloads, arrowEdge: .top) {
                DownloadsPopover(manager: store.downloads, profile: store.activeProfile, showsProfile: store.profiles.count > 1)
            }
    }
}

/// The active profile's downloads.
struct DownloadsPopover: View {
    let manager: DownloadManager
    let profile: Profile
    let showsProfile: Bool

    var body: some View {
        let items = manager.items(for: profile.id)
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Downloads").font(.headline)
                if showsProfile {
                    Text("\(profile.emoji) \(profile.name)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if items.contains(where: { $0.state != .inProgress }) {
                    Button("Clear") { manager.clearCompleted(for: profile.id) }
                        .buttonStyle(.borderless)
                }
            }
            .padding(12)
            Divider()
            if items.isEmpty {
                Text("No downloads yet")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 80)
            } else {
                ScrollView {
                    VStack(spacing: 2) {
                        ForEach(items) { item in
                            DownloadRow(item: item, manager: manager)
                        }
                    }
                    .padding(6)
                }
                .frame(maxHeight: 360)
            }
        }
        .frame(width: 340)
    }
}

private struct DownloadRow: View {
    let item: DownloadItem
    let manager: DownloadManager
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 10) {
            Image(nsImage: icon)
                .resizable()
                .frame(width: 32, height: 32)
            VStack(alignment: .leading, spacing: 3) {
                Text(item.filename).font(.system(size: 13)).lineLimit(1).truncationMode(.middle)
                switch item.state {
                case .inProgress:
                    ProgressView(value: item.progress).controlSize(.small)
                case .finished:
                    Text(sizeText).font(.system(size: 11)).foregroundStyle(.secondary)
                case .failed(let message):
                    Text(message).font(.system(size: 11)).foregroundStyle(.red).lineLimit(1)
                case .cancelled:
                    Text("Cancelled").font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
            if item.state == .inProgress {
                Button { manager.cancel(item) } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .help("Cancel")
            } else if item.destination != nil {
                Button { manager.reveal(item) } label: { Image(systemName: "magnifyingglass.circle.fill") }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .help("Show in Finder")
            }
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 8).fill(hovering ? Color.primary.opacity(0.06) : .clear))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture { manager.open(item) }
    }

    private var icon: NSImage {
        if item.state == .finished, let path = item.destination?.path(percentEncoded: false) {
            return NSWorkspace.shared.icon(forFile: path)
        }
        let ext = (item.filename as NSString).pathExtension
        return NSWorkspace.shared.icon(for: .init(filenameExtension: ext) ?? .data)
    }

    private var sizeText: String {
        item.totalBytes > 0 ? ByteCountFormatter.string(fromByteCount: item.totalBytes, countStyle: .file) : "Done"
    }
}
