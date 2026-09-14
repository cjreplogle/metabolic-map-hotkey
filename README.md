# A quick-access metabolism map viewer for macOS.

A tiny native AppKit/SwiftUI/PDFKit viewer/search tool for a local copy of the Stanford Pathways of Human Metabolism PDF.

## Important: the PDF is NOT included

This project does **not** bundle or redistribute the Stanford metabolic-map PDF. On first launch, the app asks you to select the copy that is already on your Mac and stores a its location.

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

As with any macOS full-screen/Space behavior, individual apps can impose their own window-management restrictions, but this build is configured for the normal macOS full-screen cases.
