import AppKit
@preconcurrency import ApplicationServices
import SwiftUI
import Carbon

final class ClipboardPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    let store: ClipboardStore
    let state = PanelState()
    let shortcut = GlobalShortcut()
    var panel: ClipboardPanel!
    var status: NSStatusItem!
    var settingsWindow: NSWindow?
    var target: NSRunningApplication?
    var lastExternal: NSRunningApplication?
    var localMonitor: Any?
    var globalMonitor: Any?
    var activationObserver: NSObjectProtocol?
    var permissionTimer: Timer?
    var previewPath: String?
    var pasteGeneration = 0
    var pendingPID: pid_t?
    var positioning = false
    var positionWork: DispatchWorkItem?
    var sessionObservers: [NSObjectProtocol] = []
    var recordingObserver: NSObjectProtocol?
    var recordingShortcut = false

    init(previewPath: String? = nil) {
        self.previewPath = previewPath
        store = ClipboardStore(testMode: previewPath != nil)
        super.init()
    }
    func applicationDidFinishLaunching(_ notification: Notification) {
        if previewPath == nil {
            let other = NSRunningApplication.runningApplications(withBundleIdentifier: AppIdentity.bundleIdentifier).filter { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }
            if let existing = other.first { existing.activate(options: []); NSApp.terminate(nil); return }
        }
        NSApp.setActivationPolicy(.accessory)
        configureMenu()
        panel = ClipboardPanel(contentRect: NSRect(x: 0, y: 0, width: PanelLayout.width, height: PanelLayout.height), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.title = "Clipboard"
        panel.isFloatingPanel = true; panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isOpaque = false; panel.backgroundColor = .clear; panel.hasShadow = true
        panel.isMovableByWindowBackground = true
        panel.hidesOnDeactivate = false
        panel.delegate = self
        state.connect(store)
        let host = NSHostingView(rootView: ClipboardPanelView(store: store, state: state)
            .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous)))
        host.wantsLayer = true
        host.layer?.cornerRadius = 22
        host.layer?.cornerCurve = .continuous
        host.layer?.masksToBounds = true
        host.sizingOptions = []
        host.frame = NSRect(x: 0, y: 0, width: PanelLayout.width, height: PanelLayout.height)
        if #available(macOS 26.0, *) {
            let glass = NSGlassEffectView(frame: host.frame)
            glass.cornerRadius = 22; glass.style = .regular; glass.contentView = host
            glass.wantsLayer = true; glass.layer?.cornerRadius = 22
            glass.layer?.cornerCurve = .continuous; glass.layer?.masksToBounds = true
            panel.contentView = glass
        } else {
            let effect = NSVisualEffectView(frame: host.frame)
            effect.material = .popover; effect.blendingMode = .behindWindow; effect.state = .active
            effect.wantsLayer = true; effect.layer?.cornerRadius = 22; effect.layer?.cornerCurve = .continuous; effect.layer?.masksToBounds = true
            effect.addSubview(host); panel.contentView = effect
        }
        state.paste = { [weak self] clip, plain in self?.paste(clip, plain: plain) }
        state.settings = { [weak self] in self?.showSettings() }
        state.close = { [weak self] in self?.dismiss() }
        shortcut.action = { [weak self] in self?.toggle() }
        store.preferencesChanged = { [weak self] in self?.applyAppearance(); self?.updateStatus() }
        applyAppearance()
        if let previewPath {
            loadDemo(); state.show()
            panel.center(); panel.makeKeyAndOrderFront(nil)
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in self?.renderPreview(previewPath) }
            return
        }
        status = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        status.button?.image = NSImage(systemSymbolName: "clipboard", accessibilityDescription: "Clipboard")
        status.button?.target = self; status.button?.action = #selector(statusClicked(_:)); status.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
        updateStatus()
        if !shortcut.register(store.preferences.shortcut) { store.notice = "Your shortcut is already in use. Choose another in Settings." }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .leftMouseDown, .rightMouseDown]) { [weak self] event in
            guard let self else { return event }
            return self.handle(event)
        }
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            guard let self else { return }
            if self.pendingPID != nil { self.cancelPendingPaste() }
            guard self.panel.isVisible else { return }
            if !self.panel.frame.contains(NSEvent.mouseLocation) { self.dismiss() }
        }
        activationObserver = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] notification in
            let pid = (notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.processIdentifier
            MainActor.assumeIsolated {
                guard let self, let pid, let app = NSRunningApplication(processIdentifier: pid), pid != ProcessInfo.processInfo.processIdentifier else { return }
                self.lastExternal = app
                if let pending = self.pendingPID, pending != app.processIdentifier { self.cancelPendingPaste() }
            }
        }
        permissionTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.panel.isVisible || self.settingsWindow?.isVisible == true else { return }
                let trusted = AXIsProcessTrusted()
                if self.store.trusted != trusted { self.store.trusted = trusted }
            }
        }
        permissionTimer?.tolerance = 1
        for (name, suspended) in [(NSWorkspace.sessionDidResignActiveNotification, true), (NSWorkspace.sessionDidBecomeActiveNotification, false)] {
            sessionObservers.append(NSWorkspace.shared.notificationCenter.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.store.suspend(suspended); if suspended { self?.dismiss() } }
            })
        }
        recordingObserver = NotificationCenter.default.addObserver(forName: .clipboardShortcutRecording, object: nil, queue: .main) { [weak self] note in
            let recording = note.userInfo?["recording"] as? Bool ?? false
            MainActor.assumeIsolated {
                guard let self else { return }
                self.recordingShortcut = recording
                if self.recordingShortcut { self.shortcut.stop() } else { _ = self.shortcut.register(self.store.preferences.shortcut) }
            }
        }
        store.start()
        if !store.preferences.onboardingComplete {
            store.preferences.onboardingComplete = true; store.updatePreferences()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in self?.showSettings() }
        }
    }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool { show(); return false }
    func applicationWillTerminate(_ notification: Notification) {
        positionWork?.cancel(); savePosition(); cancelPendingPaste(); store.stop(); store.flush(); shortcut.stop(removeHandler: true)
        permissionTimer?.invalidate()
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }; if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
        if let activationObserver { NSWorkspace.shared.notificationCenter.removeObserver(activationObserver) }
        for observer in sessionObservers { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
        if let recordingObserver { NotificationCenter.default.removeObserver(recordingObserver) }
    }
    func configureMenu() {
        let main = NSMenu()
        let app = NSMenuItem(); main.addItem(app); let appMenu = NSMenu(); app.submenu = appMenu
        appMenu.addItem(withTitle: "Settings…", action: #selector(openSettings), keyEquivalent: ",").target = self
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit Clipboard", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        let edit = NSMenuItem(); main.addItem(edit); let editMenu = NSMenu(title: "Edit"); edit.submenu = editMenu
        for (title, selector, key) in [("Undo", "undo:", "z"), ("Cut", "cut:", "x"), ("Copy", "copy:", "c"), ("Paste", "paste:", "v"), ("Select All", "selectAll:", "a")] {
            editMenu.addItem(withTitle: title, action: Selector(selector), keyEquivalent: key)
        }
        NSApp.mainMenu = main
    }
    func updateStatus() {
        status?.button?.toolTip = "Clipboard · \(store.preferences.shortcut.label)\(store.preferences.captureEnabled ? "" : " · Paused")"
        status?.button?.image = NSImage(systemSymbolName: store.preferences.captureEnabled ? "clipboard" : "pause.rectangle", accessibilityDescription: "Clipboard")
    }
    @objc func statusClicked(_ sender: NSStatusBarButton) {
        if NSApp.currentEvent?.type == .rightMouseUp {
            let menu = NSMenu()
            menu.addItem(withTitle: "Open Clipboard   \(store.preferences.shortcut.label)", action: #selector(openClipboard), keyEquivalent: "").target = self
            menu.addItem(withTitle: store.preferences.captureEnabled ? "Pause Recording" : "Resume Recording", action: #selector(toggleRecording), keyEquivalent: "").target = self
            menu.addItem(withTitle: "Settings…", action: #selector(openSettings), keyEquivalent: "").target = self
            menu.addItem(.separator())
            menu.addItem(withTitle: "Quit Clipboard", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
            status.menu = menu; status.button?.performClick(nil); status.menu = nil
        } else { toggle() }
    }
    @objc func openClipboard() { show() }
    @objc func openSettings() { showSettings() }
    @objc func toggleRecording() { store.preferences.captureEnabled.toggle(); store.updatePreferences() }
    func toggle() { if panel.isVisible { dismiss() } else { show() } }
    func show() {
        cancelPendingPaste()
        let front = NSWorkspace.shared.frontmostApplication
        target = front?.processIdentifier == ProcessInfo.processInfo.processIdentifier ? lastExternal : front
        if let target { lastExternal = target }
        store.trusted = AXIsProcessTrusted()
        state.tab = .clipboard; state.query = ""; state.filter = "All"; state.showSearch = false; state.selection = 0
        state.show()
        state.presentation = UUID()
        let point = NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(point) }) ?? NSScreen.main else { return }
        let areas = NSScreen.screens.map(\.visibleFrame)
        var origin: NSPoint
        if UserDefaults.standard.object(forKey: "rememberPanelPosition") as? Bool != false,
           let data = UserDefaults.standard.data(forKey: "panelPosition"), let position = try? JSONDecoder().decode(SavedPosition.self, from: data) {
            let savedScreen = NSScreen.screens.first { ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? UInt32) == position.screen }
            origin = PositionRules.restored(position, visibleAreas: areas, preferredArea: savedScreen?.visibleFrame ?? screen.visibleFrame, size: panel.frame.size)
        } else {
            var x = point.x - PanelLayout.width / 2, y = point.y - PanelLayout.height - 16
            if let pid = target?.processIdentifier, store.trusted, let caret = caretBounds(pid) {
                x = caret.minX
                let top = NSScreen.screens.first?.frame.maxY ?? screen.visibleFrame.maxY
                let caretBottom = top - caret.maxY
                y = caretBottom - PanelLayout.height - 10
                if y < screen.visibleFrame.minY { y = caretBottom + caret.height + 8 }
            }
            origin = PositionRules.clamped(NSPoint(x: x, y: y), area: screen.visibleFrame, size: panel.frame.size)
        }
        positioning = true; panel.setFrameOrigin(origin); positioning = false
        panel.makeKeyAndOrderFront(nil)
    }
    func caretBounds(_ pid: pid_t) -> CGRect? {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.05)
        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXFocusedUIElementAttribute as CFString, &focused) == .success, let focused, CFGetTypeID(focused) == AXUIElementGetTypeID() else { return nil }
        let element = focused as! AXUIElement
        var selected: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &selected) == .success, let selected else { return nil }
        var bounds: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(element, kAXBoundsForRangeParameterizedAttribute as CFString, selected, &bounds) == .success, let bounds, CFGetTypeID(bounds) == AXValueGetTypeID() else { return nil }
        var rect = CGRect.zero
        guard AXValueGetValue(bounds as! AXValue, .cgRect, &rect), rect.height > 0 else { return nil }
        return rect
    }
    func cancelPendingPaste() { pasteGeneration &+= 1; pendingPID = nil }
    func dismiss() { savePosition(); cancelPendingPaste(); state.hide(); panel.orderOut(nil) }
    func savePosition() {
        guard let positionWork else { return }
        positionWork.perform(); positionWork.cancel(); self.positionWork = nil
    }
    func windowDidMove(_ notification: Notification) {
        guard !positioning, notification.object as? NSWindow == panel, panel.isVisible,
              let screen = panel.screen else { return }
        let position = SavedPosition(x: panel.frame.minX, y: panel.frame.minY, screen: screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? UInt32 ?? 0)
        positionWork?.cancel()
        let work = DispatchWorkItem { if let data = try? JSONEncoder().encode(position) { UserDefaults.standard.set(data, forKey: "panelPosition") } }
        positionWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: work)
    }
    func paste(_ clip: Clip, plain: Bool) {
        cancelPendingPaste()
        guard store.writeToPasteboard(clip, plain: plain || store.preferences.pastePlainText) else { return }
        let expectedChange = store.pasteboard.changeCount
        let destination = target
        dismiss()
        guard store.preferences.automaticPaste, AXIsProcessTrusted(), let destination, !destination.isTerminated else {
            store.notice = "Copied. Press ⌘V in your destination app."
            if store.preferences.automaticPaste, !AXIsProcessTrusted() { showPermissionHint() }
            return
        }
        pasteGeneration += 1
        let generation = pasteGeneration
        pendingPID = destination.processIdentifier
        destination.activate(options: [])
        // Wait for the destination to become active, and for shortcut modifiers to be released.
        attemptPaste(destination, expectedChange: expectedChange, generation: generation, attempt: 0)
    }
    func attemptPaste(_ destination: NSRunningApplication, expectedChange: Int, generation: Int, attempt: Int) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            guard let self, generation == self.pasteGeneration else { return }
            guard expectedChange == self.store.pasteboard.changeCount, !IsSecureEventInputEnabled(), !destination.isTerminated else {
                self.cancelPendingPaste(); self.store.notice = "Automatic paste cancelled because the clipboard or destination changed."; return
            }
            guard attempt < 30 else { self.cancelPendingPaste(); self.store.notice = "Copied. The destination wasn't ready; paste with ⌘V."; return }
            let released = NSEvent.modifierFlags.intersection([.command, .control, .option, .shift]).isEmpty
            if NSWorkspace.shared.frontmostApplication?.processIdentifier != destination.processIdentifier || !released {
                self.attemptPaste(destination, expectedChange: expectedChange, generation: generation, attempt: attempt + 1); return
            }
            let source = CGEventSource(stateID: .combinedSessionState)
            let down = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: true)
            let up = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: false)
            down?.flags = .maskCommand; up?.flags = .maskCommand
            guard PastePolicy.canSend(expectedChange: expectedChange, actualChange: self.store.pasteboard.changeCount, expectedPID: destination.processIdentifier, activePID: NSWorkspace.shared.frontmostApplication?.processIdentifier, secureInput: IsSecureEventInputEnabled(), modifiersReleased: released), let down, let up else { self.cancelPendingPaste(); return }
            down.postToPid(destination.processIdentifier); up.postToPid(destination.processIdentifier)
            self.pendingPID = nil
        }
    }
    func showPermissionHint() { status?.button?.toolTip = "Enable Clipboard in System Settings > Privacy & Security > Accessibility for automatic paste." }
    func requestAccessibility() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true]
        store.trusted = AXIsProcessTrustedWithOptions(options as CFDictionary)
        if !store.trusted { NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!) }
    }
    func showSettings() {
        dismiss()
        if settingsWindow == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 620, height: 660), styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
            window.title = "Clipboard Settings"; window.isReleasedWhenClosed = false; window.center()
            window.contentView = NSHostingView(rootView: SettingsView(store: store, changeShortcut: { [weak self] value in self?.changeShortcut(value) ?? false }, requestAccessibility: { [weak self] in self?.requestAccessibility() }))
            settingsWindow = window
        }
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
    }
    func changeShortcut(_ value: Shortcut) -> Bool {
        let previous = store.preferences.shortcut
        guard shortcut.register(value) else { if !recordingShortcut { _ = shortcut.register(previous) }; return false }
        store.preferences.shortcut = value; store.updatePreferences(); return true
    }
    func applyAppearance() {
        NSApp.appearance = store.preferences.appearance == "dark" ? NSAppearance(named: .darkAqua) : store.preferences.appearance == "light" ? NSAppearance(named: .aqua) : nil
    }
    func handle(_ event: NSEvent) -> NSEvent? {
        guard panel.isVisible, event.window == panel else { return event }
        guard event.type == .keyDown else { return event }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if event.keyCode == 53 { dismiss(); return nil }
        if flags.contains(.command), event.charactersIgnoringModifiers == "," { showSettings(); return nil }
        if flags.contains(.command), event.charactersIgnoringModifiers?.lowercased() == "f" { state.showSearch = true; return nil }
        if state.tab == .clipboard, !state.showSearch, flags.intersection([.command, .control, .option]).isEmpty,
           let characters = event.characters, !characters.isEmpty, event.keyCode != 36, characters.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }) {
            state.showSearch = true; state.query = characters; return nil
        }
        guard state.tab == .clipboard else { return event }
        let items = state.filtered(store)
        if [UInt16(125), 126].contains(event.keyCode) {
            guard !items.isEmpty else { return nil }
            state.selection = min(max(0, state.selection + (event.keyCode == 125 ? 1 : -1)), items.count - 1); return nil
        }
        if event.keyCode == 36, items.indices.contains(state.selection) { paste(items[state.selection], plain: flags.contains(.shift)); return nil }
        if flags.contains(.command), let number = Int(event.charactersIgnoringModifiers ?? ""), number >= 1, number <= 9, items.indices.contains(number - 1) { paste(items[number - 1], plain: flags.contains(.shift)); return nil }
        if flags.contains(.command), event.keyCode == 51, items.indices.contains(state.selection) { store.delete(items[state.selection]); state.selection = min(state.selection, max(0, items.count - 2)); return nil }
        return event
    }
    func windowDidResignKey(_ notification: Notification) {
        guard notification.object as? NSWindow == panel else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            guard let self, self.panel.isVisible, !self.panel.isKeyWindow else { return }
            // Menus temporarily take focus; leave the panel available while the pointer is over it.
            if !self.panel.frame.contains(NSEvent.mouseLocation) { self.dismiss() }
        }
    }
    func loadDemo() {
        var pinned = Clip.text("The details are not the details. They make the design.", source: "Notes")
        pinned.pinned = true; pinned.created = Date().addingTimeInterval(-540)
        var code = Clip.text("{\n  \"status\": \"ready\",\n  \"message\": \"Hello, Clipboard\"\n}", source: "Visual Studio Code")
        code.created = Date().addingTimeInterval(-120)
        var link = Clip.text("https://developer.apple.com/design", source: "Safari")
        link.created = Date().addingTimeInterval(-35)
        store.clips = [link, code, pinned]
        store.trusted = true
        if CommandLine.arguments.contains("--dark") { store.preferences.appearance = "dark"; applyAppearance() }
    }
    func renderPreview(_ path: String) {
        guard let content = panel.contentView else { exit(1) }
        content.layoutSubtreeIfNeeded()
        guard let bitmap = content.bitmapImageRepForCachingDisplay(in: content.bounds) else { exit(1) }
        content.cacheDisplay(in: content.bounds, to: bitmap)
        do { try bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: path)); print("Preview written: \(path)"); exit(0) }
        catch { fputs("Preview failed\n", stderr); exit(1) }
    }
}

@main
struct ClipboardMain {
    @MainActor static func main() {
        if CommandLine.arguments.contains("--self-test") { SelfTests.run(); return }
        var preview: String?
        if let index = CommandLine.arguments.firstIndex(of: "--preview"), CommandLine.arguments.indices.contains(index + 1) { preview = CommandLine.arguments[index + 1] }
        let app = NSApplication.shared
        let delegate = AppDelegate(previewPath: preview)
        app.delegate = delegate
        withExtendedLifetime(delegate) { app.run() }
    }
}
