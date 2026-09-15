import Cocoa
import SwiftUI
import PDFKit
import ServiceManagement

// MARK: - App icon

func loadAppIcon() -> NSImage? {
    guard let url = Bundle.main.url(forResource: "AppIcon", withExtension: "png") else {
        return nil
    }
    return NSImage(contentsOf: url)
}

func configureWindowAppearance(_ window: NSWindow) {
    if let icon = loadAppIcon() {
        let imageView = NSImageView(image: icon)
        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.translatesAutoresizingMaskIntoConstraints = false
        let accessory = NSTitlebarAccessoryViewController()
        accessory.view = NSView(frame: NSRect(x: 0, y: 0, width: 22, height: 22))
        accessory.view.addSubview(imageView)
        NSLayoutConstraint.activate([
            imageView.widthAnchor.constraint(equalToConstant: 18),
            imageView.heightAnchor.constraint(equalToConstant: 18),
            imageView.centerXAnchor.constraint(equalTo: accessory.view.centerXAnchor),
            imageView.centerYAnchor.constraint(equalTo: accessory.view.centerYAnchor)
        ])
        window.addTitlebarAccessoryViewController(accessory)
    }
}

extension Notification.Name {
    static let mmIconColoringChanged = Notification.Name("mmIconColoringChanged")
    static let mmIconModeChanged = Notification.Name("mmIconModeChanged")
    static let mmMapVisibilityChanged = Notification.Name("mmMapVisibilityChanged")
}

// Tray animation mode.
enum IconMode: Int, CaseIterable, Identifiable {
    case alwaysPlay = 0
    case playWhenOpen = 1
    case alwaysPause = 2
    var id: Int { rawValue }
    var label: String {
        switch self {
        case .alwaysPlay: return "Always"
        case .playWhenOpen: return "When Open"
        case .alwaysPause: return "Paused"
        }
    }
}

/// User-adjustable settings, persisted to UserDefaults and applied live.
final class AppSettings: ObservableObject {
    static let shared = AppSettings()
    private let defaults = UserDefaults.standard

    @Published var alwaysOnTop: Bool {
        didSet {
            defaults.set(alwaysOnTop, forKey: "alwaysOnTop")
            MapWindowController.shared.setAlwaysOnTop(alwaysOnTop)
        }
    }

    @Published var peekEnabled: Bool {
        didSet {
            defaults.set(peekEnabled, forKey: "peekEnabled")
            MapWindowController.shared.refreshPeek()
        }
    }

    // Registers/unregisters the app as a macOS login item (starts in the
    // background at login; the map only appears when the shortcut is pressed).
    @Published var launchAtLogin: Bool {
        didSet { updateLoginItem() }
    }

    private func updateLoginItem() {
        do {
            if launchAtLogin {
                if SMAppService.mainApp.status != .enabled { try SMAppService.mainApp.register() }
            } else {
                if SMAppService.mainApp.status == .enabled { try SMAppService.mainApp.unregister() }
            }
        } catch {
            print("Login item update failed: \(error)")
        }
    }

    @Published var peekRadius: Double {
        didSet { defaults.set(peekRadius, forKey: "peekRadius"); MapWindowController.shared.refreshPeek() }
    }
    // 0 = fully opaque map in the hole, 1 = fully transparent (see-through).
    @Published var peekTransparency: Double {
        didSet { defaults.set(peekTransparency, forKey: "peekTransparency"); MapWindowController.shared.refreshPeek() }
    }
    // Width (points) of the soft cross-fade band at the peek boundary.
    @Published var peekFade: Double {
        didSet { defaults.set(peekFade, forKey: "peekFade"); MapWindowController.shared.refreshPeek() }
    }
    @Published var invertPan: Bool {
        didSet { defaults.set(invertPan, forKey: "invertPan") }
    }
    // Click-through: the map ignores mouse events (clicks/scroll pass to the app
    // below) and hides its window buttons; adjust the view with keyboard shortcuts.
    @Published var clickThrough: Bool {
        didSet {
            defaults.set(clickThrough, forKey: "clickThrough")
            MapWindowController.shared.applyClickThrough()
        }
    }
    // Color the tray metabolite oxygens red (off = monochrome, adapts to menu bar).
    @Published var colorOxygen: Bool {
        didSet {
            defaults.set(colorOxygen, forKey: "colorOxygen")
            NotificationCenter.default.post(name: .mmIconColoringChanged, object: nil)
        }
    }
    @Published var fullCarboxylate: Bool {
        didSet {
            defaults.set(fullCarboxylate, forKey: "fullCarboxylate")
            NotificationCenter.default.post(name: .mmIconColoringChanged, object: nil)
        }
    }
    @Published var iconModeRaw: Int {
        didSet {
            defaults.set(iconModeRaw, forKey: "iconModeRaw")
            NotificationCenter.default.post(name: .mmIconModeChanged, object: nil)
        }
    }
    var iconMode: IconMode { IconMode(rawValue: iconModeRaw) ?? .alwaysPlay }
    // Slide the map window in/out from its corner (in addition to the fade).
    @Published var slideAnimation: Bool {
        didSet { defaults.set(slideAnimation, forKey: "slideAnimation") }
    }
    // Overall map-window transparency (0 = opaque, applied even when not peeking).
    @Published var baseTransparency: Double {
        didSet { defaults.set(baseTransparency, forKey: "baseTransparency"); MapWindowController.shared.applyBaseTransparency() }
    }
    // Tray metabolism-walk speed, 0…1 (log scale: 0 = 1 step / 6 s, 1 = 15 / s).
    @Published var metabolismSpeed: Double {
        didSet { defaults.set(metabolismSpeed, forKey: "metabolismSpeed") }
    }

    /// Per-step delay for the tray metabolite walk (log-interpolated).
    var metabolismDelay: TimeInterval {
        let minDelay = 1.0 / 15.0, maxDelay = 6.0
        let t = min(max(metabolismSpeed, 0), 1)
        return exp(log(maxDelay) + (log(minDelay) - log(maxDelay)) * t)
    }
    /// Steps per second, for display.
    var metabolismStepsPerSecond: Double { 1.0 / metabolismDelay }

    // Global shortcuts. Modifiers are stored as NSEvent.ModifierFlags raw values.
    @Published var mapKeyCode: Int {
        didSet { defaults.set(mapKeyCode, forKey: "mapKeyCode"); GlobalShortcutManager.shared.reload() }
    }
    @Published var mapModifiers: UInt {
        didSet { defaults.set(mapModifiers, forKey: "mapModifiers"); GlobalShortcutManager.shared.reload() }
    }
    @Published var mapLabel: String {
        didSet { defaults.set(mapLabel, forKey: "mapLabel") }
    }
    @Published var findKeyCode: Int {
        didSet { defaults.set(findKeyCode, forKey: "findKeyCode"); GlobalShortcutManager.shared.reload() }
    }
    @Published var findModifiers: UInt {
        didSet { defaults.set(findModifiers, forKey: "findModifiers"); GlobalShortcutManager.shared.reload() }
    }
    @Published var findLabel: String {
        didSet { defaults.set(findLabel, forKey: "findLabel") }
    }

    private static let defaultModifiers = NSEvent.ModifierFlags([.command, .option]).rawValue

    private init() {
        alwaysOnTop = defaults.object(forKey: "alwaysOnTop") as? Bool ?? true
        peekEnabled = defaults.object(forKey: "peekEnabled") as? Bool ?? false
        launchAtLogin = (SMAppService.mainApp.status == .enabled)
        peekRadius = defaults.object(forKey: "peekRadius") as? Double ?? 53.9
        peekTransparency = defaults.object(forKey: "peekTransparency") as? Double ?? 1
        peekFade = defaults.object(forKey: "peekFade") as? Double ?? 200
        invertPan = defaults.bool(forKey: "invertPan")
        clickThrough = defaults.bool(forKey: "clickThrough")
        colorOxygen = defaults.object(forKey: "colorOxygen") as? Bool ?? true
        fullCarboxylate = defaults.object(forKey: "fullCarboxylate") as? Bool ?? true
        iconModeRaw = defaults.object(forKey: "iconModeRaw") as? Int ?? 1
        slideAnimation = defaults.object(forKey: "slideAnimation") as? Bool ?? true
        baseTransparency = defaults.object(forKey: "baseTransparency") as? Double ?? 0.087
        metabolismSpeed = defaults.object(forKey: "metabolismSpeed") as? Double ?? 0.82

        // Defaults: ⌘M (keyCode 46) and ⌥⌘F (keyCode 3).
        mapKeyCode = defaults.object(forKey: "mapKeyCode") as? Int ?? 46
        mapModifiers = defaults.object(forKey: "mapModifiers") as? UInt ?? NSEvent.ModifierFlags.command.rawValue
        mapLabel = defaults.string(forKey: "mapLabel") ?? "⌘M"
        findKeyCode = defaults.object(forKey: "findKeyCode") as? Int ?? 3
        findModifiers = defaults.object(forKey: "findModifiers") as? UInt ?? Self.defaultModifiers
        findLabel = defaults.string(forKey: "findLabel") ?? "⌥⌘F"
    }

    /// Alpha of the map inside the hole (inverse of transparency).
    var coreAlpha: CGFloat { CGFloat(1 - peekTransparency) }
    /// Resting alpha of the whole map window.
    var baseAlpha: CGFloat { CGFloat(1 - baseTransparency) }
}

/// Checks GitHub for a newer release and can download/install it in place.
final class UpdateChecker: ObservableObject {
    static let shared = UpdateChecker()

    @Published var updateAvailable = false
    @Published var latestVersion = ""
    @Published var installing = false
    private var downloadURL: URL?

    private let repo = "cjreplogle/metabolic-map-hotkey"

    var currentVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
    }

    func check() {
        guard let url = URL(string: "https://api.github.com/repos/\(repo)/releases/latest") else { return }
        var request = URLRequest(url: url)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")

        URLSession.shared.dataTask(with: request) { [weak self] data, _, _ in
            guard let self,
                  let data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let tag = json["tag_name"] as? String else { return }

            let latest = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
            var zip: URL?
            if let assets = json["assets"] as? [[String: Any]] {
                for asset in assets {
                    if let name = asset["name"] as? String, name.hasSuffix(".zip"),
                       let urlString = asset["browser_download_url"] as? String {
                        zip = URL(string: urlString)
                    }
                }
            }

            let newer = Self.isVersion(latest, newerThan: self.currentVersion)
            DispatchQueue.main.async {
                self.latestVersion = latest
                self.downloadURL = zip
                self.updateAvailable = newer && zip != nil
            }
        }.resume()
    }

    static func isVersion(_ a: String, newerThan b: String) -> Bool {
        let pa = a.split(separator: ".").map { Int($0) ?? 0 }
        let pb = b.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(pa.count, pb.count) {
            let x = i < pa.count ? pa[i] : 0
            let y = i < pb.count ? pb[i] : 0
            if x != y { return x > y }
        }
        return false
    }

    /// Downloads the latest release zip and swaps it in via a detached helper
    /// script that waits for this app to quit, then relaunches the new build.
    func performUpdate() {
        guard let downloadURL else { return }
        installing = true

        URLSession.shared.downloadTask(with: downloadURL) { [weak self] tmp, _, _ in
            guard let tmp else {
                DispatchQueue.main.async { self?.installing = false }
                return
            }
            let fm = FileManager.default
            let work = fm.temporaryDirectory.appendingPathComponent("mm-update-\(UUID().uuidString)")
            try? fm.createDirectory(at: work, withIntermediateDirectories: true)

            let zipPath = work.appendingPathComponent("update.zip")
            try? fm.moveItem(at: tmp, to: zipPath)

            let unzip = Process()
            unzip.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
            unzip.arguments = ["-x", "-k", zipPath.path, work.path]
            try? unzip.run(); unzip.waitUntilExit()

            let newApp = work.appendingPathComponent("MetabolicMap.app")
            guard fm.fileExists(atPath: newApp.path) else {
                DispatchQueue.main.async { self?.installing = false }
                return
            }

            let dest = Bundle.main.bundlePath
            let pid = ProcessInfo.processInfo.processIdentifier
            let script = work.appendingPathComponent("swap.sh")
            let contents = """
            #!/bin/bash
            while kill -0 \(pid) 2>/dev/null; do sleep 0.2; done
            /bin/rm -rf "\(dest)"
            /usr/bin/ditto "\(newApp.path)" "\(dest)"
            /usr/bin/open "\(dest)"
            """
            try? contents.write(to: script, atomically: true, encoding: .utf8)

            let swap = Process()
            swap.executableURL = URL(fileURLWithPath: "/bin/bash")
            swap.arguments = [script.path]
            try? swap.run()

            DispatchQueue.main.async { NSApp.terminate(nil) }
        }.resume()
    }
}

