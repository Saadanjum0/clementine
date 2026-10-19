#if canImport(AppKit)
import AppKit

enum ModifierKey: String, CaseIterable {
    case shift, command, control, option
    var flag: NSEvent.ModifierFlags { [.shift: .shift, .command: .command, .control: .control, .option: .option][self]! }
    var symbol: String { ["shift": "⇧", "command": "⌘", "control": "⌃", "option": "⌥"][rawValue]! }
    var name: String { "\(symbol) \(rawValue.capitalized)" }
}

enum WheelMode: CaseIterable {
    case convert, tools, actions, claude
    var title: String { ["Convert", "Tools", "Actions", "Claude"][WheelMode.allCases.firstIndex(of: self)!] }
}

/// The zero-click gesture. A global mouse monitor (no Accessibility permission
/// needed for mouse events) watches for a drag. A real Finder drag writes the
/// system drag pasteboard, which is readable from any app: when it holds files
/// and a modifier is down, the wheel appears under the cursor. Shift → convert,
/// Command → tools, Control → actions, as in Tangerine 2.x, plus Option → the Claude
/// wheel. Modifiers are polled on every drag event, so the mode follows the key mid-drag.
final class DragMonitor {
    static let shared = DragMonitor()
    private var monitors: [Any] = []
    private var baseline = NSPasteboard(name: .drag).changeCount
    private var lastChange = -1
    private var files: [URL] = []
    private var shown = false
    private var lastMode: WheelMode?

    func start() {
        guard monitors.isEmpty else { return }
        let mask: NSEvent.EventTypeMask = [.leftMouseDown, .leftMouseDragged, .leftMouseUp]
        if let g = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: { [weak self] in self?.handle($0) }) { monitors.append(g) }
        if let l = NSEvent.addLocalMonitorForEvents(matching: mask, handler: { [weak self] e in self?.handle(e); return e }) { monitors.append(l) }
    }

    /// Which key opens which wheel (Settings). Tangerine's defaults; each key opens exactly one wheel.
    static var keys: [WheelMode: ModifierKey] {
        get {
            let saved = UserDefaults.standard.dictionary(forKey: "wheelKeys") as? [String: String] ?? [:]
            var out: [WheelMode: ModifierKey] = [.convert: .shift, .tools: .command, .actions: .control, .claude: .option]
            for m in WheelMode.allCases { if let k = saved[m.title].flatMap(ModifierKey.init(rawValue:)) { out[m] = k } }
            return Set(out.values).count == 4 ? out : [.convert: .shift, .tools: .command, .actions: .control, .claude: .option]
        }
        set { UserDefaults.standard.set(Dictionary(uniqueKeysWithValues: newValue.map { ($0.key.title, $0.value.rawValue) }), forKey: "wheelKeys") }
    }

    /// With several keys down, Command beats Option beats Control beats Shift (so ⇧⌘ means the ⌘ wheel).
    static func mode(for flags: NSEvent.ModifierFlags) -> WheelMode? {
        let map = keys
        for key in [ModifierKey.command, .option, .control, .shift] where flags.contains(key.flag) {
            if let m = map.first(where: { $0.value == key })?.key { return m }
        }
        return nil
    }

    private func handle(_ e: NSEvent) {
        switch e.type {
        case .leftMouseDown:
            baseline = NSPasteboard(name: .drag).changeCount
            lastChange = -1
            lastMode = nil
            shown = false                      // a wheel the last drag left behind must not swallow this one
            files = []
        case .leftMouseDragged:
            let pb = NSPasteboard(name: .drag)
            guard pb.changeCount != baseline else { return }   // window move / text selection, not a drag session
            if pb.changeCount != lastChange { lastChange = pb.changeCount; files = Self.fileURLs(pb) }
            guard !files.isEmpty else { return }
            // Like Tangerine, a tap is enough: the wheel stays up after the key is released and closes on
            // drop or cancel. Only a key change switches wheels, so a chip picked on the mode bar sticks.
            guard let mode = Self.mode(for: NSEvent.modifierFlags) else { return }
            if shown { if WheelPanel.shared.isVisible, mode != lastMode { WheelPanel.shared.setMode(mode) } }   // one wheel per drag
            else { shown = true; WheelPanel.shared.show(files: files, mode: mode, at: NSEvent.mouseLocation, interactive: false) }
            lastMode = mode
        case .leftMouseUp:
            guard shown else { return }
            shown = false
            // performDragOperation arrives in this same event cycle; give it a beat before hiding.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { WheelPanel.shared.dismissIfIdle() }
        default:
            break
        }
    }

    static func fileURLs(_ pb: NSPasteboard) -> [URL] {
        let urls = pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        return urls.filter { Formats.identify($0) != nil }
    }
}
#endif
