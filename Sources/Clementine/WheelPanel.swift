#if canImport(AppKit)
import AppKit
import QuickLookThumbnailing

/// Borderless, non-activating floating panel so the Finder drag keeps running
/// while it is on screen. Dropping on a sector runs that item.
///
/// Look: Tangerine's wheel, measured from its press screenshots and demo video
/// (tangerineformac.com/press). A ~290 pt glass disc (Liquid Glass on macOS 26, like
/// Tangerine; a behind-window blur on older systems),
/// rounded-trapezoid petals of near-opaque white glass with wide gaps, solid orange
/// when hovered, bold uppercase labels, and a frosted pill in the hub with the size
/// (or the hovered target). During a Finder drag the hub is left empty for Finder's
/// own drag image; the menu-opened wheel draws the file thumbnail there instead.
/// While a job runs the panel becomes a rounded card with a title, the file name and
/// a thin progress bar.
final class WheelPanel: NSPanel {
    static let shared = WheelPanel()
    static let side: CGFloat = 360                       // disc + room for its shadow and the mode bar
    static let card = NSSize(width: 320, height: 96)
    static let cardRadius: CGFloat = 20
    let wheel = WheelView(frame: NSRect(x: 0, y: 0, width: side, height: side))
    private let backdrop: NSView              // NSGlassEffectView on macOS 26, NSVisualEffectView before
    private var keyMonitor: Any?
    private var dragWatch: Timer?
    static private(set) var liquidGlass = false

    private init() {
        let bounds = NSRect(x: 0, y: 0, width: Self.side, height: Self.side)
        var glass: NSView?
#if compiler(>=6.2)                                     // the macOS 26 SDK; older Xcodes build the blur only
        if #available(macOS 26.0, *) {
            let g = NSGlassEffectView(frame: bounds)
            g.style = .clear
            glass = g
        }
#endif
        if let glass {
            backdrop = glass
            Self.liquidGlass = true
        } else {
            let blur = NSVisualEffectView(frame: bounds)
            blur.material = .fullScreenUI
            blur.blendingMode = .behindWindow
            blur.state = .active
            backdrop = blur
        }
        super.init(contentRect: bounds, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        level = .popUpMenu
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        appearance = NSAppearance(named: .aqua)          // always the light look, like Tangerine
        let container = NSView(frame: bounds)
        container.addSubview(backdrop)
        wheel.autoresizingMask = [.width, .height]
        container.addSubview(wheel)
        contentView = container
        useCardShape(false)
    }

    override var canBecomeKey: Bool { true }

    /// Disc while picking, rounded card while a job runs (the glass takes the shape).
    func useCardShape(_ card: Bool) {
        let bounds = NSRect(x: 0, y: 0, width: Self.side, height: Self.side)
#if compiler(>=6.2)
        if #available(macOS 26.0, *), let g = backdrop as? NSGlassEffectView {
            g.frame = card ? WheelView.cardRect(in: bounds) : bounds.insetBy(dx: Self.side / 2 - WheelView.R, dy: Self.side / 2 - WheelView.R)
            g.cornerRadius = card ? Self.cardRadius : WheelView.R
            return
        }
#endif
        (backdrop as? NSVisualEffectView)?.maskImage = NSImage(size: bounds.size, flipped: false) { rect in
            NSColor.black.setFill()
            if card { NSBezierPath(roundedRect: WheelView.cardRect(in: rect), xRadius: Self.cardRadius, yRadius: Self.cardRadius).fill() }
            else { NSBezierPath(ovalIn: rect.insetBy(dx: rect.width / 2 - WheelView.R, dy: rect.height / 2 - WheelView.R)).fill() }
            return true
        }
    }

    func show(files: [URL], mode: WheelMode, at point: NSPoint, interactive: Bool) {
        wheel.load(files: files, mode: mode, interactive: interactive)
        var origin = NSPoint(x: point.x - Self.side / 2, y: point.y - Self.side / 2)
        let screen = NSScreen.screens.first(where: { $0.frame.contains(point) }) ?? NSScreen.main
        if let vf = screen?.visibleFrame {
            origin.x = min(max(origin.x, vf.minX), vf.maxX - Self.side)
            origin.y = min(max(origin.y, vf.minY), vf.maxY - Self.side)
        }
        setFrameOrigin(origin)
        if !isVisible {                                   // fade in, as Tangerine's wheel does
            alphaValue = 0
            NSAnimationContext.runAnimationGroup { $0.duration = 0.12; animator().alphaValue = 1 }
        }
        if interactive {
            NSApp.activate(ignoringOtherApps: true)
            makeKeyAndOrderFront(nil)
            makeFirstResponder(wheel)
        } else {
            orderFrontRegardless()
            // During a Finder drag every key press goes to Finder. A global monitor still sees them
            // (macOS allows that only with Accessibility permission; without it this stays silent).
            if keyMonitor == nil {
                keyMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] e in
                    guard let self, self.isVisible else { return }
                    self.wheel.handleKey(e)
                }
            }
            // A drag that ends over another app doesn't always deliver mouse-up to our monitor. The button
            // state never lies: once it is up, close the wheel (unless the drop started a job on it).
            dragWatch?.invalidate()
            let watch = Timer(timeInterval: 0.12, repeats: true) { [weak self] t in
                guard NSEvent.pressedMouseButtons & 1 == 0 else { return }
                t.invalidate()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { self?.dismissIfIdle() }
            }
            RunLoop.main.add(watch, forMode: .common)
            dragWatch = watch
        }
    }

    private func stopKeys() {
        if let m = keyMonitor { NSEvent.removeMonitor(m); keyMonitor = nil }
        dragWatch?.invalidate(); dragWatch = nil
    }

    func setMode(_ m: WheelMode) { if wheel.mode != m { wheel.mode = m } }
    func dismiss() { stopKeys(); orderOut(nil); wheel.reset() }
    func dismissIfIdle() { if wheel.state == .idle { dismiss() } }
}