/// Remembers the last non-self app that was frontmost, so focus can be returned.
final class PreviousAppTracker {
    static let shared = PreviousAppTracker()
    private(set) var previousApp: NSRunningApplication?

    func start() {
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil, queue: .main
        ) { [weak self] note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  app.bundleIdentifier != Bundle.main.bundleIdentifier else { return }
            self?.previousApp = app
        }
    }

    func returnFocus() {
        previousApp?.activate()
    }
}

/// Converts NSEvent modifier flags to the CGEventFlags used by the event tap.
func cgFlags(from nsRaw: UInt) -> CGEventFlags {
    let ns = NSEvent.ModifierFlags(rawValue: nsRaw)
    var cg: CGEventFlags = []
    if ns.contains(.command) { cg.insert(.maskCommand) }
    if ns.contains(.option) { cg.insert(.maskAlternate) }
    if ns.contains(.control) { cg.insert(.maskControl) }
    if ns.contains(.shift) { cg.insert(.maskShift) }
    return cg
}

/// A human-readable label like "⌥⌘M" for a key code + NSEvent modifiers.
func shortcutLabel(keyCode: Int, modifiers nsRaw: UInt, keyName: String) -> String {
    let ns = NSEvent.ModifierFlags(rawValue: nsRaw)
    var s = ""
    if ns.contains(.control) { s += "⌃" }
    if ns.contains(.option) { s += "⌥" }
    if ns.contains(.shift) { s += "⇧" }
    if ns.contains(.command) { s += "⌘" }
    return s + keyName
}

/// Brings a window to the front so it can appear over another app's full-screen
/// Space, then drops it back to a normal window level so it is not permanently
/// pinned above every other window.
/// Offset (toward the window's nearest screen corner) used for the slide anim.
private func cornerSlideOffset(for window: NSWindow, distance: CGFloat = 45) -> CGSize {
    guard AppSettings.shared.slideAnimation else { return .zero }
    let vf = (window.screen ?? NSScreen.main)?.visibleFrame ?? window.frame
    let tol: CGFloat = 40   // treat as "centered" within this tolerance
    let cx = window.frame.midX - vf.midX
    let cy = window.frame.midY - vf.midY
    let dx: CGFloat = abs(cx) < tol ? 0 : (cx < 0 ? -1 : 1)
    var dy: CGFloat = abs(cy) < tol ? 0 : (cy < 0 ? -1 : 1)
    // If centered horizontally (or fully), slide vertically (top/bottom).
    if dx == 0, dy == 0 { dy = -1 }
    return CGSize(width: dx * distance, height: dy * distance)
}

func presentWindow(_ window: NSWindow, activate: Bool = true, finalAlpha: CGFloat = 1) {
    window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
    window.level = .floating

    // Start offset toward the window's corner, then fade + slide into place.
    let finalFrame = window.frame
    let off = cornerSlideOffset(for: window)
    window.setFrame(finalFrame.offsetBy(dx: off.width, dy: off.height), display: false)
    window.alphaValue = 0
    if activate {
        window.makeKeyAndOrderFront(nil)
        NSApplication.shared.activate(ignoringOtherApps: true)
    } else {
        window.orderFrontRegardless()
    }
    NSAnimationContext.runAnimationGroup { context in
        context.duration = 0.22
        context.timingFunction = CAMediaTimingFunction(name: .easeOut)
        window.animator().setFrame(finalFrame, display: true)
        window.animator().alphaValue = finalAlpha
    }

    DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
        // Drop back to a normal level unless the user pinned it on top.
        if !AppSettings.shared.alwaysOnTop {
            window.level = .normal
        }
    }
}

/// Fades + slides a window out toward its corner, then orders it out (keeping the
/// instance and restoring its frame for the next show).
func fadeOutWindow(_ window: NSWindow, completion: (() -> Void)? = nil) {
    let finalFrame = window.frame
    let off = cornerSlideOffset(for: window)
    NSAnimationContext.runAnimationGroup({ context in
        context.duration = 0.18
        context.timingFunction = CAMediaTimingFunction(name: .easeIn)
        window.animator().setFrame(finalFrame.offsetBy(dx: off.width, dy: off.height), display: true)
        window.animator().alphaValue = 0
    }, completionHandler: {
        window.orderOut(nil)
        window.setFrame(finalFrame, display: false)
        window.alphaValue = 1
        completion?()
    })
}

// MARK: - Persistent PDF selection

final class MapFileManager {
    static let shared = MapFileManager()
    private let bookmarkKey = "MetabolicMapPDFBookmark"
    private init() {}

    func resolveMapURL() -> URL? {
        guard let data = UserDefaults.standard.data(forKey: bookmarkKey) else { return nil }
        var stale = false
        do {
            let url = try URL(
                resolvingBookmarkData: data,
                options: [],
                relativeTo: nil,
                bookmarkDataIsStale: &stale
            )
            if stale { saveBookmark(for: url) }
            guard url.isFileURL, FileManager.default.fileExists(atPath: url.path) else { return nil }
            return url
        } catch {
            return nil
        }
    }

    // This target is not sandboxed, so no security-scoped access is required to
    // read a user-selected file. These remain as harmless no-ops so callers do
    // not need to special-case sandbox vs. non-sandbox builds.
    @discardableResult
    func startAccessing(_ url: URL) -> Bool {
        return true
    }

    func stopAccessing(_ url: URL) {}

    private func saveBookmark(for url: URL) {
        do {
            let data = try url.bookmarkData(
                options: [],
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
            UserDefaults.standard.set(data, forKey: bookmarkKey)
        } catch {
            print("Could not save PDF bookmark: \(error)")
        }
    }

    func chooseMap(completion: @escaping (Bool) -> Void) {
        let panel = NSOpenPanel()
        panel.title = "Select Your Metabolic Map PDF"
        panel.message = "Select the metabolic map PDF already stored on your Mac."
        panel.prompt = "Use This PDF"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.pdf]

        panel.begin { response in
            guard response == .OK, let url = panel.url else {
                completion(false)
                return
            }
            self.saveBookmark(for: url)
            completion(true)
        }
    }
}

// MARK: - Robust CGEventTap Global ⌥⌘M / ⌥⌘S Listener

final class GlobalShortcutManager {

    static let shared = GlobalShortcutManager()

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var trustTimer: Timer?

    // Current (user-configurable) shortcuts, read from AppSettings via reload().
    private var mapKeyCode: Int64 = 46
    private var mapModifiers: CGEventFlags = [.maskAlternate, .maskCommand]
    private var findKeyCode: Int64 = 1
    private var findModifiers: CGEventFlags = [.maskAlternate, .maskCommand]

    // Fixed modifiers for the ⌥⌘ + arrow pan shortcuts.
    private let panModifiers: CGEventFlags = [.maskAlternate, .maskCommand]
    // Modifiers we care about when deciding whether a chord matches exactly.
    private let trackedModifiers: CGEventFlags =
        [.maskAlternate, .maskCommand, .maskControl, .maskShift]

    private init() {}

    /// Loads the current shortcut definitions from AppSettings.
    func reload() {
        let s = AppSettings.shared
        mapKeyCode = Int64(s.mapKeyCode)
        mapModifiers = cgFlags(from: s.mapModifiers)
        findKeyCode = Int64(s.findKeyCode)
        findModifiers = cgFlags(from: s.findModifiers)
    }

    func start() {
        reload()
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        let isTrusted = AXIsProcessTrustedWithOptions(options)

        if isTrusted {
            setupEventTap()
        } else {
            // Accessibility not granted yet (common right after a rebuild, since
            // the ad-hoc code identity changes). Poll until the user grants it,
            // then create the tap — no relaunch required.
            print("Accessibility not granted yet; waiting for permission…")
            waitForTrustThenSetup()
        }
    }

    private func waitForTrustThenSetup() {
        trustTimer?.invalidate()
        trustTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] timer in
            guard let self else { timer.invalidate(); return }
            if AXIsProcessTrusted() {
                timer.invalidate()
                self.trustTimer = nil
                self.setupEventTap()
                print("Accessibility granted; global shortcuts active.")
            }
        }
    }

    private func setupEventTap() {

        // Avoid creating a second tap if one already exists.
        if let existing = eventTap {
            CGEvent.tapEnable(tap: existing, enable: true)
            return
        }

        let eventMask = (1 << CGEventType.keyDown.rawValue)

        let callback: CGEventTapCallBack = { _, type, event, refcon in
            guard let refcon = refcon else { return Unmanaged.passUnretained(event) }
            let manager = Unmanaged<GlobalShortcutManager>.fromOpaque(refcon).takeUnretainedValue()

            if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                if let tap = manager.eventTap {
                    CGEvent.tapEnable(tap: tap, enable: true)
                }
                return Unmanaged.passUnretained(event)
            }

            guard type == .keyDown else {
                return Unmanaged.passUnretained(event)
            }

            let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
            let mods = event.flags.intersection(manager.trackedModifiers)

            // User-configurable shortcuts.
            if keyCode == manager.mapKeyCode, mods == manager.mapModifiers {
                DispatchQueue.main.async { MapWindowController.shared.toggle() }
                return nil // consume so the key chord doesn't beep or fall through
            }

            if keyCode == manager.findKeyCode, mods == manager.findModifiers {
                DispatchQueue.main.async { MapWindowController.shared.openFind() }
                return nil
            }

            // ⌥⌘B returns focus to the app that was active before the map.
            if mods == manager.panModifiers, keyCode == 11 {
                DispatchQueue.main.async { PreviousAppTracker.shared.returnFocus() }
                return nil
            }

            // ⌥⌘ + arrows pan the map globally (even when another app is focused).
            // Virtual key codes: left = 123, right = 124, down = 125, up = 126.
            if mods == manager.panModifiers {
                switch keyCode {
                case 123: DispatchQueue.main.async { MapWindowController.shared.panFromShortcut(dx: -1, dy: 0) }; return nil
                case 124: DispatchQueue.main.async { MapWindowController.shared.panFromShortcut(dx: 1, dy: 0) }; return nil
                case 125: DispatchQueue.main.async { MapWindowController.shared.panFromShortcut(dx: 0, dy: -1) }; return nil
                case 126: DispatchQueue.main.async { MapWindowController.shared.panFromShortcut(dx: 0, dy: 1) }; return nil
                default: break
                }
            }

            // ⌃⌘ +/- grow/shrink the window; ⌃⌘ + arrows snap it across a 3×3 grid.
            // Key codes: = 24, - 27, keypad + 69, keypad - 78; arrows 123-126.
            if event.flags.contains(.maskCommand), event.flags.contains(.maskControl) {
                switch keyCode {
                case 24, 69: DispatchQueue.main.async { MapWindowController.shared.resizeWindowFromShortcut(1.1) }; return nil
                case 27, 78: DispatchQueue.main.async { MapWindowController.shared.resizeWindowFromShortcut(0.9) }; return nil
                case 123: DispatchQueue.main.async { MapWindowController.shared.snapToGrid(dCol: -1, dRow: 0) }; return nil
                case 124: DispatchQueue.main.async { MapWindowController.shared.snapToGrid(dCol: 1, dRow: 0) }; return nil
                case 125: DispatchQueue.main.async { MapWindowController.shared.snapToGrid(dCol: 0, dRow: 1) }; return nil
                case 126: DispatchQueue.main.async { MapWindowController.shared.snapToGrid(dCol: 0, dRow: -1) }; return nil
                default: break
                }
            }

            // ⌥⌘ +/- zoom the map content.
            if event.flags.contains(.maskCommand), event.flags.contains(.maskAlternate) {
                switch keyCode {
                case 24, 69: DispatchQueue.main.async { MapWindowController.shared.zoomFromShortcut(1.25) }; return nil
                case 27, 78: DispatchQueue.main.async { MapWindowController.shared.zoomFromShortcut(0.8) }; return nil
                default: break
                }
            }

            return Unmanaged.passUnretained(event)
        }

        let selfPointer = Unmanaged.passUnretained(self).toOpaque()

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: CGEventMask(eventMask),
            callback: callback,
            userInfo: selfPointer
        ) else {
            print("Failed to create CGEventTap. Waiting for Accessibility permission…")
            waitForTrustThenSetup()
            return
        }

        self.eventTap = tap
        self.runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        if let source = runLoopSource {
            CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
            CGEvent.tapEnable(tap: tap, enable: true)
        }
    }

    deinit {
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
        }
    }
}

