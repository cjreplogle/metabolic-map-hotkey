## Quick-access metabolic pathway viewer for macOS.

A tiny native AppKit/SwiftUI/PDFKit viewer for a local copy of the Stanford
Pathways of Human Metabolism PDF. It lives in the menu bar, pops the map
open (or over any full-screen app) with a global hotkey, and adds fast find,
zoom, pan, and a cursor "peek-through" so you can glance at what's behind it.

> [!NOTE]
> The PDF is NOT included. Please download from [here](https://mededucation.stanford.edu/pathways-download/).
> On first launch the app asks you to pick your local copy and remembers it; the
> tray menu also has a **Stanford Pathways Map** shortcut to the download page.

### Download (no build required)

Grab the prebuilt app from the
[latest release](https://github.com/cjreplogle/metabolic-map-hotkey/releases/latest):

1. Download `MetabolicMap.zip`, unzip, and move `MetabolicMap.app` to Applications.
2. First launch: right-click the app → **Open** (it's signed with a personal
   Apple Development certificate and isn't notarized, so Gatekeeper warns once).
3. Pick your local map PDF when prompted.
4. Grant Accessibility (below) so the global hotkeys work.

Requires macOS 14+.

### Permissions

The global shortcuts use a keyboard event tap, which macOS gates behind:

**System Settings → Privacy & Security → Accessibility**

Enable **MetabolicMap** there. The app polls for the permission, so it starts
working the moment you toggle it on — no relaunch needed.

### Shortcuts

Global (work from any app):

- **⌥⌘M** — show the map / bring it to front; hide it when it's already frontmost
- **⌥⌘S** — show the map and open the find bar
- **⌥⌘ + arrows** — pan the map

Inside the map window:

- **⌘F** — find in map (live search; Return / ↑ ↓ to step matches, Esc to close)
- **Ctrl +/−** — zoom in / out (smooth)
- **⌘ + arrows** — pan
- **⌘⇧ + arrows** — move the window around the screen

### Features

- Menu-bar app; the map opens over full-screen Spaces and can be pinned
  **Always on Top**.
- Cover-fit rendering that fills the window with no gray letterbox bars, with a
  low-resolution underlay so panning/zooming doesn't flash white.
- **Peek-through**: hover near the window and a soft circular hole lets you read
  whatever is behind it (toggle in the tray menu).
- Frameless rounded window, opens at a compact size in the top-right corner.

## Build from source

Requires macOS + Xcode Command Line Tools.

```bash
./build.sh
```

`build.sh` compiles `MetabolicMapApp.swift`, generates the app icon and
`Info.plist`, and code-signs with a stable identity (so the Accessibility grant
survives rebuilds). If macOS reports `zsh: permission denied: ./build.sh`, run
`chmod +x build.sh` once first. Then launch `MetabolicMap.app`.

## Note

This project does not bundle or redistribute the Stanford metabolic-map PDF; it
only views a copy you already have.
