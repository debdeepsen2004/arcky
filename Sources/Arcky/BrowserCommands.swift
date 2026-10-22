import AppKit
import SwiftUI
import WebKit

/// Menu bar commands, using Arc's keyboard shortcuts.
struct BrowserCommands: Commands {
    let store: BrowserStore

    private var activeWebView: WKWebViewProxy { WKWebViewProxy(store: store) }

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("New Tab") { store.openCommandBar(.newTab) }
                .keyboardShortcut("t")
            Button("New Little Arc Window") { store.openLittleArc(nil) }
                .keyboardShortcut("n", modifiers: [.command, .option])
            Button("New Space") { store.createSpace() }
            Button("New Folder") { store.newFolder() }
                .keyboardShortcut("n", modifiers: [.command, .control])
            Divider()
            Button("Reopen Closed Tab") { store.reopenClosedTab() }
                .keyboardShortcut("t", modifiers: [.command, .shift])
            Button("Close Tab") { store.closeActiveTab() }
                .keyboardShortcut("w")
        }

        CommandGroup(after: .pasteboard) {
            Divider()
            Button("Copy URL") { copyActiveURL() }
                .keyboardShortcut("c", modifiers: [.command, .shift])
        }

        CommandGroup(replacing: .textEditing) {
            Button("Find in Page…") { store.showFindBar() }
                .keyboardShortcut("f")
            Button("Find Next") { store.find() }
                .keyboardShortcut("g")
                .disabled(store.findQuery.isEmpty)
            Button("Find Previous") { store.find(backwards: true) }
                .keyboardShortcut("g", modifiers: [.command, .shift])
                .disabled(store.findQuery.isEmpty)
        }

        CommandGroup(replacing: .sidebar) {
            Button(store.sidebarVisible ? "Hide Sidebar" : "Show Sidebar") { store.toggleSidebar() }
                .keyboardShortcut("s")
            Divider()
            Button("Actual Size") { activeWebView.setZoom(1) }
                .keyboardShortcut("0")
            Button("Zoom In") { activeWebView.zoom(by: 0.1) }
                .keyboardShortcut("=")
            Button("Zoom Out") { activeWebView.zoom(by: -0.1) }
                .keyboardShortcut("-")
            Divider()
            Button("Picture in Picture") {
                if let id = store.activeTabID { store.pool.startPictureInPicture(tabID: id, fallbackToMiniPlayer: false) }
            }
            .keyboardShortcut("p", modifiers: [.command, .control])
        }

        CommandMenu("Navigate") {
            Button("Open Location") { store.openCommandBar(.editCurrent) }
                .keyboardShortcut("l")
            Button("Reload Page") { activeWebView.webView?.reload() }
                .keyboardShortcut("r")
            Button("Back") { activeWebView.webView?.goBack() }
                .keyboardShortcut("[")
            Button("Forward") { activeWebView.webView?.goForward() }
                .keyboardShortcut("]")
        }

        CommandMenu("Tabs") {
            Button("Pin / Unpin Tab") { store.activeTabID.map(store.togglePin) }
                .keyboardShortcut("d")
            Button("Add / Remove Favorite") { store.activeTabID.map(store.toggleFavorite) }
            Button("Duplicate Tab") { store.activeTabID.map(store.duplicate) }
            Divider()
            Button("Add Split View") { store.openCommandBar(.splitPane) }
                .keyboardShortcut("=", modifiers: [.control, .shift])
                .disabled(store.activeTabID == nil)
            Button("Close Split View Pane") { store.activeTabID.map(store.removeFromSplit) }
                .disabled(store.split(containing: store.activeTabID) == nil)
            Button("Rotate Split View") { store.rotateSplit(containing: store.activeTabID) }
                .disabled(store.split(containing: store.activeTabID) == nil)
            Button("Separate Split View") { store.separateSplit(containing: store.activeTabID) }
                .disabled(store.split(containing: store.activeTabID) == nil)
            Divider()
            Button("Boost This Site…") { store.editBoostForActiveSite() }
                .keyboardShortcut("b", modifiers: [.command, .option])
                .disabled(store.activeHost == nil)
            Button("Zap Elements") { store.startZapping() }
                .disabled(store.activeHost == nil)
            Divider()
            Button("Rename Tab") { store.renamingID = store.activeTabID }
            Button("Clear Today Tabs") { store.clearToday() }
            Divider()
            Button("Show Archive") { store.showingArchive = true }
            Button("Show Downloads") { store.showDownloads() }
                .keyboardShortcut("j", modifiers: [.command, .shift])
            Divider()
            Button("Next Tab") { store.cycleTab(by: 1) }
                .keyboardShortcut(.downArrow, modifiers: [.command, .option])
            Button("Previous Tab") { store.cycleTab(by: -1) }
                .keyboardShortcut(.upArrow, modifiers: [.command, .option])
            Button("Next Tab ") { store.cycleTab(by: 1) }
                .keyboardShortcut(.tab, modifiers: .control)
            Button("Previous Tab ") { store.cycleTab(by: -1) }
                .keyboardShortcut(.tab, modifiers: [.control, .shift])
            Divider()
            ForEach(1...9, id: \.self) { n in
                Button(n == 9 ? "Last Tab" : "Tab \(n)") { store.selectTab(atPosition: n) }
                    .keyboardShortcut(KeyEquivalent(Character("\(n)")))
            }
        }

        CommandMenu("Spaces") {
            Button("Next Space") { store.cycleSpace(by: 1) }
                .keyboardShortcut(.rightArrow, modifiers: [.command, .option])
            Button("Previous Space") { store.cycleSpace(by: -1) }
                .keyboardShortcut(.leftArrow, modifiers: [.command, .option])
            Button("Edit Theme…") { store.editTheme(of: store.activeSpaceID) }
            Menu("Profile") {
                ForEach(store.profiles) { profile in
                    Toggle("\(profile.emoji) \(profile.name)", isOn: Binding(
                        get: { store.activeProfileID == profile.id },
                        set: { if $0 { store.setProfile(profile.id, forSpace: store.activeSpaceID) } }
                    ))
                }
            }
            Divider()
            ForEach(Array(store.spaces.enumerated()), id: \.element.id) { index, space in
                let button = Button("\(space.emoji) \(space.name)") { store.switchToSpace(space.id) }
                if index < 9 {
                    button.keyboardShortcut(KeyEquivalent(Character("\(index + 1)")), modifiers: .control)
                } else {
                    button
                }
            }
        }
    }

    private func copyActiveURL() {
        guard let url = store.activeTab?.url else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(url.absoluteString, forType: .string)
    }
}

/// Small helper for commands that act on the active tab's web view.
@MainActor
struct WKWebViewProxy {
    let store: BrowserStore

    var webView: WKWebView? { store.pool.existingWebView(for: store.activeTabID) }

    func setZoom(_ zoom: CGFloat) { webView?.pageZoom = zoom }

    func zoom(by delta: CGFloat) {
        guard let webView else { return }
        webView.pageZoom = min(3, max(0.3, webView.pageZoom + delta))
    }
}