// MARK: - App delegate & Main Entry Point

@main
final class AppDelegate: NSObject, NSApplicationDelegate {

    private static var strongDelegate: AppDelegate?

    static func main() {
        let application = NSApplication.shared
        let delegate = AppDelegate()
        strongDelegate = delegate
        application.delegate = delegate
        application.setActivationPolicy(.accessory)
        application.run()
    }

    private var statusItem: NSStatusItem?
    private var metaboliteIcons: [NSImage] = []
    private var iconIndex = 0
    private var iconDirection = 1
    private var tcaLoopsRemaining = 0
    private var hexoseLoopsRemaining = 0
    private var tcaStartIndex = 6
    private var iconTimer: Timer?

    /// Advances the pathway walk. Both the hexose (6-carbon: glucose…F1,6BP) and
    /// the TCA cycle segments spin several extra times, so the walk dwells about
    /// evenly in 6-carbon metabolism and the TCA cycle.
    private func advancePathway() {
        let count = metaboliteIcons.count
        guard count > 1 else { return }
        let hexTop = min(2, count - 1)          // F1,6BP
        let tcaStart = min(tcaStartIndex, count - 1)   // citrate (dynamic)
        let tcaEnd = count - 1                  // oxaloacetate

        if iconDirection > 0 {
            if iconIndex == 0 {
                // Start of a forward pass through the hexose phase: cycle it a few
                // times (more loops than TCA since it has fewer intermediates).
                hexoseLoopsRemaining = (Int.random(in: 0..<100) < 85) ? Int.random(in: 3...6) : 0
                iconIndex = 1
            } else if iconIndex == hexTop {
                if hexoseLoopsRemaining > 0 {
                    hexoseLoopsRemaining -= 1
                    iconIndex = 0               // loop the hexose phase
                } else {
                    iconIndex += 1              // proceed into lower glycolysis
                }
            } else if iconIndex == tcaEnd {
                if tcaLoopsRemaining > 0 {
                    tcaLoopsRemaining -= 1
                    iconIndex = tcaStart        // loop the TCA cycle
                } else {
                    iconDirection = -1
                    iconIndex -= 1
                }
            } else {
                iconIndex += 1
                if iconIndex == tcaStart {
                    tcaLoopsRemaining = (Int.random(in: 0..<100) < 85) ? Int.random(in: 2...3) : 0
                }
            }
        } else {
            if iconIndex <= 1 {
                iconDirection = 1
                iconIndex = 0
            } else {
                iconIndex -= 1
            }
        }
    }

    private var splitIcon: NSImage?
    private var hmpIcons: [NSImage] = []
    private var frameQueue: [(image: NSImage, delay: TimeInterval)] = []

    private func loadTemplateSVG(_ name: String) -> NSImage? {
        guard let url = Bundle.main.url(forResource: name, withExtension: "svg"),
              let image = NSImage(contentsOf: url) else { return nil }
        image.size = NSSize(width: 18, height: 18)
        // Non-template shows the red oxygens; template renders monochrome/adaptive.
        image.isTemplate = !AppSettings.shared.colorOxygen
        return image
    }

    /// Reloads the icons (color mode / full-carboxylate can change which files are
    /// used) and refreshes the current frame.
    private func applyIconColoring() {
        loadMetaboliteIcons()
        if let button = statusItem?.button, !metaboliteIcons.isEmpty {
            button.image = metaboliteIcons[min(iconIndex, metaboliteIcons.count - 1)]
        }
    }

    private func loadMetaboliteIcons() {
        splitIcon = loadTemplateSVG("SplitIcon")
        hmpIcons = ["Hmp0_6pg", "Hmp1_ru5p"].compactMap { loadTemplateSVG($0) }
        // Ordered glycolysis → TCA intermediates (Path00_… Path11_…).
        let urls = (Bundle.main.urls(forResourcesWithExtension: "svg", subdirectory: nil) ?? [])
            .filter { $0.lastPathComponent.hasPrefix("Path") && !$0.lastPathComponent.contains("_full") }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        tcaStartIndex = urls.firstIndex { $0.lastPathComponent.contains("citrate") } ?? 6

        let full = AppSettings.shared.fullCarboxylate
        let template = !AppSettings.shared.colorOxygen
        metaboliteIcons = urls.compactMap { url in
            var use = url
            if full {
                let fullName = url.deletingPathExtension().lastPathComponent + "_full"
                if let fullURL = Bundle.main.url(forResource: fullName, withExtension: "svg") {
                    use = fullURL
                }
            }
            guard let image = NSImage(contentsOf: use) else { return nil }
            image.size = NSSize(width: 18, height: 18)
            image.isTemplate = template
            return image
        }
    }

    private func startIconCycling() {
        statusItem?.button?.wantsLayer = true
        applyIconMode()
    }

    /// Starts/stops the walk per the selected mode and the map's visibility.
    private func applyIconMode() {
        guard metaboliteIcons.count > 1 else { return }
        switch AppSettings.shared.iconMode {
        case .alwaysPlay:
            resumeCycling()
        case .playWhenOpen:
            MapWindowController.shared.isMapVisible ? resumeCycling() : pauseOnGlucose()
        case .alwaysPause:
            pauseOnGlucose()
        }
    }

    private func resumeCycling() {
        guard iconTimer == nil else { return }
        scheduleNextFrame()
    }

    private func pauseOnGlucose() {
        iconTimer?.invalidate()
        iconTimer = nil
        frameQueue.removeAll()
        iconIndex = 0
        iconDirection = 1
        if let button = statusItem?.button, let glucose = metaboliteIcons.first {
            animatePathwayStep(to: glucose, forward: true, on: button)
        }
    }

    /// Displays the next queued frame (or builds new ones), self-scheduling with a
    /// per-frame delay so glycolysis runs faster than the TCA cycle.
    private func scheduleNextFrame() {
        iconTimer?.invalidate()
        if frameQueue.isEmpty { buildNextFrames() }
        guard !frameQueue.isEmpty, let button = statusItem?.button else { return }
        let frame = frameQueue.removeFirst()
        animatePathwayStep(to: frame.image, forward: iconDirection > 0, on: button)
        iconTimer = Timer.scheduledTimer(withTimeInterval: frame.delay, repeats: false) { [weak self] _ in
            self?.scheduleNextFrame()
        }
    }

    private func buildNextFrames() {
        guard !metaboliteIcons.isEmpty else { return }
        let prev = iconIndex
        let delay = AppSettings.shared.metabolismDelay

        // Occasionally branch off the HMP (pentose phosphate) shunt from G6P.
        if iconIndex == 1, iconDirection > 0, !hmpIcons.isEmpty, Int.random(in: 0..<100) < 10 {
            for img in hmpIcons { frameQueue.append((img, delay)) }
            for img in hmpIcons.reversed() { frameQueue.append((img, delay)) }
            frameQueue.append((metaboliteIcons[1], delay))  // rejoin at G6P
            return
        }

        advancePathway()
        let newIndex = iconIndex

        // Aldolase split/merge (F1,6BP 2 <-> G3P 3): flash the two-fragment frame.
        if min(prev, newIndex) == 2, max(prev, newIndex) == 3, let split = splitIcon {
            frameQueue.append((split, delay))
        }
        frameQueue.append((metaboliteIcons[newIndex], delay))
    }

    /// Crossfades (dissolves) between the old and new icon.
    private func animatePathwayStep(to image: NSImage, forward: Bool, on button: NSStatusBarButton) {
        let transition = CATransition()
        transition.type = .fade
        transition.duration = min(0.18, AppSettings.shared.metabolismDelay * 0.85)
        transition.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        button.layer?.add(transition, forKey: "pathwayCrossfade")
        button.image = image
    }

    func applicationDidFinishLaunching(_ notification: Notification) {

        if let icon = loadAppIcon() {
            NSApplication.shared.applicationIconImage = icon
        }

        GlobalShortcutManager.shared.start()
        PreviousAppTracker.shared.start()
        UpdateChecker.shared.check()

        if MapFileManager.shared.resolveMapURL() == nil {
            showSetup()
        } else {
            createMenuBarItem()
        }
    }

