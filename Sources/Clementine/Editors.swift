#if canImport(AppKit)
import AppKit
import PDFKit

/// Interactive tools: each collects its parameters in a small window, then runs
/// the plans on a background queue with a floating progress HUD.
enum Editors {
    static func open(_ tool: Tool, _ urls: [URL]) {
        NSApp.activate(ignoringOtherApps: true)
        switch tool.id {
        case "crop":     CropEditor.show(urls)
        case "trim":     TrimEditor.show(urls)
        case "reorder":  ReorderEditor.show(urls[0])
        case "metadata": MetadataEditor.show(urls[0])
        case "shrink":   shrink(urls)
        case "qr":       readQR(urls)
        case "rotate":   rotate(urls)
        case "frames":   frames(urls)
        case "speed":    speed(urls)
        case "split":    split(urls)
        case "bleep":    bleep(urls)
        case "background": BackgroundEditor.show(urls)
        case "annotate": AnnotateEditor.show(urls)
        case "redact":   redact(urls)
        case "adjust":   AdjustEditor.show(urls)
        case "fit":      fit(urls)
        default: break
        }
    }

    // MARK: shared dialogs

    /// A popup of choices. Returns the chosen index.
    static func choose(_ title: String, _ message: String, options: [String], button: String = "OK") -> Int? {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        let popup = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 260, height: 26), pullsDown: false)
        popup.addItems(withTitles: options)
        alert.accessoryView = popup
        alert.addButton(withTitle: button)
        alert.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        return alert.runModal() == .alertFirstButtonReturn ? popup.indexOfSelectedItem : nil
    }

    /// Labelled numeric fields. Returns the values in order.
    static func numbers(_ title: String, _ message: String, fields: [(String, Double)], button: String = "OK") -> [Double]? {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        let box = NSView(frame: NSRect(x: 0, y: 0, width: 300, height: CGFloat(fields.count) * 30))
        var inputs: [NSTextField] = []
        for (n, (label, value)) in fields.enumerated() {
            let y = CGFloat(fields.count - 1 - n) * 30
            let l = NSTextField(labelWithString: label)
            l.frame = NSRect(x: 0, y: y + 4, width: 150, height: 20)
            let f = NSTextField(frame: NSRect(x: 160, y: y, width: 140, height: 24))
            f.stringValue = value == value.rounded() ? String(Int(value)) : String(format: "%.2f", value)
            box.addSubview(l)
            box.addSubview(f)
            inputs.append(f)
        }
        alert.accessoryView = box
        alert.window.initialFirstResponder = inputs.first
        alert.addButton(withTitle: button)
        alert.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        return inputs.map { Double($0.stringValue.trimmingCharacters(in: .whitespaces)) ?? 0 }
    }

    private static func name(_ urls: [URL]) -> String { urls.count == 1 ? urls[0].lastPathComponent : "\(urls.count) files" }

    // MARK: the small parameter tools

    static func rotate(_ urls: [URL]) {
        let options = ["Rotate 90° clockwise", "Rotate 180°", "Rotate 90° counter-clockwise", "Flip horizontally", "Flip vertically"]
        guard let i = choose("Rotate & Flip", name(urls), options: options, button: "Apply") else { return }
        let degrees = [90, 180, 270, 0, 0][i], h = i == 3, v = i == 4
        run(urls.map { (u: URL) -> () throws -> Plan in { try Tools.rotatePlan(u, degrees: degrees, flipH: h, flipV: v) } }, title: options[i])
    }

    static func frames(_ urls: [URL]) {
        guard let v = numbers("Save video frames", "One PNG every N seconds, into a folder next to \(name(urls)).", fields: [("Every (seconds)", 5)], button: "Save Frames"),
              v[0] > 0 else { return }
        run(urls.map { (u: URL) -> () throws -> Plan in { Tools.framesPlan(u, every: v[0]) } }, title: "Frames")
    }

    static func speed(_ urls: [URL]) {
        let options = ["0.25×", "0.5×", "0.75×", "1.25×", "1.5×", "2×", "3×", "4×"]
        let factors = [0.25, 0.5, 0.75, 1.25, 1.5, 2, 3, 4]
        guard let i = choose("Change speed", name(urls), options: options, button: "Apply") else { return }
        run(urls.map { (u: URL) -> () throws -> Plan in { try Tools.speedPlan(u, factor: factors[i]) } }, title: "Speed \(options[i])")
    }

    static func split(_ urls: [URL]) {
        if Formats.identify(urls[0])?.kind == .document {
            run(urls.map { (u: URL) -> () throws -> Plan in { try Tools.plan(Tools.tool("split"), inputs: [u])[0] } }, title: "Split pages")
            return
        }
        let total = (try? Tools.duration(urls[0])) ?? 0
        guard let v = numbers("Split video", "Cut \(name(urls)) into two files at this time (duration \(String(format: "%.1f", total)) s).",
                              fields: [("Split at (seconds)", (total / 2 * 10).rounded() / 10)], button: "Split"), v[0] > 0 else { return }
        run(urls.map { (u: URL) -> () throws -> Plan in { try Tools.splitPlan(u, at: v[0]) } }, title: "Split")
    }

    static func bleep(_ urls: [URL]) {
        let total = (try? Tools.duration(urls[0])) ?? 0
        guard let v = numbers("Bleep audio", "Replace this range of \(name(urls)) with a tone (duration \(String(format: "%.1f", total)) s).",
                              fields: [("From (seconds)", 0), ("To (seconds)", min(1, total))], button: "Bleep"), v[1] > v[0] else { return }
        run(urls.map { (u: URL) -> () throws -> Plan in { try Tools.bleepPlan(u, start: v[0], end: v[1]) } }, title: "Bleep")
    }

    static func fit(_ urls: [URL]) {
        let options = ["Email · 10 MB", "WhatsApp · 16 MB", "Discord · 25 MB", "iMessage · 100 MB", "Custom…"]
        let sizes = [10, 16, 25, 100]
        guard let i = choose("Fit to size", "Shrink \(name(urls)) until it is under:", options: options, button: "Fit") else { return }
        var mb = i < sizes.count ? Double(sizes[i]) : 0
        if i == sizes.count {
            guard let v = numbers("Fit to size", name(urls), fields: [("Maximum size (MB)", 5)], button: "Fit"), v[0] > 0 else { return }
            mb = v[0]
        }
        let bytes = Int(mb * 1_000_000)
        run(urls.map { (u: URL) -> () throws -> Plan in { try Tools.fitPlan(u, bytes: bytes) } }, title: "Fit under \(mb) MB")
    }

    static func redact(_ urls: [URL]) {
        let hud = JobHUD.show("Looking for faces and text…")
        DispatchQueue.global(qos: .userInitiated).async {
            let found = Native.redactionCount(urls[0])          // full-resolution Vision pass: not on the main thread
            DispatchQueue.main.async {
                hud.close()
                guard let i = choose("Redact photo", "Black boxes over what Vision finds in \(name(urls)) (\(found) face/text regions in the first file).",
                                     options: ["Faces and text", "Faces only", "Text only"], button: "Redact") else { return }
                run(urls.map { (u: URL) -> () throws -> Plan in {
                    let o = Naming.sibling(of: u, ext: "png", suffix: " redacted")
                    return Plan(steps: [.native(.redact(u, o, i != 2, i != 1))], outputs: [o])
                } }, title: "Redact")
            }
        }
    }

    /// Runs plans in order on a background queue; HUD shows progress, errors become an alert.
    static func run(_ makers: [() throws -> Plan], title: String, done: (([URL]) -> Void)? = nil) {
        let hud = JobHUD.show(title)
        DispatchQueue.global(qos: .userInitiated).async {
            var outs: [URL] = []
            do {
                for (n, make) in makers.enumerated() {
                    DispatchQueue.main.async { hud.update("\(title) · \(n + 1) of \(makers.count)") }
                    let plan = try make()
                    try Runner.execute(plan)
                    outs += plan.outputs
                }
                DispatchQueue.main.async {
                    hud.finish("Done · " + outs.prefix(3).map(\.lastPathComponent).joined(separator: ", "))
                    done?(outs)
                }
            } catch {
                DispatchQueue.main.async { hud.close(); alert("\(title) failed", error.localizedDescription) }
            }
        }
    }

    /// Tangerine shows the results in Finder when a job finishes.
    static func reveal(_ urls: [URL]) {
        guard revealResults, !urls.isEmpty else { return }
        NSWorkspace.shared.activateFileViewerSelecting(urls)
    }
    static var revealResults: Bool {
        get { UserDefaults.standard.object(forKey: "revealResults") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "revealResults") }
    }

    static func alert(_ title: String, _ body: String) {
        NSApp.activate(ignoringOtherApps: true)
        let a = NSAlert()
        a.messageText = title
        a.informativeText = body
        a.runModal()
    }

    // MARK: Shrink to %

    private static var sliderLabel: SliderLabel?

    static func shrink(_ urls: [URL]) {
        let alert = NSAlert()
        alert.messageText = "Shrink to what percentage of the original size?"
        alert.informativeText = (urls.count == 1 ? urls[0].lastPathComponent : "\(urls.count) files")
            + "\nImages scale their pixels; audio and video lower their bitrate."
        let slider = NSSlider(value: 50, minValue: 5, maxValue: 95, target: nil, action: nil)
        slider.frame = NSRect(x: 0, y: 0, width: 250, height: 24)
        let label = NSTextField(labelWithString: "50%")
        label.frame = NSRect(x: 260, y: 2, width: 60, height: 20)
        let binding = SliderLabel(label: label)
        sliderLabel = binding
        slider.target = binding
        slider.action = #selector(SliderLabel.changed(_:))
        let box = NSView(frame: NSRect(x: 0, y: 0, width: 320, height: 24))
        box.addSubview(slider)
        box.addSubview(label)
        alert.accessoryView = box
        alert.addButton(withTitle: "Shrink")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let pct = slider.doubleValue
        run(urls.map { (u: URL) -> () throws -> Plan in { try Tools.shrinkPlan(u, percent: pct) } }, title: "Shrink to \(Int(pct))%")
    }

    private final class SliderLabel: NSObject {
        let label: NSTextField
        init(label: NSTextField) { self.label = label }
        @objc func changed(_ s: NSSlider) { label.stringValue = "\(Int(s.doubleValue))%" }
    }

    // MARK: Read QR

    static func readQR(_ urls: [URL]) {
        // Vision renders every PDF page at 200 dpi: off the main thread, behind the HUD, so the Finder drop returns at once.
        let hud = JobHUD.show("Reading codes…")
        DispatchQueue.global(qos: .userInitiated).async {
            var lines: [String] = []
            for u in urls {
                let codes = (try? Native.barcodes(u)) ?? []
                lines += codes.isEmpty ? ["\(u.lastPathComponent): no code found"] : codes
            }
            let payloads = lines.filter { !$0.hasSuffix("no code found") }
            DispatchQueue.main.async {
                hud.close()
                if !payloads.isEmpty {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(payloads.joined(separator: "\n"), forType: .string)
                }
                alert(payloads.isEmpty ? "No QR code found" : "QR code\(payloads.count == 1 ? "" : "s") · copied to clipboard", lines.joined(separator: "\n"))
            }
        }
    }
}

