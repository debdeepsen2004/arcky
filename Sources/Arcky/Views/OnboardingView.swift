import AppKit
import SwiftUI

/// The first-run guide: import, a colour for your first space, the key shortcuts, and a few
/// optional settings. Shown once (Help ▸ Welcome to Arcky brings it back).
struct OnboardingView: View {
    @Environment(BrowserStore.self) private var store
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.dismiss) private var dismiss

    enum Step: Int, CaseIterable {
        case welcome, importing, style, basics, finish
    }

    @State private var step = Step.welcome
    @State private var importMessage: String?
    @State private var addEasyList = true
    @State private var isDefaultBrowser = false

    static let completedKey = "onboardingCompleted"

    var body: some View {
        let theme = SpaceTheme(space: store.activeSpace, systemDark: colorScheme == .dark)
        VStack(spacing: 0) {
            ZStack {
                switch step {
                case .welcome: welcome
                case .importing: importing
                case .style: style
                case .basics: basics
                case .finish: finish
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(.horizontal, 44)
            .padding(.top, 36)
            .transition(.asymmetric(insertion: .move(edge: .trailing).combined(with: .opacity), removal: .opacity))
            .id(step)

            HStack {
                HStack(spacing: 6) {
                    ForEach(Step.allCases, id: \.self) { item in
                        Capsule()
                            .fill(item == step ? theme.accent : Color.secondary.opacity(0.3))
                            .frame(width: item == step ? 18 : 7, height: 7)
                    }
                }
                Spacer()
                if step != .welcome {
                    Button("Back") { move(-1) }
                }
                if step == .finish {
                    Button("Start Browsing") { complete() }
                        .keyboardShortcut(.defaultAction)
                        .glassButtonStyle(prominent: true)
                } else {
                    Button(step == .welcome ? "Get Started" : "Continue") { move(1) }
                        .keyboardShortcut(.defaultAction)
                        .glassButtonStyle(prominent: true)
                }
            }
            .padding(20)
            .animation(.spring(duration: 0.3), value: step)
        }
        .frame(width: 640, height: 520)
        .background(theme.background.opacity(0.18))
        .background(Color(nsColor: .windowBackgroundColor))
        .tint(theme.accent)
        .interactiveDismissDisabled()
    }

    private func move(_ delta: Int) {
        withAnimation(.spring(duration: 0.35)) {
            step = Step(rawValue: step.rawValue + delta) ?? step
        }
    }

    private func complete() {
        if addEasyList, let url = URL(string: FilterListManager.presets[0].url) {
            FilterListManager.shared.subscribe(name: FilterListManager.presets[0].name, url: url)
        }
        UserDefaults.standard.set(true, forKey: Self.completedKey)
        dismiss()
    }

    // MARK: Steps

    private var welcome: some View {
        VStack(spacing: 18) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 120, height: 120)
            Text("Welcome to Arcky").font(.system(size: 34, weight: .bold))
            Text("A calm, fast browser for the Mac, with a sidebar of spaces, pinned tabs that stay put, and Today tabs that tidy themselves away.")
                .font(.title3)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .frame(maxWidth: 460)
            Label("This is a test build. Thanks for trying it!", systemImage: "hand.wave")
                .font(.callout)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(Capsule().fill(.quaternary))
        }
    }

    private var importing: some View {
        VStack(alignment: .leading, spacing: 14) {
            header("Bring your stuff", "Import spaces and tabs from Arc, or bookmarks from another browser. You can skip this and do it later from File ▸ Import.")
            let sources = BrowserImporter.availableSources().filter { if case .safari = $0 { return false } else { return true } }
            if sources.isEmpty {
                Text("No other browsers found on this Mac.").foregroundStyle(.secondary)
            }
            ForEach(sources) { source in
                HStack {
                    Image(systemName: icon(for: source)).frame(width: 24)
                    Text(name(for: source)).font(.body.weight(.medium))
                    Spacer()
                    Button("Import") { run(source) }
                }
                .padding(12)
                .background(RoundedRectangle(cornerRadius: 10).fill(.quaternary.opacity(0.6)))
            }
            Button("Import a Bookmarks File…") { pickFile() }
                .buttonStyle(.link)
            if let importMessage {
                Label(importMessage, systemImage: "checkmark.circle").foregroundStyle(.green)
            }
            Spacer()
        }
    }

    private var style: some View {
        VStack(alignment: .leading, spacing: 16) {
            header("Make it yours", "Every space has its own colour and icon. Pick some for your first space; you can change them any time from the space's right-click menu.")
            let space = store.activeSpace
            HStack(spacing: 16) {
                SpaceTheme(space: space, systemDark: colorScheme == .dark).background
                    .frame(width: 180, height: 120)
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .overlay(Text(space.emoji).font(.system(size: 44)))
                VStack(alignment: .leading, spacing: 12) {
                    Text("Colour").font(.headline)
                    HStack(spacing: 10) {
                        ForEach([0.60, 0.75, 0.95, 0.01, 0.08, 0.15, 0.38, 0.50], id: \.self) { hue in
                            Button { store.updateSpace(space.id) { $0.hue = hue; $0.style = nil } } label: {
                                Circle()
                                    .fill(Color(hue: hue, saturation: 0.6, brightness: 0.9))
                                    .frame(width: 24, height: 24)
                                    .overlay(Circle().strokeBorder(.primary.opacity(abs(space.hue - hue) < 0.001 && space.style == nil ? 0.8 : 0), lineWidth: 2).padding(-3))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    Text("Icon").font(.headline)
                    HStack(spacing: 8) {
                        ForEach(["🏠", "💼", "🎨", "📚", "🚀", "🌿", "🎧", "💡"], id: \.self) { emoji in
                            Button { store.updateSpace(space.id) { $0.emoji = emoji } } label: {
                                Text(emoji).font(.title2)
                                    .padding(4)
                                    .background(RoundedRectangle(cornerRadius: 8).fill(space.emoji == emoji ? Color.secondary.opacity(0.25) : .clear))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
            Spacer()
        }
    }

    private var basics: some View {
        VStack(alignment: .leading, spacing: 14) {
            header("The basics", "A few shortcuts go a long way.")
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)], spacing: 12) {
                tip("⌘T", "New tab", "Type a site or a search. ⇧↩ jumps straight to the top result.")
                tip("⌘S", "Hide the sidebar", "Move to the left edge to peek at it.")
                tip("⌘D", "Pin a tab", "Pinned tabs stay; Today tabs archive after 12 hours.")
                tip("⌥⌘→", "Next space", "Or swipe sideways with two fingers on the sidebar.")
                tip("⌃⇧=", "Split View", "Up to four tabs side by side.")
                tip("⌘Y", "History", "Each profile keeps its own.")
            }
            Spacer()
        }
    }

    private var finish: some View {
        VStack(alignment: .leading, spacing: 16) {
            header("You're set", "A couple of optional extras:")
            Toggle(isOn: $addEasyList) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Block more ads with EasyList")
                    Text("Arcky blocks common trackers already; EasyList adds about 80,000 more rules.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Make Arcky your default browser")
                    Text("Links from other apps then open in Little Arc windows.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if isDefaultBrowser {
                    Label("Done", systemImage: "checkmark").foregroundStyle(.green)
                } else {
                    Button("Make Default") {
                        Task {
                            try? await NSWorkspace.shared.setDefaultApplication(at: Bundle.main.bundleURL, toOpenURLsWithScheme: "http")
                            isDefaultBrowser = NSWorkspace.shared.urlForApplication(toOpen: URL(string: "https://example.com")!)
                                .flatMap { Bundle(url: $0)?.bundleIdentifier } == Bundle.main.bundleIdentifier
                        }
                    }
                }
            }
            Label("Found a bug or have an idea? Tell whoever sent you Arcky. Every bit of feedback helps.", systemImage: "ladybug")
                .font(.callout)
                .foregroundStyle(.secondary)
                .padding(.top, 6)
            Spacer()
        }
    }

    // MARK: Pieces

    private func header(_ title: String, _ subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.system(size: 26, weight: .bold))
            Text(subtitle).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .padding(.bottom, 6)
    }

    private func tip(_ keys: String, _ title: String, _ detail: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text(keys)
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(RoundedRectangle(cornerRadius: 6).fill(.quaternary))
                .frame(minWidth: 52)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.body.weight(.medium))
                Text(detail).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .frame(maxWidth: .infinity, minHeight: 74, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 10).fill(.quaternary.opacity(0.5)))
    }

    private func run(_ source: BrowserImporter.Source) {
        do {
            let result = try BrowserImporter.load(source)
            store.applyImport(result, from: name(for: source))
            importMessage = "Imported \(result.spaces.count) spaces and \(result.tabCount) tabs from \(name(for: source))."
        } catch {
            importMessage = error.localizedDescription
        }
    }

    private func pickFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.html]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        run(.bookmarksHTML(url))
    }

    private func name(for source: BrowserImporter.Source) -> String {
        switch source {
        case .arc: "Arc"
        case .chromium(let name, _): name
        case .safari: "Safari"
        case .bookmarksHTML(let url): url.lastPathComponent
        }
    }

    private func icon(for source: BrowserImporter.Source) -> String {
        switch source {
        case .arc: "sparkles"
        case .chromium: "globe"
        case .safari: "safari"
        case .bookmarksHTML: "doc.text"
        }
    }
}