    private func createMenuBarItem() {

        guard statusItem == nil else { return }

        statusItem = NSStatusBar.system.statusItem(
            withLength: NSStatusItem.squareLength
        )

        if let button = statusItem?.button {
            loadMetaboliteIcons()
            button.image = metaboliteIcons.first
                ?? NSImage(systemSymbolName: "map", accessibilityDescription: "Metabolic Map")
            button.image?.isTemplate = !AppSettings.shared.colorOxygen
            button.toolTip = "Metabolic Map"
            startIconCycling()
            NotificationCenter.default.addObserver(
                forName: .mmIconColoringChanged, object: nil, queue: .main
            ) { [weak self] _ in self?.applyIconColoring() }
            NotificationCenter.default.addObserver(
                forName: .mmIconModeChanged, object: nil, queue: .main
            ) { [weak self] _ in self?.applyIconMode() }
            NotificationCenter.default.addObserver(
                forName: .mmMapVisibilityChanged, object: nil, queue: .main
            ) { [weak self] _ in self?.applyIconMode() }
        }

        let menu = NSMenu()

        addItem("Open Metabolic Map", action: #selector(openMap), to: menu)
        addItem("Search Map", action: #selector(searchMap), to: menu)

        menu.addItem(.separator())

        addItem("Options…", action: #selector(openOptions), to: menu)

        menu.addItem(.separator())

        let shortcuts = NSMenuItem(
            title: "Shortcuts: ⌥⌘M open map  ·  ⌥⌘S search",
            action: nil,
            keyEquivalent: ""
        )
        shortcuts.isEnabled = false
        menu.addItem(shortcuts)

        menu.addItem(.separator())

        addItem("Quit Metabolic Map", action: #selector(quit), to: menu)

        statusItem?.menu = menu
    }

    private func addItem(
        _ title: String,
        action: Selector,
        to menu: NSMenu
    ) {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        menu.addItem(item)
    }

    @objc private func openMap() {
        MapWindowController.shared.show()
    }

    @objc private func searchMap() {
        MapWindowController.shared.openFind()
    }

    @objc private func openOptions() {
        OptionsWindowController.shared.show()
    }

    @objc private func quit() {
        NSApplication.shared.terminate(nil)
    }

    private func showSetup() {
        NSApplication.shared.setActivationPolicy(.regular)

        SetupWindowController.shared.show {
            NSApplication.shared.setActivationPolicy(.accessory)
            self.createMenuBarItem()
        }
    }
}

// MARK: - Setup

final class SetupWindowController: NSObject {

    static let shared = SetupWindowController()
    private var window: NSWindow?

    func show(completion: @escaping () -> Void) {

        let hosting = NSHostingView(
            rootView: SetupView(completion: completion)
        )

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 330),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )

        window.title = "Metabolic Map Setup"
        window.contentView = hosting
        configureWindowAppearance(window)
        window.isReleasedWhenClosed = false
        window.center()

        self.window = window

        NSApplication.shared.setActivationPolicy(.regular)
        presentWindow(window)
    }

    func dismiss() {
        window?.orderOut(nil)
        window?.close()
        window = nil
    }
}

struct SetupView: View {

    let completion: () -> Void

    @State private var selecting = false

    var body: some View {

        VStack(spacing: 20) {

            Image(systemName: "map")
                .font(.system(size: 52))

            Text("Metabolic Map")
                .font(.system(size: 28, weight: .semibold))

            Text("""
            This app does not include or redistribute the metabolic map PDF.

            Select the copy of the map already stored on your Mac.
            The app will remember its location for future launches.
            """)
            .multilineTextAlignment(.center)
            .foregroundStyle(.secondary)
            .frame(maxWidth: 460)

            Button {
                choosePDF()
            } label: {
                HStack {
                    Image(systemName: "folder")
                    Text("Choose Map PDF…")
                }
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)

            if selecting {
                ProgressView()
                    .controlSize(.small)
            }
        }
        .padding(35)
        .frame(width: 560, height: 330)
    }

    private func choosePDF() {

        selecting = true

        MapFileManager.shared.chooseMap { success in

            DispatchQueue.main.async {

                selecting = false

                if success {
                    SetupWindowController.shared.dismiss()
                    completion()
                }
            }
        }
    }
}

// MARK: - Map viewer

/// A clip view that keeps the document centered when it's smaller than the
/// viewport (instead of pinning it to a corner) and blocks over-scroll.
final class CenteringClipView: NSClipView {
    override func constrainBoundsRect(_ proposedBounds: NSRect) -> NSRect {
        guard let doc = documentView else { return super.constrainBoundsRect(proposedBounds) }
        var rect = proposedBounds
        let frame = doc.frame

        // Center if the viewport is larger than the document on an axis; otherwise
        // hard-clamp the origin so there's no rubber-band over-scroll.
        if rect.width >= frame.width {
            rect.origin.x = frame.minX + (frame.width - rect.width) / 2
        } else {
            rect.origin.x = min(max(rect.origin.x, frame.minX), frame.maxX - rect.width)
        }
        if rect.height >= frame.height {
            rect.origin.y = frame.minY + (frame.height - rect.height) / 2
        } else {
            rect.origin.y = min(max(rect.origin.y, frame.minY), frame.maxY - rect.height)
        }
        return rect
    }
}

/// A PDFView where click-drag pans the document (grab/hand tool) instead of
/// selecting text.
final class PanningPDFView: PDFView {

    private var scroll: NSScrollView? { subviews.compactMap { $0 as? NSScrollView }.first }

    override func mouseDown(with event: NSEvent) {
        // ⌘-drag moves the window (there's no title bar to grab); plain drag pans.
        if event.modifierFlags.contains(.command) {
            window?.performDrag(with: event)
            return
        }
        NSCursor.closedHand.set()
        // Intentionally not calling super -> no text selection.
    }

    override func mouseDragged(with event: NSEvent) {
        guard let clip = scroll?.contentView else { return }
        // Convert screen-point deltas to the clip's (possibly magnified) document
        // coordinates so the page tracks the cursor 1:1 at any zoom.
        let fx = clip.bounds.width / max(1, clip.frame.width)
        let fy = clip.bounds.height / max(1, clip.frame.height)
        let sign: CGFloat = AppSettings.shared.invertPan ? 1 : -1
        var origin = clip.bounds.origin
        origin.x += event.deltaX * fx * sign
        origin.y -= event.deltaY * fy * sign

        if let doc = scroll?.documentView {
            origin.x = min(max(0, origin.x), max(0, doc.frame.width - clip.bounds.width))
            origin.y = min(max(0, origin.y), max(0, doc.frame.height - clip.bounds.height))
        }
        clip.setBoundsOrigin(origin)
        scroll?.reflectScrolledClipView(clip)
    }

    override func mouseUp(with event: NSEvent) {
        NSCursor.arrow.set()
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .openHand)
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 49 { return }   // swallow Space (no page jump / break-through)
        super.keyDown(with: event)
    }

    // Trackpad/wheel scrolling is left to PDFKit (native) so it re-tiles correctly;
    // the centering clip view hard-clamps the scroll to prevent over-scroll.
}

/// Hosts the PDFView plus an in-window ⌘F find bar (search field, prev/next,
/// and a live "n of m" match count).
final class MapContainerView: NSView {

    let pdfView = PanningPDFView()

    // A low-resolution full-page render kept behind the PDFView. When the PDFView
    // hasn't drawn fresh tiles yet (e.g. right after a jump), the transparent
    // areas reveal this instead of flashing white.
    private let underlay = NSImageView()
    private var scrollObserver: NSObjectProtocol?
    private var scaleObserver: NSObjectProtocol?

    private let findBar = NSVisualEffectView()
    private let searchField = NSSearchField()
    private let countLabel = NSTextField(labelWithString: "")

    private let zoomControls = NSStackView()
    private var zoomControlsVisible = false

    private var matches: [PDFSelection] = []
    private var currentMatch = -1
    private var searchDebounce: Timer?
    private var searchGeneration = 0
    private var zoomTimer: Timer?
    private var zoomTargetScale: CGFloat = 1
    private var isZooming = false
    private var didRestore = false
    private var saveTimer: Timer?
    // Set once the user manually zooms/pans, so the auto fill-zoom on layout does
    // not fight/override their navigation. Cleared by resetZoom().
    private var userControlledView = false

    // "Peek hole": makes a circular region under the cursor transparent so you
    // can see whatever is behind the map window.
    private var mouseMonitors: [Any] = []
    private var focusObservers: [NSObjectProtocol] = []
    // Peek is suppressed while the window is focused (clicked into); it fades out
    // on focus and resumes when the window loses focus.
    private var peekSuppressed = false
    private var peekStrength: CGFloat = 1     // 1 = full hole, 0 = no hole
    private var peekFadeTimer: Timer?
    private var peekCenter: NSPoint?
    private var peekRadius: CGFloat { CGFloat(AppSettings.shared.peekRadius) }
    private var peekFade: CGFloat { CGFloat(AppSettings.shared.peekFade) }  // soft fade band beyond the core
    private let peekMaskLayer = CALayer()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setup()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setup()
    }

    // 1.0 = exact cover. The view is bottom-anchored so the cropped/overscanned
    // dimension comes off the top.
    private let fillZoom: CGFloat = 1.0
    // The PDFView is kept the same size as the visible container (margin 0) so
    // its scroll range isn't reduced. White flicker on pan/jump is instead
    // covered by the low-res underlay showing through the transparent PDFView.
    private let renderMargin: CGFloat = 0
    private var isAdjustingZoom = false

    /// The actually-visible area (the container's own bounds; the PDFView extends
    /// beyond it by `renderMargin`).
    private var visibleSize: NSSize { bounds.size }

