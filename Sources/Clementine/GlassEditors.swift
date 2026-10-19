#if canImport(AppKit)
import AppKit
import ServiceManagement

/// Tangerine's editor window: a rounded glass panel (Liquid Glass on macOS 26, a behind-window
/// blur before) tinted by whatever is behind it, a round ✕ at the top left, a centred bold title,
/// a hairline under the header, and orange controls. `body` is top-down (flipped) below the header.
final class GlassSheet: NSWindow {
    static let header: CGFloat = 58
    let body: FlippedView
    var onClose: (() -> Void)?

    init(title: String, size: NSSize) {
        let frame = NSRect(origin: .zero, size: size)
        body = FlippedView(frame: NSRect(x: 0, y: 0, width: size.width, height: size.height - Self.header))
        super.init(contentRect: frame, styleMask: [.borderless, .resizable], backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        isMovableByWindowBackground = true
        isReleasedWhenClosed = false
        appearance = NSAppearance(named: .aqua)
        level = .floating

        let root = NSView(frame: frame)
        var glass: NSView?
#if compiler(>=6.2)
        if #available(macOS 26.0, *) {
            let g = NSGlassEffectView(frame: frame)
            g.cornerRadius = 26
            g.tintColor = NSColor(srgbRed: 1, green: 0.62, blue: 0.2, alpha: 0.10)   // Tangerine's warm cast
            glass = g
        }
#endif
        if glass == nil {
            let v = NSVisualEffectView(frame: frame)
            v.material = .popover
            v.blendingMode = .behindWindow
            v.state = .active
            v.maskImage = NSImage(size: size, flipped: false) { r in NSColor.black.setFill(); NSBezierPath(roundedRect: r, xRadius: 26, yRadius: 26).fill(); return true }
            glass = v
        }
        glass!.autoresizingMask = [.width, .height]
        root.addSubview(glass!)

        let close = NSButton(title: "", target: nil, action: #selector(NSWindow.performClose(_:)))
        close.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: "Close")?.withSymbolConfiguration(.init(pointSize: 13, weight: .semibold))
        close.isBordered = false
        close.contentTintColor = NSColor(calibratedWhite: 0.15, alpha: 0.85)
        close.frame = NSRect(x: 16, y: size.height - 16 - 30, width: 30, height: 30)
        close.wantsLayer = true
        close.layer?.cornerRadius = 15
        close.layer?.backgroundColor = NSColor(calibratedWhite: 0, alpha: 0.07).cgColor
        close.autoresizingMask = [.maxXMargin, .minYMargin]
        root.addSubview(close)

        let t = NSTextField(labelWithString: title)
        t.font = .systemFont(ofSize: 17, weight: .bold)
        t.textColor = NSColor(calibratedWhite: 0.12, alpha: 0.9)
        t.alignment = .center
        t.frame = NSRect(x: 60, y: size.height - 16 - 26, width: size.width - 120, height: 24)
        t.autoresizingMask = [.width, .minYMargin]
        root.addSubview(t)

        let line = NSView(frame: NSRect(x: 0, y: size.height - Self.header, width: size.width, height: 1))
        line.wantsLayer = true
        line.layer?.backgroundColor = NSColor(calibratedWhite: 0, alpha: 0.08).cgColor
        line.autoresizingMask = [.width, .minYMargin]
        root.addSubview(line)

        body.autoresizingMask = [.width, .height]
        root.addSubview(body)
        contentView = root
        NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: self, queue: .main) { [weak self] _ in self?.onClose?() }
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
    override func cancelOperation(_ sender: Any?) { close() }
    override func performClose(_ sender: Any?) { close() }

    func present() {
        center()
        NSApp.activate(ignoringOtherApps: true)
        makeKeyAndOrderFront(nil)
    }

    // MARK: controls in Tangerine's style

    static func label(_ s: String, size: CGFloat = 13.5, weight: NSFont.Weight = .regular, color: NSColor = NSColor(calibratedWhite: 0.12, alpha: 0.85)) -> NSTextField {
        let l = NSTextField(labelWithString: s)
        l.font = .systemFont(ofSize: size, weight: weight)
        l.textColor = color
        return l
    }

    static func slider(_ v: Double, _ lo: Double, _ hi: Double, target: AnyObject, action: Selector) -> NSSlider {
        let s = NSSlider(value: v, minValue: lo, maxValue: hi, target: target, action: action)
        s.trackFillColor = WheelView.orange
        s.isContinuous = true
        return s
    }

    static func button(_ title: String, primary: Bool = false, target: AnyObject, action: Selector) -> NSButton {
        let b = NSButton(title: title, target: target, action: action)
        b.bezelStyle = .rounded
        b.controlSize = .large
        if primary { b.bezelColor = WheelView.orange; b.keyEquivalent = "\r" }
        return b
    }
}

final class FlippedView: NSView { override var isFlipped: Bool { true } }

/// A rounded colour / gradient / image chip; an orange ring when selected.
final class Swatch: NSControl {
    var draw: (CGContext, CGRect) -> Void = { _, _ in }
    var selected = false { didSet { needsDisplay = true } }
    var onPick: (() -> Void)?

