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