    private func setup() {

        // Rounded corners: the window background is made transparent (in the
        // controller) and the content is clipped to this radius.
        wantsLayer = true
        layer?.cornerRadius = 20
        layer?.masksToBounds = true
        layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        peekMaskLayer.contentsGravity = .resize

        // Low-res underlay sits behind everything and is positioned manually to
        // track the page.
        underlay.imageScaling = .scaleAxesIndependently
        underlay.wantsLayer = true
        underlay.translatesAutoresizingMaskIntoConstraints = true
        addSubview(underlay)

        // The PDFView is extended beyond the visible container by `renderMargin`
        // on every side, so PDFKit renders a ring of off-screen content. The
        // container clips it (masksToBounds), so panning reveals already-rendered
        // area instead of white flicker.
        pdfView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(pdfView)
        NSLayoutConstraint.activate([
            pdfView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: -renderMargin),
            pdfView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: renderMargin),
            pdfView.topAnchor.constraint(equalTo: topAnchor, constant: -renderMargin),
            pdfView.bottomAnchor.constraint(equalTo: bottomAnchor, constant: renderMargin)
        ])

        findBar.material = .titlebar
        findBar.blendingMode = .withinWindow
        findBar.state = .active
        findBar.isHidden = true
        findBar.translatesAutoresizingMaskIntoConstraints = false

        searchField.placeholderString = "Find in map"
        searchField.sendsWholeSearchString = false
        searchField.delegate = self
        searchField.setContentHuggingPriority(.defaultLow, for: .horizontal)
        searchField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        countLabel.textColor = .secondaryLabelColor
        countLabel.font = .systemFont(ofSize: 11)
        countLabel.alignment = .right
        countLabel.setContentHuggingPriority(.defaultHigh, for: .horizontal)

        let prev = makeButton("chevron.up", label: "Previous", action: #selector(goPrevious))
        let next = makeButton("chevron.down", label: "Next", action: #selector(goNext))
        let done = NSButton(title: "Done", target: self, action: #selector(hideFindBar))
        done.bezelStyle = .rounded

        let stack = NSStackView(views: [searchField, countLabel, prev, next, done])
        stack.orientation = .horizontal
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 6, left: 12, bottom: 6, right: 12)
        stack.translatesAutoresizingMaskIntoConstraints = false

        findBar.addSubview(stack)
        addSubview(findBar)

        NSLayoutConstraint.activate([
            findBar.leadingAnchor.constraint(equalTo: leadingAnchor),
            findBar.trailingAnchor.constraint(equalTo: trailingAnchor),
            findBar.bottomAnchor.constraint(equalTo: bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: findBar.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: findBar.trailingAnchor),
            stack.topAnchor.constraint(equalTo: findBar.topAnchor),
            stack.bottomAnchor.constraint(equalTo: findBar.bottomAnchor),
            searchField.widthAnchor.constraint(greaterThanOrEqualToConstant: 110)
        ])

        // Hover-activated zoom controls in the bottom-right.
        let zoomIn = makeButton("plus", label: "Zoom in", action: #selector(zoomInButton))
        let zoomOut = makeButton("minus", label: "Zoom out", action: #selector(zoomOutButton))
        for button in [zoomIn, zoomOut] {
            button.translatesAutoresizingMaskIntoConstraints = false
            button.widthAnchor.constraint(equalToConstant: 22).isActive = true
        }
        zoomControls.orientation = .vertical
        zoomControls.spacing = 6
        zoomControls.edgeInsets = NSEdgeInsets(top: 5, left: 5, bottom: 5, right: 5)
        zoomControls.addArrangedSubview(zoomIn)
        zoomControls.addArrangedSubview(zoomOut)
        zoomControls.wantsLayer = true
        zoomControls.layer?.backgroundColor = NSColor.windowBackgroundColor.withAlphaComponent(0.75).cgColor
        zoomControls.layer?.cornerRadius = 8
        zoomControls.translatesAutoresizingMaskIntoConstraints = false
        zoomControls.alphaValue = 0
        zoomControls.isHidden = true
        // Keep the zoom controls beneath the find bar so the find bar covers them
        // when they overlap at the bottom.
        addSubview(zoomControls, positioned: .below, relativeTo: findBar)
        NSLayoutConstraint.activate([
            zoomControls.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            zoomControls.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -14)
        ])
    }

    @objc private func zoomInButton() { smoothZoom(by: 1.25) }
    @objc private func zoomOutButton() { smoothZoom(by: 0.8) }

    /// Fades the bottom-right zoom controls in when the cursor is near the corner.
    private func updateZoomControls(near viewPoint: NSPoint?) {
        let show: Bool
        // No on-screen buttons in click-through (keyboard-only) mode.
        if let p = viewPoint, !AppSettings.shared.clickThrough {
            let corner = NSPoint(x: bounds.maxX, y: bounds.minY)
            show = hypot(p.x - corner.x, p.y - corner.y) < 170
        } else {
            show = false
        }
        guard show != zoomControlsVisible else { return }
        zoomControlsVisible = show
        if show { zoomControls.isHidden = false }
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.15
            zoomControls.animator().alphaValue = show ? 1 : 0
        }, completionHandler: { [weak self] in
            if !show { self?.zoomControls.isHidden = true }
        })
    }

    private func makeButton(_ symbol: String, label: String, action: Selector) -> NSButton {
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)
        let button = NSButton(image: image ?? NSImage(), target: self, action: action)
        button.bezelStyle = .rounded
        button.imagePosition = .imageOnly
        return button
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {

        let flags = event.modifierFlags
        let chars = event.charactersIgnoringModifiers?.lowercased()

        if flags.contains(.command), chars == "f" {
            showFindBar()
            return true
        }

        // Ctrl +/- : smooth zoom in / out.
        if flags.contains(.control) {
            if chars == "=" || chars == "+" {
                smoothZoom(by: 1.25)
                return true
            }
            if chars == "-" || chars == "_" {
                smoothZoom(by: 0.8)
                return true
            }
        }

        // Arrow panning/moving is handled globally by the event tap (⌥⌘ pan,
        // ⌃⌘ grid/resize). We intentionally do NOT handle bare ⌘/⌘⇧ + arrows here,
        // so a stray ⌘+arrow (e.g. Ctrl lagging while pressing ⌃⌘+arrow) can't
        // accidentally pan the map.
        return super.performKeyEquivalent(with: event)
    }

    override func layout() {
        super.layout()
        if let sv = pdfScrollView {
            sv.verticalScrollElasticity = .none
            sv.horizontalScrollElasticity = .none
            sv.usesPredominantAxisScrolling = false
        }
        applyOrRestoreZoom()
        updateUnderlayFrame()
        updatePeekMask()
    }

    private func applyOrRestoreZoom() {
        guard !isAdjustingZoom else { return }
        // On first valid layout, restore the last saved zoom/scroll if we have one.
        if !didRestore,
           UserDefaults.standard.bool(forKey: "hasSavedView"),
           let page = pdfView.document?.page(at: 0),
           bounds.width > 1, bounds.height > 1 {
            restoreSavedView(page: page)
            didRestore = true
            userControlledView = true
            return
        }
        applyFillZoom()
    }

    private func restoreSavedView(page: PDFPage) {
        let d = UserDefaults.standard
        let scale = CGFloat(d.double(forKey: "savedScale"))
        let cx = CGFloat(d.double(forKey: "savedCenterX"))
        let cy = CGFloat(d.double(forKey: "savedCenterY"))
        isAdjustingZoom = true
        pdfView.autoScales = false
        pdfView.scaleFactor = max(0.02, min(8, scale))
        center(on: NSPoint(x: cx, y: cy), page: page)
        isAdjustingZoom = false
    }

    /// Persists the current zoom + view-center (debounced) so it's restored later.
    private func scheduleSaveViewState() {
        saveTimer?.invalidate()
        saveTimer = Timer.scheduledTimer(withTimeInterval: 0.4, repeats: false) { [weak self] _ in
            self?.saveViewState()
        }
    }

    func saveViewState() {
        guard let page = pdfView.document?.page(at: 0), bounds.width > 1 else { return }
        let c = currentCenter(on: page)
        let d = UserDefaults.standard
        d.set(Double(pdfView.scaleFactor), forKey: "savedScale")
        d.set(Double(c.x), forKey: "savedCenterX")
        d.set(Double(c.y), forKey: "savedCenterY")
        d.set(true, forKey: "hasSavedView")
    }

    /// Tracks the cursor globally so the peek hole appears when the pointer is
    /// close enough to reach the window — not only when directly over it.
    func startPeekTracking() {
        let handler: (NSEvent) -> Void = { [weak self] _ in self?.handleMouseMoved() }
        if let global = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved], handler: handler) {
            mouseMonitors.append(global)
        }
        if let local = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved], handler: { [weak self] event in
            self?.handleMouseMoved()
            return event
        }) {
            mouseMonitors.append(local)
        }
        let center = NotificationCenter.default
        focusObservers.append(center.addObserver(
            forName: NSWindow.didBecomeKeyNotification, object: nil, queue: .main
        ) { [weak self] note in
            guard let self, note.object as? NSWindow === self.window else { return }
            self.suppressPeekWithFade()
        })
        focusObservers.append(center.addObserver(
            forName: NSWindow.didResignKeyNotification, object: nil, queue: .main
        ) { [weak self] note in
            guard let self, note.object as? NSWindow === self.window else { return }
            self.resumePeek()
        })
    }

    private func suppressPeekWithFade() {
        peekSuppressed = true
        peekFadeTimer?.invalidate()
        let startStrength = peekStrength
        let startTime = Date()
        let duration = 0.25
        peekFadeTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60.0, repeats: true) { [weak self] timer in
            guard let self else { timer.invalidate(); return }
            let progress = min(Date().timeIntervalSince(startTime) / duration, 1.0)
            self.peekStrength = startStrength * (1 - CGFloat(progress))
            self.updatePeekMask()
            if progress >= 1.0 {
                self.peekStrength = 0
                self.layer?.mask = nil
                timer.invalidate()
                self.peekFadeTimer = nil
            }
        }
    }

    private func resumePeek() {
        peekFadeTimer?.invalidate()
        peekFadeTimer = nil
        peekSuppressed = false
        peekStrength = 1
        handleMouseMoved()   // recompute from the current cursor position, not stale
    }

    private func handleMouseMoved() {
        guard let window else {
            updateZoomControls(near: nil)
            return
        }
        let viewPoint = convert(window.convertPoint(fromScreen: NSEvent.mouseLocation), from: nil)
        let overWindow = bounds.contains(viewPoint)
        updateZoomControls(near: overWindow ? viewPoint : nil)

        // Click-through: capture events (so scroll pans the map, no double-scroll)
        // only while the cursor is over the window; pass through everywhere else.
        if AppSettings.shared.clickThrough {
            window.ignoresMouseEvents = !overWindow
        }

        guard !peekSuppressed else { return }   // peek disabled while window is focused
        guard AppSettings.shared.peekEnabled else {
            peekCenter = nil
            updatePeekMask()
            return
        }
        // Active when within the window, or within the peek's reach of its edge.
        let reach = peekRadius + peekFade
        if bounds.insetBy(dx: -reach, dy: -reach).contains(viewPoint) {
            peekCenter = viewPoint
        } else {
            peekCenter = nil
        }
        updatePeekMask()
    }

    /// Cuts a soft-edged transparent circle out of the window under the cursor
    /// (or removes it when the cursor leaves), revealing whatever is behind the
    /// map. The mask is a downscaled radial-alpha bitmap: transparent core that
    /// fades to opaque, so the edge is feathered.
    /// Called when the peek-through setting is toggled from the menu.
    func peekSettingChanged() {
        if !AppSettings.shared.peekEnabled { peekCenter = nil }
        updatePeekMask()
    }

    private func updatePeekMask() {
        guard !isZooming,
              AppSettings.shared.peekEnabled, peekStrength > 0.001,
              let center = peekCenter, bounds.width > 1, bounds.height > 1 else {
            layer?.mask = nil
            return
        }

        let scale: CGFloat = 0.4
        let w = max(1, Int(bounds.width * scale))
        let h = max(1, Int(bounds.height * scale))

        let radius = Float(peekRadius)
        let fade = Float(peekFade)
        let coreAlpha = Float(AppSettings.shared.coreAlpha)
        let strength = Float(peekStrength)
        let cx = Float(center.x)
        let cy = Float(center.y)
        let boundsW = Float(bounds.width)
        let boundsH = Float(bounds.height)
        let invScale = Float(1 / scale)

        // How much each side "flattens" toward its edge, ramped continuously with
        // how far the hole penetrates past that edge (0 = untouched circle, 1 =
        // fully flat to the edge). This avoids a snap when the cursor crosses the
        // radius threshold, and removes thin slivers near corners.
        func flatten(_ gap: Float) -> Float { 1 - max(0, min(1, (radius - gap) / radius)) }
        let mLeft = flatten(cx)
        let mRight = flatten(boundsW - cx)
        let mBottom = flatten(cy)
        let mTop = flatten(boundsH - cy)

        var buffer = [UInt8](repeating: 0, count: w * h * 4)
        buffer.withUnsafeMutableBufferPointer { buf in
            for row in 0..<h {
                let viewY = Float(h - row) * invScale   // row 0 = top of image = top of view
                for col in 0..<w {
                    let viewX = Float(col) * invScale

                    var dx = viewX - cx
                    dx *= (viewX < cx) ? mLeft : mRight
                    var dy = viewY - cy
                    dy *= (viewY < cy) ? mBottom : mTop

                    let d = (dx * dx + dy * dy).squareRoot()
                    let alpha: Float
                    if d <= radius {
                        alpha = coreAlpha
                    } else if d >= radius + fade {
                        alpha = 1
                    } else {
                        let u = (d - radius) / fade
                        let s = u * u * u * (u * (u * 6 - 15) + 10)  // smootherstep
                        alpha = coreAlpha + (1 - coreAlpha) * s
                    }

                    // Fade the whole hole out toward opaque when suppressed.
                    let finalAlpha = 1 - strength * (1 - alpha)
                    let v = UInt8(max(0, min(255, finalAlpha * 255)))
                    let idx = (row * w + col) * 4
                    buf[idx] = v; buf[idx + 1] = v; buf[idx + 2] = v; buf[idx + 3] = v
                }
            }
        }

        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let provider = CGDataProvider(data: Data(buffer) as CFData),
              let image = CGImage(
                width: w, height: h,
                bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: w * 4,
                space: colorSpace,
                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent
              ) else { return }

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        peekMaskLayer.frame = bounds
        peekMaskLayer.contents = image
        layer?.mask = peekMaskLayer
        CATransaction.commit()
    }

    /// Builds the low-res underlay for the loaded document and starts tracking
    /// the PDFView's scrolling so the underlay stays aligned.
    func documentDidLoad() {
        guard let page = pdfView.document?.page(at: 0) else { return }
        underlay.image = lowResImage(of: page)
        startPeekTracking()

        if let scrollView = pdfScrollView {
            // Allow free diagonal trackpad scrolling (no axis lock) and reduce the
            // rubber-band over-scroll. Keep PDFKit's own clip view so tile
            // rendering isn't broken while scrolling.
            scrollView.usesPredominantAxisScrolling = false
            scrollView.verticalScrollElasticity = .none
            scrollView.horizontalScrollElasticity = .none

            scrollView.contentView.postsBoundsChangedNotifications = true
            scrollObserver = NotificationCenter.default.addObserver(
                forName: NSView.boundsDidChangeNotification,
                object: scrollView.contentView,
                queue: .main
            ) { [weak self] _ in
                self?.updateUnderlayFrame()
            }
        }

        // If the PDFView's scale changes for any reason other than our own
        // fill-zoom (e.g. a native trackpad pinch), treat it as user control so
        // applyFillZoom stops resetting it back to the fill scale.
        // queue: nil so the handler runs synchronously on the posting (main)
        // thread — this way `isAdjustingZoom` is still true during our own
        // fill-zoom and we don't mistake it for a user zoom.
        scaleObserver = NotificationCenter.default.addObserver(
            forName: .PDFViewScaleChanged,
            object: pdfView,
            queue: nil
        ) { [weak self] _ in
            guard let self, !self.isAdjustingZoom else { return }
            self.userControlledView = true
            self.updateUnderlayFrame()
        }

        updateUnderlayFrame()
    }

    private var pdfScrollView: NSScrollView? {
        pdfView.subviews.compactMap { $0 as? NSScrollView }.first
    }

    /// Renders the page once at low resolution for the underlay.
    private func lowResImage(of page: PDFPage) -> NSImage {
        let box = page.bounds(for: .cropBox)
        let maxDimension: CGFloat = 2600
        let scale = min(maxDimension / max(box.width, box.height), 1)
        let size = NSSize(width: box.width * scale, height: box.height * scale)

        let image = NSImage(size: size)
        image.lockFocus()
        if let ctx = NSGraphicsContext.current?.cgContext {
            ctx.setFillColor(NSColor.white.cgColor)
            ctx.fill(CGRect(origin: .zero, size: size))
            ctx.scaleBy(x: scale, y: scale)
            ctx.translateBy(x: -box.minX, y: -box.minY)
            page.draw(with: .cropBox, to: ctx)
        }
        image.unlockFocus()
        return image
    }

    /// Positions the underlay so it exactly overlays the page at the current
    /// zoom and scroll offset.
    private func updateUnderlayFrame() {
        guard underlay.image != nil, let page = pdfView.document?.page(at: 0) else { return }
        let pageRectInPDFView = pdfView.convert(page.bounds(for: .cropBox), from: page)
        underlay.frame = convert(pageRectInPDFView, from: pdfView)
        scheduleSaveViewState()   // remember the current zoom/scroll (debounced)
    }

    /// Scales the page slightly past "fit" so the surrounding gray margins are
    /// cropped, and reapplies on every resize.
    private func applyFillZoom() {
        guard !isAdjustingZoom, !userControlledView,
              let page = pdfView.document?.page(at: 0) else { return }
        let scale = fillScale(for: page)
        guard scale > 0 else { return }

        isAdjustingZoom = true
        pdfView.autoScales = false
        pdfView.scaleFactor = scale
        // Use the *actual* applied scale (PDFView may clamp it) so the anchor math
        // matches, then anchor the page bottom to the view bottom and center
        // horizontally.
        let actualScale = pdfView.scaleFactor
        let bounds = page.bounds(for: .cropBox)
        let halfViewInPage = (visibleSize.height / 2) / actualScale
        center(on: NSPoint(x: bounds.midX, y: bounds.minY + halfViewInPage), page: page)
        isAdjustingZoom = false
    }

    /// Scale that *covers* the visible container with the page (crops the excess
    /// rather than letterboxing), so there's never a gray band regardless of the
    /// window's aspect ratio.
    private func fillScale(for page: PDFPage) -> CGFloat {
        let r = page.bounds(for: .cropBox)
        var w = r.width, h = r.height
        if page.rotation == 90 || page.rotation == 270 { swap(&w, &h) }
        guard w > 0, h > 0 else { return pdfView.scaleFactor }
        return max(visibleSize.width / w, visibleSize.height / h) * fillZoom
    }

    func showFindBar() {
        findBar.isHidden = false
        window?.makeFirstResponder(searchField)
        searchField.selectText(nil)
        if !searchField.stringValue.isEmpty {
            runSearch(term: searchField.stringValue)
        }
    }

    @objc private func hideFindBar() {
        findBar.isHidden = true
        searchDebounce?.invalidate()
        // Keep the current zoom/scroll position — don't reset to the fill view.
        matches = []
        currentMatch = -1
        countLabel.stringValue = ""
        pdfView.highlightedSelections = nil
        pdfView.setCurrentSelection(nil, animate: false)
        window?.makeFirstResponder(pdfView)
    }

    /// Debounces keystrokes so we don't run a full-document search on every
    /// character (which lags noticeably on the first keystroke of a large PDF).
    private func scheduleSearch(term: String) {
        searchDebounce?.invalidate()
        searchDebounce = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: false) { [weak self] _ in
            self?.runSearch(term: term)
        }
    }

    private func runSearch(term: String) {

        let trimmed = term.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !trimmed.isEmpty, let document = pdfView.document else {
            matches = []
            currentMatch = -1
            countLabel.stringValue = ""
            pdfView.highlightedSelections = nil
            return
        }

        // Run the (potentially slow) find off the main thread; only the newest
        // query's results are applied.
        searchGeneration += 1
        let generation = searchGeneration
        countLabel.stringValue = "…"

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let found = document.findString(trimmed, withOptions: .caseInsensitive)
            DispatchQueue.main.async {
                guard let self, generation == self.searchGeneration else { return }
                self.matches = found
                self.pdfView.highlightedSelections = found.isEmpty ? nil : found

                if found.isEmpty {
                    self.currentMatch = -1
                    self.countLabel.stringValue = "Not found"
                } else {
                    self.currentMatch = 0
                    self.focusCurrentMatch(zoom: false)
                }
            }
        }
    }

    /// Reveals the current match. Live typing (`zoom: false`) centers on it at the
    /// current zoom (never zooms out); stepping through results (`zoom: true`)
    /// zooms in on the match.
    private func focusCurrentMatch(zoom: Bool) {
        guard matches.indices.contains(currentMatch) else { return }
        let selection = matches[currentMatch]
        pdfView.setCurrentSelection(selection, animate: true)
        countLabel.stringValue = "\(currentMatch + 1) of \(matches.count)"

        guard let page = selection.pages.first else { return }
        let b = selection.bounds(for: page)
        if zoom {
            zoomToMatch(selection, on: page)
        } else {
            animateView(
                toScale: pdfView.scaleFactor,
                toCenter: NSPoint(x: b.midX, y: b.midY),
                on: page,
                duration: 0.25
            )
        }
    }

    @objc private func goNext() {
        guard !matches.isEmpty else { return }
        currentMatch = (currentMatch + 1) % matches.count
        focusCurrentMatch(zoom: true)
    }

    @objc private func goPrevious() {
        guard !matches.isEmpty else { return }
        currentMatch = (currentMatch - 1 + matches.count) % matches.count
        focusCurrentMatch(zoom: true)
    }

    /// Smoothly zooms in and centers on the given match so the highlighted text
    /// is comfortably readable.
    private func zoomToMatch(_ selection: PDFSelection, on page: PDFPage) {
        let bounds = selection.bounds(for: page)
        guard bounds.width > 0, bounds.height > 0 else {
            pdfView.go(to: selection)
            return
        }
        let viewSize = visibleSize
        // Smaller fractions -> more surrounding context (less tight zoom).
        let widthScale = (viewSize.width * 0.14) / bounds.width
        let heightScale = (viewSize.height * 0.07) / bounds.height
        let baseline = fillScale(for: page)
        let target = min(max(min(widthScale, heightScale), baseline), 6.0)

        animateView(
            toScale: target,
            toCenter: NSPoint(x: bounds.midX, y: bounds.midY),
            on: page,
            duration: 0.3
        )
    }

    /// Smoothly zooms in/out by `factor`. The animation is done with a GPU layer
    /// transform on the already-rendered content (no per-frame PDFKit re-tiling,
    /// so no white flicker); the real scaleFactor is committed once at the end.
    private func smoothZoom(by factor: CGFloat) {
        let starting = (zoomTimer == nil)
        let base = starting ? pdfView.scaleFactor : zoomTargetScale
        zoomTargetScale = min(max(base * factor, 0.05), 8.0)
        userControlledView = true
        guard starting else { return }   // key-repeat just extends the target

        // Hide the peek hole while zooming, and bring the (opaque, hi-res) underlay
        // in front so it covers PDFKit's blank white tiles during re-render.
        isZooming = true
        layer?.mask = nil
        underlay.layer?.zPosition = 1

        zoomTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60.0, repeats: true) { [weak self] timer in
            guard let self else { timer.invalidate(); return }
            let current = self.pdfView.scaleFactor
            let next = current + (self.zoomTargetScale - current) * 0.28

            self.isAdjustingZoom = true
            self.pdfView.scaleFactor = next
            self.isAdjustingZoom = false
            self.pdfView.layoutSubtreeIfNeeded()
            self.updateUnderlayFrame()

            if abs(self.zoomTargetScale - next) < 0.002 {
                self.isAdjustingZoom = true
                self.pdfView.scaleFactor = self.zoomTargetScale
                self.isAdjustingZoom = false
                self.pdfView.layoutSubtreeIfNeeded()
                self.updateUnderlayFrame()
                timer.invalidate()
                self.zoomTimer = nil
                self.isZooming = false
                // Cross-fade the in-front underlay out while PDFKit renders under it,
                // so there's no hard reveal of unrendered (white) tiles.
                NSAnimationContext.runAnimationGroup({ context in
                    context.duration = 0.55
                    self.underlay.animator().alphaValue = 0
                }, completionHandler: { [weak self] in
                    guard let self else { return }
                    self.underlay.layer?.zPosition = 0
                    self.underlay.alphaValue = 1
                })
                self.updatePeekMask()   // restore the peek hole at the cursor
            }
        }
    }

    /// Smoothly slides the view by a fraction of the visible area in a direction,
    /// scrolling only the requested axis so a horizontal pan never nudges the
    /// vertical position (and vice-versa). `dx`/`dy` are -1, 0, or 1; +y is up.
    /// Public entry point for the global ⌥⌘+arrow shortcut.
    func panBy(dx: CGFloat, dy: CGFloat) {
        pan(dx: dx, dy: dy)
    }

    /// Public entry point for the global ⌥⌘ +/- zoom shortcut.
    func zoomBy(_ factor: CGFloat) {
        smoothZoom(by: factor)
    }

    private func pan(dx: CGFloat, dy: CGFloat) {
        guard let scrollView = pdfScrollView else { return }
        let clip = scrollView.contentView
        let visible = clip.bounds
        let step: CGFloat = 0.3

        // Arrow-key panning is a fixed direction (not affected by Invert Pan).
        var origin = visible.origin
        origin.x += dx * visible.width * step
        origin.y += dy * visible.height * step

        let docSize = scrollView.documentView?.frame.size ?? visible.size
        origin.x = min(max(0, origin.x), max(0, docSize.width - visible.width))
        origin.y = min(max(0, origin.y), max(0, docSize.height - visible.height))

        userControlledView = true
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.22
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            clip.animator().setBoundsOrigin(origin)
        }, completionHandler: { [weak self] in
            scrollView.reflectScrolledClipView(clip)
            self?.updateUnderlayFrame()
        })
    }

    /// Moves the whole window around the screen (Cmd+Shift+arrows). +y is up.
    private func moveWindow(dx: CGFloat, dy: CGFloat) {
        guard let window else { return }
        let step: CGFloat = 90
        var origin = window.frame.origin
        origin.x += dx * step
        origin.y += dy * step
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.12
            window.animator().setFrameOrigin(origin)
        }
    }

    /// Shared eased animator that interpolates scale and view-center together.
    private func animateView(
        toScale targetScale: CGFloat,
        toCenter endCenter: NSPoint,
        on page: PDFPage,
        duration: TimeInterval
    ) {
        userControlledView = true

        let startScale = pdfView.scaleFactor
        let startCenter = currentCenter(on: page)
        let startTime = Date()

        zoomTimer?.invalidate()
        zoomTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60.0, repeats: true) { [weak self] timer in
            guard let self else { timer.invalidate(); return }

            let progress = min(Date().timeIntervalSince(startTime) / duration, 1.0)
            let eased = self.easeInOut(CGFloat(progress))

            self.isAdjustingZoom = true
            self.pdfView.scaleFactor = startScale + (targetScale - startScale) * eased
            self.isAdjustingZoom = false

            let center = NSPoint(
                x: startCenter.x + (endCenter.x - startCenter.x) * eased,
                y: startCenter.y + (endCenter.y - startCenter.y) * eased
            )
            self.center(on: center, page: page)

            if progress >= 1.0 {
                timer.invalidate()
                self.zoomTimer = nil
            }
        }
    }

    /// The page-space point currently at the center of the view.
    private func currentCenter(on page: PDFPage) -> NSPoint {
        let viewCenter = NSPoint(x: pdfView.bounds.midX, y: pdfView.bounds.midY)
        return pdfView.convert(viewCenter, to: page)
    }

    /// Scrolls so the given page-space point is centered in the view.
    private func center(on point: NSPoint, page: PDFPage) {
        let visibleWidth = pdfView.bounds.width / pdfView.scaleFactor
        let visibleHeight = pdfView.bounds.height / pdfView.scaleFactor
        let topLeft = NSPoint(
            x: point.x - visibleWidth / 2,
            y: point.y + visibleHeight / 2
        )
        pdfView.go(to: PDFDestination(page: page, at: topLeft))
        updateUnderlayFrame()
    }

    deinit {
        if let scrollObserver {
            NotificationCenter.default.removeObserver(scrollObserver)
        }
        if let scaleObserver {
            NotificationCenter.default.removeObserver(scaleObserver)
        }
        for monitor in mouseMonitors {
            NSEvent.removeMonitor(monitor)
        }
        for observer in focusObservers {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    private func easeInOut(_ t: CGFloat) -> CGFloat {
        return t < 0.5 ? 2 * t * t : 1 - pow(-2 * t + 2, 2) / 2
    }

    /// Restores the full-page fill view (used when the search is cleared/closed).
    private func resetZoom() {
        zoomTimer?.invalidate()
        zoomTimer = nil
        userControlledView = false
        applyFillZoom()
    }
}

extension MapContainerView: NSSearchFieldDelegate {

    func controlTextDidChange(_ notification: Notification) {
        scheduleSearch(term: searchField.stringValue)
    }

    func control(
        _ control: NSControl,
        textView: NSTextView,
        doCommandBy commandSelector: Selector
    ) -> Bool {
        switch commandSelector {
        case #selector(NSResponder.insertNewline(_:)),
             #selector(NSResponder.moveDown(_:)):
            goNext()
            return true
        case #selector(NSResponder.moveUp(_:)):
            goPrevious()
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            hideFindBar()
            return true
        default:
            return false
        }
    }
}

final class MapWindowController: NSObject {

    static let shared = MapWindowController()
    private var window: NSWindow?
    private var pdfView: PDFView?
    private var container: MapContainerView?

    // 3×3 grid position: column 0=left,1=center,2=right; row 0=top,1=middle,2=bottom.
    // Default matches the top-right launch position.
    private var gridCol = 2
    private var gridRow = 0

    var isMapVisible: Bool { window?.isVisible ?? false }

    private func postVisibilityChanged() {
        NotificationCenter.default.post(name: .mmMapVisibilityChanged, object: nil)
    }

    /// Ensures the map window exists and is frontmost. Returns the live PDFView,
    /// or nil if the PDF could not be opened.
    @discardableResult
    func show(activate: Bool = true) -> PDFView? {

        guard let url = MapFileManager.shared.resolveMapURL() else {

            SetupWindowController.shared.show {
                self.show()
            }

            return nil
        }

        if let existing = window {
            presentWindow(existing, activate: activate, finalAlpha: AppSettings.shared.baseAlpha)
            postVisibilityChanged()
            return pdfView
        }

        guard MapFileManager.shared.startAccessing(url) else {
            showFileError()
            return nil
        }

        guard let document = PDFDocument(url: url) else {
            MapFileManager.shared.stopAccessing(url)
            showFileError()
            return nil
        }

        let container = MapContainerView()
        let pdfView = container.pdfView

        pdfView.document = document
        pdfView.autoScales = false   // we manage scale via applyFillZoom (cover fit)
        pdfView.displayMode = .singlePage
        pdfView.displayDirection = .horizontal
        // Transparent so unrendered tiles reveal the low-res underlay instead of
        // flashing white.
        pdfView.backgroundColor = .clear
        // No page-break margins/shadows, so there is no blank padding to scroll
        // into above/below the page.
        pdfView.displaysPageBreaks = false
        pdfView.displayBox = .cropBox
        // Allow very small/large scales so our cover-fit isn't clamped.
        pdfView.minScaleFactor = 0.02
        pdfView.maxScaleFactor = 8.0

        container.documentDidLoad()

        let contentSize = Self.contentSize(for: document)

        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: contentSize),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )

        window.title = "Stanford Metabolic Map"
        window.contentView = container
        // Initial size uses the page's aspect ratio, but the window is free to be
        // resized to any shape afterward. The minimum is a small square so the
        // window can shrink well below the page ratio on either axis.
        let minDimension = min(contentSize.width, contentSize.height) / 3
        window.contentMinSize = NSSize(width: minDimension, height: minDimension)

        // Hide the title bar; let the map fill to the top edge. Traffic-light
        // buttons remain (floating over the content) so the window can still be
        // moved and closed.
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.styleMask.insert(.fullSizeContentView)

        // Transparent background so the container's rounded corners are visible.
        window.isOpaque = false
        window.backgroundColor = .clear
        // No drop shadow (it renders as a black outline, incl. around the peek hole).
        window.hasShadow = false

        // Remove the green zoom/fullscreen and orange minimize buttons.
        window.standardWindowButton(.zoomButton)?.isHidden = true
        window.standardWindowButton(.miniaturizeButton)?.isHidden = true

        window.acceptsMouseMovedEvents = true
        // Position in the top-right corner of the screen.
        if let visibleFrame = NSScreen.main?.visibleFrame {
            let margin: CGFloat = 20
            let frame = window.frame
            window.setFrameOrigin(NSPoint(
                x: visibleFrame.maxX - frame.width - margin,
                y: visibleFrame.maxY - frame.height - margin
            ))
        } else {
            window.center()
        }
        window.isReleasedWhenClosed = false
        window.delegate = self

        self.window = window
        self.pdfView = pdfView
        self.container = container

        applyClickThrough()
        presentWindow(window, activate: activate, finalAlpha: AppSettings.shared.baseAlpha)
        postVisibilityChanged()
        return pdfView
    }

    func applyBaseTransparency() {
        guard let window, window.isVisible else { return }
        window.animator().alphaValue = AppSettings.shared.baseAlpha
    }

    /// Shows the map (if needed) and opens the in-map find bar. Used by ⌥⌘S.
    func openFind() {
        show()
        container?.showFindBar()
    }

    /// Computes an initial content size matching the aspect ratio of the PDF's
    /// first page, scaled to comfortably fit the active screen.
    private static func contentSize(for document: PDFDocument) -> NSSize {

        let fallback = NSSize(width: 1200, height: 850)

        guard let page = document.page(at: 0) else { return fallback }

        let pageRect = page.bounds(for: .cropBox)
        guard pageRect.width > 0, pageRect.height > 0 else { return fallback }

        // Account for page rotation (90°/270° swaps width and height).
        var pageSize = NSSize(width: pageRect.width, height: pageRect.height)
        if page.rotation == 90 || page.rotation == 270 {
            pageSize = NSSize(width: pageRect.height, height: pageRect.width)
        }

        let visible = NSScreen.main?.visibleFrame.size ?? NSSize(width: 1440, height: 900)
        let maxWidth = visible.width * 0.9
        let maxHeight = visible.height * 0.9

        // Shrink the default window to 1/3 of the fit size (half the previous default).
        let scale = min(maxWidth / pageSize.width, maxHeight / pageSize.height, 1) * (1.0 / 3.0)

        return NSSize(
            width: (pageSize.width * scale).rounded(),
            height: (pageSize.height * scale).rounded()
        )
    }

    /// Opens the map (if needed) and scrolls to / highlights every occurrence of
    /// `term` on the given zero-based page index.
    func showResult(term: String, pageIndex: Int) {

        guard let pdfView = show(),
              let document = pdfView.document,
              pageIndex >= 0, pageIndex < document.pageCount,
              let page = document.page(at: pageIndex)
        else {
            return
        }

        pdfView.go(to: page)

        let matches = document
            .findString(term, withOptions: [.caseInsensitive])
            .filter { $0.pages.contains(page) }

        pdfView.highlightedSelections = matches.isEmpty ? nil : matches

        if let first = matches.first {
            pdfView.setCurrentSelection(first, animate: true)
            pdfView.go(to: first)
        }
    }

    /// Same ⌥⌘M shortcut: hide the map if it's showing, otherwise show it on top
    /// WITHOUT stealing focus from the current app.
    func toggle() {
        if let window, window.isVisible {
            container?.saveViewState()
            fadeOutWindow(window) { [weak self] in self?.postVisibilityChanged() }
        } else {
            show(activate: false)
        }
    }

    func close() {
        window?.close()
        window = nil
        pdfView = nil
        container = nil
    }

    func setAlwaysOnTop(_ on: Bool) {
        window?.level = on ? .floating : .normal
    }

    /// Applies click-through: window ignores mouse events and hides its buttons.
    func applyClickThrough() {
        guard let window else { return }
        let on = AppSettings.shared.clickThrough
        window.ignoresMouseEvents = on
        window.standardWindowButton(.closeButton)?.isHidden = on
        window.standardWindowButton(.zoomButton)?.isHidden = true
        window.standardWindowButton(.miniaturizeButton)?.isHidden = true
    }

    func refreshPeek() {
        container?.peekSettingChanged()
    }

    /// Pans the map from the global ⌥⌘+arrow shortcut (no-op if map isn't open).
    func panFromShortcut(dx: CGFloat, dy: CGFloat) {
        container?.panBy(dx: dx, dy: dy)
    }

    /// Zooms the map from the global ⌥⌘ +/- shortcut (no-op if map isn't open).
    func zoomFromShortcut(_ factor: CGFloat) {
        container?.zoomBy(factor)
    }

    /// Grows/shrinks the window from the global ⌃⌘ +/- shortcut, anchored to the
    /// top-right corner and clamped to the screen (never expands past the edge).
    func resizeWindowFromShortcut(_ factor: CGFloat) {
        guard let window, let screen = window.screen ?? NSScreen.main else { return }
        let f = window.frame
        let vf = screen.visibleFrame

        // The real Auto Layout minimum (driven by the find bar's width). Using
        // this as the floor means the window never snaps its width back afterward.
        let fitting = window.contentView?.fittingSize ?? NSSize(width: 240, height: 140)
        let minW = max(fitting.width, 200)
        let minH = max(fitting.height, 140)

        // Anchor horizontally so growing never pushes the window off-screen:
        //  • left edge  when the window hugs the left,
        //  • right edge when it hugs the right,
        //  • center     when it's roughly centered (grow symmetrically).
        let top = min(f.maxY, vf.maxY)
        let left = max(f.minX, vf.minX)
        let right = min(f.maxX, vf.maxX)
        let tol = max(24, f.width * 0.1)   // "centered" slop
        enum HA { case left, center, right }
        let ha: HA = abs(f.midX - vf.midX) <= tol ? .center
                   : (f.midX < vf.midX ? .left : .right)

        // Space available for growth given the anchor (center is limited by the
        // tighter of the two sides, doubled).
        let availW: CGFloat
        switch ha {
        case .left:   availW = vf.maxX - left
        case .right:  availW = right - vf.minX
        case .center: availW = 2 * min(f.midX - vf.minX, vf.maxX - f.midX)
        }

        // Uniform scale (preserve aspect) so the window never narrows on one axis
        // after the other hits its limit. Clamp the factor to the min size and the
        // available screen space, then stop if it can't change.
        var k = factor
        if factor < 1 {
            k = max(k, minW / f.width, minH / f.height)
        } else {
            k = min(k, availW / f.width, (top - vf.minY) / f.height)
        }
        guard abs(k - 1) > 0.001 else { return }

        let newW = f.width * k
        let newH = f.height * k
        let newX: CGFloat
        switch ha {
        case .left:   newX = left
        case .right:  newX = right - newW
        case .center: newX = f.midX - newW / 2
        }
        window.setFrame(NSRect(x: newX, y: top - newH, width: newW, height: newH), display: true)
    }

    /// Snaps the window to a cell of a 3×3 grid of screen positions (⌃⌘ + arrows).
    func snapToGrid(dCol: Int, dRow: Int) {
        guard let window, let screen = window.screen ?? NSScreen.main else { return }
        gridCol = min(2, max(0, gridCol + dCol))
        gridRow = min(2, max(0, gridRow + dRow))

        let vf = screen.visibleFrame
        let w = window.frame.width
        let h = window.frame.height
        let m: CGFloat = 20   // buffer from the screen edge (matches default open position)
        let xs = [vf.minX + m, vf.midX - w / 2, vf.maxX - w - m]
        let ys = [vf.maxY - h - m, vf.midY - h / 2, vf.minY + m]   // row 0 = top

        let origin = NSPoint(x: xs[gridCol], y: ys[gridRow])
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.14
            window.animator().setFrame(NSRect(origin: origin, size: window.frame.size), display: true)
        }
    }

    /// Moves the window from the global ⌥⌘⇧ + arrow shortcut. +y is up.
    func moveWindowFromShortcut(dx: CGFloat, dy: CGFloat) {
        guard let window else { return }
        let step: CGFloat = 90
        var origin = window.frame.origin
        origin.x += dx * step
        origin.y += dy * step
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.12
            window.animator().setFrameOrigin(origin)
        }
    }

    private func showFileError() {

        let alert = NSAlert()

        alert.messageText = "Unable to Open Metabolic Map"

        alert.informativeText = """
        The selected PDF could not be opened.

        You can select a different copy from the menu-bar icon.
        """

        alert.alertStyle = .warning
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }
}