/// Small floating progress panel for editor-launched jobs.
final class JobHUD: NSPanel {
    private let label = NSTextField(labelWithString: "")
    private let spinner = NSProgressIndicator()

    static func show(_ title: String) -> JobHUD {
        let hud = JobHUD(contentRect: NSRect(x: 0, y: 0, width: 360, height: 64),
                         styleMask: [.titled, .nonactivatingPanel, .utilityWindow], backing: .buffered, defer: false)
        hud.title = "Clementine"
        hud.level = .floating
        hud.isReleasedWhenClosed = false
        hud.spinner.style = .spinning
        hud.spinner.frame = NSRect(x: 16, y: 20, width: 24, height: 24)
        hud.spinner.startAnimation(nil)
        hud.label.frame = NSRect(x: 52, y: 22, width: 296, height: 20)
        hud.label.stringValue = title
        hud.label.lineBreakMode = .byTruncatingMiddle
        hud.contentView?.addSubview(hud.spinner)
        hud.contentView?.addSubview(hud.label)
        hud.center()
        hud.orderFrontRegardless()
        return hud
    }

    func update(_ s: String) { label.stringValue = s }

    func finish(_ s: String, after seconds: Double = 1.6) {
        spinner.stopAnimation(nil)
        spinner.isHidden = true
        label.stringValue = s
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { [weak self] in self?.close() }
    }
}