    override func draw(_ dirtyRect: NSRect) {
        let cg = NSGraphicsContext.current!.cgContext
        let r = bounds.insetBy(dx: 3, dy: 3)
        let shape = CGPath(roundedRect: r, cornerWidth: 8, cornerHeight: 8, transform: nil)
        cg.saveGState(); cg.addPath(shape); cg.clip(); draw(cg, r); cg.restoreGState()
        cg.addPath(shape); cg.setStrokeColor(NSColor(calibratedWhite: 0, alpha: 0.1).cgColor); cg.setLineWidth(0.5); cg.strokePath()
        if selected {
            cg.addPath(CGPath(roundedRect: bounds.insetBy(dx: 1.2, dy: 1.2), cornerWidth: 10, cornerHeight: 10, transform: nil))
            cg.setStrokeColor(WheelView.orange.cgColor); cg.setLineWidth(2.4); cg.strokePath()
        }
    }
    override func mouseDown(with event: NSEvent) { onPick?() }
}

// MARK: - Add BG

final class BackgroundEditor: NSObject {
    private static var open: [BackgroundEditor] = []
    private let urls: [URL]
    private let sheet: GlassSheet
    private let preview = NSImageView()
    private let source: CGImage                 // ≤ 1200 px copy for the live preview
    private let scale: Double                   // preview px per source px
    private var style = Backdrop()
    private var defaults = Backdrop()
    private var swatches: [Swatch] = []
    private let well = NSColorWell()
    private var sliders: [String: (NSSlider, NSTextField)] = [:]
    private let ratio = NSSegmentedControl(labels: ["Auto", "1:1", "16:9", "4:5"], trackingMode: .selectOne, target: nil, action: nil)
    private var pending: DispatchWorkItem?
    private var renders = 0