extension MapWindowController: NSWindowDelegate {

    func windowWillClose(_ notification: Notification) {
        container?.saveViewState()
        window = nil
        pdfView = nil
        container = nil
        postVisibilityChanged()
    }
}


// MARK: - Options

final class OptionsWindowController: NSObject {

    static let shared = OptionsWindowController()
    private var window: NSWindow?
    private var hosting: NSHostingView<OptionsView>?

    func show() {
        if let window {
            presentWindow(window)
            return
        }

        let hosting = NSHostingView(rootView: OptionsView())
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 380, height: 220),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "Metabolic Map Options"
        window.contentView = hosting
        window.setContentSize(hosting.fittingSize)
        window.isReleasedWhenClosed = false
        window.center()
        window.delegate = self
        self.window = window
        self.hosting = hosting
        presentWindow(window)
    }

    /// Resizes the window to fit the current tab's content (keeping the top-left
    /// corner fixed, since the title bar is at the top).
    func fitToContent() {
        guard let window, let hosting else { return }
        let size = hosting.fittingSize
        var frame = window.frame
        let top = frame.maxY
        frame.size.height = size.height + (frame.height - window.contentLayoutRect.height)
        frame.size.width = size.width
        frame.origin.y = top - frame.size.height   // keep top edge fixed
        window.setFrame(frame, display: true, animate: false)
    }
}

