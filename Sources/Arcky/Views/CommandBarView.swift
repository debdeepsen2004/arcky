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

    enum Suggestion: Hashable {
        case navigate(URL)
        case search(String)
        case tab(BrowserTab)
        case history(HistoryEntry)
    }

    var body: some View {
        let items = suggestions
        ZStack(alignment: .top) {
            Color.black.opacity(0.12)
                .contentShape(Rectangle())
                .onTapGesture { dismiss() }
            VStack(spacing: 0) {
                HStack(spacing: 12) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 17, weight: .medium))
                        .foregroundStyle(.secondary)
                    TextField("Search or Enter URL…", text: $query)
                        .textFieldStyle(.plain)
                        .font(.system(size: 20))
                        .focused($focused)
                        .onSubmit { if items.indices.contains(selection) { run(items[selection]) } }
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
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(.white.opacity(0.2)))
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
            let recent = store.allTabs.filter { $0.url != nil }.sorted { $0.lastActive > $1.lastActive }
            return recent.prefix(6).map(Suggestion.tab)
        }

        var results: [Suggestion] = []
        let isURL = URLResolver.isLikelyURL(text)
        if isURL, let url = URLResolver.resolve(text) {
            results.append(.navigate(url))
        } else {
            results.append(.search(text))
        }

        let needle = text.lowercased()
        func matches(_ title: String, _ url: URL?) -> Bool {
            title.lowercased().contains(needle) || (url?.absoluteString.lowercased().contains(needle) ?? false)
        }

        let tabs = store.allTabs.filter { $0.id != store.activeTabID && matches($0.title, $0.url) }.prefix(4)
        results += tabs.map(Suggestion.tab)

        var seen = Set(tabs.compactMap(\.url))
        var historyCount = 0
        for entry in store.history where historyCount < 5 && matches(entry.title, entry.url) && !seen.contains(entry.url) {
            results.append(.history(entry))
            seen.insert(entry.url)
            historyCount += 1
        }

        if isURL { results.append(.search(text)) }
        return results
    }

    private func run(_ suggestion: Suggestion) {
        let newTab = mode == .newTab
        switch suggestion {
        case .navigate(let url): store.open(url, inNewTab: newTab)
        case .search(let text): store.open(URLResolver.searchURL(text), inNewTab: newTab)
        case .tab(let tab): store.select(tab.id)
        case .history(let entry): store.open(entry.url, inNewTab: newTab)
        }
        dismiss()
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
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(selected ? theme.accent : .clear))
    }

    @ViewBuilder private var icon: some View {
        switch item {
        case .navigate: Image(systemName: "globe")
        case .search: Image(systemName: "magnifyingglass")
        case .tab(let tab): Favicon(tab: tab, size: 16)
        case .history(let entry): Favicon(tab: BrowserTab(url: entry.url), size: 16)
        }
    }

    private var title: String {
        switch item {
        case .navigate(let url): url.absoluteString
        case .search(let text): text
        case .tab(let tab): tab.displayTitle
        case .history(let entry): entry.title.isEmpty ? entry.url.absoluteString : entry.title
        }
    }

    private var subtitle: String? {
        switch item {
        case .navigate, .search: nil
        case .tab(let tab): tab.url?.host()?.strippingWWW
        case .history(let entry): entry.url.host()?.strippingWWW
        }
    }

    private var badge: String? {
        switch item {
        case .navigate: "Open"
        case .search: "Search Google"
        case .tab: "Switch to Tab"
        case .history: "History"
        }
    }
}