// MARK: - Edit photo (adjust)

// MARK: - Crop

final class CropEditor: NSObject {
    private static var open: [CropEditor] = []        // one per window: a second editor must not orphan the first
    private let urls: [URL]
    private let window: NSWindow
    private let cropView = CropView(frame: NSRect(x: 16, y: 60, width: 728, height: 524))
    private let info = NSTextField(labelWithString: "")
    private var temps: [URL] = []

    static func show(_ urls: [URL]) {
        do { open.append(try CropEditor(urls: urls)) } catch { Editors.alert("Crop", error.localizedDescription) }
    }

    private init(urls: [URL]) throws {
        self.urls = urls
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 600),
                          styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        super.init()
        window.isReleasedWhenClosed = false          // this object owns the window; AppKit must not release it on close
        let first = urls[0]
        let source: URL
        if Formats.identify(first)?.kind == .video {
            source = Naming.temp(ext: "png")
            temps.append(source)
            try Runner.shell(try EngineLocator.require(.ffmpeg), Convert.ffBase + ["-i", first.path, "-frames:v", "1", source.path])
        } else {
            source = first
        }
        guard let cg = Native.loadImage(source) else { throw ConvertError.failed("Could not read \(first.lastPathComponent)") }
        cropView.image = NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
        cropView.pixelSize = CGSize(width: cg.width, height: cg.height)
        cropView.rect = CGRect(origin: .zero, size: cropView.pixelSize)
        cropView.autoresizingMask = [.width, .height]
        cropView.onChange = { [weak self] r in
            self?.info.stringValue = "\(Int(r.width)) × \(Int(r.height)) px at \(Int(r.minX)), \(Int(r.minY))"
        }