extension OptionsWindowController: NSWindowDelegate {
    func windowWillClose(_ notification: Notification) {
        window = nil
    }
}

struct OptionsView: View {

    @ObservedObject private var updater = UpdateChecker.shared
    @State private var tab = 0

    var body: some View {
        VStack(spacing: 0) {

            Picker("", selection: $tab) {
                Text("General").tag(0)
                Text("Shortcuts").tag(1)
                Text("Animation").tag(2)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .controlSize(.small)
            .frame(width: 260)
            .padding(.top, 8)
            .padding(.bottom, 6)
            .onChange(of: tab) {
                DispatchQueue.main.async { OptionsWindowController.shared.fitToContent() }
            }

            Group {
                switch tab {
                case 1: ShortcutOptionsView()
                case 2: AnimationOptionsView()
                default: GeneralOptionsView()
                }
            }
            .frame(maxWidth: .infinity, minHeight: 300, maxHeight: 300, alignment: .top)
            .font(.system(size: 11))
            .controlSize(.small)
            .padding(.horizontal, 16)
            .padding(.bottom, 14)

            Divider()
                .padding(.horizontal, 12)

            HStack {
                if updater.installing {
                    Text("Updating…")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                } else if updater.updateAvailable {
                    Button("Update to v\(updater.latestVersion)") {
                        updater.performUpdate()
                    }
                    .controlSize(.small)
                }

                Spacer()

                Link("v\(updater.currentVersion)",
                     destination: URL(string: "https://github.com/cjreplogle/metabolic-map-hotkey")!)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .padding(.trailing, 4)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
        .frame(width: 320)
    }
}

struct GeneralOptionsView: View {

    @ObservedObject private var settings = AppSettings.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {

            Toggle("Launch at Login", isOn: $settings.launchAtLogin)
                .padding(.top, 8)
            Toggle("Always on Top", isOn: $settings.alwaysOnTop)
            Toggle("Peek-Through", isOn: $settings.peekEnabled)
            Toggle("Invert Pan", isOn: $settings.invertPan)
            Toggle("Click-Through (keyboard-only)", isOn: $settings.clickThrough)

            Divider()
                .padding(.top, 8)

            Text("PEEK-THROUGH")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text("Radius")
                    Spacer()
                    Text("\(Int(settings.peekRadius)) pt")
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                Slider(value: $settings.peekRadius, in: 30...260)
                    .controlSize(.mini)
            }

            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text("Peek-Through Transparency")
                    Spacer()
                    Text("\(Int(settings.peekTransparency * 100))%")
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                Slider(value: $settings.peekTransparency, in: 0...1)
                    .controlSize(.mini)
            }
            .disabled(!settings.peekEnabled)

            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text("Base Transparency")
                    Spacer()
                    Text("\(Int(settings.baseTransparency * 100))%")
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                Slider(value: $settings.baseTransparency, in: 0...0.9)
                    .controlSize(.mini)
            }


            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text("Edge Fade")
                    Spacer()
                    Text("\(Int(settings.peekFade)) pt")
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                Slider(value: $settings.peekFade, in: 0...200)
                    .controlSize(.mini)
            }
            .disabled(!settings.peekEnabled)

