# Arcky roadmap

Arcky is a from-scratch, native macOS browser modelled on Arc. Nothing from Arc's
bundle (code, icons, sounds, fonts, strings) is copied. Arc is only inspected to
learn which features exist and how they behave.

## How Arc is built (from inspecting Arc 1.169.0)

- **Language/UI:** Swift, SwiftUI + AppKit. State uses The Composable Architecture:
  binary symbols include `SidebarFeature`, `CommandBarViewReducer`, `ArchiveFeature`,
  `WindowReducer` and dozens more `*Feature`/`*Reducer` types.
- **Engine:** Chromium, embedded as the private `ArcCore.framework`. That is why Arc
  supports Chrome extensions.
- **Modules:** each feature ships as a resource bundle in `Contents/Resources`
  (`ARC_CommandBar`, `ARC_LittleBrowser`, `ARC_BoostsEditor`, `ARC_EaselUI`,
  `ARC_SpaceStyleEditor`, `ARC_PictureInPicture`, `ARC_SiteControlCenter`, …).
- **Data model:** spaces → `pinned` / `unpinned` (Today) containers of `SidebarItem`s;
  `topApps` holds the Favorites. Stored in `StorableSidebar.json` and synced with
  CloudKit/Firestore.
- **Scripting:** `Arc.sdef` exposes window → tab / space, with `active tab`,
  `active space`, `execute` (JS) and `go back`/`go forward`/`reload`/`stop`.

### Engine choice

Arcky uses **WKWebView** (WebKit). Compared with embedding Chromium it gives a much
smaller app, lower memory and power use, and native integration. The trade-off:
Chrome extensions won't run. Safari Web Extensions are possible later. If Chrome
extension support becomes a must-have, the `WebViewPool` boundary is where a CEF
backend would plug in.

## Stages

### Stage 1: Core shell ✅
- Arc-style window: hidden titlebar, sidebar with traffic lights, rounded web card
- Sidebar: favorites grid, space header, pinned section, Today tabs, "New Tab", "Clear"
- Command bar (⌘T new tab, ⌘L edit URL): URL/search resolution, switch-to-tab, history
- Tabs: lazy loading, close (⌘W), reopen (⇧⌘T), pin (⌘D), favorites, duplicate,
  drag-reorder between sections, ⌘1–9, ⌥⌘↑/↓, ⌃Tab
- Pinned tabs reset to their pinned URL when closed, as in Arc
- Spaces: create, switch (⌃1–9, ⌥⌘←/→), rename, icon, colour, delete, per-space selection
- Navigation: back/forward/reload/stop, ⌘-click background tabs, popups as tabs, zoom
- Copy URL (⇧⌘C), JS alert/confirm, file upload, persistence of the whole sidebar

### Stage 2: Sidebar depth
- Folders and nested folders in pinned; "New Folder from Selection"
- Rename tabs (double-click), multi-select (⌘/⇧-click), drag between spaces
- Auto-archive Today tabs (12h / 24h / 7d / 30d / never) and the Archive page
- Show the sidebar on hover at the left edge when hidden; resizable sidebar width
- Two-finger swipe between spaces; sidebar on the right option
- Downloads (WKDownload) with a downloads popover

### Stage 3: Arc signature features
- **Little Arc**: small floating windows for links opened from other apps; default browser
- **Split View**: two to four panes, horizontal/vertical (⌃⇧+)
- **Peek**: preview pinned-tab links in an overlay instead of navigating
- **Picture-in-Picture** and media controls in the sidebar
- Find in page (⌘F), print, view source, web inspector toggle

### Stage 4: Personalisation
- Space themes: gradient editor, noise/grain, light/dark per space
- **Boosts**: per-site CSS/JS injection with a zap (hide elements) picker
- Profiles: separate `WKWebsiteDataStore` per profile, bound to spaces
- Settings window, custom search engines, shortcut editor

### Stage 5: Power features
- **Easels and Notes** (canvas and rich-text documents in the sidebar)
- Live folders (GitHub PRs, RSS), hover cards, "Instant Links"
- Import from Chrome/Safari/Arc, sync (CloudKit), AppleScript (`.sdef` parity)
- Content blocking (WKContentRuleList), site control centre (permissions)

## Using Ghidra for deeper research

Ghidra is installed (`brew install ghidra`). Headless analysis of the Arc binary is
slow, so we run it per feature when strings and symbols aren't enough, e.g.:

```bash
analyzeHeadless re/ghidra ArcProject -import /Applications/Arc.app/Contents/MacOS/Arc -processor AARCH64:LE:64:AppleSilicon
```
