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

### Stage 2: Sidebar depth ✅
- Folders and nested folders in pinned (⌥⌘N, "Add to New Folder", ungroup, delete);
  drop onto a folder to file a tab; collapsed folders still show the active tab
- Inline rename for tabs and folders
- Auto-archive Today tabs (12h / 24h / 7d / 30d / never, default 12h, checked every
  minute and at launch) and the Archive sheet with search, day grouping and restore
- Hidden sidebar slides in when the pointer reaches the left edge; resizable sidebar width
- Downloads (WKDownload) into ~/Downloads with a progress ring, popover (⇧⌘J),
  open/reveal/cancel; tabs opened only to download a file close themselves

### Stage 2.5: Sidebar polish ✅
- Multi-select: ⌘-click toggles (the current tab joins the first time), ⇧-click selects a
  range; the selection can be closed, pinned/unpinned, filed into a new folder, opened in
  Split View, moved to another space or dragged as one
- Drag tabs onto a space icon to move them there; hold them over it to switch to that
  space and drop them anywhere in its sidebar
- Two-finger horizontal swipe over the sidebar moves between spaces (the sidebar follows
  the fingers and slides in the direction of travel); horizontal mouse wheels step one space

### Stage 3: Arc signature features ✅
- **Find in page** (⌘F, ⌘G, ⇧⌘G): match count, wrap-around, highlight cleared on close
- **Split View** (⌃⇧=): up to four panes, draggable dividers, click a pane to focus it,
  rotate, close pane, separate; saved across launches
- **Peek**: links that leave a pinned tab's or favorite's site (and ⇧-clicked links) open
  in an overlay; "Open as Tab" keeps them
- **Picture-in-Picture**: leaving a playing video pops it out. WKWebView doesn't expose
  native PiP to third-party apps, so Arcky's floating mini player (the tab's own web view
  with the video stretched to fill it) takes over; ⌃⌘P tries native PiP
- **Little Arc** (⌥⌘N): links from other apps open in a small window (Arcky registers
  for http/https; "Make Default" in Settings); "Open in Arcky" moves the page to Today
- Not yet: print, view source, sidebar media controls

### Stage 4: Personalisation ✅
- **Space themes** (Spaces ▸ Edit Theme…, or a space's right-click menu): presets, up to
  three gradient colours, intensity, film grain, and Auto/Light/Dark per space
- **Boosts** (⌥⌘B or the bolt in the address pill): per-site CSS, JavaScript, page font and
  zapped elements. CSS goes in a constructed stylesheet and JS is inlined in a user script,
  so sites' Content Security Policies don't block them. The zap tool runs in Arcky's own
  script world and refuses to hide the whole page
- **Profiles** (Settings ▸ Profiles; Spaces ▸ Profile): each has its own
  `WKWebsiteDataStore` (cookies, logins, storage) and its own favorites; spaces belong to
  one profile. Deleting a profile erases its website data
- Not yet: per-profile history and downloads, custom search engines, shortcut editor

### Stage 5: Power features (in progress)
Done:
- **Content blocking**: a built-in WebKit content rule list (≈170 ad, tracker and analytics
  domains blocked as third-party loads, plus common ad containers hidden). Toggle in
  Settings; allow a site with the shield in the address bar or the Tabs menu
- **Import** (File ▸ Import…): Arc spaces with pinned folders, Today tabs, per-profile
  favorites, emoji and space colour; Chrome/Brave/Edge/Vivaldi/Chromium bookmarks; Safari
  bookmarks (needs Full Disk Access); any exported bookmarks HTML file
- **AppleScript**: Arc's dictionary (same terms and codes): windows, tabs, spaces;
  `make new tab`, `select`, `close`, `reload`, `go back`/`go forward`, `stop`,
  `execute … javascript`, `focus` (space). Arc scripts work after renaming the app

- **Notes** (⌃⇧N, or right-click New Tab): rich text with headings, bold/italic/strike,
  bullets and checklists; Markdown shortcuts (`# `, `- `, `[] `), list continuation,
  click-to-tick boxes; links open in Arcky
- **Easels** (⌃⇧E): a canvas with select/move/resize, text, pen, rectangles, ellipses,
  colours, images (file or paste) and Captures of open tabs that link back to their page
- Notes and Easels are sidebar items like tabs (`arcky://note/…`, `arcky://easel/…`), so
  pinning, folders, Split View, multi-select and the Archive all work on them

- **Live folders** (File ▸ New Live Folder…): pinned folders filled from an RSS/Atom feed
  ("Use This Page's Feed" finds the current site's), a public repo's open pull requests,
  or, with a GitHub token in Settings (kept in the Keychain), your PRs and review requests.
  Refresh on launch, every 15 minutes and on demand; new items get an unread dot and the
  folder a count; tabs already open keep their page across refreshes
- **Hover cards**: resting on a sidebar tab shows a thumbnail of the page as you left it,
  its title, address and when you last viewed it (Settings can turn them off)

- **Instant Links**: ⇧↩ on a search in the command bar (or its "Go to the top result" row)
  opens the top DuckDuckGo result directly; "top 5 …" / "3 …" opens that many results as
  tabs. Arc used an AI service for this; Arcky reads search results, no account needed

- **Sync between Macs** (Settings ▸ Sync): through iCloud Drive (default) or any shared
  folder. Each Mac writes only its own snapshot; others merge what changed since they last
  looked (adds, edits, deletes), with unpublished local edits winning. Spaces, pinned
  items, favorites, profiles, Boosts, Notes and Easels sync; Today tabs stay per-Mac;
  live folders sync their source. CloudKit would need a signed app with an iCloud
  entitlement, so a folder is used instead

- **Per-profile history, Archive and downloads**: visits, archived tabs and downloads are
  tagged with the profile they happened in; the command bar, History window (⌘Y, new),
  Archive and downloads popover show the active space's profile. Clearing is per profile;
  deleting a profile removes its history, Archive and download list

Next:
- Subscribing to EasyList-style filter lists

## Using Ghidra for deeper research

Ghidra is installed (`brew install ghidra`). Headless analysis of the Arc binary is
slow, so we run it per feature when strings and symbols aren't enough, e.g.:

```bash
analyzeHeadless re/ghidra ArcProject -import /Applications/Arc.app/Contents/MacOS/Arc -processor AARCH64:LE:64:AppleSilicon
```
