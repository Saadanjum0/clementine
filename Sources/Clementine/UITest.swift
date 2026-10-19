#if canImport(AppKit)
import AppKit

/// `Clementine --uitest`: the wheel is driven through its real NSEvent handlers
/// (mouseMoved / mouseDown / keyDown / the drop path) and the outcomes are checked
/// on disk. Needs a window server; runs on a Mac or a macOS CI runner.
enum UITest {
    private static var passes = 0, fails = 0

    private static func check(_ name: String, _ ok: Bool) {
        if ok { passes += 1; print("  ok    \(name)") } else { fails += 1; print("  FAIL  \(name)") }
    }

    private static func pump(_ seconds: TimeInterval) {
        RunLoop.main.run(until: Date(timeIntervalSinceNow: seconds))
    }

    /// Pumps the run loop until `cond` holds or `seconds` pass.
    private static func wait(_ seconds: TimeInterval, until cond: () -> Bool) -> Bool {
        let end = Date(timeIntervalSinceNow: seconds)
        while Date() < end { if cond() { return true }; pump(0.05) }
        return cond()
    }

    private static func mouse(_ type: NSEvent.EventType, _ p: NSPoint) -> NSEvent {
        NSEvent.mouseEvent(with: type, location: p, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                           windowNumber: WheelPanel.shared.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
    }

    private static func key(_ code: UInt16, chars: String = "") -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: WheelPanel.shared.windowNumber,
                         context: nil, characters: chars, charactersIgnoringModifiers: chars, isARepeat: false, keyCode: code)!
    }

    private static func isDone(_ v: WheelView) -> Bool { if case .done = v.state { return true }; return false }
    private static func isRunning(_ v: WheelView) -> Bool { if case .running = v.state { return true }; return false }
    private static func isError(_ v: WheelView) -> Bool { if case .error = v.state { return true }; return false }
    private static func exists(_ u: URL) -> Bool { FileManager.default.fileExists(atPath: u.path) }

    static func run() -> Int32 {
        print("Clementine UI test")
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("clementine-uitest-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let png = dir.appendingPathComponent("photo.png")
        SelfTest.makePNG(png)
        let png2 = dir.appendingPathComponent("logo.png")
        SelfTest.makePNG(png2, w: 64, h: 64)
        let txt = dir.appendingPathComponent("notes.txt")
        try? "Hello wheel.\n".write(to: txt, atomically: true, encoding: .utf8)
        let pdf = dir.appendingPathComponent("notes.pdf")
        try? Native.perform(.docToPDF(txt, pdf))

        let panel = WheelPanel.shared
        let view = panel.wheel
        let at = NSPoint(x: 600, y: 400)
        let center = NSPoint(x: view.bounds.midX, y: view.bounds.midY)

        print("\nconvert wheel")
        panel.show(files: [png], mode: .convert, at: at, interactive: true)
        pump(0.2)
        check("panel visible", panel.isVisible)
        check("png targets in wheel order", view.labels == ["JPG", "WEBP", "HEIC", "TIFF", "AVIF", "BMP", "PDF", "DOCX"])
        for (i, label) in view.labels.enumerated() {
            view.mouseMoved(with: mouse(.mouseMoved, view.sectorCenter(i)))
            check("hover sector \(i) highlights \(label)", view.hoveredLabel == label)
        }
        view.mouseMoved(with: mouse(.mouseMoved, center))
        check("hub is not a target", view.hoveredLabel == nil)
        view.mouseMoved(with: mouse(.mouseMoved, NSPoint(x: 2, y: 2)))
        check("outside the disc is not a target", view.hoveredLabel == nil)

        print("\nkeyboard")
        view.keyDown(with: key(48))
        check("tab → tools wheel", view.mode == .tools)
        check("png tools include Crop…, Read QR, Metadata…, Edit Photo…, Read Text, Fit to Size…; not Collage", view.labels.contains("Crop…") && view.labels.contains("Read QR")
              && view.labels.contains("Metadata…") && view.labels.contains("Edit Photo…") && view.labels.contains("Read Text") && view.labels.contains("Fit to Size…") && !view.labels.contains("Collage"))
        view.keyDown(with: key(48)); view.keyDown(with: key(48)); view.keyDown(with: key(48))   // back to convert
        check("tab ×3 → convert again", view.mode == .convert)
        view.keyDown(with: key(124))
        check("→ selects the first sector", view.hoveredLabel == "JPG")
        view.keyDown(with: key(124))
        check("→ again selects the second", view.hoveredLabel == "WEBP")
        view.keyDown(with: key(123))
        check("← goes back", view.hoveredLabel == "JPG")
        for c in "ti" { view.keyDown(with: key(0, chars: String(c))) }
        check("typing \"ti\" jumps to TIFF", view.hoveredLabel == "TIFF")
        view.keyDown(with: key(48))   // tools
        view.keyDown(with: key(48))
        check("tab → actions wheel with 6 actions", view.mode == .actions && view.labels.count == 6)
        view.keyDown(with: key(48))
        check("tab → claude wheel starts with Ask…", view.mode == .claude && view.labels.first == "Ask…")
        view.keyDown(with: key(48))
        check("tab → back to convert", view.mode == .convert)
        view.keyDown(with: key(53))
        check("esc dismisses", !panel.isVisible)

        print("\nclick to convert")
        panel.show(files: [png], mode: .convert, at: at, interactive: true)
        pump(0.1)
        let jpg = view.labels.firstIndex(of: "JPG")!
        view.mouseMoved(with: mouse(.mouseMoved, view.sectorCenter(jpg)))
        view.mouseDown(with: mouse(.leftMouseDown, view.sectorCenter(jpg)))
        check("click → running state", isRunning(view) || isDone(view))
        check("running → done", wait(20) { isDone(view) })
        check("photo.jpg written next to photo.png", exists(dir.appendingPathComponent("photo.jpg")))
        check("wheel auto-dismisses after done", wait(3) { !panel.isVisible })

        print("\ndrop path (Finder drag)")
        panel.show(files: [png], mode: .convert, at: at, interactive: false)
        pump(0.1)
        let tiff = view.labels.firstIndex(of: "TIFF")!
        check("drop on TIFF sector accepted", view.performDrop(at: view.sectorCenter(tiff), files: [png]))
        check("drop converts to photo.tiff", wait(20) { isDone(view) } && exists(dir.appendingPathComponent("photo.tiff")))
        _ = wait(3) { !panel.isVisible }
        panel.show(files: [png], mode: .convert, at: at, interactive: false)
        pump(0.1)
        check("drop on the hub is rejected", !view.performDrop(at: center, files: [png]))
        check("drop outside the disc is rejected", !view.performDrop(at: NSPoint(x: 1, y: 1), files: [png]))
        panel.dismiss()

        print("\nbatches")
        panel.show(files: [png, pdf], mode: .convert, at: at, interactive: true)
        pump(0.1)
        check("png + pdf share JPG and DOCX", view.labels == ["JPG", "DOCX"])
        panel.show(files: [png, txt], mode: .convert, at: at, interactive: true)
        pump(0.1)
        check("png + txt share PDF and DOCX", view.labels == ["PDF", "DOCX"])
        let zip = dir.appendingPathComponent("empty.zip")
        try? Runner.shell("/usr/bin/tar", ["-a", "-c", "-f", zip.path, "-C", dir.path, "notes.txt"])
        panel.show(files: [png, zip], mode: .convert, at: at, interactive: true)
        pump(0.1)
        check("png + zip share no format", view.labels.isEmpty)
        panel.show(files: [png, png2], mode: .tools, at: at, interactive: true)
        pump(0.1)
        check("two images offer Collage", view.labels.contains("Collage"))
        let collage = view.labels.firstIndex(of: "Collage")!
        view.mouseMoved(with: mouse(.mouseMoved, view.sectorCenter(collage)))
        view.mouseDown(with: mouse(.leftMouseDown, view.sectorCenter(collage)))
        check("collage written", wait(20) { isDone(view) } && exists(dir.appendingPathComponent("photo collage.jpg")))
        _ = wait(3) { !panel.isVisible }
        panel.show(files: [pdf, pdf], mode: .tools, at: at, interactive: true)
        pump(0.1)
        check("two pdfs offer Merge", view.labels.contains("Merge"))
        panel.dismiss()

        print("\nerror handling")
        let broken = dir.appendingPathComponent("broken.pdf")
        try? "this is not a pdf".write(to: broken, atomically: true, encoding: .utf8)
        panel.show(files: [broken], mode: .tools, at: at, interactive: true)
        pump(0.1)
        let compress = view.labels.firstIndex(of: "Compress")!
        view.mouseMoved(with: mouse(.mouseMoved, view.sectorCenter(compress)))
        view.mouseDown(with: mouse(.leftMouseDown, view.sectorCenter(compress)))
        check("broken pdf → error state", wait(10) { isError(view) })
        check("error names the file", { if case .error(let m) = view.state { return m.contains("broken.pdf") }; return false }())
        check("error keeps the wheel open", panel.isVisible)
        view.mouseDown(with: mouse(.leftMouseDown, center))
        check("click closes the error", !panel.isVisible)

        print("\nactions wheel")
        panel.show(files: [png], mode: .actions, at: at, interactive: true)
        pump(0.1)
        let copyPath = view.labels.firstIndex(of: "Copy Path")!
        view.mouseDown(with: mouse(.leftMouseDown, view.sectorCenter(copyPath)))
        check("Copy Path puts the path on the clipboard", NSPasteboard.general.string(forType: .string) == png.path)
        check("action dismisses the wheel", !panel.isVisible)
        panel.show(files: [png], mode: .actions, at: at, interactive: true)
        pump(0.1)
        let copy = view.labels.firstIndex(of: "Copy")!
        view.mouseDown(with: mouse(.leftMouseDown, view.sectorCenter(copy)))
        let pasted = NSPasteboard.general.readObjects(forClasses: [NSURL.self], options: nil) as? [URL] ?? []
        check("Copy puts the file on the clipboard", pasted.map(\.standardizedFileURL.path).contains(png.standardizedFileURL.path))

        print("\nclaude wheel")
        panel.show(files: [png], mode: .claude, at: at, interactive: true)
        pump(0.1)
        check("image gets the four Claude actions", view.labels == ["Ask…", "Summarize", "Translate…", "New Chat"])
        panel.show(files: [pdf, txt], mode: .claude, at: at, interactive: true)
        pump(0.1)
        check("pdf + txt batch gets the same four", view.labels.count == ClaudeAction.allCases.count)
        panel.show(files: [dir], mode: .claude, at: at, interactive: true)
        pump(0.1)
        check("a folder can still go to a Claude chat (Ask…, New Chat)", view.labels == ["Ask…", "New Chat"])
        panel.dismiss()

        print("\nclipboard")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setData(try! Data(contentsOf: png), forType: .png)
        let fromClip = AppDelegate.convertClipboard(into: dir)
        pump(0.1)
        check("image on the clipboard becomes a PNG file", fromClip.first?.pathExtension == "png" && exists(fromClip[0]))
        check("and opens the convert wheel for it", panel.isVisible && view.mode == .convert && view.labels.first == "JPG")
        panel.dismiss()
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString("hello", forType: .string)
        let fromText = AppDelegate.convertClipboard(into: dir)
        pump(0.1)
        check("text on the clipboard becomes a .txt file", fromText.first?.pathExtension == "txt")
        panel.dismiss()

        print("\n\(passes) passed, \(fails) failed")
        return fails == 0 ? 0 : 1
    }
}
#endif