            Text("Hover near the map to preview.")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)

            Spacer(minLength: 8)

            HStack(spacing: 16) {
                Button("Change Map PDF…") { changePDF() }
                Link(
                    "Download Stanford Map",
                    destination: URL(string: "https://mededucation.stanford.edu/pathways-download/")!
                )
            }
            .frame(maxWidth: .infinity, alignment: .center)
        }
    }

    private func changePDF() {
        MapFileManager.shared.chooseMap { success in
            if success {
                DispatchQueue.main.async { MapWindowController.shared.close() }
            }
        }
    }
}

struct ShortcutOptionsView: View {

    @ObservedObject private var settings = AppSettings.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {

            Text("Click a field, then press the new key combination (include a modifier such as ⌘ or ⌥).")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            row(title: "Show / hide map", label: settings.mapLabel) { code, mods, label in
                settings.mapKeyCode = code
                settings.mapModifiers = mods
                settings.mapLabel = label
            }

            row(title: "Open find bar", label: settings.findLabel) { code, mods, label in
                settings.findKeyCode = code
                settings.findModifiers = mods
                settings.findLabel = label
            }

            Divider()

            Text("OTHER SHORTCUTS")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)

            reference("Pan the map", "⌥⌘ + arrows")
            reference("Zoom in / out", "⌥⌘ + / −")
            reference("Resize window", "⌃⌘ + / −")
            reference("Move window (grid)", "⌃⌘ + arrows")
            reference("Return focus to last app", "⌥⌘B")
            reference("Find in map (when focused)", "⌘F")
        }
    }

    private func reference(_ title: String, _ keys: String) -> some View {
        HStack {
            Text(title)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
            Spacer()
            Text(keys)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
        }
    }

    private func row(
        title: String,
        label: String,
        onCapture: @escaping (Int, UInt, String) -> Void
    ) -> some View {
        HStack {
            Text(title)
            Spacer()
            ShortcutRecorder(label: label, onCapture: onCapture)
                .frame(width: 110, height: 22)
        }
    }
}

struct AnimationOptionsView: View {

    @ObservedObject private var settings = AppSettings.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {

            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text("Metabolism Speed")
                    Spacer()
                    Text(String(format: "%.1f /s", settings.metabolismStepsPerSecond))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                Slider(value: $settings.metabolismSpeed, in: 0...1)
                    .disabled(settings.iconMode == .alwaysPause)
            }

            Toggle("Color atoms (O red · P green · S purple)", isOn: $settings.colorOxygen)
            Toggle("Full carboxylate groups (TCA)", isOn: $settings.fullCarboxylate)
            Toggle("Slide window in/out from corner", isOn: $settings.slideAnimation)

            Text("The menu-bar icon walks glycolysis, the TCA cycle, the HMP shunt, and CoA-linked steps.")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                Text("Play")
                Spacer()
                Picker("", selection: $settings.iconModeRaw) {
                    ForEach(IconMode.allCases) { mode in
                        Text(mode.label).tag(mode.rawValue)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
            }
        }
    }
}

// MARK: - Shortcut recorder

struct ShortcutRecorder: NSViewRepresentable {
    let label: String
    let onCapture: (Int, UInt, String) -> Void

    func makeNSView(context: Context) -> RecorderButton {
        let button = RecorderButton()
        button.bezelStyle = .rounded
        button.controlSize = .small
        button.onCapture = onCapture
        button.title = label
        return button
    }

    func updateNSView(_ nsView: RecorderButton, context: Context) {
        nsView.onCapture = onCapture
        if !nsView.isRecording { nsView.title = label }
    }
}

final class RecorderButton: NSButton {
    var onCapture: ((Int, UInt, String) -> Void)?
    private(set) var isRecording = false
    private var monitor: Any?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        target = self
        action = #selector(toggleRecording)
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        target = self
        action = #selector(toggleRecording)
    }

    @objc private func toggleRecording() {
        isRecording ? stopRecording() : startRecording()
    }

    private func startRecording() {
        isRecording = true
        title = "Press keys…"
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
            guard let self else { return event }
            let mods = event.modifierFlags.intersection([.command, .option, .control, .shift])
            if event.keyCode == 53 { self.stopRecording(); return nil }  // Esc cancels
            guard !mods.isEmpty else { return nil }                       // require a modifier

            let name = RecorderButton.keyName(for: Int(event.keyCode), chars: event.charactersIgnoringModifiers)
            let label = shortcutLabel(keyCode: Int(event.keyCode), modifiers: mods.rawValue, keyName: name)
            self.onCapture?(Int(event.keyCode), mods.rawValue, label)
            self.title = label
            self.stopRecording()
            return nil
        }
    }

    private func stopRecording() {
        isRecording = false
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }

    static func keyName(for keyCode: Int, chars: String?) -> String {
        let specials: [Int: String] = [
            123: "←", 124: "→", 125: "↓", 126: "↑",
            49: "Space", 36: "↩", 48: "⇥", 53: "⎋", 51: "⌫", 117: "⌦"
        ]
        if let s = specials[keyCode] { return s }
        if let c = chars, !c.isEmpty, c != " " { return c.uppercased() }
        return "•"
    }
}