        window.title = "Crop · \(first.lastPathComponent)" + (urls.count > 1 ? " (+\(urls.count - 1) more, same proportions)" : "")
        window.minSize = NSSize(width: 480, height: 360)
        let content = window.contentView!
        content.addSubview(cropView)

        let aspect = NSPopUpButton(frame: NSRect(x: 16, y: 16, width: 150, height: 26), pullsDown: false)
        aspect.addItems(withTitles: ["Free", "Square 1:1", "4:3", "3:2", "16:9", "9:16"])
        aspect.target = self
        aspect.action = #selector(aspectChanged(_:))
        aspect.autoresizingMask = [.maxXMargin, .maxYMargin]
        content.addSubview(aspect)

        info.frame = NSRect(x: 180, y: 20, width: 400, height: 20)
        info.autoresizingMask = [.width, .maxYMargin]
        content.addSubview(info)
        cropView.onChange?(cropView.rect)

        let apply = NSButton(title: "Crop", target: self, action: #selector(apply))
        apply.frame = NSRect(x: 660, y: 13, width: 84, height: 32)
        apply.keyEquivalent = "\r"
        apply.autoresizingMask = [.minXMargin, .maxYMargin]
        content.addSubview(apply)

        NotificationCenter.default.addObserver(self, selector: #selector(closed), name: NSWindow.willCloseNotification, object: window)
        window.center()
        window.makeKeyAndOrderFront(nil)
    }

    @objc private func aspectChanged(_ p: NSPopUpButton) {
        let ratios: [CGFloat?] = [nil, 1, 4.0 / 3, 3.0 / 2, 16.0 / 9, 9.0 / 16]
        cropView.aspect = ratios[p.indexOfSelectedItem]
        cropView.applyAspect()
    }

    @objc private func apply() {
        let r = cropView.rect
        let px = cropView.pixelSize
        let fx = r.minX / px.width, fy = r.minY / px.height, fw = r.width / px.width, fh = r.height / px.height
        let urls = self.urls
        window.close()
        // The same proportions on each file of the batch, scaled to its own (displayed) size.
        Editors.run(urls.map { (u: URL) -> () throws -> Plan in { try Tools.cropPlan(u, fraction: CGRect(x: fx, y: fy, width: fw, height: fh)) } }, title: "Crop")
    }

    @objc private func closed() {
        temps.forEach { try? FileManager.default.removeItem(at: $0) }
        CropEditor.open.removeAll { $0 === self }
    }
}

/// Aspect-fit preview with a draggable crop rectangle. `rect` is in source pixels, origin top-left.
final class CropView: NSView {
    var image: NSImage? { didSet { needsDisplay = true } }
    var pixelSize = CGSize(width: 1, height: 1)
    var rect = CGRect.zero { didSet { needsDisplay = true } }
    var aspect: CGFloat?
    var onChange: ((CGRect) -> Void)?

    private enum Drag { case idle, move(NSPoint), corner(CGPoint), new(CGPoint) }
    private var drag = Drag.idle

    private var frameRect: CGRect {
        let s = min(bounds.width / pixelSize.width, bounds.height / pixelSize.height)
        let w = pixelSize.width * s, h = pixelSize.height * s
        return CGRect(x: (bounds.width - w) / 2, y: (bounds.height - h) / 2, width: w, height: h)
    }

    private func toView(_ r: CGRect) -> CGRect {
        let f = frameRect, s = f.width / pixelSize.width
        return CGRect(x: f.minX + r.minX * s, y: f.maxY - (r.minY + r.height) * s, width: r.width * s, height: r.height * s)
    }

