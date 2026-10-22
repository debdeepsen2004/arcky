import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// File ▸ Import…: brings in spaces and tabs from Arc, and bookmarks from other browsers.
struct ImportView: View {
    @Environment(BrowserStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var sources = BrowserImporter.availableSources()
    @State private var message: (text: String, isError: Bool)?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Import").font(.title2.weight(.semibold))
            Text("Imported spaces are added alongside your current ones. Logins and cookies can't be imported.")
                .font(.callout)
                .foregroundStyle(.secondary)

            VStack(spacing: 8) {
                ForEach(sources) { source in
                    SourceRow(title: title(of: source), detail: detail(of: source), systemImage: icon(of: source)) {
                        run(source)
                    }
                }
                SourceRow(title: "Bookmarks File…", detail: "An HTML file exported from any browser", systemImage: "doc.text") {
                    pickFile()
                }
            }

            if let message {
                Label(message.text, systemImage: message.isError ? "exclamationmark.triangle" : "checkmark.circle")
                    .foregroundStyle(message.isError ? .red : .green)
                    .font(.callout)
            }

            HStack {
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 480)
    }

    private func run(_ source: BrowserImporter.Source) {
        do {
            let result = try BrowserImporter.load(source)
            guard result.tabCount > 0 else {
                message = ("Nothing to import from \(title(of: source)).", true)
                return
            }
            store.applyImport(result, from: title(of: source))
            let spaces = result.spaces.count == 1 ? "1 space" : "\(result.spaces.count) spaces"
            message = ("Imported \(spaces) and \(result.tabCount) tabs from \(title(of: source)).", false)
        } catch {
            var text = error.localizedDescription
            if case .safari = source {
                text += " Give Arcky Full Disk Access, or export bookmarks from Safari (File ▸ Export ▸ Bookmarks) and import that file."
            }
            message = (text, true)
        }
    }

    private func pickFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.html]
        panel.prompt = "Import"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        run(.bookmarksHTML(url))
    }

    private func title(of source: BrowserImporter.Source) -> String {
        switch source {
        case .arc: "Arc"
        case .chromium(let name, _): name
        case .safari: "Safari"
        case .bookmarksHTML(let url): url.lastPathComponent
        }
    }

    private func detail(of source: BrowserImporter.Source) -> String {
        switch source {
        case .arc: "Spaces, pinned tabs and folders, Today tabs, favorites and space colors"
        case .chromium: "Bookmarks, as a new space"
        case .safari: "Bookmarks, as a new space (needs Full Disk Access)"
        case .bookmarksHTML: "Bookmarks"
        }
    }

    private func icon(of source: BrowserImporter.Source) -> String {
        switch source {
        case .arc: "sparkles"
        case .chromium: "globe"
        case .safari: "safari"
        case .bookmarksHTML: "doc.text"
        }
    }
}

private struct SourceRow: View {
    let title: String
    let detail: String
    let systemImage: String
    let action: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: systemImage)
                .font(.title3)
                .frame(width: 28)
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.body.weight(.medium))
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button("Import", action: action)
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.05)))
    }
}
