import AppKit
import SwiftUI

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
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var keyMonitor: Any?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate()
        // ⌘W closes the tab, not the window. A local monitor sees the key before the menu's window Close does.
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            guard flags == .command, event.charactersIgnoringModifiers == "w" else { return event }
            MainActor.assumeIsolated { BrowserStore.shared.closeActiveTab() }
            return nil
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        MainActor.assumeIsolated { BrowserStore.shared.saveNow() }
    }
}