    private func toPixels(_ p: NSPoint) -> CGPoint {
        let f = frameRect, s = pixelSize.width / f.width
        return CGPoint(x: min(max((p.x - f.minX) * s, 0), pixelSize.width), y: min(max((f.maxY - p.y) * s, 0), pixelSize.height))
    }

    private func viewCorners(_ r: CGRect) -> [NSPoint] {
        [NSPoint(x: r.minX, y: r.minY), NSPoint(x: r.maxX, y: r.minY), NSPoint(x: r.maxX, y: r.maxY), NSPoint(x: r.minX, y: r.maxY)]
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.windowBackgroundColor.setFill()
        bounds.fill()
        guard let image else { return }
        image.draw(in: frameRect)
        let vr = toView(rect)
        let shade = NSBezierPath(rect: frameRect)
        shade.appendRect(vr)
        shade.windingRule = .evenOdd
        NSColor(calibratedWhite: 0, alpha: 0.5).setFill()
        shade.fill()
        NSColor.white.setStroke()
        let outline = NSBezierPath(rect: vr)
        outline.lineWidth = 1.5
        outline.stroke()
        NSColor.white.setFill()
        for c in viewCorners(vr) { NSBezierPath(ovalIn: NSRect(x: c.x - 5, y: c.y - 5, width: 10, height: 10)).fill() }
    }

    override func mouseDown(with e: NSEvent) {
        let p = convert(e.locationInWindow, from: nil)
        let corners = viewCorners(toView(rect))
        if let i = corners.firstIndex(where: { hypot($0.x - p.x, $0.y - p.y) < 12 }) {
            drag = .corner(toPixels(corners[(i + 2) % 4]))       // anchor on the opposite corner
        } else if toView(rect).contains(p) {
            drag = .move(p)
        } else {
            let px = toPixels(p)
            drag = .new(px)
            rect = CGRect(origin: px, size: .zero)
        }
    }

    override func mouseDragged(with e: NSEvent) {
        let p = convert(e.locationInWindow, from: nil)
        switch drag {
        case .move(let last):
            let a = toPixels(last), b = toPixels(p)
            var r = rect.offsetBy(dx: b.x - a.x, dy: b.y - a.y)
            r.origin.x = min(max(r.minX, 0), pixelSize.width - r.width)
            r.origin.y = min(max(r.minY, 0), pixelSize.height - r.height)
            rect = r
            drag = .move(p)
        case .corner(let anchor):
            rect = spanned(anchor, toPixels(p))
        case .new(let origin):
            rect = spanned(origin, toPixels(p))
        case .idle:
            return
        }
        onChange?(rect)
    }

    override func mouseUp(with e: NSEvent) {
        drag = .idle
        if rect.width < 2 || rect.height < 2 { rect = CGRect(origin: .zero, size: pixelSize); applyAspect() }
        onChange?(rect)
    }

    /// Rectangle from an anchor corner to a point, honouring the aspect ratio and the image bounds.
    private func spanned(_ a: CGPoint, _ p: CGPoint) -> CGRect {
        var w = abs(p.x - a.x), h = abs(p.y - a.y)
        if let asp = aspect {
            h = w / asp
            let sx: CGFloat = p.x >= a.x ? 1 : -1, sy: CGFloat = p.y >= a.y ? 1 : -1
            let maxH = sy > 0 ? pixelSize.height - a.y : a.y
            if h > maxH { h = maxH; w = h * asp }
            return CGRect(x: min(a.x, a.x + sx * w), y: min(a.y, a.y + sy * h), width: w, height: h)
        }
        return CGRect(x: min(a.x, p.x), y: min(a.y, p.y), width: w, height: h)
    }

    func applyAspect() {
        guard let asp = aspect else { onChange?(rect); return }
        var w = rect.width, h = w / asp
        if h > pixelSize.height { h = pixelSize.height; w = h * asp }
        if w > pixelSize.width { w = pixelSize.width; h = w / asp }
        var r = CGRect(x: rect.midX - w / 2, y: rect.midY - h / 2, width: w, height: h)
        r.origin.x = min(max(r.minX, 0), pixelSize.width - w)
        r.origin.y = min(max(r.minY, 0), pixelSize.height - h)
        rect = r
        onChange?(rect)
    }
}

// MARK: - Trim

final class TrimEditor: NSObject {
    private static var open: [TrimEditor] = []        // one per window: a second editor must not orphan the first
    private let urls: [URL]
    private let window: NSWindow
    private let duration: Double
    private let start = NSSlider(), end = NSSlider()
    private let startLabel = NSTextField(labelWithString: ""), endLabel = NSTextField(labelWithString: "")
    private let preview = NSImageView()
    private let isVideo: Bool
    private var pending: DispatchWorkItem?
    private var renders = 0                      // a cancelled-but-running render must not overwrite a newer one

