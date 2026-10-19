#if canImport(AppKit)
import AppKit
import Carbon.HIToolbox

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var openItem: NSMenuItem!

    func applicationDidFinishLaunching(_ notification: Notification) {
        // One Clementine at a time: two copies would both open a wheel on every drag. The one just launched wins.
        let me = ProcessInfo.processInfo.processIdentifier
        NSRunningApplication.runningApplications(withBundleIdentifier: Bundle.main.bundleIdentifier ?? "")
            .filter { $0.processIdentifier != me }
            .forEach { $0.forceTerminate() }

        DragMonitor.shared.start()
        NSApp.servicesProvider = self

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.image = Self.menuBarLogo
        statusItem.button?.toolTip = "Clementine"
        let menu = NSMenu()
        openItem = menu.addItem(withTitle: "Open Wheel", action: #selector(openWheelFromMenu), keyEquivalent: "")
        menu.addItem(withTitle: "Convert Clipboard…", action: #selector(convertClipboardFromMenu), keyEquivalent: "v")
        menu.addItem(withTitle: "How It Works", action: #selector(showHelp), keyEquivalent: "")
        menu.addItem(withTitle: "Engines…", action: #selector(showEngines), keyEquivalent: "")
        menu.addItem(withTitle: "Install Engines (no Homebrew)…", action: #selector(installEngines), keyEquivalent: "")
        menu.addItem(withTitle: "Settings…", action: #selector(showSettings), keyEquivalent: ",")
        menu.addItem(.separator())
        let ver = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"
        menu.addItem(withTitle: "Clementine \(ver)", action: nil, keyEquivalent: "").isEnabled = false
        menu.addItem(withTitle: "Quit Clementine", action: #selector(quit), keyEquivalent: "q")
        menu.items.forEach { $0.target = self }
        statusItem.menu = menu

        // The global shortcut (⌃⌥C unless changed in Settings): the wheel for the Finder selection, from anywhere.
        HotKey.shared.action = { [weak self] in self?.openWheelForSelection() }
        applyHotKey()
        NotificationCenter.default.addObserver(forName: HotKey.changed, object: nil, queue: .main) { [weak self] _ in self?.applyHotKey() }

        // Keys on the wheel during a Finder drag need Accessibility (Finder owns the keyboard then). Ask once;
        // Settings shows the state and links to the pane afterwards.
        if !AXIsProcessTrusted(), !UserDefaults.standard.bool(forKey: "askedAccessibility") {
            UserDefaults.standard.set(true, forKey: "askedAccessibility")
            AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary)
        }

        // A menu-bar app has no window or Dock icon, so say that it started and where it lives.
        JobHUD.show("").finish("Clementine is running in the menu bar 🍊", after: 4)
    }

    /// Opening the app again while it runs (Finder, Launchpad, Spotlight) drops its menu down.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        statusItem.button?.performClick(nil)
        return false
    }

    /// The app icon's clementine as a template image, so it follows light/dark menu bars.
    static let menuBarLogo: NSImage = {
        let img = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { _ in
            NSColor.black.set()
            NSBezierPath(ovalIn: NSRect(x: 2, y: 1, width: 13.5, height: 12.5)).fill()
            let leaf = NSBezierPath()
            leaf.move(to: NSPoint(x: 9, y: 13))
            leaf.curve(to: NSPoint(x: 16, y: 17), controlPoint1: NSPoint(x: 10, y: 16.5), controlPoint2: NSPoint(x: 13.5, y: 17.5))
            leaf.curve(to: NSPoint(x: 9, y: 13), controlPoint1: NSPoint(x: 15, y: 14), controlPoint2: NSPoint(x: 11.5, y: 12.5))
            leaf.fill()
            return true
        }
        img.isTemplate = true
        img.accessibilityDescription = "Clementine"
        return img
    }()

    @objc private func quit() { NSApp.terminate(nil) }

    /// Registers the chosen shortcut and shows it beside "Open Wheel" in the menu.
    private func applyHotKey() {
        let choice = HotKey.current
        let ok = HotKey.shared.register(choice)
        openItem.keyEquivalent = ok ? choice.key : ""
        openItem.keyEquivalentModifierMask = choice.menuMods
        openItem.title = ok || choice.name == "Off" ? "Open Wheel" : "Open Wheel  (\(choice.name) is taken by another app)"
    }

    @objc private func openWheelFromMenu() { openWheelForSelection() }

    /// The files selected in Finder get the wheel at the cursor. With Finder in front but nothing selected,
    /// or another app in front, a file chooser opens instead.
    func openWheelForSelection() {
        let finderInFront = NSWorkspace.shared.frontmostApplication?.bundleIdentifier == "com.apple.finder"
        if finderInFront {
            switch Self.finderSelection() {
            case .success(let picked) where !picked.isEmpty:
                let urls = picked.filter { Formats.identify($0) != nil }
                guard !urls.isEmpty else {
                    JobHUD.show("").finish("Clementine can't work with \(picked.count == 1 ? picked[0].lastPathComponent : "these files")", after: 2.5)
                    return
                }
                WheelPanel.shared.show(files: urls, mode: .convert, at: NSEvent.mouseLocation, interactive: true)
                return
            case .failure(let e) where e.code == -1743:      // the user said no to "Clementine wants to control Finder"
                Editors.alert("Allow Clementine to read the Finder selection",
                              "System Settings → Privacy & Security → Automation → Clementine → turn on Finder. Until then the shortcut opens a file chooser.")
            default:
                break
            }
        }
        chooseFilesForWheel()
    }

    /// Paths of the items selected in Finder (front window or Desktop). macOS asks once for permission.
    static func finderSelection() -> Result<[URL], NSError> {
        let src = """
        tell application "Finder"
            set out to {}
            repeat with a in (get selection as alias list)
                set end of out to POSIX path of a
            end repeat
            return out
        end tell
        """
        var err: NSDictionary?
        guard let res = NSAppleScript(source: src)?.executeAndReturnError(&err) else {
            return .failure(NSError(domain: "AppleScript", code: (err?[NSAppleScript.errorNumber] as? Int) ?? -1))
        }
        let n = res.numberOfItems
        return .success(n == 0 ? [] : (1...n).compactMap { res.atIndex($0)?.stringValue }.map { URL(fileURLWithPath: $0) })
    }

    private func chooseFilesForWheel() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.prompt = "Show Wheel"
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK else { return }
        let urls = panel.urls.filter { Formats.identify($0) != nil }
        guard !urls.isEmpty else { return }
        WheelPanel.shared.show(files: urls, mode: .convert, at: NSEvent.mouseLocation, interactive: true)
    }

    @objc private func showSettings() { SettingsWindow.show() }
    @objc private func convertClipboardFromMenu() { Self.convertClipboard() }

    /// Whatever is on the clipboard becomes a file the wheel can work on: copied files directly,
    /// an image as PNG in Downloads, text as .txt in Downloads.
    @discardableResult
    static func convertClipboard(into dir: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads")) -> [URL] {
        let pb = NSPasteboard.general
        var urls = (pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []).filter { Formats.identify($0) != nil }
        if urls.isEmpty {
            let stamp = DateFormatter()
            stamp.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
            let base = dir.appendingPathComponent("Clipboard \(stamp.string(from: Date()))")
            if let data = pb.data(forType: .png) ?? pb.data(forType: .tiff), let rep = NSBitmapImageRep(data: data),
               let png = rep.representation(using: .png, properties: [:]) {
                let u = base.appendingPathExtension("png")
                try? png.write(to: u)
                urls = [u]
            } else if let s = pb.string(forType: .string), !s.isEmpty {
                let u = base.appendingPathExtension("txt")
                try? s.write(to: u, atomically: true, encoding: .utf8)
                urls = [u]
            }
        }
        guard !urls.isEmpty else { Editors.alert("Clipboard", "Nothing on the clipboard that Clementine can convert (files, an image, or text)."); return [] }
        WheelPanel.shared.show(files: urls, mode: .convert, at: NSEvent.mouseLocation, interactive: true)
        return urls
    }
    @objc private func installEngines() { EngineInstaller.run() }

    @objc private func showHelp() {
        alert("How It Works", """
        Drag a file in Finder, then hold a key:

        ⇧ Shift      Convert wheel – drop on a format, the copy lands next to the original
        ⌘ Command    Tools wheel – compress, strip metadata, rotate, split, merge, …
        ⌃ Control    Actions wheel – AirDrop, Float, Copy, Move, Copy Path, Terminal
        ⌥ Option     Claude wheel – opens the file in a new chat in the Claude app

        Or select files in Finder and press \(HotKey.current.name) (Open Wheel), or use “Convert Clipboard…”. Keys on the wheel:
        Tab switches wheels, arrows move, Return runs, 1–9 pick a sector, type a name to jump, Esc closes.
        Everything runs on this Mac. The Claude wheel hands the file to the Claude app, which asks before uploading it.
        """)
    }

    @objc private func showEngines() {
        let lines = EngineID.allCases.filter { $0 != .native }.map { id -> String in
            let p = EngineLocator.path(for: id)
            return "\(p == nil ? "✗" : "✓")  \(id.rawValue)  \(p ?? "→ \(id.installHint)")"
        }
        alert("Engines", lines.joined(separator: "\n") + "\n\nffmpeg: audio, video, WebP, AVIF, subtitles\npandoc: Markdown, EPUB, DOCX\nsoffice (LibreOffice): XLSX, ODS, PPTX, PDF → DOCX with layout")
    }

    private func alert(_ title: String, _ body: String) {
        NSApp.activate(ignoringOtherApps: true)
        let a = NSAlert()
        a.messageText = title
        a.informativeText = body
        a.runModal()
    }

    /// Finder → Services → "Open in Clementine wheel"
    @objc func openWheel(_ pboard: NSPasteboard, userData: String, error: AutoreleasingUnsafeMutablePointer<NSString>) {
        let urls = DragMonitor.fileURLs(pboard)
        guard !urls.isEmpty else { return }
        WheelPanel.shared.show(files: urls, mode: .convert, at: NSEvent.mouseLocation, interactive: true)
    }
}

/// One system-wide shortcut through Carbon's RegisterEventHotKey: no Accessibility permission needed,
/// and the key press is consumed, so it never also reaches the app in front.
final class HotKey {
    struct Choice {
        let name: String, keyCode: UInt32, carbonMods: UInt32, key: String, menuMods: NSEvent.ModifierFlags
    }
    static let choices: [Choice] = [
        Choice(name: "⌃⌥C", keyCode: UInt32(kVK_ANSI_C), carbonMods: UInt32(controlKey | optionKey), key: "c", menuMods: [.control, .option]),
        Choice(name: "⌥Space", keyCode: UInt32(kVK_Space), carbonMods: UInt32(optionKey), key: " ", menuMods: [.option]),
        Choice(name: "⌃⌥Space", keyCode: UInt32(kVK_Space), carbonMods: UInt32(controlKey | optionKey), key: " ", menuMods: [.control, .option]),
        Choice(name: "⌥⌘O", keyCode: UInt32(kVK_ANSI_O), carbonMods: UInt32(optionKey | cmdKey), key: "o", menuMods: [.option, .command]),
        Choice(name: "Off", keyCode: 0, carbonMods: 0, key: "", menuMods: []),
    ]
    static let changed = Notification.Name("ClementineHotKeyChanged")
    static var current: Choice {
        get { choices.first { $0.name == UserDefaults.standard.string(forKey: "hotKey") } ?? choices[0] }
        set { UserDefaults.standard.set(newValue.name, forKey: "hotKey"); NotificationCenter.default.post(name: changed, object: nil) }
    }

    static let shared = HotKey()
    var action: () -> Void = {}
    private var ref: EventHotKeyRef?
    var isRegistered: Bool { ref != nil }
    private var handler: EventHandlerRef?

    /// False when another app already owns the combination (or it is Off).
    @discardableResult
    func register(_ c: Choice) -> Bool {
        if let ref { UnregisterEventHotKey(ref); self.ref = nil }
        guard c.name != "Off" else { return false }
        if handler == nil {
            var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
            InstallEventHandler(GetApplicationEventTarget(), { _, _, _ in
                DispatchQueue.main.async { HotKey.shared.action() }
                return noErr
            }, 1, &spec, nil, &handler)
        }
        let id = EventHotKeyID(signature: OSType(0x434C_4D4E), id: 1)      // 'CLMN'
        guard RegisterEventHotKey(c.keyCode, c.carbonMods, id, GetApplicationEventTarget(), 0, &ref) == noErr else { ref = nil; return false }
        return true
    }
}
#endif
