import AppKit
import SwiftUI

/// Arc's ⌘T / ⌘L command bar: URL entry, search, open-tab switching and history.
struct CommandBarView: View {
    let mode: CommandBarMode
    @Environment(BrowserStore.self) private var store
    @Environment(\.spaceTheme) private var theme
    @State private var query = ""
    @State private var selection = 0
    @State private var keyMonitor: Any?
    @FocusState private var focused: Bool

    private static var backdropDim: Double {
        if #available(macOS 26, *) { return 0.05 }
        return 0.12
    }

    enum Suggestion: Hashable {
        case navigate(URL)
        case search(String)
        /// Instant Links: straight to the top result (or the top N).
        case instant(String)
        case tab(BrowserTab)
        case history(HistoryEntry)
    }

    var body: some View {
        let items = suggestions
        ZStack(alignment: .top) {
            // A lighter dim where the panel is glass, so it shows the page rather than a grey wash.
            Color.black.opacity(Self.backdropDim)
                .contentShape(Rectangle())
                .onTapGesture { dismiss() }
            VStack(spacing: 0) {
                HStack(spacing: 12) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 17, weight: .medium))
                        .foregroundStyle(.secondary)
                    TextField(mode == .splitPane ? "Open in Split View…" : "Search or Enter URL…", text: $query)
                        .textFieldStyle(.plain)
                        .font(.system(size: 20))
                        .focused($focused)
                        .onSubmit { submit(items) }
                }
                .padding(.horizontal, 18)
                .frame(height: 56)
                if !items.isEmpty {
                    Divider()
                    VStack(spacing: 2) {
                        ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                            SuggestionRow(item: item, selected: index == selection)
                                .contentShape(Rectangle())
                                .onTapGesture { run(item) }
                                .onHover { if $0 { selection = index } }
                        }
                    }
                    .padding(6)
                }
            }
            .frame(width: 640)
            .readableGlassSurface(RoundedRectangle(cornerRadius: 20, style: .continuous))
            .shadow(color: .black.opacity(0.25), radius: 30, y: 12)
            .padding(.top, 110)
        }
        .onAppear {
            if mode == .editCurrent { query = store.activeTab?.url?.absoluteString ?? "" }
            focused = true
            installKeyMonitor()
        }
        .onDisappear {
            if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        }
        .onChange(of: query) { selection = 0 }
    }

    private var suggestions: [Suggestion] {
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty {
            let recent = store.allTabs
                .filter { $0.url != nil && $0.id != store.activeTabID }
                .sorted { $0.lastActive > $1.lastActive }
            return recent.prefix(6).map(Suggestion.tab)
        }

        var results: [Suggestion] = []
        let isURL = URLResolver.isLikelyURL(text)
        if isURL, let url = URLResolver.resolve(text) {
            results.append(.navigate(url))
        } else {
            results.append(.search(text))
            results.append(.instant(text))
        }

        let needle = text.lowercased()
        func matches(_ title: String, _ url: URL?) -> Bool {
            title.lowercased().contains(needle) || (url?.absoluteString.lowercased().contains(needle) ?? false)
        }

        let tabs = store.allTabs.filter { $0.id != store.activeTabID && matches($0.title, $0.url) }.prefix(4)
        results += tabs.map(Suggestion.tab)

        var seen = Set(tabs.compactMap(\.url))
        var historyCount = 0
        for entry in store.activeHistory where historyCount < 5 && matches(entry.title, entry.url) && !seen.contains(entry.url) {
            results.append(.history(entry))
            seen.insert(entry.url)
            historyCount += 1
        }

        if isURL { results.append(.search(text)) }
        return results
    }

    /// Return runs the highlighted row; ⇧Return on a search goes straight to the top result.
    private func submit(_ items: [Suggestion]) {
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let shift = NSApp.currentEvent?.modifierFlags.contains(.shift) == true
        if shift, !text.isEmpty, !URLResolver.isLikelyURL(text), mode != .splitPane {
            run(.instant(text))
        } else if items.indices.contains(selection) {
            run(items[selection])
        }
    }

    private func run(_ suggestion: Suggestion) {
        switch suggestion {
        case .navigate(let url): open(url)
        case .search(let text): open(URLResolver.searchURL(text))
        case .instant(let text): store.openInstantLinks(text, inNewTab: mode != .editCurrent)
        case .history(let entry): open(entry.url)
        case .tab(let tab):
            if mode == .splitPane {
                store.splitWithActive(tab.id)
            } else {
                store.select(tab.id)
            }
        }
        dismiss()
    }

    private func open(_ url: URL) {
        switch mode {
        case .newTab: store.open(url, inNewTab: true)
        case .editCurrent: store.open(url, inNewTab: false)
        case .splitPane: store.openSplitPane(url)
        }
    }

    private func dismiss() {
        store.commandBar = nil
    }

    /// Arrow keys and Escape go to the suggestion list instead of the text field.
    private func installKeyMonitor() {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            switch event.keyCode {
            case 125: // down
                selection = min(selection + 1, max(suggestions.count - 1, 0))
                return nil
            case 126: // up
                selection = max(selection - 1, 0)
                return nil
            case 53: // escape
                dismiss()
                return nil
            default:
                return event
            }
        }
    }
}

private struct SuggestionRow: View {
    let item: CommandBarView.Suggestion
    let selected: Bool
    @Environment(\.spaceTheme) private var theme

    var body: some View {
        HStack(spacing: 12) {
            icon.frame(width: 18, height: 18)
            Text(title).font(.system(size: 14)).lineLimit(1)
            if let subtitle {
                Text(subtitle).font(.system(size: 12)).foregroundStyle(selected ? .white.opacity(0.75) : .secondary).lineLimit(1)
            }
            Spacer()
            if let badge {
                Text(badge).font(.system(size: 11, weight: .medium)).foregroundStyle(selected ? .white.opacity(0.8) : .secondary)
            }
        }
        .foregroundStyle(selected ? .white : .primary)
        .padding(.horizontal, 12)
        .frame(height: 38)
        .background(RoundedRectangle(cornerRadius: 13, style: .continuous).fill(selected ? theme.accent : .clear))
    }

    @ViewBuilder private var icon: some View {
        switch item {
        case .navigate: Image(systemName: "globe")
        case .search: Image(systemName: "magnifyingglass")
        case .instant: Image(systemName: "bolt.fill")
        case .tab(let tab): Favicon(tab: tab, size: 16)
        case .history(let entry): Favicon(tab: BrowserTab(url: entry.url), size: 16)
        }
    }

    private var title: String {
        switch item {
        case .navigate(let url): url.absoluteString
        case .search(let text): text
        case .instant(let text):
            InstantLinks.parse(text).count > 1
                ? "Open the top \(InstantLinks.parse(text).count) results for “\(InstantLinks.parse(text).query)”"
                : "Go to the top result for “\(text)”"
        case .tab(let tab): tab.displayTitle
        case .history(let entry): entry.title.isEmpty ? entry.url.absoluteString : entry.title
        }
    }

    private var subtitle: String? {
        switch item {
        case .navigate, .search, .instant: nil
        case .tab(let tab): tab.url?.host()?.strippingWWW
        case .history(let entry): entry.url.host()?.strippingWWW
        }
    }

    private var badge: String? {
        switch item {
        case .navigate: "Open"
        case .search: "Search Google"
        case .instant: "Instant Link ⇧↩"
        case .tab: "Switch to Tab"
        case .history: "History"
        }
    }
}