    static func show(_ urls: [URL]) {
        do { open.append(try TrimEditor(urls: urls)) } catch { Editors.alert("Trim", error.localizedDescription) }
    }

    private init(urls: [URL]) throws {
        self.urls = urls
        let first = urls[0]
        isVideo = Formats.identify(first)?.kind == .video
        duration = try Tools.duration(first)
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: isVideo ? 520 : 170),
                          styleMask: [.titled, .closable], backing: .buffered, defer: false)
        super.init()
        window.isReleasedWhenClosed = false          // this object owns the window; AppKit must not release it on close
        window.title = "Trim · \(first.lastPathComponent)" + (urls.count > 1 ? " (+\(urls.count - 1) more, same times)" : "")
        let content = window.contentView!
        if isVideo {
            preview.frame = NSRect(x: 16, y: 170, width: 608, height: 334)
            preview.imageScaling = .scaleProportionallyUpOrDown
            content.addSubview(preview)
        }
        for (slider, label, y, value) in [(start, startLabel, 116, 0.0), (end, endLabel, 76, duration)] {
            slider.minValue = 0
            slider.maxValue = duration
            slider.doubleValue = value
            slider.frame = NSRect(x: 16, y: CGFloat(y), width: 500, height: 24)
            slider.target = self
            slider.action = #selector(changed)
            slider.isContinuous = true
            content.addSubview(slider)
            label.frame = NSRect(x: 524, y: CGFloat(y + 2), width: 100, height: 20)
            label.alignment = .right
            content.addSubview(label)
        }
        let hint = NSTextField(labelWithString: "Start · End")
        hint.frame = NSRect(x: 16, y: 140, width: 300, height: 18)
        hint.textColor = .secondaryLabelColor
        content.addSubview(hint)
        let apply = NSButton(title: "Trim", target: self, action: #selector(apply))
        apply.frame = NSRect(x: 540, y: 16, width: 84, height: 32)
        apply.keyEquivalent = "\r"
        content.addSubview(apply)
        changed()
        NotificationCenter.default.addObserver(self, selector: #selector(closed), name: NSWindow.willCloseNotification, object: window)
        window.center()
        window.makeKeyAndOrderFront(nil)
    }

    private static func clock(_ t: Double) -> String {
        String(format: "%d:%02d.%d", Int(t) / 60, Int(t) % 60, Int(t * 10) % 10)
    }

    @objc private func changed() {
        if end.doubleValue <= start.doubleValue { end.doubleValue = min(start.doubleValue + 0.5, duration) }
        startLabel.stringValue = Self.clock(start.doubleValue)
        endLabel.stringValue = Self.clock(end.doubleValue)
        guard isVideo else { return }
        pending?.cancel()
        renders += 1
        let t = start.doubleValue, url = urls[0], id = renders
        let work = DispatchWorkItem { [weak self] in
            let png = Naming.temp(ext: "png")
            defer { try? FileManager.default.removeItem(at: png) }
            guard let ff = EngineLocator.path(for: .ffmpeg),
                  (try? Runner.shell(ff, Convert.ffBase + ["-ss", String(t), "-i", url.path, "-frames:v", "1", "-vf", "scale=608:-2", png.path])) != nil,
                  let img = NSImage(contentsOf: png) else { return }
            DispatchQueue.main.async { guard let self, id == self.renders else { return }; self.preview.image = img }
        }
        pending = work
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.2, execute: work)
    }

    @objc private func apply() {
        let s = start.doubleValue, e = end.doubleValue, urls = self.urls
        window.close()
        Editors.run(urls.map { (u: URL) -> () throws -> Plan in { try Tools.trimPlan(u, start: s, end: e) } }, title: "Trim")
    }

    @objc private func closed() { TrimEditor.open.removeAll { $0 === self } }
}

// MARK: - Reorder pages

final class ReorderEditor: NSObject, NSTableViewDataSource, NSTableViewDelegate {
    private static var open: [ReorderEditor] = []        // one per window: a second editor must not orphan the first
    private let url: URL
    private let doc: PDFDocument
    private var order: [Int]
    private let window: NSWindow
    private let table = NSTableView()

