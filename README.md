# Arcky

A native macOS browser in the spirit of Arc, built with Swift, SwiftUI and WKWebView.

## Build and run

Requires macOS 15+ and Xcode 16+ (Swift 6 toolchain).

```bash
scripts/build-app.sh          # debug build → build/Arcky.app
scripts/build-app.sh release  # optimised build
open build/Arcky.app
```

State is saved to `~/Library/Application Support/Arcky/state.json`.

## Sharing a build

```bash
scripts/package.sh
```

Builds a universal (Apple Silicon + Intel) release and writes `dist/Arcky-<version>.dmg`
(drag-to-Applications, with install notes), a fixed-name `dist/Arcky.dmg` for "latest
release" links, and a zip. The app is signed ad hoc (no Developer ID), so on first launch
testers approve it once in System Settings ▸ Privacy & Security ▸ Open Anyway.
`docs/index.html` is the download page (for GitHub Pages).

The icon is drawn by `swift scripts/make-icon.swift`.

## Layout

- `Sources/Arcky/BrowserStore.swift`: all sidebar state and actions (spaces, tabs, history)
- `Sources/Arcky/WebViewPool.swift`: one lazily created `WKWebView` per loaded tab
- `Sources/Arcky/Views/`: sidebar, tab rows, command bar, space switcher, web content
- `docs/ROADMAP.md`: what Arc does, how it's built, and the stage plan

## Shortcuts

| Action | Keys |
| --- | --- |
| New tab / command bar | ⌘T |
| Instant Link (top result) | ⇧↩ in the command bar |
| Edit URL | ⌘L |
| Close tab / reopen | ⌘W / ⇧⌘T |
| Pin / unpin | ⌘D |
| Toggle sidebar | ⌘S |
| New folder | ⌃⌘N |
| Little Arc window | ⌥⌘N |
| Find in page | ⌘F, ⌘G / ⇧⌘G |
| Add Split View | ⌃⇧= |
| Picture in Picture | ⌃⌘P |
| Boost this site | ⌥⌘B |
| New Note / Easel | ⌃⇧N / ⌃⇧E |
| Downloads | ⇧⌘J |
| History | ⌘Y |
| Copy URL | ⇧⌘C |
| Next / previous tab | ⌥⌘↓ / ⌥⌘↑, ⌃Tab |
| Next / previous space | ⌥⌘→ / ⌥⌘← |
| Go to tab / space | ⌘1–9 / ⌃1–9 |

## AppleScript

Arcky speaks Arc's AppleScript dictionary:

```applescript
tell application "Arcky"
    tell front window
        make new tab with properties {URL:"https://example.com"}
        execute active tab javascript "document.title"
    end tell
end tell
```
