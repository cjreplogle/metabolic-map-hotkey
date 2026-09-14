# Metabolic Map — macOS menu-bar app v1.5

A tiny native AppKit/SwiftUI/PDFKit viewer/search tool for a local copy of the Stanford Pathways of Human Metabolism PDF.

## Important: the PDF is NOT included

This project does **not** bundle or redistribute the Stanford metabolic-map PDF. On first launch, the app asks you to select the copy that is already on your Mac and stores a security-scoped bookmark to it.

## What changed in v1.4

- Added a simple map + stethoscope app icon (`Resources/AppIcon.svg`).
- Added PNG artwork used to create the native macOS `.icns` at build time.
- The icon is applied to the application and added to each app window's title bar.
- Windows pop over another app's macOS full-screen Space (`fullScreenAuxiliary` + `canJoinAllSpaces`), then drop back to a normal window level so they are not permanently pinned on top.
- Global shortcuts are now the modifier chords **⌥⌘M** (open map) and **⌥⌘S** (search) instead of the old Tab-prefix sequence, which could fire during ordinary typing.
- Search results now show the surrounding text of each hit and jump the map to that page, highlighting every occurrence when clicked.
- Keeps the external-PDF design; no PDF is redistributed.

## Build

If macOS reports `zsh: permission denied: ./build.sh`, run `chmod +x build.sh` once, then run `./build.sh`. The v1.5 ZIP already preserves the executable bit.

Requires macOS + Xcode Command Line Tools.

```bash
cd ~/Desktop/MetabolicMap/MetabolicMap
./build.sh
```

Then launch `MetabolicMap.app`.

## Global shortcuts

- **⌥⌘M** (Option-Command-M) — open the metabolic map
- **⌥⌘S** (Option-Command-S) — open search

These are simultaneous modifier chords. The app consumes the chord when it fires, so it does not beep or fall through to the foreground app.

For global key listening, macOS may require you to grant the app permission under:

**System Settings → Privacy & Security → Accessibility**

## Full-screen behavior

The viewer windows use macOS's `fullScreenAuxiliary` and `canJoinAllSpaces` window behaviors and a floating level. This is specifically intended to let the map/search window appear above a separate app that is occupying a full-screen Space when the shortcut is triggered.

As with any macOS full-screen/Space behavior, individual apps can impose their own window-management restrictions, but this build is configured for the normal macOS full-screen case.

## Shortcuts (v1.5)
The old sequential Tab-prefix listener has been replaced with plain **⌥⌘M** / **⌥⌘S** modifier chords. Because these require Option+Command, they no longer fire accidentally during ordinary typing, and there is no partial-sequence state to reset.

## First-run setup fix (v1.4)
On a machine where no PDF bookmark exists yet, the app explicitly switches to a regular activation policy, activates itself, and orders the setup window to the front. The setup window is also dismissed after a PDF is successfully selected.
