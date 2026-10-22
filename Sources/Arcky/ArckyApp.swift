import AppKit
import SwiftUI
import WebKit

@main
struct ArckyApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var store = BrowserStore.shared

    var body: some Scene {
        Window("Arcky", id: "main") {
            RootView()
                .environment(store)
                .frame(minWidth: 720, minHeight: 460)
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1360, height: 860)
        .commands { BrowserCommands(store: store) }

        Settings {
            SettingsView().environment(store)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var monitors: [Any] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate()

        // Local monitors run on the main thread, so handing the event to main-actor code is safe.
        monitors.append(NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            nonisolated(unsafe) let event = event
            let handled = MainActor.assumeIsolated { Self.handleKeyDown(event) }
            return handled ? nil : event
        } as Any)
        monitors.append(NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { event in
            nonisolated(unsafe) let event = event
            let swiped = MainActor.assumeIsolated { SpaceSwipeTracker.shared.handle(event) }
            return swiped ? nil : event
        } as Any)
        monitors.append(NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { event in
            nonisolated(unsafe) let event = event
            MainActor.assumeIsolated { Self.focusSplitPane(for: event) }
            return event
        } as Any)
    }

    /// Links opened from other apps (with Arcky as the default browser) go to Little Arc.
    func application(_ application: NSApplication, open urls: [URL]) {
        MainActor.assumeIsolated {
            for url in urls where ["http", "https", "file"].contains(url.scheme?.lowercased() ?? "") {
                BrowserStore.shared.openLittleArc(url)
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        MainActor.assumeIsolated {
            BrowserStore.shared.saveNow()
            DocumentStore.shared.saveNow()
        }
    }

    /// Key handling that must beat the menus and the web page. Returns true when the key was used.
    @MainActor
    private static func handleKeyDown(_ event: NSEvent) -> Bool {
        let store = BrowserStore.shared
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        // ⌘W closes the tab, not the window. A local monitor sees the key before the menu's window Close does.
        if flags == .command, event.charactersIgnoringModifiers == "w", event.window === store.mainWindow {
            if store.peekTabID != nil {
                store.closePeek()
            } else {
                store.closeActiveTab()
            }
            return true
        }
        // Esc dismisses Peek, unless the command bar or find bar has it.
        if event.keyCode == 53, store.peekTabID != nil, store.commandBar == nil, !store.findBarVisible {
            store.closePeek()
            return true
        }
        return false
    }

    /// Clicking into a split pane makes that pane's tab the active one.
    @MainActor
    private static func focusSplitPane(for event: NSEvent) {
        let store = BrowserStore.shared
        guard let window = event.window, window === store.mainWindow,
              let split = store.split(containing: store.activeTabID),
              var view = window.contentView?.hitTest(event.locationInWindow) else { return }
        while !(view is WKWebView) {
            guard let parent = view.superview else { return }
            view = parent
        }
        guard let webView = view as? WKWebView, let id = store.pool.tabID(of: webView),
              id != store.activeTabID, split.tabIDs.contains(id) else { return }
        store.select(id)
    }
}
