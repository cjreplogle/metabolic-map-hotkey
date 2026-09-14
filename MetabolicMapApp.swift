import Cocoa
import SwiftUI
import PDFKit

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

/// App-wide user settings shared across windows.
enum AppSettings {
    static var alwaysOnTop = false
    static var peekEnabled = true
}

/// Brings a window to the front so it can appear over another app's full-screen
/// Space, then drops it back to a normal window level so it is not permanently
/// pinned above every other window.
func presentWindow(_ window: NSWindow) {
    window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
    window.level = .floating
    // Fade in.
    window.alphaValue = 0
    window.makeKeyAndOrderFront(nil)
    NSApplication.shared.activate(ignoringOtherApps: true)
    NSAnimationContext.runAnimationGroup { context in
        context.duration = 0.2
        context.timingFunction = CAMediaTimingFunction(name: .easeOut)
        window.animator().alphaValue = 1
    }

    DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
        // Drop back to a normal level unless the user pinned it on top.
        if !AppSettings.alwaysOnTop {
            window.level = .normal
        }
    }
}

/// Fades a window out, then orders it out (keeping the instance).
func fadeOutWindow(_ window: NSWindow, completion: (() -> Void)? = nil) {
    NSAnimationContext.runAnimationGroup({ context in
        context.duration = 0.18
        context.timingFunction = CAMediaTimingFunction(name: .easeIn)
        window.animator().alphaValue = 0
    }, completionHandler: {
        window.orderOut(nil)
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

    // Virtual Key Codes: M = 46, S = 1
    private let mKeyCode: Int64 = 46
    private let sKeyCode: Int64 = 1

    // Required modifiers for the global shortcuts: Option + Command.
    private let requiredModifiers: CGEventFlags = [.maskAlternate, .maskCommand]
    // Modifiers we care about when deciding whether the chord matches exactly.
    private let trackedModifiers: CGEventFlags =
        [.maskAlternate, .maskCommand, .maskControl, .maskShift]

    private init() {}

    func start() {
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

            guard mods == manager.requiredModifiers else {
                return Unmanaged.passUnretained(event)
            }

            if keyCode == manager.mKeyCode {
                DispatchQueue.main.async { MapWindowController.shared.toggle() }
                return nil // consume so the key chord doesn't beep or fall through
            }

            if keyCode == manager.sKeyCode {
                DispatchQueue.main.async { MapWindowController.shared.openFind() }
                return nil
            }

            // ⌥⌘ + arrows pan the map globally (even when another app is focused).
            // Virtual key codes: left = 123, right = 124, down = 125, up = 126.
            switch keyCode {
            case 123: DispatchQueue.main.async { MapWindowController.shared.panFromShortcut(dx: -1, dy: 0) }; return nil
            case 124: DispatchQueue.main.async { MapWindowController.shared.panFromShortcut(dx: 1, dy: 0) }; return nil
            case 125: DispatchQueue.main.async { MapWindowController.shared.panFromShortcut(dx: 0, dy: -1) }; return nil
            case 126: DispatchQueue.main.async { MapWindowController.shared.panFromShortcut(dx: 0, dy: 1) }; return nil
            default: break
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

    func applicationDidFinishLaunching(_ notification: Notification) {

        if let icon = loadAppIcon() {
            NSApplication.shared.applicationIconImage = icon
        }

        GlobalShortcutManager.shared.start()

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
            let image = NSImage(
                systemSymbolName: "map",
                accessibilityDescription: "Metabolic Map"
            )
            image?.isTemplate = true
            button.image = image
            button.toolTip = "Metabolic Map"
        }

        let menu = NSMenu()

        addItem("Open Metabolic Map", action: #selector(openMap), to: menu)
        addItem("Search Map", action: #selector(searchMap), to: menu)

        menu.addItem(.separator())

        addItem("Change Map PDF…", action: #selector(changeMap), to: menu)
        addItem("Stanford Pathways Map (Download)…", action: #selector(openPathwaysMap), to: menu)

        menu.addItem(.separator())

        let alwaysOnTop = NSMenuItem(
            title: "Always on Top",
            action: #selector(toggleAlwaysOnTop(_:)),
            keyEquivalent: ""
        )
        alwaysOnTop.target = self
        alwaysOnTop.state = AppSettings.alwaysOnTop ? .on : .off
        menu.addItem(alwaysOnTop)

        let peek = NSMenuItem(
            title: "Peek-Through",
            action: #selector(togglePeek(_:)),
            keyEquivalent: ""
        )
        peek.target = self
        peek.state = AppSettings.peekEnabled ? .on : .off
        menu.addItem(peek)

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

    @objc private func changeMap() {
        MapFileManager.shared.chooseMap { success in
            if success {
                DispatchQueue.main.async {
                    MapWindowController.shared.close()
                }
            }
        }
    }

    @objc private func openPathwaysMap() {
        // Opens the Stanford metabolic pathways map in the default browser so the
        // PDF can be downloaded. Update this URL if the canonical location moves.
        if let url = URL(string: "https://metabolicpathways.stanford.edu") {
            NSWorkspace.shared.open(url)
        }
    }

    @objc private func toggleAlwaysOnTop(_ sender: NSMenuItem) {
        AppSettings.alwaysOnTop.toggle()
        sender.state = AppSettings.alwaysOnTop ? .on : .off
        MapWindowController.shared.setAlwaysOnTop(AppSettings.alwaysOnTop)
    }

    @objc private func togglePeek(_ sender: NSMenuItem) {
        AppSettings.peekEnabled.toggle()
        sender.state = AppSettings.peekEnabled ? .on : .off
        MapWindowController.shared.refreshPeek()
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

/// Hosts the PDFView plus an in-window ⌘F find bar (search field, prev/next,
/// and a live "n of m" match count).
final class MapContainerView: NSView {

    let pdfView = PDFView()

    // A low-resolution full-page render kept behind the PDFView. When the PDFView
    // hasn't drawn fresh tiles yet (e.g. right after a jump), the transparent
    // areas reveal this instead of flashing white.
    private let underlay = NSImageView()
    private var scrollObserver: NSObjectProtocol?
    private var scaleObserver: NSObjectProtocol?

    private let findBar = NSVisualEffectView()
    private let searchField = NSSearchField()
    private let countLabel = NSTextField(labelWithString: "")

    private var matches: [PDFSelection] = []
    private var currentMatch = -1
    private var searchDebounce: Timer?
    private var searchGeneration = 0
    private var zoomTimer: Timer?
    // Set once the user manually zooms/pans, so the auto fill-zoom on layout does
    // not fight/override their navigation. Cleared by resetZoom().
    private var userControlledView = false

    // "Peek hole": makes a circular region under the cursor transparent so you
    // can see whatever is behind the map window.
    private var mouseMonitors: [Any] = []
    private var peekCenter: NSPoint?
    private let peekRadius: CGFloat = 95   // fully-transparent core
    private let peekFade: CGFloat = 55     // soft fade band beyond the core
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
            searchField.widthAnchor.constraint(greaterThanOrEqualToConstant: 240)
        ])
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

        // Cmd + Shift + arrows : move the window itself around the screen.
        // (Virtual key codes: left = 123, right = 124, down = 125, up = 126.)
        if flags.contains(.command), flags.contains(.shift) {
            switch event.keyCode {
            case 123: moveWindow(dx: -1, dy: 0); return true
            case 124: moveWindow(dx: 1, dy: 0); return true
            case 125: moveWindow(dx: 0, dy: -1); return true
            case 126: moveWindow(dx: 0, dy: 1); return true
            default: break
            }
        }

        // Cmd + arrows : smooth pan in a direction (Virtual key codes:
        // left = 123, right = 124, down = 125, up = 126).
        if flags.contains(.command) {
            switch event.keyCode {
            case 123: pan(dx: -1, dy: 0); return true
            case 124: pan(dx: 1, dy: 0); return true
            case 125: pan(dx: 0, dy: -1); return true
            case 126: pan(dx: 0, dy: 1); return true
            default: break
            }
        }

        return super.performKeyEquivalent(with: event)
    }

    override func layout() {
        super.layout()
        applyFillZoom()
        updateUnderlayFrame()
        updatePeekMask()
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
    }

    private func handleMouseMoved() {
        guard AppSettings.peekEnabled, let window else {
            peekCenter = nil
            updatePeekMask()
            return
        }
        let viewPoint = convert(window.convertPoint(fromScreen: NSEvent.mouseLocation), from: nil)
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
        if !AppSettings.peekEnabled { peekCenter = nil }
        updatePeekMask()
    }

    private func updatePeekMask() {
        guard AppSettings.peekEnabled,
              let center = peekCenter, bounds.width > 1, bounds.height > 1 else {
            layer?.mask = nil
            return
        }

        let scale: CGFloat = 0.3
        let width = max(1, Int(bounds.width * scale))
        let height = max(1, Int(bounds.height * scale))

        guard let ctx = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return }

        let outerRadius = (peekRadius + peekFade) * scale
        let coreFraction = peekRadius / (peekRadius + peekFade)
        // Low (not zero) core alpha so the map stays faintly visible in the hole
        // while what's behind remains readable.
        let coreAlpha: CGFloat = 0.4
        let colors = [
            CGColor(red: 1, green: 1, blue: 1, alpha: coreAlpha),   // faint map in core
            CGColor(red: 1, green: 1, blue: 1, alpha: coreAlpha),
            CGColor(red: 1, green: 1, blue: 1, alpha: 1)            // fully opaque map
        ] as CFArray
        guard let gradient = CGGradient(
            colorsSpace: CGColorSpaceCreateDeviceRGB(),
            colors: colors,
            locations: [0, coreFraction, 1]
        ) else { return }

        let c = CGPoint(x: center.x * scale, y: center.y * scale)
        ctx.setBlendMode(.copy)
        ctx.drawRadialGradient(
            gradient,
            startCenter: c, startRadius: 0,
            endCenter: c, endRadius: outerRadius,
            options: [.drawsAfterEndLocation]
        )

        guard let image = ctx.makeImage() else { return }

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
        let maxDimension: CGFloat = 1600
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
                // New query: return to the full-page view; Enter/next will zoom.
                self.resetZoom()

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

    private func focusCurrentMatch(zoom: Bool) {
        guard matches.indices.contains(currentMatch) else { return }
        let selection = matches[currentMatch]
        pdfView.setCurrentSelection(selection, animate: true)
        countLabel.stringValue = "\(currentMatch + 1) of \(matches.count)"

        if zoom, let page = selection.pages.first {
            zoomToMatch(selection, on: page)
        } else {
            pdfView.go(to: selection)
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
        // Aim for the match to occupy a comfortable slice of the view, then clamp
        // to a sane zoom range so we never over- or under-shoot.
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

    /// Smoothly zooms in/out by `factor`, keeping the current view center fixed.
    private func smoothZoom(by factor: CGFloat) {
        guard let page = pdfView.currentPage else { return }
        let target = min(max(pdfView.scaleFactor * factor, 0.25), 8.0)
        animateView(
            toScale: target,
            toCenter: currentCenter(on: page),
            on: page,
            duration: 0.18
        )
    }

    /// Smoothly slides the view by a fraction of the visible area in a direction,
    /// scrolling only the requested axis so a horizontal pan never nudges the
    /// vertical position (and vice-versa). `dx`/`dy` are -1, 0, or 1; +y is up.
    /// Public entry point for the global ⌥⌘+arrow shortcut.
    func panBy(dx: CGFloat, dy: CGFloat) {
        pan(dx: dx, dy: dy)
    }

    private func pan(dx: CGFloat, dy: CGFloat) {
        guard let scrollView = pdfScrollView else { return }
        let clip = scrollView.contentView
        let visible = clip.bounds
        let step: CGFloat = 0.3

        var origin = visible.origin
        origin.x += dx * visible.width * step
        // Document view is flipped (top-left origin): scrolling "up" decreases y.
        origin.y -= dy * visible.height * step

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

    /// Ensures the map window exists and is frontmost. Returns the live PDFView,
    /// or nil if the PDF could not be opened.
    @discardableResult
    func show() -> PDFView? {

        guard let url = MapFileManager.shared.resolveMapURL() else {

            SetupWindowController.shared.show {
                self.show()
            }

            return nil
        }

        if let existing = window {
            presentWindow(existing)
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
        pdfView.autoScales = true
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

        presentWindow(window)
        return pdfView
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

    /// Same ⌥⌘M shortcut: hide only when the map is already the frontmost window;
    /// otherwise show it / bring it to the front (even if hidden or behind others).
    func toggle() {
        if let window, window.isVisible, window.isKeyWindow {
            fadeOutWindow(window)
        } else {
            show()
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

    func refreshPeek() {
        container?.peekSettingChanged()
    }

    /// Pans the map from the global ⌥⌘+arrow shortcut (no-op if map isn't open).
    func panFromShortcut(dx: CGFloat, dy: CGFloat) {
        container?.panBy(dx: dx, dy: dy)
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
        window = nil
        pdfView = nil
        container = nil
    }
}

