#if canImport(AppKit)
import AppKit

/// The Control-drag wheel. All six run on the main thread; none produce files.
enum Actions {
    static func perform(_ action: FileAction, _ urls: [URL]) throws {
        switch action {
        case .airdrop:
            guard let s = NSSharingService(named: .sendViaAirDrop), s.canPerform(withItems: urls) else {
                throw ConvertError.failed("AirDrop is not available for these files")
            }
            s.perform(withItems: urls)
        case .copy:
            let pb = NSPasteboard.general
            pb.clearContents()
            pb.writeObjects(urls.map { $0 as NSURL })
        case .copyPath:
            let pb = NSPasteboard.general
            pb.clearContents()
            pb.setString(urls.map(\.path).joined(separator: "\n"), forType: .string)
        case .terminal:
            let dir = urls[0].hasDirectoryPath ? urls[0] : urls[0].deletingLastPathComponent()
            let terminal = URL(fileURLWithPath: "/System/Applications/Utilities/Terminal.app")
            NSWorkspace.shared.open([dir], withApplicationAt: terminal, configuration: NSWorkspace.OpenConfiguration())
        case .move:
            let panel = NSOpenPanel()
            panel.canChooseDirectories = true
            panel.canChooseFiles = false
            panel.canCreateDirectories = true
            panel.prompt = "Move Here"
            panel.message = "Move \(urls.count == 1 ? urls[0].lastPathComponent : "\(urls.count) items") to:"
            WheelPanel.shared.orderOut(nil)          // the wheel floats at .popUpMenu, above the modal panel
            NSApp.activate(ignoringOtherApps: true)
            guard panel.runModal() == .OK, let dest = panel.url else { return }
            for u in urls {
                try FileManager.default.moveItem(at: u, to: dest.appendingPathComponent(u.lastPathComponent))
            }
        case .float:
            urls.forEach { FloatPanel.show($0) }
        }
    }
}

/// "Float": a small always-on-top tile holding the file, so it can be dragged
/// into any other app later without going back to Finder. Close it like a window.
final class FloatPanel: NSPanel {
    private static var open: [FloatPanel] = []

    static func show(_ url: URL) {
        let p = FloatPanel(contentRect: NSRect(x: 0, y: 0, width: 120, height: 120),
                           styleMask: [.titled, .closable, .utilityWindow, .nonactivatingPanel],
                           backing: .buffered, defer: false)
        p.title = url.lastPathComponent
        p.level = .floating
        p.isFloatingPanel = true
        p.hidesOnDeactivate = false
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        p.contentView = FileTile(url: url, frame: NSRect(x: 0, y: 0, width: 120, height: 120))
        let mouse = NSEvent.mouseLocation
        p.setFrameOrigin(NSPoint(x: mouse.x + 20, y: mouse.y - 140))
        p.orderFrontRegardless()
        open.append(p)
    }

    override func close() {
        super.close()
        Self.open.removeAll { $0 === self }       // a block observer here would retain the panel for ever
    }
}

private final class FileTile: NSView, NSDraggingSource {
    let url: URL
    init(url: URL, frame: NSRect) { self.url = url; super.init(frame: frame) }
    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.windowBackgroundColor.setFill()
        bounds.fill()
        let icon = NSWorkspace.shared.icon(forFile: url.path)
        icon.draw(in: NSRect(x: bounds.midX - 32, y: bounds.midY - 24, width: 64, height: 64))
        let name = NSAttributedString(string: url.lastPathComponent, attributes: [
            .font: NSFont.systemFont(ofSize: 10), .foregroundColor: NSColor.secondaryLabelColor])
        let w = min(name.size().width, bounds.width - 8)
        name.draw(in: NSRect(x: bounds.midX - w / 2, y: 6, width: w, height: 14))
    }

    override func mouseDragged(with event: NSEvent) {
        let item = NSDraggingItem(pasteboardWriter: url as NSURL)
        let icon = NSWorkspace.shared.icon(forFile: url.path)
        item.setDraggingFrame(NSRect(x: bounds.midX - 32, y: bounds.midY - 24, width: 64, height: 64), contents: icon)
        beginDraggingSession(with: [item], event: event, source: self)
    }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        [.copy, .generic]
    }
}
#endif