    static let gradients: [[[Double]]] = [
        [[0.36, 0.86, 0.96], [0.14, 0.72, 0.76]],                       // lagoon
        [[0.98, 0.96, 1.0], [0.56, 0.62, 0.99]],                        // lilac sky
        [[1.0, 0.88, 0.84], [0.98, 0.98, 1.0], [0.82, 0.88, 1.0]],      // pastel
        [[1.0, 1.0, 1.0], [0.45, 0.78, 1.0]],                           // cloud (Tangerine's default look)
        [[0.02, 0.10, 0.11], [0.0, 0.46, 0.42]],                        // deep teal
        [[1.0, 0.74, 0.46], [0.98, 0.42, 0.55]],                        // peach
        [[0.45, 0.76, 1.0], [0.32, 0.45, 0.96]],                        // ocean
        [[0.14, 0.70, 0.76], [0.26, 0.82, 0.55]],                       // mint
    ]
    /// The macOS wallpapers on this Mac that are full-size files (the rest download on demand and
    /// only keep a small thumbnail locally), plus the default desktop picture.
    static let wallpapers: [URL] = {
        let fm = FileManager.default
        let dir = URL(fileURLWithPath: "/System/Library/Desktop Pictures")
        var out = ((try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? [])
            .filter { ["heic", "jpg", "jpeg", "png"].contains($0.pathExtension.lowercased()) }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
        let def = URL(fileURLWithPath: "/System/Library/CoreServices/DefaultDesktop.heic")
        if fm.fileExists(atPath: def.path), !out.contains(where: { $0.resolvingSymlinksInPath() == def.resolvingSymlinksInPath() }) { out.insert(def, at: 0) }
        return out
    }()
    static var thumbs: [URL: CGImage] = [:]

    static let solids: [[Double]] = [
        [0.24, 0.40, 0.88], [0.15, 0.22, 0.33], [0.48, 0.30, 0.78], [0.66, 0.56, 0.86], [0.86, 0.36, 0.55],
        [0.84, 0.22, 0.22], [0.94, 0.42, 0.36], [0.94, 0.55, 0.16], [0.45, 0.30, 0.20], [1, 1, 1],
    ]

    static func show(_ urls: [URL]) {
        guard let img = Native.loadImage(urls[0], maxPixels: 1200), let full = Optional(Native.imageSize(urls[0])), full.width > 0 else {
            Editors.alert("Add BG", "Could not read \(urls[0].lastPathComponent)"); return
        }
        open.append(BackgroundEditor(urls: urls, image: img, fullWidth: Double(max(full.width, full.height))))
    }

    private init(urls: [URL], image: CGImage, fullWidth: Double) {
        self.urls = urls
        source = image
        scale = Double(max(image.width, image.height)) / fullWidth
        sheet = GlassSheet(title: "Add BG", size: NSSize(width: 540, height: 812))
        super.init()
        let long = fullWidth
        defaults = Backdrop(fill: .gradient(Self.gradients[3]), padding: (long * 0.12).rounded(), corners: (long * 0.02).rounded(), shadow: (long * 0.025).rounded())
        style = defaults
        let b = sheet.body
        let W = b.bounds.width

        let box = NSView(frame: NSRect(x: 20, y: 14, width: W - 40, height: 340))
        box.wantsLayer = true
        box.layer?.cornerRadius = 16
        box.layer?.backgroundColor = NSColor(calibratedWhite: 0, alpha: 0.06).cgColor
        b.addSubview(box)
        preview.frame = box.bounds.insetBy(dx: 16, dy: 16)
        preview.imageScaling = .scaleProportionallyUpOrDown
        box.addSubview(preview)

        // Background: gradients (and a blurred copy of the photo) on row 1, colours on row 2,
        // then a custom image and a colour well, like Tangerine's grid.
        let bgLabel = GlassSheet.label("Background"); bgLabel.frame = NSRect(x: 24, y: 378, width: 110, height: 20); b.addSubview(bgLabel)
        let cell: CGFloat = 36, x0: CGFloat = 132
        let row1: [Backdrop.Fill] = [.blur] + Self.gradients.map { .gradient($0) }
        let row2: [Backdrop.Fill] = Self.solids.prefix(9).map { .color($0) }
        for (r, fills) in [row1, row2].enumerated() {
            for (i, fill) in fills.enumerated() {
                let sw = Swatch(frame: NSRect(x: x0 + CGFloat(i) * cell, y: 370 + CGFloat(r) * (cell + 4), width: cell, height: cell))
                sw.draw = { [weak self] cg, rect in self?.paint(fill, cg, rect) }
                sw.onPick = { [weak self, weak sw] in self?.pick(fill, sw) }
                b.addSubview(sw)
                swatches.append(sw)
                if case .gradient(let g) = fill, g == Self.gradients[3] { sw.selected = true }
            }
        }
        let imageButton = NSButton(title: "", target: self, action: #selector(chooseImage))
        imageButton.image = NSImage(systemSymbolName: "photo.badge.plus", accessibilityDescription: "Image background")
        imageButton.bezelStyle = .regularSquare
        imageButton.isBordered = true
        imageButton.frame = NSRect(x: x0 + 9 * cell + 4, y: 373, width: cell - 6, height: cell - 6)
        imageButton.toolTip = "Use an image as the background"
        b.addSubview(imageButton)
        well.frame = NSRect(x: x0 + 9 * cell + 2, y: 370 + cell + 8, width: cell - 2, height: cell - 10)
        well.color = NSColor(srgbRed: 0.24, green: 0.4, blue: 0.88, alpha: 1)
        if #available(macOS 13.0, *) { well.colorWellStyle = .minimal }
        well.target = self
        well.action = #selector(wellChanged)
        b.addSubview(well)

        // Row 3: the full-size wallpapers that ship with macOS, scrolling sideways.
        let wl = GlassSheet.label("Wallpapers"); wl.frame = NSRect(x: 24, y: 462, width: 110, height: 20); b.addSubview(wl)
        let strip = NSScrollView(frame: NSRect(x: x0, y: 452, width: W - x0 - 20, height: 42))
        strip.drawsBackground = false
        strip.hasHorizontalScroller = true
        strip.autohidesScrollers = true
        strip.horizontalScrollElasticity = .allowed
        let walls = Self.wallpapers
        let doc = FlippedView(frame: NSRect(x: 0, y: 0, width: CGFloat(walls.count) * 56, height: 40))
        for (i, u) in walls.enumerated() {
            let sw = Swatch(frame: NSRect(x: CGFloat(i) * 56, y: 0, width: 56, height: 40))
            sw.toolTip = u.deletingPathExtension().lastPathComponent
            sw.draw = { cg, rect in
                guard let t = BackgroundEditor.thumbs[u] else { cg.setFillColor(CGColor(gray: 0.85, alpha: 1)); cg.fill(rect); return }
                let k = max(rect.width / CGFloat(t.width), rect.height / CGFloat(t.height))
                cg.draw(t, in: CGRect(x: rect.midX - CGFloat(t.width) * k / 2, y: rect.midY - CGFloat(t.height) * k / 2, width: CGFloat(t.width) * k, height: CGFloat(t.height) * k))
            }
            sw.onPick = { [weak self, weak sw] in self?.pick(.image(u), sw) }
            doc.addSubview(sw)
            swatches.append(sw)
            if BackgroundEditor.thumbs[u] == nil {      // 6K HEICs: decode small, off the main thread, once per launch
                DispatchQueue.global(qos: .userInitiated).async {
                    // macOS keeps a ready-made thumbnail beside each wallpaper; decode the 6K original only without one.
                    let small = u.deletingLastPathComponent().appendingPathComponent(".thumbnails").appendingPathComponent(u.lastPathComponent)
                    guard let t = Native.loadImage(FileManager.default.fileExists(atPath: small.path) ? small : u, maxPixels: 160) else { return }
                    DispatchQueue.main.async { BackgroundEditor.thumbs[u] = t; sw.needsDisplay = true }
                }
            }
        }
        strip.documentView = doc
        b.addSubview(strip)
        if walls.isEmpty { wl.isHidden = true }

        var y: CGFloat = 520
        for (key, title, hi) in [("padding", "Padding", long * 0.5), ("corners", "Corners", long * 0.2), ("shadow", "Shadow", long * 0.1)] {
            let l = GlassSheet.label(title); l.frame = NSRect(x: 24, y: y + 2, width: 100, height: 20); b.addSubview(l)
            let v: Double = key == "padding" ? style.padding : key == "corners" ? style.corners : style.shadow
            let s = GlassSheet.slider(v, 0, max(hi.rounded(), 1), target: self, action: #selector(changed))
            s.frame = NSRect(x: 132, y: y, width: W - 132 - 100, height: 24)
            b.addSubview(s)
            let value = GlassSheet.label("\(Int(v)) px"); value.alignment = .right
            value.frame = NSRect(x: W - 96, y: y + 2, width: 72, height: 20)
            b.addSubview(value)
            sliders[key] = (s, value)
            y += 44
        }
        let rl = GlassSheet.label("Ratio"); rl.frame = NSRect(x: 24, y: y + 4, width: 100, height: 20); b.addSubview(rl)
        ratio.selectedSegment = 0
        ratio.selectedSegmentBezelColor = WheelView.orange
        ratio.target = self
        ratio.action = #selector(changed)
        ratio.controlSize = .large
        ratio.sizeToFit()
        ratio.frame.origin = NSPoint(x: W - 24 - ratio.frame.width, y: y)
        b.addSubview(ratio)

        let line = NSView(frame: NSRect(x: 0, y: y + 50, width: W, height: 1))
        line.wantsLayer = true; line.layer?.backgroundColor = NSColor(calibratedWhite: 0, alpha: 0.08).cgColor
        b.addSubview(line)
        let reset = GlassSheet.button("Reset", target: self, action: #selector(resetAll))
        reset.sizeToFit(); reset.frame.origin = NSPoint(x: 24, y: y + 64); b.addSubview(reset)
        let save = GlassSheet.button(urls.count > 1 ? "Save \(urls.count) with Background" : "Save with Background", primary: true, target: self, action: #selector(saveAll))
        save.sizeToFit(); save.frame.origin = NSPoint(x: W - 24 - save.frame.width, y: y + 64); b.addSubview(save)

        sheet.onClose = { [weak self] in BackgroundEditor.open.removeAll { $0 === self } }
        sheet.present()
        render()
    }

    private func paint(_ fill: Backdrop.Fill, _ cg: CGContext, _ r: CGRect) {
        switch fill {
        case .color(let c): cg.setFillColor(Native.cg(c)); cg.fill(r)
        case .gradient(let g):
            cg.drawLinearGradient(CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: g.map(Native.cg) as CFArray, locations: nil)!,
                                  start: CGPoint(x: r.minX, y: r.maxY), end: CGPoint(x: r.maxX, y: r.minY), options: [])
        case .blur:
            if let bg = try? Native.backdrop(source, Backdrop(fill: .blur, padding: 0)) {
                let ci = CIImage(cgImage: bg).applyingGaussianBlur(sigma: 18)
                if let b = CIContext().createCGImage(ci, from: CIImage(cgImage: bg).extent) { cg.draw(b, in: r) }
            }
        case .image: break
        }
    }

    private func pick(_ fill: Backdrop.Fill, _ chosen: Swatch?) {
        swatches.forEach { $0.selected = $0 === chosen }
        style.fill = fill
        render()
    }

    @objc private func wellChanged() {
        let c = well.color.usingColorSpace(.sRGB) ?? .white
        swatches.forEach { $0.selected = false }
        style.fill = .color([Double(c.redComponent), Double(c.greenComponent), Double(c.blueComponent)])
        render()
    }

    @objc private func chooseImage() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.prompt = "Use as Background"
        guard panel.runModal() == .OK, let u = panel.url else { return }
        swatches.forEach { $0.selected = false }
        style.fill = .image(u)
        render()
    }

    @objc private func changed() {
        for (k, (s, l)) in sliders {
            let v = s.doubleValue.rounded()
            l.stringValue = "\(Int(v)) px"
            switch k { case "padding": style.padding = v; case "corners": style.corners = v; default: style.shadow = v }
        }
        style.ratio = [nil, 1, 16.0 / 9, 4.0 / 5][ratio.selectedSegment]
        render()
    }

    @objc private func resetAll() {
        style = defaults
        for (k, (s, _)) in sliders { s.doubleValue = k == "padding" ? style.padding : k == "corners" ? style.corners : style.shadow }
        ratio.selectedSegment = 0
        swatches.forEach { $0.selected = false }
        swatches[4].selected = true             // the default gradient (after Blur + 3)
        changed()
    }

    /// Preview at preview scale on a background queue; a newer render wins.
    private func render() {
        pending?.cancel()
        renders += 1
        var b = style
        b.padding *= scale; b.corners *= scale; b.shadow *= scale
        let src = source, id = renders
        let work = DispatchWorkItem { [weak self] in
            guard let out = try? Native.backdrop(src, b) else { return }
            let img = NSImage(cgImage: out, size: NSSize(width: out.width, height: out.height))
            DispatchQueue.main.async { guard let self, id == self.renders else { return }; self.preview.image = img }
        }
        pending = work
        DispatchQueue.global(qos: .userInteractive).asyncAfter(deadline: .now() + 0.03, execute: work)
    }

    @objc private func saveAll() {
        let b = style, urls = self.urls
        sheet.close()
        Editors.run(urls.map { (u: URL) -> () throws -> Plan in {
            // PNG keeps the rounded corners crisp; JPEG sources stay JPEG.
            let ext = ["jpg", "heic"].contains(Formats.identify(u)?.id ?? "") ? "jpg" : "png"
            let o = Naming.sibling(of: u, ext: ext, suffix: " with background")
            return Plan(steps: [.native(.background(u, o, b))], outputs: [o])
        } }, title: "Add BG", done: Editors.reveal)
    }
}

// MARK: - Annotate

final class AnnotateEditor: NSObject {
    private static var open: [AnnotateEditor] = []
    private let url: URL
    private let sheet: GlassSheet
    private let canvas: AnnotateCanvas
    private let tools = NSSegmentedControl(labels: ["Pen", "Highlight", "Arrow", "Box", "Text"], trackingMode: .selectOne, target: nil, action: nil)
    private var colorSwatches: [Swatch] = []
    private var widthSlider: NSSlider!

    static let colors: [[Double]] = [[0.93, 0.24, 0.2], [0.98, 0.55, 0.1], [1.0, 0.84, 0.1], [0.2, 0.75, 0.35], [0.2, 0.5, 0.98], [0.1, 0.1, 0.1], [1, 1, 1]]

    static func show(_ urls: [URL]) {
        for u in urls {
            guard let img = Native.loadImage(u, maxPixels: 2000) else { Editors.alert("Annotate", "Could not read \(u.lastPathComponent)"); continue }
            open.append(AnnotateEditor(url: u, image: img))
        }
    }

    private init(url: URL, image: CGImage) {
        self.url = url
        sheet = GlassSheet(title: "Annotate", size: NSSize(width: 720, height: 680))
        canvas = AnnotateCanvas(image: image)
        super.init()
        let b = sheet.body
        let W = b.bounds.width
        let box = NSView(frame: NSRect(x: 20, y: 14, width: W - 40, height: 470))
        box.wantsLayer = true
        box.layer?.cornerRadius = 16
        box.layer?.backgroundColor = NSColor(calibratedWhite: 0, alpha: 0.75).cgColor
        b.addSubview(box)
        canvas.frame = box.bounds.insetBy(dx: 10, dy: 10)
        canvas.autoresizingMask = [.width, .height]
        box.addSubview(canvas)

        tools.selectedSegment = 0
        tools.selectedSegmentBezelColor = WheelView.orange
        tools.target = self
        tools.action = #selector(toolChanged)
        tools.controlSize = .large
        tools.sizeToFit()
        tools.frame.origin = NSPoint(x: 24, y: 500)
        b.addSubview(tools)
        for (i, c) in Self.colors.enumerated() {
            let sw = Swatch(frame: NSRect(x: W - 24 - CGFloat(Self.colors.count - i) * 32, y: 498, width: 32, height: 32))
            sw.draw = { cg, r in cg.setFillColor(Native.cg(c)); cg.fillEllipse(in: r.insetBy(dx: 2, dy: 2)) }
            sw.onPick = { [weak self, weak sw] in self?.colorSwatches.forEach { $0.selected = $0 === sw }; self?.canvas.rgba = c }
            sw.selected = i == 0
            b.addSubview(sw)
            colorSwatches.append(sw)
        }
        let wl = GlassSheet.label("Size"); wl.frame = NSRect(x: 24, y: 552, width: 60, height: 20); b.addSubview(wl)
        widthSlider = GlassSheet.slider(0.008, 0.002, 0.03, target: self, action: #selector(widthChanged))
        widthSlider.frame = NSRect(x: 84, y: 550, width: 260, height: 24)
        b.addSubview(widthSlider)
        let undo = GlassSheet.button("Undo", target: canvas, action: #selector(AnnotateCanvas.undo))
        undo.keyEquivalent = "z"; undo.keyEquivalentModifierMask = .command
        undo.sizeToFit(); undo.frame.origin = NSPoint(x: W - 24 - 190, y: 546); b.addSubview(undo)
        let clear = GlassSheet.button("Clear", target: canvas, action: #selector(AnnotateCanvas.clear))
        clear.sizeToFit(); clear.frame.origin = NSPoint(x: W - 24 - 100, y: 546); b.addSubview(clear)
        let save = GlassSheet.button("Save Annotated Copy", primary: true, target: self, action: #selector(saveCopy))
        save.sizeToFit(); save.frame.origin = NSPoint(x: W - 24 - save.frame.width, y: 594); b.addSubview(save)
        sheet.onClose = { [weak self] in AnnotateEditor.open.removeAll { $0 === self } }
        sheet.present()
        sheet.makeFirstResponder(canvas)
    }

    @objc private func toolChanged() { canvas.kind = ["pen", "highlight", "arrow", "box", "text"][tools.selectedSegment] }
    @objc private func widthChanged() { canvas.width = widthSlider.doubleValue }

    @objc private func saveCopy() {
        let marks = canvas.marks, u = url
        guard !marks.isEmpty else { sheet.close(); return }
        sheet.close()
        let ext = ["jpg", "heic"].contains(Formats.identify(u)?.id ?? "") ? "jpg" : "png"
        let o = Naming.sibling(of: u, ext: ext, suffix: " annotated")
        Editors.run([{ Plan(steps: [.native(.annotate(u, o, marks))], outputs: [o]) }], title: "Annotate", done: Editors.reveal)
    }
}

/// The picture, fitted, with marks drawn live. Marks are stored in image-relative coordinates.
final class AnnotateCanvas: NSView {
    private let image: CGImage
    var marks: [Mark] = [] { didSet { needsDisplay = true } }
    var kind = "pen"
    var rgba: [Double] = AnnotateEditor.colors[0]
    var width = 0.008
    private var current: Mark?

    init(image: CGImage) { self.image = image; super.init(frame: .zero) }
    required init?(coder: NSCoder) { fatalError() }
    override var acceptsFirstResponder: Bool { true }

    private var imageRect: CGRect {
        let s = min(bounds.width / CGFloat(image.width), bounds.height / CGFloat(image.height))
        let w = CGFloat(image.width) * s, h = CGFloat(image.height) * s
        return CGRect(x: bounds.midX - w / 2, y: bounds.midY - h / 2, width: w, height: h)
    }

    private func rel(_ e: NSEvent) -> [Double] {
        let p = convert(e.locationInWindow, from: nil), r = imageRect
        return [Double(min(max((p.x - r.minX) / r.width, 0), 1)), Double(min(max((p.y - r.minY) / r.height, 0), 1))]
    }

    override func draw(_ dirtyRect: NSRect) {
        let cg = NSGraphicsContext.current!.cgContext
        let r = imageRect
        cg.draw(image, in: r)
        cg.saveGState()
        cg.translateBy(x: r.minX, y: r.minY)
        cg.clip(to: CGRect(origin: .zero, size: r.size))
        Native.drawMarks(marks + (current.map { [$0] } ?? []), in: cg, size: r.size)
        cg.restoreGState()
    }

    override func mouseDown(with e: NSEvent) {
        let p = rel(e)
        if kind == "text" {
            guard let s = PromptDialog.ask("Add text", placeholder: "Text", singleLine: true), !s.isEmpty else { return }
            marks.append(Mark(kind: "text", points: [p], rgba: rgba, width: width, text: s))
            return
        }
        current = Mark(kind: kind, points: [p], rgba: rgba, width: width)
    }

    override func mouseDragged(with e: NSEvent) {
        guard current != nil else { return }
        let p = rel(e)
        if ["arrow", "box"].contains(kind) { current!.points = [current!.points[0], p] } else { current!.points.append(p) }
        needsDisplay = true
    }

    override func mouseUp(with e: NSEvent) {
        guard var m = current else { return }
        current = nil
        if m.points.count == 1 { m.points.append(m.points[0]) }      // a click leaves a dot
        marks.append(m)
    }

    @objc func undo() { if !marks.isEmpty { marks.removeLast() } }
    @objc func clear() { marks.removeAll() }
}

// MARK: - Edit Photo

final class AdjustEditor: NSObject {
    private static var open: [AdjustEditor] = []
    private let urls: [URL]
    private let sheet: GlassSheet
    private let preview = NSImageView()
    private let source: CGImage                 // ≤ 1400 px copy for the live preview
    private var sliders: [String: (NSSlider, NSTextField)] = [:]
    private var pending: DispatchWorkItem?
    private var renders = 0

    static let light: [(String, String)] = [("exposure", "Exposure"), ("brightness", "Brightness"), ("contrast", "Contrast"), ("highlights", "Highlights"),
                                            ("shadows", "Shadows"), ("whites", "Whites"), ("blacks", "Blacks"), ("gamma", "Gamma")]
    static let color: [(String, String)] = [("temperature", "Temperature"), ("tint", "Tint"), ("saturation", "Saturation"), ("vibrance", "Vibrance")]

    static func show(_ urls: [URL]) {
        guard let img = Native.loadImage(urls[0], maxPixels: 1400) else { Editors.alert("Edit Photo", "Could not read \(urls[0].lastPathComponent)"); return }
        open.append(AdjustEditor(urls: urls, image: img))
    }

    private init(urls: [URL], image: CGImage) {
        self.urls = urls
        source = image
        sheet = GlassSheet(title: "Edit Photo", size: NSSize(width: 560, height: 860))
        super.init()
        let b = sheet.body
        let W = b.bounds.width
        let box = NSView(frame: NSRect(x: 20, y: 12, width: W - 40, height: 280))
        box.wantsLayer = true
        box.layer?.cornerRadius = 16
        box.layer?.backgroundColor = NSColor(srgbRed: 0.07, green: 0.05, blue: 0.04, alpha: 1).cgColor
        b.addSubview(box)
        preview.frame = box.bounds.insetBy(dx: 10, dy: 10)
        preview.imageScaling = .scaleProportionallyUpOrDown
        preview.image = NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
        box.addSubview(preview)

        var y: CGFloat = 306
        for (title, rows) in [("Light", Self.light), ("Color", Self.color)] {
            let h = GlassSheet.label(title, size: 13.5, weight: .semibold, color: NSColor(srgbRed: 0.72, green: 0.2, blue: 0.05, alpha: 1))
            h.frame = NSRect(x: 24, y: y, width: 200, height: 20); b.addSubview(h)
            y += 28
            for (key, label) in rows {
                let l = GlassSheet.label(label); l.frame = NSRect(x: 24, y: y + 3, width: 110, height: 20); b.addSubview(l)
                let ev = key == "exposure"
                let s = GlassSheet.slider(0, ev ? -3 : -100, ev ? 3 : 100, target: self, action: #selector(changed))
                s.frame = NSRect(x: 140, y: y, width: W - 140 - 120, height: 24); b.addSubview(s)
                let value = GlassSheet.label(ev ? "0.00 EV" : "+0"); value.alignment = .right
                value.frame = NSRect(x: W - 116, y: y + 3, width: 66, height: 20); b.addSubview(value)
                let reset = NSButton(image: NSImage(systemSymbolName: "arrow.counterclockwise", accessibilityDescription: "Reset \(label)")!, target: self, action: #selector(resetOne(_:)))
                reset.isBordered = false
                reset.contentTintColor = NSColor(calibratedWhite: 0.2, alpha: 0.6)
                reset.identifier = NSUserInterfaceItemIdentifier(key)
                reset.frame = NSRect(x: W - 44, y: y + 2, width: 20, height: 20); b.addSubview(reset)
                sliders[key] = (s, value)
                y += 30
            }
            y += 10
        }
        let line = NSView(frame: NSRect(x: 0, y: y, width: W, height: 1))
        line.wantsLayer = true; line.layer?.backgroundColor = NSColor(calibratedWhite: 0, alpha: 0.08).cgColor
        b.addSubview(line)
        let reset = GlassSheet.button("Reset", target: self, action: #selector(resetAll))
        reset.sizeToFit(); reset.frame.origin = NSPoint(x: 24, y: y + 14); b.addSubview(reset)
        let save = GlassSheet.button(urls.count > 1 ? "Save \(urls.count) Copies" : "Save Copy", primary: true, target: self, action: #selector(apply))
        save.sizeToFit(); save.frame.origin = NSPoint(x: W - 24 - save.frame.width, y: y + 14); b.addSubview(save)
        sheet.onClose = { [weak self] in AdjustEditor.open.removeAll { $0 === self } }
        sheet.present()
    }

    private var params: [String: Double] { sliders.mapValues { $0.0.doubleValue }.filter { $0.value != 0 } }

    @objc private func changed() {
        for (k, (s, l)) in sliders {
            if k == "exposure" { l.stringValue = String(format: "%.2f EV", s.doubleValue) }
            else { s.doubleValue = s.doubleValue.rounded(); l.stringValue = (s.doubleValue >= 0 ? "+" : "") + "\(Int(s.doubleValue))" }
        }
        pending?.cancel()
        renders += 1
        let p = params, src = source, id = renders
        let work = DispatchWorkItem { [weak self] in
            guard let out = try? Native.adjusted(src, p) else { return }
            let img = NSImage(cgImage: out, size: NSSize(width: out.width, height: out.height))
            DispatchQueue.main.async { guard let self, id == self.renders else { return }; self.preview.image = img }
        }
        pending = work
        DispatchQueue.global(qos: .userInteractive).asyncAfter(deadline: .now() + 0.03, execute: work)
    }

    @objc private func resetOne(_ sender: NSButton) { sliders[sender.identifier?.rawValue ?? ""]?.0.doubleValue = 0; changed() }
    @objc private func resetAll() { sliders.values.forEach { $0.0.doubleValue = 0 }; changed() }

    @objc private func apply() {
        let p = params, urls = self.urls
        sheet.close()
        guard !p.isEmpty else { return }
        Editors.run(urls.map { (u: URL) -> () throws -> Plan in {
            let fmt = Formats.identify(u)!
            let o = Naming.sibling(of: u, ext: Convert.imageIOWritable.contains(fmt.id) ? fmt.id : "png", suffix: " edited")
            return Plan(steps: [.native(.adjust(u, o, p))], outputs: [o])
        } }, title: "Edit Photo", done: Editors.reveal)
    }
}

// MARK: - Settings

final class SettingsWindow: NSObject {
    private static var shared: SettingsWindow?
    private let sheet = GlassSheet(title: "Settings", size: NSSize(width: 440, height: 492))
    private var popups: [WheelMode: NSPopUpButton] = [:]
    private let keysState = GlassSheet.label("", size: 12)
    private var allowKeys: NSButton!

    static func show() {
        if shared == nil { shared = SettingsWindow() }
        shared!.refreshAccess()
        shared!.sheet.present()
    }

    /// Keyboard control of a drag-opened wheel needs Accessibility; show whether it is on.
    private func refreshAccess() {
        let ok = AXIsProcessTrusted()
        keysState.stringValue = ok ? "✓ Arrows, Return, 1–9 and typing work on the wheel during drags"
                                   : "Arrows, Return, 1–9 and typing during drags need Accessibility access"
        keysState.textColor = ok ? NSColor(srgbRed: 0.1, green: 0.5, blue: 0.2, alpha: 1) : NSColor(calibratedWhite: 0.15, alpha: 0.8)
        allowKeys.isHidden = ok
    }

    @objc private func openAccessibility() {
        AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary)
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in self?.refreshAccess() }
    }

    private override init() {
        super.init()
        let b = sheet.body
        let head = GlassSheet.label("Hold a key while dragging a file to open a wheel", size: 12, color: NSColor(calibratedWhite: 0.1, alpha: 0.6))
        head.frame = NSRect(x: 24, y: 16, width: 392, height: 18); b.addSubview(head)
        var y: CGFloat = 46
        for m in WheelMode.allCases {
            let l = GlassSheet.label(m.title + " wheel"); l.frame = NSRect(x: 24, y: y + 4, width: 160, height: 20); b.addSubview(l)
            let p = NSPopUpButton(frame: NSRect(x: 236, y: y, width: 180, height: 28), pullsDown: false)
            p.addItems(withTitles: ModifierKey.allCases.map(\.name))
            p.target = self; p.action = #selector(keyChanged(_:))
            b.addSubview(p)
            popups[m] = p
            y += 38
        }
        let hl = GlassSheet.label("Open Wheel shortcut"); hl.frame = NSRect(x: 24, y: y + 4, width: 200, height: 20); b.addSubview(hl)
        let hot = NSPopUpButton(frame: NSRect(x: 236, y: y, width: 180, height: 28), pullsDown: false)
        hot.addItems(withTitles: HotKey.choices.map(\.name))
        hot.selectItem(withTitle: HotKey.current.name)
        hot.target = self; hot.action = #selector(hotKeyChanged(_:))
        b.addSubview(hot)
        y += 42
        let reveal = NSButton(checkboxWithTitle: "Show results in Finder when a job finishes", target: self, action: #selector(revealChanged(_:)))
        reveal.state = Editors.revealResults ? .on : .off
        reveal.frame = NSRect(x: 22, y: y + 10, width: 392, height: 20); b.addSubview(reveal)
        let login = NSButton(checkboxWithTitle: "Open Clementine at login", target: self, action: #selector(loginChanged(_:)))
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        login.frame = NSRect(x: 22, y: y + 40, width: 392, height: 20); b.addSubview(login)
        keysState.frame = NSRect(x: 24, y: y + 78, width: 392, height: 18); b.addSubview(keysState)
        allowKeys = GlassSheet.button("Allow Keyboard Control…", target: self, action: #selector(openAccessibility))
        allowKeys.sizeToFit(); allowKeys.frame.origin = NSPoint(x: 22, y: y + 100); b.addSubview(allowKeys)
        NotificationCenter.default.addObserver(forName: NSWindow.didBecomeKeyNotification, object: sheet, queue: .main) { [weak self] _ in self?.refreshAccess() }
        sync()
    }

    private func sync() { for (m, p) in popups { p.selectItem(at: ModifierKey.allCases.firstIndex(of: DragMonitor.keys[m]!)!) } }

    /// Picking a key another wheel uses swaps the two, so every wheel always has its own key.
    @objc private func keyChanged(_ sender: NSPopUpButton) {
        guard let mode = popups.first(where: { $0.value === sender })?.key else { return }
        var keys = DragMonitor.keys
        let key = ModifierKey.allCases[sender.indexOfSelectedItem]
        if let other = keys.first(where: { $0.value == key && $0.key != mode })?.key { keys[other] = keys[mode] }
        keys[mode] = key
        DragMonitor.keys = keys
        sync()
    }

    @objc private func revealChanged(_ sender: NSButton) { Editors.revealResults = sender.state == .on }

    @objc private func hotKeyChanged(_ sender: NSPopUpButton) {
        guard let c = HotKey.choices.first(where: { $0.name == sender.titleOfSelectedItem }) else { return }
        HotKey.current = c                     // the app delegate re-registers it
        DispatchQueue.main.async {
            if c.name != "Off", !HotKey.shared.isRegistered {
                Editors.alert("\(c.name) is taken", "Another app already uses \(c.name). Pick a different shortcut.")
            }
        }
    }

    @objc private func loginChanged(_ sender: NSButton) {
        do {
            if sender.state == .on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            sender.state = SMAppService.mainApp.status == .enabled ? .on : .off
            Editors.alert("Open at login", "macOS refused: \(error.localizedDescription). Add Clementine in System Settings → General → Login Items instead.")
        }
    }
}
#endif