    static func show(_ url: URL) {
        guard let doc = PDFDocument(url: url) else { Editors.alert("Reorder Pages", "Could not open \(url.lastPathComponent)"); return }
        open.append(ReorderEditor(url: url, doc: doc))
    }

    private init(url: URL, doc: PDFDocument) {
        self.url = url
        self.doc = doc
        order = Array(0..<doc.pageCount)
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 440, height: 560),
                          styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        super.init()
        window.isReleasedWhenClosed = false          // this object owns the window; AppKit must not release it on close
        window.title = "Reorder Pages · \(url.lastPathComponent)"
        let content = window.contentView!
        let scroll = NSScrollView(frame: NSRect(x: 16, y: 60, width: 408, height: 484))
        scroll.autoresizingMask = [.width, .height]
        scroll.hasVerticalScroller = true
        let thumb = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("thumb"))
        thumb.width = 70
        let name = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("name"))
        name.width = 300
        table.addTableColumn(thumb)
        table.addTableColumn(name)
        table.headerView = nil
        table.rowHeight = 72
        table.dataSource = self
        table.delegate = self
        scroll.documentView = table
        content.addSubview(scroll)

        var x: CGFloat = 16
        for (title, sel) in [("↑", #selector(up)), ("↓", #selector(down)), ("Remove", #selector(remove)), ("Reverse", #selector(reverse))] {
            let b = NSButton(title: title, target: self, action: sel)
            b.frame = NSRect(x: x, y: 16, width: title.count > 2 ? 80 : 40, height: 32)
            b.autoresizingMask = [.maxXMargin, .maxYMargin]
            content.addSubview(b)
            x += b.frame.width + 8
        }
        let apply = NSButton(title: "Save Copy", target: self, action: #selector(apply))
        apply.frame = NSRect(x: 324, y: 16, width: 100, height: 32)
        apply.keyEquivalent = "\r"
        apply.autoresizingMask = [.minXMargin, .maxYMargin]
        content.addSubview(apply)
        NotificationCenter.default.addObserver(self, selector: #selector(closed), name: NSWindow.willCloseNotification, object: window)
        window.center()
        window.makeKeyAndOrderFront(nil)
    }

    func numberOfRows(in tableView: NSTableView) -> Int { order.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let page = order[row]
        if tableColumn?.identifier.rawValue == "thumb" {
            let v = NSImageView(frame: NSRect(x: 0, y: 0, width: 60, height: 70))
            v.image = doc.page(at: page)?.thumbnail(of: NSSize(width: 56, height: 68), for: .mediaBox)
            v.imageScaling = .scaleProportionallyDown
            return v
        }
        return NSTextField(labelWithString: "Page \(page + 1)")
    }

    private func move(_ delta: Int) {
        let r = table.selectedRow
        guard r >= 0, r + delta >= 0, r + delta < order.count else { return }
        order.swapAt(r, r + delta)
        table.reloadData()
        table.selectRowIndexes(IndexSet(integer: r + delta), byExtendingSelection: false)
    }

    @objc private func up() { move(-1) }
    @objc private func down() { move(1) }
    @objc private func remove() {
        let r = table.selectedRow
        guard r >= 0, order.count > 1 else { return }
        order.remove(at: r)
        table.reloadData()
    }
    @objc private func reverse() { order.reverse(); table.reloadData() }
    @objc private func apply() {
        let plan = Tools.reorderPlan(url, order: order)
        window.close()
        Editors.run([{ plan }], title: "Reorder Pages")
    }
    @objc private func closed() { ReorderEditor.open.removeAll { $0 === self } }
}

// MARK: - Metadata

final class MetadataEditor: NSObject {
    private static var open: [MetadataEditor] = []        // one per window: a second editor must not orphan the first
    private let url: URL
    private let window: NSWindow
    private let text = NSTextView()
    private let title = NSTextField(), author = NSTextField(), comment = NSTextField()

    static func show(_ url: URL) { open.append(MetadataEditor(url: url)) }

    private init(url: URL) {
        self.url = url
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 560),
                          styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        super.init()
        window.isReleasedWhenClosed = false          // this object owns the window; AppKit must not release it on close
        window.title = "Metadata · \(url.lastPathComponent)"
        let content = window.contentView!
        let scroll = NSScrollView(frame: NSRect(x: 16, y: 170, width: 568, height: 374))
        scroll.autoresizingMask = [.width, .height]
        scroll.hasVerticalScroller = true
        text.isEditable = false
        text.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        text.frame = scroll.bounds
        text.autoresizingMask = [.width]
        text.isVerticallyResizable = true
        text.textContainer?.widthTracksTextView = true
        scroll.documentView = text
        content.addSubview(scroll)

        let fields = Self.read(url)
        text.string = fields.map { "\($0.0): \($0.1)" }.joined(separator: "\n")
        let lower = Dictionary(fields.map { ($0.0.lowercased(), $0.1) }, uniquingKeysWith: { a, _ in a })
        func pick(_ keys: [String]) -> String { keys.compactMap { k in lower.first { $0.key.hasSuffix(k) }?.value }.first ?? "" }
        title.stringValue = pick(["imagedescription", "title"])
        author.stringValue = pick(["artist", "author"])
        comment.stringValue = pick(["usercomment", "comment", "subject"])

        var y: CGFloat = 128
        for (label, field) in [("Title", title), ("Author", author), ("Comment", comment)] {
            let l = NSTextField(labelWithString: label)
            l.frame = NSRect(x: 16, y: y + 3, width: 70, height: 20)
            l.autoresizingMask = [.maxYMargin]
            content.addSubview(l)
            field.frame = NSRect(x: 90, y: y, width: 494, height: 24)
            field.autoresizingMask = [.width, .maxYMargin]
            content.addSubview(field)
            y -= 34
        }
        let copy = NSButton(title: "Copy All", target: self, action: #selector(copyAll))
        copy.frame = NSRect(x: 16, y: 16, width: 100, height: 32)
        copy.autoresizingMask = [.maxYMargin]
        content.addSubview(copy)
        let strip = NSButton(title: "Remove All & Save Copy", target: self, action: #selector(removeAll))
        strip.frame = NSRect(x: 124, y: 16, width: 200, height: 32)
        strip.autoresizingMask = [.maxYMargin]
        content.addSubview(strip)
        let save = NSButton(title: "Save Copy with Fields", target: self, action: #selector(save))
        save.frame = NSRect(x: 400, y: 16, width: 184, height: 32)
        save.keyEquivalent = "\r"
        save.autoresizingMask = [.minXMargin, .maxYMargin]
        content.addSubview(save)
        NotificationCenter.default.addObserver(self, selector: #selector(closed), name: NSWindow.willCloseNotification, object: window)
        window.center()
        window.makeKeyAndOrderFront(nil)
    }

    /// Image: ImageIO properties. PDF: document attributes. Audio/video: ffprobe format + stream fields.
    static func read(_ url: URL) -> [(String, String)] {
        switch Formats.identify(url)?.kind {
        case .image: return Native.imageMetadata(url)
        case .document: return Native.pdfMetadata(url)
        case .audio, .video:
            guard let ff = EngineLocator.path(for: .ffmpeg) else { return [("ffmpeg", "not installed: brew install ffmpeg")] }
            let probe = URL(fileURLWithPath: ff).deletingLastPathComponent().appendingPathComponent("ffprobe").path
            let p = Process()
            p.executableURL = URL(fileURLWithPath: probe)
            p.arguments = ["-v", "error", "-show_format", "-show_streams", "-of", "flat", url.path]
            let pipe = Pipe(); p.standardOutput = pipe; p.standardError = FileHandle.nullDevice
            guard (try? p.run()) != nil else { return [] }
            let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            p.waitUntilExit()
            return out.split(separator: "\n").compactMap { line -> (String, String)? in
                let parts = line.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
                guard parts.count == 2 else { return nil }
                return (String(parts[0]), String(parts[1]).trimmingCharacters(in: CharacterSet(charactersIn: "\"")))
            }
        default: return []
        }
    }

    @objc private func copyAll() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text.string, forType: .string)
    }

    @objc private func removeAll() {
        let u = url
        window.close()
        Editors.run([{ try Tools.plan(Tools.tool("strip"), inputs: [u])[0] }], title: "Strip Metadata")
    }

    @objc private func save() {
        var fields: [String: String] = [:]
        if !title.stringValue.isEmpty { fields["title"] = title.stringValue }
        if !author.stringValue.isEmpty { fields["author"] = author.stringValue }
        if !comment.stringValue.isEmpty { fields["comment"] = comment.stringValue }
        let u = url
        window.close()
        Editors.run([{ try Tools.metadataPlan(u, fields: fields) }], title: "Metadata")
    }

    @objc private func closed() { MetadataEditor.open.removeAll { $0 === self } }
}
#endif