final class WheelView: NSView {
    enum State: Equatable { case idle, running(String), done(String), error(String) }

    var state: State = .idle {
        didSet {
            needsDisplay = true
            (window as? WheelPanel)?.useCardShape(state != .idle)
        }
    }
    var mode: WheelMode = .convert { didSet { hovered = nil; needsDisplay = true } }
    private(set) var files: [URL] = []
    private var formats: [Format] = []
    private var interactive = false
    private var hovered: Int? { didSet { if hovered != oldValue { needsDisplay = true } } }
    private var typed = ""
    private var typedReset: DispatchWorkItem?
    private var jobTitle = ""
    private var progress: Double = 0
    private var thumb: NSImage?
    private var job = 0            // bumps on every run/load/reset so stale callbacks are ignored

    // Proportions of Tangerine's wheel, as fractions of the disc radius R.
    static let R: CGFloat = 145                // disc radius (290 pt across)
    static let hub: CGFloat = 0.40 * R         // petals start here; inside is not a target
    static let ring: CGFloat = 0.68 * R        // label centre radius
    static let orange = NSColor(srgbRed: 0.925, green: 0.29, blue: 0.098, alpha: 1)   // Tangerine's orange, sampled from its demo video
    static let ink = NSColor(calibratedWhite: 0.07, alpha: 1)

    override init(frame: NSRect) {
        super.init(frame: frame)
        registerForDraggedTypes([.fileURL])
        wantsLayer = true
    }
    required init?(coder: NSCoder) { fatalError() }
    override var acceptsFirstResponder: Bool { true }

