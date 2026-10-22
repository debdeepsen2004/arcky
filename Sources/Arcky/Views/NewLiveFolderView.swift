import SwiftUI

/// Creates a live folder from an RSS feed or GitHub pull requests.
struct NewLiveFolderView: View {
    @Environment(BrowserStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    enum Kind: String, CaseIterable, Identifiable {
        case rss = "RSS or Atom Feed"
        case repo = "Pull Requests in a Repository"
        case mine = "My Pull Requests"
        case reviews = "Review Requests"
        var id: String { rawValue }
    }

    @State private var kind = Kind.rss
    @State private var address = ""
    @State private var name = ""
    @State private var detecting = false
    @State private var error: String?

    private var hasToken: Bool { GitHubToken.load() != nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("New Live Folder").font(.title2.weight(.semibold))
            Text("A pinned folder that keeps itself up to date. New items get a dot until you open them.")
                .font(.callout)
                .foregroundStyle(.secondary)

            Picker("Source", selection: $kind) {
                ForEach(Kind.allCases) { Text($0.rawValue).tag($0) }
            }

            switch kind {
            case .rss:
                HStack {
                    TextField("Feed address, e.g. https://example.com/feed.xml", text: $address)
                    Button(detecting ? "Looking…" : "Use This Page's Feed") { detectFeed() }
                        .disabled(detecting || store.activeHost == nil)
                }
            case .repo:
                TextField("owner/repository, e.g. apple/swift", text: $address)
            case .mine, .reviews:
                if !hasToken {
                    Label("Needs a GitHub token. Add one in Settings ▸ General.", systemImage: "key")
                        .foregroundStyle(.orange)
                        .font(.callout)
                }
            }

            TextField("Name (optional)", text: $name)

            if let error {
                Label(error, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.red)
                    .font(.callout)
            }

            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                Button("Create") { create() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(source == nil)
            }
        }
        .padding(20)
        .frame(width: 520)
        .onChange(of: kind) { error = nil }
    }

    /// The source described by the form, or nil if it isn't complete.
    private var source: LiveSource? {
        let text = address.trimmingCharacters(in: .whitespacesAndNewlines)
        switch kind {
        case .rss:
            guard let url = URL(string: text.contains("://") ? text : "https://" + text), url.host() != nil, !text.isEmpty else { return nil }
            return .rss(url)
        case .repo:
            let parts = text.split(separator: "/")
            guard parts.count == 2, parts.allSatisfy({ !$0.isEmpty }) else { return nil }
            return .githubRepoPullRequests(text)
        case .mine:
            return hasToken ? .githubMyPullRequests : nil
        case .reviews:
            return hasToken ? .githubReviewRequests : nil
        }
    }

    private func create() {
        guard let source else { return }
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        store.createLiveFolder(source, name: trimmed.isEmpty ? nil : trimmed)
        dismiss()
    }

    private func detectFeed() {
        detecting = true
        error = nil
        Task {
            if let feed = await store.detectFeedForActivePage() {
                address = feed.absoluteString
            } else {
                error = "This page doesn't advertise a feed."
            }
            detecting = false
        }
    }
}