    func load(files: [URL], mode: WheelMode, interactive: Bool) {
        self.files = files
        formats = files.compactMap(Formats.identify)
        self.interactive = interactive
        self.mode = mode
        job += 1
        state = .idle
        hovered = nil
        typed = ""
        progress = 0
        trackingAreas.forEach(removeTrackingArea)
        if interactive {
            addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseMoved, .activeAlways, .inVisibleRect], owner: self, userInfo: nil))
        }
        loadThumbnail()
    }

    func reset() { job += 1; state = .idle; hovered = nil }

    var labels: [String] {
        switch mode {
        case .convert: return Formats.targets(for: formats).map(\.label)
        case .tools:   return Tools.available(for: formats).map(\.label)
        case .actions: return FileAction.allCases.map(\.label)
        case .claude:  return Claude.actions(for: formats).map(\.label)
        }
    }

    // Test hooks (UITest.swift drives the real event handlers through these).
    var hoveredLabel: String? { hovered.flatMap { $0 < labels.count ? labels[$0] : nil } }

    func sectorCenter(_ i: Int) -> NSPoint {
        let n = labels.count
        let a = CGFloat.pi / 2 - CGFloat(i) * (2 * CGFloat.pi / CGFloat(max(n, 1)))
        return NSPoint(x: bounds.midX + cos(a) * Self.ring, y: bounds.midY + sin(a) * Self.ring)
    }

    static func cardRect(in rect: NSRect) -> NSRect {
        NSRect(x: rect.midX - WheelPanel.card.width / 2, y: rect.midY - WheelPanel.card.height / 2,
               width: WheelPanel.card.width, height: WheelPanel.card.height)
    }

    // MARK: geometry — item i sits at angle π/2 − i·step (clockwise from 12 o'clock)

    private func index(at p: NSPoint) -> Int? {
        let n = labels.count
        guard n > 0 else { return nil }
        let dx = p.x - bounds.midX, dy = p.y - bounds.midY
        let d = hypot(dx, dy)
        guard d > Self.hub, d < Self.R else { return nil }
        let step = 2 * CGFloat.pi / CGFloat(n)
        var a = CGFloat.pi / 2 - atan2(dy, dx)
        if a < 0 { a += 2 * .pi }
        return Int(((a + step / 2) / step).rounded(.down)) % n
    }

    // MARK: hub thumbnail

    private func loadThumbnail() {
        thumb = nil
        guard let url = files.first else { return }
        thumb = NSWorkspace.shared.icon(forFile: url.path)
        let req = QLThumbnailGenerator.Request(fileAt: url, size: NSSize(width: 96, height: 96), scale: 2, representationTypes: .thumbnail)
        QLThumbnailGenerator.shared.generateBestRepresentation(for: req) { [weak self] rep, _ in
            guard let rep, let self else { return }
            DispatchQueue.main.async {
                guard self.files.first == url else { return }
                self.thumb = rep.nsImage
                self.needsDisplay = true
            }
        }
    }

    private var sizeText: String {
        if files.count != 1 { return "\(files.count) files" }
        let bytes = (try? FileManager.default.attributesOfItem(atPath: files[0].path)[.size] as? Int64) ?? 0
        let f = ByteCountFormatter(); f.countStyle = .file
        return f.string(fromByteCount: bytes)
    }

    // MARK: drawing

    override func draw(_ dirtyRect: NSRect) {
        guard state == .idle else { drawCard(); return }
        let cg = NSGraphicsContext.current!.cgContext
        let c = CGPoint(x: bounds.midX, y: bounds.midY)
        let R = Self.R
        let disc = CGPath(ellipseIn: CGRect(x: c.x - R, y: c.y - R, width: 2 * R, height: 2 * R), transform: nil)

        // Soft shadow outside the disc only (the glass stays clear), then the glass band:
        // a light veil over the blur with a bright rim, the colour that shows in the gaps.
        // Liquid Glass brings its own rim, refraction and depth; the blur fallback gets them painted on.
        let glass = WheelPanel.liquidGlass
        Self.outerShadow(cg, disc, in: bounds, blur: 18, alpha: glass ? 0.12 : 0.22)
        if !glass {
            cg.addPath(disc); cg.setFillColor(NSColor(calibratedWhite: 1, alpha: 0.12).cgColor); cg.fillPath()
            cg.addPath(CGPath(ellipseIn: CGRect(x: c.x - R + 0.75, y: c.y - R + 0.75, width: 2 * R - 1.5, height: 2 * R - 1.5), transform: nil))
            cg.setStrokeColor(NSColor(calibratedWhite: 1, alpha: 0.38).cgColor); cg.setLineWidth(1.5); cg.strokePath()
        }
        // Hub: a lighter well inside the band.
        let well = 0.34 * R
        cg.addEllipse(in: CGRect(x: c.x - well, y: c.y - well, width: 2 * well, height: 2 * well))
        cg.setFillColor(NSColor(calibratedWhite: 1, alpha: 0.16).cgColor); cg.fillPath()

        let items = labels
        let n = items.count
        let step = n > 0 ? 2 * CGFloat.pi / CGFloat(n) : 0
        let ri = Self.hub, ro = 0.955 * R
        for (i, label) in items.enumerated() {
            let a = CGFloat.pi / 2 - CGFloat(i) * step
            let petal = Self.petal(center: c, inner: ri, outer: ro, from: a - step / 2, to: a + step / 2,
                                   gap: n > 1 ? 0.042 * R : 0, innerCorner: 0.05 * R, outerCorner: 0.11 * R)
            let hot = i == hovered
            cg.saveGState()
            cg.setShadow(offset: CGSize(width: 0, height: -1), blur: 3, color: NSColor(calibratedWhite: 0, alpha: hot ? 0.18 : 0.08).cgColor)
            cg.addPath(petal); cg.setFillColor(NSColor.white.cgColor); cg.fillPath()   // shadow source; covered below
            cg.restoreGState()
            // Frosted petal: translucent white, brighter at the top, so the glass shows through; solid orange when hovered.
            let top = hot ? NSColor(srgbRed: 0.98, green: 0.376, blue: 0.118, alpha: 1) : NSColor(calibratedWhite: 1, alpha: glass ? 0.62 : 0.72)
            let bottom = hot ? Self.orange : NSColor(calibratedWhite: 1, alpha: glass ? 0.46 : 0.58)
            cg.saveGState()
            cg.addPath(petal); cg.clip()
            cg.setBlendMode(.copy)
            cg.drawLinearGradient(CGGradient(colorsSpace: nil, colors: [top.cgColor, bottom.cgColor] as CFArray, locations: [0, 1])!,
                                  start: CGPoint(x: c.x, y: c.y + R), end: CGPoint(x: c.x, y: c.y - R), options: [])
            cg.restoreGState()

            let p = NSPoint(x: c.x + cos(a) * Self.ring, y: c.y + sin(a) * Self.ring)
            let color = hot ? NSColor.white : Self.ink
            if mode == .convert {
                text(label.uppercased(), at: p, size: (0.105 * R * min(1, sqrt(8 / CGFloat(n)))).rounded(), weight: .bold, color: color, tracking: 0.4)
            } else {
                let crowded = n > 10                       // icons only; the hub pill names the hovered one
                let icon: CGFloat = crowded ? 15 : 17
                if let sym = Self.symbol(for: label),
                   let img = NSImage(systemSymbolName: sym, accessibilityDescription: nil)?
                    .withSymbolConfiguration(.init(pointSize: icon, weight: .semibold).applying(.init(paletteColors: [color]))) {
                    let r = NSRect(x: p.x - img.size.width / 2, y: p.y + (crowded ? -img.size.height / 2 : 1), width: img.size.width, height: img.size.height)
                    img.draw(in: r, from: .zero, operation: .sourceOver, fraction: 1)
                }
                if crowded { continue }
                text(Self.short(label).uppercased(), at: NSPoint(x: p.x, y: p.y - 10), size: 8.5, weight: .bold, color: color, tracking: 0.7)
            }
        }
        if n == 0 { text("Nothing to do with this file", at: NSPoint(x: c.x, y: c.y + Self.ring), size: 12, weight: .semibold, color: Self.ink) }

        // Hub. During a Finder drag, Finder's drag image sits here under the cursor, so only the
        // pill is drawn; the menu-opened wheel has no drag image and shows the thumbnail instead.
        if interactive, let t = thumb {
            let s: CGFloat = 60
            let ar = t.size.width / max(t.size.height, 1)
            let w = ar >= 1 ? s : s * ar, h = ar >= 1 ? s / ar : s
            let r = NSRect(x: c.x - w / 2, y: c.y - h / 2 + 4, width: w, height: h)
            NSGraphicsContext.saveGraphicsState()
            NSBezierPath(roundedRect: r, xRadius: 5, yRadius: 5).addClip()
            t.draw(in: r, from: .zero, operation: .sourceOver, fraction: 1)
            NSGraphicsContext.restoreGraphicsState()
        }
        let pillText = hoveredLabel.map { Self.short($0).uppercased() } ?? sizeText
        let maxW = 2 * Self.hub - 8                      // the pill may overhang the well, never the petals
        var size: CGFloat = 12.5
        var tw = (pillText as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: size, weight: .medium), .kern: 0.3]).width
        if tw + 24 > maxW { size = max(8, size * (maxW - 24) / tw); tw = maxW - 24 }
        let pw = min(max(0.6 * R, tw + 28), maxW), ph: CGFloat = 0.17 * R
        let pill = CGPath(roundedRect: CGRect(x: c.x - pw / 2, y: c.y - ph / 2 - 4, width: pw, height: ph), cornerWidth: ph / 2, cornerHeight: ph / 2, transform: nil)
        cg.saveGState()
        cg.setShadow(offset: CGSize(width: 0, height: -1), blur: 4, color: NSColor(calibratedWhite: 0, alpha: 0.12).cgColor)
        cg.addPath(pill); cg.setFillColor(NSColor(calibratedWhite: 0.97, alpha: 0.80).cgColor); cg.fillPath()
        cg.restoreGState()
        cg.addPath(pill); cg.setStrokeColor(NSColor(calibratedWhite: 1, alpha: 0.6).cgColor); cg.setLineWidth(0.5); cg.strokePath()
        text(pillText, at: NSPoint(x: c.x, y: c.y - 4), size: size, weight: .medium, color: Self.ink, tracking: 0.3)
        if mode == .claude { text("opens in the Claude app", at: NSPoint(x: c.x, y: c.y - 30), size: 8, weight: .semibold, color: Self.orange) }
        drawModeBar(cg)
    }

    // MARK: mode bar — which key opens which wheel; click (or drag over) a chip to switch

    static var modeKeys: [WheelMode: String] { DragMonitor.keys.mapValues(\.symbol) }
    private static let chipFont = NSFont.systemFont(ofSize: 10.5, weight: .semibold)

    /// One chip per wheel, in a capsule centred under the disc.
    func modeChips() -> [(WheelMode, NSRect)] {
        let titles = WheelMode.allCases.map { "\(Self.modeKeys[$0]!) \($0.title)" }
        let widths = titles.map { ($0 as NSString).size(withAttributes: [.font: Self.chipFont]).width + 16 }
        let h: CGFloat = 20, y = (bounds.midY - Self.R - h) / 2 - 1
        var x = bounds.midX - widths.reduce(0, +) / 2
        return zip(WheelMode.allCases, widths).map { m, w in defer { x += w }; return (m, NSRect(x: x, y: y, width: w, height: h)) }
    }

    func modeChip(at p: NSPoint) -> WheelMode? { modeChips().first { $0.1.insetBy(dx: 0, dy: -4).contains(p) }?.0 }

    private func drawModeBar(_ cg: CGContext) {
        let chips = modeChips()
        guard let first = chips.first?.1, let last = chips.last?.1 else { return }
        let bar = CGPath(roundedRect: first.union(last).insetBy(dx: -2, dy: -2), cornerWidth: 12, cornerHeight: 12, transform: nil)
        cg.saveGState()
        cg.setShadow(offset: CGSize(width: 0, height: -1), blur: 6, color: NSColor(calibratedWhite: 0, alpha: 0.2).cgColor)
        cg.addPath(bar); cg.setFillColor(NSColor(calibratedWhite: 1, alpha: 0.9).cgColor); cg.fillPath()
        cg.restoreGState()
        for (m, r) in chips {
            let on = m == mode
            if on {
                cg.addPath(CGPath(roundedRect: r, cornerWidth: 10, cornerHeight: 10, transform: nil))
                cg.setFillColor(Self.orange.cgColor); cg.fillPath()
            }
            text("\(Self.modeKeys[m]!) \(m.title)", at: NSPoint(x: r.midX, y: r.midY), size: 10.5, weight: .semibold, color: on ? .white : Self.ink)
        }
    }

    /// Tangerine's petal: an annular sector with a constant-width gap to its neighbours
    /// (the radial edges are offset, not rotated) and rounded corners, larger outside.
    static func petal(center c: CGPoint, inner ri: CGFloat, outer ro: CGFloat, from a1: CGFloat, to a2: CGFloat,
                      gap: CGFloat, innerCorner: CGFloat, outerCorner: CGFloat) -> CGPath {
        let h = gap / 2
        func pt(_ r: CGFloat, _ a: CGFloat) -> CGPoint { CGPoint(x: c.x + cos(a) * r, y: c.y + sin(a) * r) }
        func toward(_ p: CGPoint, _ a: CGFloat) -> CGPoint { CGPoint(x: p.x + cos(a) * 10, y: p.y + sin(a) * 10) }
        let i1 = a1 + asin(min(h / ri, 1)), i2 = a2 - asin(min(h / ri, 1))
        let o1 = a1 + asin(min(h / ro, 1)), o2 = a2 - asin(min(h / ro, 1))
        // Corners can't be wider than their edge allows.
        let side = (ro - ri) * 0.45
        let rOut = min(outerCorner, ro * (o2 - o1) * 0.45, side), rIn = min(innerCorner, max(ri * (i2 - i1) * 0.45, 0.5), side)
        let A = pt(ri, i1), B = pt(ro, o1), C = pt(ro, o2), D = pt(ri, i2)
        let p = CGMutablePath()
        p.move(to: CGPoint(x: (A.x + B.x) / 2, y: (A.y + B.y) / 2))
        p.addArc(tangent1End: B, tangent2End: toward(B, o1 + .pi / 2), radius: rOut)
        p.addArc(center: c, radius: ro, startAngle: o1 + rOut / ro, endAngle: max(o2 - rOut / ro, o1 + rOut / ro), clockwise: false)
        p.addArc(tangent1End: C, tangent2End: D, radius: rOut)
        p.addArc(tangent1End: D, tangent2End: toward(D, i2 - .pi / 2), radius: rIn)
        p.addArc(center: c, radius: ri, startAngle: i2 - rIn / ri, endAngle: min(i1 + rIn / ri, i2 - rIn / ri), clockwise: true)
        p.addArc(tangent1End: A, tangent2End: B, radius: rIn)
        p.closeSubpath()
        return p
    }

    /// A shadow that falls only outside `shape`, so translucent glass isn't darkened from below.
    static func outerShadow(_ cg: CGContext, _ shape: CGPath, in rect: CGRect, blur: CGFloat, alpha: CGFloat) {
        cg.saveGState()
        cg.addRect(rect); cg.addPath(shape); cg.clip(using: .evenOdd)
        cg.setShadow(offset: CGSize(width: 0, height: -4), blur: blur, color: NSColor(calibratedWhite: 0, alpha: alpha).cgColor)
        cg.addPath(shape); cg.setFillColor(NSColor.black.cgColor); cg.fillPath()
        cg.restoreGState()
    }

    /// Tangerine's short petal captions ("ADD BG", "EDIT"): the label up to any "…" or long tail.
    static func short(_ label: String) -> String {
        let l = label.replacingOccurrences(of: "…", with: "")
        let map = ["Add Background": "Add BG", "Edit Photo": "Edit", "Strip Metadata": "Remove Meta", "Rotate & Flip": "Rotate"]
        return map[l] ?? l
    }

    private func drawCard() {
        let cg = NSGraphicsContext.current!.cgContext
        let r = Self.cardRect(in: bounds)
        let rad = WheelPanel.cardRadius
        let shape = CGPath(roundedRect: r, cornerWidth: rad, cornerHeight: rad, transform: nil)
        Self.outerShadow(cg, shape, in: bounds, blur: 16, alpha: 0.18)
        cg.addPath(shape); cg.setFillColor(NSColor(calibratedWhite: 1, alpha: WheelPanel.liquidGlass ? 0.3 : 0.50).cgColor); cg.fillPath()
        cg.addPath(shape); cg.setStrokeColor(NSColor(calibratedWhite: 1, alpha: 0.55).cgColor); cg.setLineWidth(1); cg.strokePath()
        // close button: a faint disc with an ✕
        let bx = NSRect(x: r.minX + 14, y: r.maxY - 14 - 24, width: 24, height: 24)
        NSColor(calibratedWhite: 0, alpha: 0.06).setFill()
        NSBezierPath(ovalIn: bx).fill()
        let x = NSBezierPath()
        x.move(to: NSPoint(x: bx.midX - 4, y: bx.midY - 4)); x.line(to: NSPoint(x: bx.midX + 4, y: bx.midY + 4))
        x.move(to: NSPoint(x: bx.midX - 4, y: bx.midY + 4)); x.line(to: NSPoint(x: bx.midX + 4, y: bx.midY - 4))
        x.lineWidth = 1.4; x.lineCapStyle = .round
        NSColor(calibratedWhite: 0.1, alpha: 0.7).setStroke(); x.stroke()
        let title: String, detail: String, fill: Double, detailColor: NSColor
        let secondary = NSColor(calibratedWhite: 0.1, alpha: 0.72)
        switch state {
        case .running(let s): (title, detail, fill, detailColor) = (jobTitle, s, max(progress, 0.06), secondary)
        case .done(let s):    (title, detail, fill, detailColor) = ("Done", s.replacingOccurrences(of: "\n", with: " · "), 1, secondary)
        case .error(let s):   (title, detail, fill, detailColor) = ("Failed", s, 0, NSColor(calibratedRed: 0.7, green: 0.1, blue: 0.05, alpha: 1))
        case .idle:           return
        }
        text(title, at: NSPoint(x: bx.maxX + 10, y: bx.midY), size: 15, weight: .semibold, color: NSColor(calibratedWhite: 0.1, alpha: 0.88), align: .left)
        text(detail.count > 44 ? String(detail.prefix(43)) + "…" : detail, at: NSPoint(x: r.minX + 18, y: r.minY + 39), size: 12.5, weight: .regular, color: detailColor, align: .left)
        let track = NSRect(x: r.minX + 18, y: r.minY + 18, width: r.width - 36, height: 4)
        NSColor(calibratedWhite: 0.2, alpha: 0.22).setFill()
        NSBezierPath(roundedRect: track, xRadius: 2, yRadius: 2).fill()
        if fill > 0 {
            Self.orange.setFill()
            NSBezierPath(roundedRect: NSRect(x: track.minX, y: track.minY, width: track.width * fill, height: 4), xRadius: 2, yRadius: 2).fill()
        }
        if case .error = state { text("click to close", at: NSPoint(x: r.maxX - 18, y: r.minY + 8), size: 9, weight: .regular, color: .gray, align: .right) }
    }

    private func text(_ s: String, at p: NSPoint, size: CGFloat, weight: NSFont.Weight, color: NSColor, tracking: CGFloat = 0, align: NSTextAlignment = .center) {
        var attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: size, weight: weight), .foregroundColor: color]
        if tracking != 0 { attrs[.kern] = tracking }
        let str = NSAttributedString(string: s, attributes: attrs)
        let sz = str.size()
        let x = align == .center ? p.x - sz.width / 2 : align == .left ? p.x : p.x - sz.width
        str.draw(at: NSPoint(x: x, y: p.y - sz.height / 2))
    }

    /// SF Symbols for the tools / actions / Claude wheels, matched on the label.
    private static func symbol(for label: String) -> String? {
        let l = label.lowercased()
        let table: [(String, String)] = [
            ("compress", "arrow.down.right.and.arrow.up.left"), ("shrink", "percent"), ("fit to size", "ruler"),
            ("strip metadata", "tag.slash"), ("metadata", "tag"), ("crop", "crop"), ("trim silence", "waveform.badge.minus"),
            ("trim", "scissors"), ("rotate", "rotate.right"), ("edit photo", "slider.horizontal.3"), ("add background", "photo"),
            ("redact", "eye.slash"), ("annotate", "pencil.tip.crop.circle"), ("collage", "square.grid.2x2"), ("create pdf", "doc"), ("read qr", "qrcode"),
            ("read text", "text.viewfinder"), ("searchable", "doc.text.magnifyingglass"), ("mute", "speaker.slash"),
            ("extract audio", "waveform"), ("extract text", "text.alignleft"), ("extract", "archivebox"), ("snapshot", "camera"),
            ("frames", "film"), ("speed", "speedometer"), ("split", "film"), ("join", "link"), ("mono", "hifispeaker"),
            ("normalize", "waveform"), ("bleep", "speaker.wave.2"), ("visualizer", "waveform.circle"), ("image + audio", "play.rectangle"),
            ("merge", "doc.on.doc"), ("reorder", "arrow.up.arrow.down"), ("airdrop", "dot.radiowaves.left.and.right"),
            ("float", "pin"), ("copy path", "link"), ("copy", "doc.on.doc"), ("move", "folder"), ("terminal", "terminal"),
            ("ask", "bubble.left"), ("summarize", "text.alignleft"), ("translate", "globe"), ("new chat", "plus.bubble"),
        ]
        return table.first { l.hasPrefix($0.0) }?.1 ?? "wrench"
    }

    // MARK: drop target

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { track(sender) }
    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation { track(sender) }
    override func draggingExited(_ sender: NSDraggingInfo?) { hovered = nil }

    private func track(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard state == .idle else { return [] }
        let p = convert(sender.draggingLocation, from: nil)
        if let m = modeChip(at: p) { mode = m; return [] }        // dragging over a chip switches wheels
        hovered = index(at: p)
        return hovered == nil ? [] : .copy
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        performDrop(at: convert(sender.draggingLocation, from: nil), files: DragMonitor.fileURLs(sender.draggingPasteboard))
    }

    /// The drop itself, separated from NSDraggingInfo so the UI test can exercise it.
    @discardableResult
    func performDrop(at point: NSPoint, files dropped: [URL]) -> Bool {
        guard state == .idle, let i = index(at: point) else { return false }
        if !dropped.isEmpty, Set(dropped) != Set(files) {
            files = dropped
            formats = dropped.compactMap(Formats.identify)
            loadThumbnail()
        }
        run(i)
        return true
    }

    // MARK: mouse / keyboard (interactive wheel from the menu bar)

    override func mouseMoved(with e: NSEvent) {
        guard interactive, state == .idle else { return }
        hovered = index(at: convert(e.locationInWindow, from: nil))
    }

    override func mouseDown(with e: NSEvent) {
        switch state {
        case .idle:
            if let m = modeChip(at: convert(e.locationInWindow, from: nil)) { mode = m }
            else if let i = index(at: convert(e.locationInWindow, from: nil)) { run(i) }
            else if interactive { WheelPanel.shared.dismiss() }
        case .running: break
        default: WheelPanel.shared.dismiss()
        }
    }

    override func keyDown(with e: NSEvent) { if !handleKey(e) { super.keyDown(with: e) } }

    /// The wheel's keys. Called for the wheel's own key events (menu-opened wheel) and, during a
    /// Finder drag, for global key events: Finder owns the keyboard then. False = not a wheel key.
    @discardableResult
    func handleKey(_ e: NSEvent) -> Bool {
        switch e.keyCode {
        case 53: WheelPanel.shared.dismiss()                                   // esc
        case 48:                                                               // tab cycles the wheels
            let all = WheelMode.allCases
            mode = all[(all.firstIndex(of: mode)! + 1) % all.count]
        case 124, 125:                                                         // → ↓ next sector
            guard !labels.isEmpty else { return true }
            hovered = ((hovered ?? -1) + 1) % labels.count
        case 123, 126:                                                         // ← ↑ previous sector
            guard !labels.isEmpty else { return true }
            hovered = ((hovered ?? 0) - 1 + labels.count) % labels.count
        case 36, 76:                                                           // return / enter runs the selection
            if state == .idle, let i = hovered { run(i) }
        case 18, 19, 20, 21, 23, 22, 26, 28, 25:                               // 1…9 run that sector
            let digit = [18: 1, 19: 2, 20: 3, 21: 4, 23: 5, 22: 6, 26: 7, 28: 8, 25: 9][e.keyCode]!
            if state == .idle, digit <= labels.count { run(digit - 1) }
        default:
            // Type-to-pick: letters narrow to the first label with that prefix.
            guard let chars = e.charactersIgnoringModifiers?.lowercased(), chars.count == 1, chars.first!.isLetter else { return false }
            typed += chars
            if let i = labels.firstIndex(where: { $0.lowercased().hasPrefix(typed) }) { hovered = i }
            typedReset?.cancel()
            let reset = DispatchWorkItem { [weak self] in self?.typed = "" }
            typedReset = reset
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2, execute: reset)
        }
        return true
    }

    // MARK: execution

    private func run(_ i: Int) {
        let urls = files
        guard i < labels.count else { return }
        let label = labels[i]
        let fmts = formats
        let names = urls.count == 1 ? urls[0].lastPathComponent : "\(urls.count) files"
        job += 1
        let my = job
        if mode == .actions {
            do { try Actions.perform(FileAction.allCases[i], urls); WheelPanel.shared.dismiss() } catch { fail(error) }
            return
        }
        if mode == .claude {
            let action = Claude.actions(for: fmts)[i]
            jobTitle = "Claude · \(label)"
            progress = 0
            state = .running(names)
            WheelPanel.shared.orderOut(nil)          // dialogs come first; the wheel returns with progress
            Claude.perform(action, urls, progress: { [weak self] s in
                guard let self, my == self.job else { return }
                self.state = .running(s)
                WheelPanel.shared.orderFrontRegardless()
            }) { [weak self] outcome in
                guard let self, my == self.job else { return }
                switch outcome {
                case .cancelled: WheelPanel.shared.dismiss()
                case .failed(let e): self.fail(e)
                case .done(let s):
                    self.state = .done(s)
                    WheelPanel.shared.orderFrontRegardless()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 3) { if my == self.job, case .done = self.state { WheelPanel.shared.dismiss() } }   // long enough to read the next step
                }
            }
            return
        }
        if mode == .tools {
            let tool = Tools.available(for: fmts)[i]
            if tool.interactive {
                WheelPanel.shared.dismiss()
                Editors.open(tool, urls)
                return
            }
        }
        let makePlans: () throws -> [Plan] = mode == .convert
            ? { let t = Formats.targets(for: fmts)[i]; return try urls.map { try Convert.plan($0, to: t) } }
            : { try Tools.plan(Tools.available(for: fmts)[i], inputs: urls) }

        jobTitle = mode == .convert ? "Converting to \(label.uppercased())" : label.replacingOccurrences(of: "…", with: "")
        progress = 0
        state = .running(names)
        WheelPanel.shared.makeKeyAndOrderFront(nil)
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let plans = try makePlans()
                var outs: [URL] = []
                for (n, plan) in plans.enumerated() {
                    DispatchQueue.main.async {
                        guard my == self.job else { return }
                        self.progress = Double(n) / Double(max(plans.count, 1))
                        self.state = .running(plans.count == 1 ? names : "\(names) · \(n + 1) of \(plans.count)")
                    }
                    try Runner.execute(plan)
                    outs += plan.outputs
                }
                DispatchQueue.main.async {
                    guard my == self.job else { return }
                    self.progress = 1
                    self.state = .done(outs.prefix(3).map(\.lastPathComponent).joined(separator: "\n") + (outs.count > 3 ? "\n+\(outs.count - 3) more" : ""))
                    Editors.reveal(outs)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.3) {
                        if my == self.job, case .done = self.state { WheelPanel.shared.dismiss() }
                    }
                }
            } catch {
                DispatchQueue.main.async { if my == self.job { self.fail(error) } }
            }
        }
    }

    private func fail(_ e: Error) {
        state = .error(e.localizedDescription)
        NSApp.activate(ignoringOtherApps: true)
        WheelPanel.shared.makeKeyAndOrderFront(nil)
    }
}
#endif
