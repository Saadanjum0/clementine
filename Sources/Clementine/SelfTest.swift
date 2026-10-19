import Foundation
#if canImport(AppKit)
import AppKit
import CoreImage
#endif

/// `Clementine --selftest` – the test suite. XCTest is not in the Command Line
/// Tools SDK, so checks ship inside the binary. Logic checks always run; real
/// conversions run on generated fixtures in a temp dir, skipping engines that
/// are not installed (each skip is printed). `--quick` skips the slow ffmpeg video checks.
enum SelfTest {
    private static var passes = 0, failures = 0, skips = 0

    static func check(_ name: String, _ cond: @autoclosure () throws -> Bool) {
        do {
            if try cond() { passes += 1; print("  ok    \(name)") } else { failures += 1; print("  FAIL  \(name)") }
        } catch { failures += 1; print("  FAIL  \(name): \(error.localizedDescription)") }
    }
    static func skip(_ name: String, _ why: String) { skips += 1; print("  skip  \(name) (\(why))") }

    static func run(quick: Bool) -> Bool {
        print("Clementine self-test")
        logic()
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("clementine-selftest-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        #if canImport(AppKit)
        images(in: dir)
        pdfs(in: dir)
        documents(in: dir)
        #else
        skip("images / pdf / textutil documents", "needs macOS frameworks")
        #endif
        pandocDocs(in: dir)
        office(in: dir)
        archives(in: dir)
        media(in: dir, quick: quick)
        print("\n\(passes) passed, \(failures) failed, \(skips) skipped")
        return failures == 0
    }

    // MARK: pure logic

    static func logic() {
        print("\nformat graph")
        let f = { (s: String) in Formats.byID[s]! }
        check("identify by extension, case-insensitive", Formats.identify(ext: "JPEG")?.id == "jpg")
        check("tar.gz alias", Formats.identify(ext: "gz")?.id == "tgz")
        check("every input-only format is never a target",
              Formats.all.filter(\.inputOnly).allSatisfy { io in Formats.all.allSatisfy { !Formats.targets(for: $0).contains(io) } })
        check("a format never targets itself", Formats.all.allSatisfy { !Formats.targets(for: $0).contains($0) })
        check("image → pdf", Formats.targets(for: f("heic")).contains(f("pdf")))
        check("svg → jpg (input only, still converts out)", Formats.targets(for: f("svg")).map(\.id) == ["jpg", "png", "webp", "heic", "tiff", "avif", "bmp", "pdf", "docx"])
        check("video → mp3 but not m4a", Formats.targets(for: f("mov")).contains(f("mp3")) && !Formats.targets(for: f("mov")).contains(f("m4a")))
        check("pdf → docx pages pptx xlsx jpg png epub txt md html", Formats.targets(for: f("pdf")).map(\.id) == ["docx", "pages", "pptx", "xlsx", "jpg", "png", "epub", "txt", "md", "html"])
        check("pptx → pdf jpg png, srt → txt", Formats.targets(for: f("pptx")).map(\.id) == ["pdf", "jpg", "png"] && Formats.targets(for: f("srt")).contains(f("txt")))
        check("docx → pdf", Formats.targets(for: f("docx")).contains(f("pdf")))
        check("pages ↔ docx / pdf", Formats.targets(for: f("pages")).contains(f("docx")) && Formats.targets(for: f("docx")).contains(f("pages")))
        check("rar → zip tar tgz", Formats.targets(for: f("rar")).map(\.id) == ["zip", "tar", "tgz"])
        check("folder → archives", Formats.targets(for: f("folder")).map(\.id) == ["zip", "tar", "tgz"])
        check("batch: jpg+mp4 share nothing", Formats.targets(for: [f("jpg"), f("mp4")]).isEmpty)
        check("batch: jpg+png share png-less image set", Formats.targets(for: [f("jpg"), f("png")]).map(\.id) == ["webp", "heic", "tiff", "avif", "bmp", "pdf", "docx"])
        check("conversion count ≥ 200 (Tangerine: 249)", Formats.conversionCount >= 200)
        print("  info  \(Formats.conversionCount) conversion paths")

        print("\ntools & actions")
        check("at least 26 tools across kinds (Tangerine: 26)", Tools.toolCount >= 26)
        print("  info  \(Tools.toolCount) tool slots, \(Tools.all.count) distinct tools, \(Tools.all.filter(\.interactive).count) with editors")
        check("6 actions (Tangerine: 6)", FileAction.allCases.count == 6)
        check("merge needs two pdfs", !Tools.available(for: [f("pdf")]).contains { $0.id == "merge" }
              && Tools.available(for: [f("pdf"), f("pdf")]).contains { $0.id == "merge" })
        check("single pdf offers reorder, split, text", ["reorder", "split", "text"].allSatisfy { id in Tools.available(for: [f("pdf")]).contains { $0.id == id } })
        check("docx gets no pdf tools", Tools.available(for: [f("docx")]).isEmpty)
        check("mixed image+video → only shared tools", Tools.available(for: [f("jpg"), f("mp4")]).map(\.id) == ["compress", "shrink", "strip", "metadata", "crop", "rotate", "fit"])
        check("every Tangerine tool has a counterpart", ["compress", "metadata", "adjust", "background", "crop", "redact", "shrink", "rotate", "createpdf", "collage", "trim", "speed", "join", "frames", "split", "normalize", "channels", "bleep", "visualizer", "merge", "reorder", "qr"].allSatisfy { id in Tools.all.contains { $0.id == id } })
        check("image + audio → shared tools plus slideshow", Tools.available(for: [f("jpg"), f("mp3")]).map(\.id) == ["compress", "shrink", "strip", "metadata", "fit", "slideshow"])
        check("image + two audio → no slideshow", !Tools.available(for: [f("jpg"), f("mp3"), f("wav")]).contains { $0.id == "slideshow" })
        check("join: same-format clips or audio only", Tools.available(for: [f("mp4"), f("mp4")]).contains { $0.id == "join" }
              && Tools.available(for: [f("wav"), f("mp3")]).contains { $0.id == "join" }
              && !Tools.available(for: [f("mp4"), f("mov")]).contains { $0.id == "join" }
              && !Tools.available(for: [f("mp4"), f("mp3")]).contains { $0.id == "join" })
        check("archive → extract only", Tools.available(for: [f("zip")]).map(\.id) == ["extract"])
        check("gif hides the audio-dependent and H.264-only tools", !Tools.available(for: [f("gif")]).contains { ["mute", "audio", "speed", "shrink", "fit"].contains($0.id) })
        check("csv quoting", Native.csv([["a", "b,c"], ["say \"hi\"", "x\ny"]]) == "a,\"b,c\"\n\"say \"\"hi\"\"\",\"x\ny\"\n")

        print("\nengines & naming")
        check("tar found", EngineLocator.path(for: .tar) != nil)
        #if os(macOS)
        check("textutil found", EngineLocator.path(for: .textutil) != nil)
        #endif
        check("Mach-O arch check accepts /bin/ls", MachO.runnable("/bin/ls"))
        check("Mach-O arch check passes non-binaries", MachO.runnable("/etc/hosts"))
        let tmp = FileManager.default.temporaryDirectory
        let a = tmp.appendingPathComponent("clementine-naming-\(UUID().uuidString).heic")
        _ = FileManager.default.createFile(atPath: a.path, contents: Data())
        let first = Naming.sibling(of: a, ext: "jpg")
        _ = FileManager.default.createFile(atPath: first.path, contents: Data())
        let second = Naming.sibling(of: a, ext: "jpg")
        check("sibling naming avoids collisions", first.lastPathComponent.hasSuffix(".jpg") && second.lastPathComponent.hasSuffix(" 2.jpg"))
        try? FileManager.default.removeItem(at: a); try? FileManager.default.removeItem(at: first)
        let b = a.deletingPathExtension().appendingPathExtension("png")
        check("batch naming: two inputs never plan the same output", Naming.sibling(of: a, ext: "txt") != Naming.sibling(of: b, ext: "txt"))
        check("ffmpeg args exist for every a/v target",
              (Formats.of(.audio) + Formats.of(.video)).allSatisfy { !Convert.mediaArgs($0.id, crf: nil).isEmpty })
        check("webp plan stages through png, or names the missing encoder", {
            do { return try Convert.plan(a, to: f("webp")).steps.count == 2 }
            catch ConvertError.engineMissing(let e) { return e == .cwebp }
            catch { return false }
        }())
        check("unsupported pair throws", (try? Convert.plan(a, to: f("mp3"))) == nil)
    }

    // MARK: real conversions on generated fixtures

    static func exists(_ u: URL) -> Bool { FileManager.default.fileExists(atPath: u.path) }

    @discardableResult
    static func conv(_ u: URL, _ ext: String) throws -> URL {
        let p = try Convert.plan(u, to: Formats.byID[ext]!)
        try Runner.execute(p)
        guard exists(p.outputs[0]) else { throw ConvertError.failed("no output") }
        return p.outputs[0]
    }

    @discardableResult
    static func tool(_ id: String, _ urls: [URL]) throws -> [URL] {
        let outs = try Tools.plan(Tools.all.first { $0.id == id }!, inputs: urls).flatMap { p -> [URL] in try Runner.execute(p); return p.outputs }
        guard outs.allSatisfy(exists) else { throw ConvertError.failed("missing output") }
        return outs
    }

    #if canImport(AppKit)
    static func makePNG(_ url: URL, w: Int = 320, h: Int = 200) {
        let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(CGColor(red: 1, green: 0.6, blue: 0.1, alpha: 1)); ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        ctx.setFillColor(CGColor(red: 0.2, green: 0.8, blue: 0.6, alpha: 1)); ctx.fill(CGRect(x: 20, y: 20, width: w / 2, height: h / 2))
        try! Native.writeImage(ctx.makeImage()!, to: url, ext: "png", quality: 1, strip: true)
    }

    static func makeTextImage(_ text: String, to url: URL) {
        let w = 900, h = 160
        let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(CGColor.white); ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [.font: NSFont.systemFont(ofSize: 56), .foregroundColor: NSColor.black]))
        ctx.textPosition = CGPoint(x: 30, y: 55)
        CTLineDraw(line, ctx)
        try! Native.writeImage(ctx.makeImage()!, to: url, ext: "png", quality: 1, strip: true)
    }

    static func makeQR(_ text: String, to url: URL) throws {
        guard let filter = CIFilter(name: "CIQRCodeGenerator") else { throw ConvertError.failed("no CIQRCodeGenerator") }
        filter.setValue(Data(text.utf8), forKey: "inputMessage")
        guard let out = filter.outputImage?.transformed(by: CGAffineTransform(scaleX: 8, y: 8)),
              let cg = CIContext().createCGImage(out, from: out.extent) else { throw ConvertError.failed("QR render failed") }
        try Native.writeImage(cg, to: url, ext: "png", quality: 1, strip: true)
    }

    static func size(_ u: URL) -> (Int, Int) {
        guard let img = Native.loadImage(u) else { return (0, 0) }
        return (img.width, img.height)
    }

    static func images(in dir: URL) {
        print("\nimages (ImageIO)")
        let png = dir.appendingPathComponent("photo.png")
        makePNG(png)
        for ext in ["jpg", "tiff", "heic"] { check("png → \(ext)", exists(try conv(png, ext))) }
        check("png → pdf", exists(try conv(png, "pdf")))
        let jpg = dir.appendingPathComponent("photo.jpg")
        check("jpg → png round trip keeps size", size(try conv(jpg, "png")) == (320, 200))
        check("rotate 90° swaps dimensions", try { let p = try Tools.rotatePlan(png, degrees: 90); try Runner.execute(p); return size(p.outputs[0]) == (200, 320) }())
        check("rotate 180° keeps dimensions", try { let p = try Tools.rotatePlan(png, degrees: 180); try Runner.execute(p); return size(p.outputs[0]) == (320, 200) }())
        check("flip horizontal + vertical", try { let p = try Tools.rotatePlan(png, degrees: 0, flipH: true, flipV: true); try Runner.execute(p); return exists(p.outputs[0]) }())
        check("add background (blur) grows the canvas", try { let p = Plan(steps: [.native(.background(png, dir.appendingPathComponent("framed.jpg"), Backdrop(fill: .blur, padding: 32)))], outputs: []); try Runner.execute(p); return size(dir.appendingPathComponent("framed.jpg")) == (384, 264) }())
        check("add background: gradient, corners, shadow, 1:1 canvas", try { let o = dir.appendingPathComponent("bg-square.png"); try Runner.execute(Plan(steps: [.native(.background(png, o, Backdrop(padding: 40, corners: 24, shadow: 30, ratio: 1)))], outputs: [])); let s = size(o); return s.0 == s.1 && s.0 >= 400 }())
        check("annotate draws on the picture", try { let o = dir.appendingPathComponent("marked.png"); try Runner.execute(Plan(steps: [.native(.annotate(png, o, [Mark(kind: "arrow", points: [[0.1, 0.1], [0.9, 0.9]], rgba: [1, 0, 0], width: 0.02), Mark(kind: "text", points: [[0.2, 0.5]], rgba: [0, 0, 1], width: 0.01, text: "Hi")]))], outputs: [])); return size(o) == size(png) }())
        check("srt → txt keeps only the dialogue", NativeOp.dialogue("1\n00:00:01,000 --> 00:00:02,000\n<i>Hello</i>\n\n2\n00:00:03,000 --> 00:00:04,000\nWorld\n") == "Hello\nWorld\n")
        check("edit photo (adjust) renders", try { let o = dir.appendingPathComponent("adjusted.jpg"); try Native.perform(.adjust(png, o, ["brightness": 20, "contrast": 30, "highlights": -40, "shadows": 25, "gamma": 10, "temperature": 30, "tint": -10, "vibrance": 20, "exposure": 0.5])); return size(o) == (320, 200) }())
        // Vision needs an ML inference context; virtualized CI runners have none. Real Macs do.
        let visionOK: Bool = { do { _ = try Native.redacted(Native.loadImage(png)!, faces: true, text: true); return true } catch { return false } }()
        if visionOK {
            check("redact (faces + text) renders", try { let o = dir.appendingPathComponent("redacted.png"); try Native.perform(.redact(png, o, true, true)); return size(o) == (320, 200) }())
        } else { skip("redact (Vision)", "no ML inference context on this host") }
        check("two images → one combined pdf", try { let p = try Tools.plan(Tools.tool("createpdf"), inputs: [png, jpg])[0]; try Runner.execute(p); return Native.pdfPageCount(p.outputs[0]) == 2 }())
        check("png → bmp (ImageIO)", exists(try conv(png, "bmp")))
        check("png → docx has the picture in it", { let d = try? conv(png, "docx"); return d.flatMap { try? Data(contentsOf: $0) }.map { $0.range(of: Data("word/media/image1.png".utf8)) != nil } ?? false }())
        check("strip metadata", exists(try tool("strip", [jpg])[0]))
        let compressed = try? tool("compress", [jpg])[0]
        check("compress jpg is smaller", { () -> Bool in
            guard let c = compressed else { return false }
            let s = { (u: URL) in (try? FileManager.default.attributesOfItem(atPath: u.path)[.size] as? Int) ?? 0 }
            return s(c) > 0 && s(c) <= s(jpg)
        }())
        let svg = dir.appendingPathComponent("logo.svg")
        try? "<svg xmlns='http://www.w3.org/2000/svg' width='64' height='64'><circle cx='32' cy='32' r='30' fill='orange'/></svg>".write(to: svg, atomically: true, encoding: .utf8)
        check("svg → png rasterizes", size(try conv(svg, "png")) == (128, 128))
        print("\nnew image tools")
        check("collage of two images", size(try tool("collage", [png, jpg])[0]).0 > 1000)
        let crop = try? Tools.cropPlan(png, rect: CGRect(x: 10, y: 20, width: 100, height: 50))
        check("crop plan → 100×50", try { guard let c = crop else { return false }; try Runner.execute(c); return size(c.outputs[0]) == (100, 50) }())
        check("shrink 50% halves the area", try { let p = try Tools.shrinkPlan(png, percent: 50); try Runner.execute(p); let s = size(p.outputs[0]); return abs(s.0 * s.1 - 32000) < 1500 }())
        let tagged = try? Tools.metadataPlan(jpg, fields: ["title": "Holiday", "author": "Clementine"])
        check("image metadata written and read back", try { guard let t = tagged else { return false }; try Runner.execute(t)
            let meta = Native.imageMetadata(t.outputs[0])
            let ok = meta.contains { ($0.0.hasSuffix("ImageDescription") || $0.0.hasSuffix("ObjectName") || $0.0.hasSuffix("CaptionAbstract")) && $0.1 == "Holiday" }
            if !ok { print("  info  metadata keys: " + meta.map { "\($0.0)=\($0.1)" }.filter { $0.contains("Holiday") || $0.contains("Clementine") || $0.contains("Description") }.joined(separator: "; ")) }
            return ok }())
        let qr = dir.appendingPathComponent("qr.png")
        if visionOK {
            check("QR generated and read back (Vision)", try { try makeQR("https://example.com/clementine", to: qr); return try Native.barcodes(qr) == ["https://example.com/clementine"] }())
            let words = dir.appendingPathComponent("words.png")
            makeTextImage("Hello Clementine OCR", to: words)
            check("OCR reads rendered text", try { let p = try Tools.plan(Tools.tool("ocr"), inputs: [words])[0]; try Runner.execute(p)
                return (try String(contentsOf: p.outputs[0], encoding: .utf8)).contains("Clementine") }())
            check("searchable PDF from an image has selectable text", try { let p = try Tools.plan(Tools.tool("ocrpdf"), inputs: [words])[0]; try Runner.execute(p)
                return (try Native.open(p.outputs[0]).string ?? "").contains("Clementine") }())
            check("QR inside a PDF", try { let p = try Convert.plan(qr, to: Formats.byID["pdf"]!); try Runner.execute(p); return try Native.barcodes(p.outputs[0]).first == "https://example.com/clementine" }())
        } else { skip("QR / OCR (Vision)", "no ML inference context on this host") }
        check("fit image under 20 KB", try { let p = try Tools.fitPlan(jpg, bytes: 20_000); try Runner.execute(p)
            return ((try FileManager.default.attributesOfItem(atPath: p.outputs[0].path)[.size] as? Int) ?? Int.max) <= 20_000 }())
        if EngineLocator.path(for: .cwebp) != nil || Convert.ffmpegEncoders.contains("libwebp") {
            check("png → webp (\(EngineLocator.path(for: .cwebp) != nil ? "cwebp" : "ffmpeg"))", exists(try conv(png, "webp")))
            check("webp → jpg (ImageIO or ffmpeg decode)", exists(try conv(dir.appendingPathComponent("photo.webp"), "jpg")))
        } else { skip("webp", "no cwebp and ffmpeg lacks libwebp") }
        if EngineLocator.path(for: .avifenc) != nil || Convert.ffmpegEncoders.contains("libaom-av1") {
            check("png → avif", exists(try conv(png, "avif")))
        } else { skip("avif", "no avifenc and ffmpeg lacks libaom") }
    }

    static func pdfs(in dir: URL) {
        print("\npdf (PDFKit / Quartz)")
        let txt = dir.appendingPathComponent("notes.txt")
        try? (1...120).map { "Line \($0): the quick brown fox jumps over the lazy dog." }.joined(separator: "\n").write(to: txt, atomically: true, encoding: .utf8)
        let pdf = (try? conv(txt, "pdf")) ?? dir.appendingPathComponent("notes.pdf")
        check("txt → pdf (Core Text), 2+ pages", Native.pdfPageCount(pdf) >= 2)
        check("pdf → txt keeps content", (try String(contentsOf: try conv(pdf, "txt"), encoding: .utf8)).contains("Line 120"))
        check("pdf → png per page folder", exists(try conv(pdf, "png").appendingPathComponent("page 1.png")))
        check("split → one pdf per page", exists(try tool("split", [pdf])[0].appendingPathComponent("page 2.pdf")))
        let pages = Native.pdfPageCount(pdf)
        check("merge doubles pages", Native.pdfPageCount(try tool("merge", [pdf, pdf])[0]) == pages * 2)
        check("rotate pdf 90°", try { let p = try Tools.rotatePlan(pdf, degrees: 90); try Runner.execute(p); return Native.pdfPageCount(p.outputs[0]) == pages }())
        check("strip metadata", Native.pdfPageCount(try tool("strip", [pdf])[0]) == pages)
        check("compress (Quartz filter)", Native.pdfPageCount(try tool("compress", [pdf])[0]) == pages)
        check("extract text tool", exists(try tool("text", [pdf])[0]))
        let reversed = Tools.reorderPlan(pdf, order: Array((0..<pages).reversed()))
        check("reorder (reverse) keeps page count", try { try Runner.execute(reversed); return Native.pdfPageCount(reversed.outputs[0]) == pages }())
        let dropped = Tools.reorderPlan(pdf, order: [0])
        check("reorder can drop pages", try { try Runner.execute(dropped); return Native.pdfPageCount(dropped.outputs[0]) == 1 }())
        let meta = try? Tools.metadataPlan(pdf, fields: ["title": "Notes", "author": "Clementine"])
        check("pdf metadata written and read back", try { guard let m = meta else { return false }; try Runner.execute(m)
            return Native.pdfMetadata(m.outputs[0]).contains { $0.0 == "Title" && $0.1 == "Notes" } }())
        if EngineLocator.path(for: .pandoc) != nil {
            check("pdf → md (text route)", exists(try conv(pdf, "md")))
            check("pdf → docx (text route or LibreOffice)", exists(try conv(pdf, "docx")))
        } else { skip("pdf → md/docx/epub", "pandoc not installed") }
    }

    static func documents(in dir: URL) {
        print("\ndocuments (textutil / pandoc / LibreOffice)")
        let txt = dir.appendingPathComponent("doc.txt")
        try? "Hello from Clementine.\n\nSecond paragraph.".write(to: txt, atomically: true, encoding: .utf8)
        check("txt → docx (textutil)", exists(try conv(txt, "docx")))
        check("docx → html (textutil)", (try String(contentsOf: try conv(dir.appendingPathComponent("doc.docx"), "html"), encoding: .utf8)).contains("Clementine"))
        check("html → rtf (textutil)", exists(try conv(dir.appendingPathComponent("doc.html"), "rtf")))
        check("docx → pdf (native when LibreOffice absent)", Native.pdfPageCount(try conv(dir.appendingPathComponent("doc.docx"), "pdf")) == 1)
        let csv = dir.appendingPathComponent("table.csv")
        try? "a,b\n1,2\n".write(to: csv, atomically: true, encoding: .utf8)
        check("csv → tsv", (try String(contentsOf: try conv(csv, "tsv"), encoding: .utf8)) == "a\tb\n1\t2\n")
        if EngineLocator.path(for: .pandoc) != nil {
            let md = dir.appendingPathComponent("readme.md")
            try? "# Title\n\nSome *markdown*.".write(to: md, atomically: true, encoding: .utf8)
            check("md → pdf (pandoc html → Core Text)", Native.pdfPageCount(try conv(md, "pdf")) == 1)
        }
        if EngineLocator.path(for: .soffice) != nil {
            check("csv → xlsx (LibreOffice)", exists(try conv(csv, "xlsx")))
        } else { skip("xlsx / ods / pptx", "LibreOffice not installed") }
    }
    #endif

    static func pandocDocs(in dir: URL) {
        print("\ndocuments (pandoc)")
        guard EngineLocator.path(for: .pandoc) != nil else { skip("markdown / epub / docx ↔ md", "pandoc not installed"); return }
        let md = dir.appendingPathComponent("readme.md")
        try? "# Title\n\nSome *markdown* text.".write(to: md, atomically: true, encoding: .utf8)
        check("md → docx", exists(try conv(md, "docx")))
        check("md → epub", exists(try conv(md, "epub")))
        check("md → html keeps text", (try String(contentsOf: try conv(md, "html"), encoding: .utf8)).contains("markdown"))
        check("docx → md round trip", (try String(contentsOf: try conv(dir.appendingPathComponent("readme.docx"), "md"), encoding: .utf8)).contains("Title"))
        check("epub → txt", exists(try conv(dir.appendingPathComponent("readme.epub"), "txt")))
        let csv = dir.appendingPathComponent("grid.csv")
        try? "a,b\n1,2\n".write(to: csv, atomically: true, encoding: .utf8)
        check("csv → tsv (native, no engine)", (try String(contentsOf: try conv(csv, "tsv"), encoding: .utf8)) == "a\tb\n1\t2\n")
    }

    static func office(in dir: URL) {
        print("\noffice (LibreOffice)")
        guard EngineLocator.path(for: .soffice) != nil else { skip("xlsx / ods / pptx / pdf → docx with layout", "LibreOffice not installed"); return }
        let csv = dir.appendingPathComponent("sheet.csv")
        try? "name,qty\napples,3\n".write(to: csv, atomically: true, encoding: .utf8)
        check("csv → xlsx", exists(try conv(csv, "xlsx")))
        check("xlsx → ods", exists(try conv(dir.appendingPathComponent("sheet.xlsx"), "ods")))
        check("xlsx → pdf", exists(try conv(dir.appendingPathComponent("sheet.xlsx"), "pdf")))
        let html = dir.appendingPathComponent("deck.html")
        try? "<h1>Slide</h1><p>Body</p>".write(to: html, atomically: true, encoding: .utf8)
        check("html → pdf (LibreOffice route)", exists(try conv(html, "pdf")))
        check("pdf → docx (writer_pdf_import keeps layout)", exists(try conv(dir.appendingPathComponent("deck.pdf"), "docx")))
    }

    static func archives(in dir: URL) {
        print("\narchives (bsdtar)")
        let folder = dir.appendingPathComponent("bundle")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try? "x".write(to: folder.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        check("folder → tgz", exists(try conv(folder, "tgz")))
        check("tgz → tar (re-pack)", exists(try conv(dir.appendingPathComponent("bundle.tgz"), "tar")))
        check("extract tar", exists(try tool("extract", [dir.appendingPathComponent("bundle.tar")])[0].appendingPathComponent("bundle/a.txt")))
        #if os(macOS)
        check("folder → zip", exists(try conv(folder, "zip")))
        check("zip → tgz (re-pack)", exists(try conv(dir.appendingPathComponent("bundle.zip"), "tgz")))
        #else
        skip("zip", "GNU tar cannot write zip; macOS bsdtar can")
        #endif
    }

    static func media(in dir: URL, quick: Bool) {
        print("\naudio / video (ffmpeg)")
        guard let ff = EngineLocator.path(for: .ffmpeg) else { skip("all audio/video", "ffmpeg not installed: brew install ffmpeg"); return }
        let wav = dir.appendingPathComponent("tone.wav")
        try? Runner.shell(ff, Convert.ffBase + ["-f", "lavfi", "-i", "sine=frequency=440:duration=1", wav.path])
        check("fixture wav", exists(wav))
        for ext in ["mp3", "m4a", "flac", "ogg", "opus", "aiff"] { check("wav → \(ext)", exists(try conv(wav, ext))) }
        print("  info  ogg codec: \(Convert.ffmpegEncoders.contains("libvorbis") ? "vorbis" : Convert.ffmpegEncoders.contains("libopus") ? "opus-in-ogg" : "flac-in-ogg")")
        check("mp3 → wav", exists(try conv(dir.appendingPathComponent("tone.mp3"), "wav")))
        check("audio compress", exists(try tool("compress", [wav])[0]))
        check("audio normalize keeps 44.1 kHz", try { let o = try tool("normalize", [wav])[0]; return try Tools.probe(o, "stream=sample_rate", stream: "a:0") == 44100 }())
        check("audio trim silence", exists(try tool("silence", [wav])[0]))
        let gap = dir.appendingPathComponent("gap.wav")
        try? Runner.shell(ff, Convert.ffBase + ["-f", "lavfi", "-i", "aevalsrc='if(between(t,1,2),0,sin(440*2*PI*t))':d=3", gap.path])
        check("trim silence keeps an internal pause", try { let o = try tool("silence", [gap])[0]; return try Tools.duration(o) > 2.5 }())
        check("audio strip metadata", exists(try tool("strip", [dir.appendingPathComponent("tone.mp3")])[0]))
        check("mono ⇄ stereo flips channel count", try { let o = try tool("channels", [wav])[0]; return try Tools.probe(o, "stream=channels", stream: "a:0") == 2 }())
        check("trim 0.2–0.7 s → ~0.5 s", try { let p = try Tools.trimPlan(wav, start: 0.2, end: 0.7); try Runner.execute(p); return abs(try Tools.duration(p.outputs[0]) - 0.5) < 0.1 }())
        check("audio shrink to 50%", try { let p = try Tools.shrinkPlan(dir.appendingPathComponent("tone.mp3"), percent: 50); try Runner.execute(p); return exists(p.outputs[0]) }())
        check("audio metadata tag", try { let p = try Tools.metadataPlan(dir.appendingPathComponent("tone.mp3"), fields: ["title": "Tone"]); try Runner.execute(p); return exists(p.outputs[0]) }())
        let srt = dir.appendingPathComponent("subs.srt")
        try? "1\n00:00:00,000 --> 00:00:01,000\nHello\n".write(to: srt, atomically: true, encoding: .utf8)
        check("srt → vtt", exists(try conv(srt, "vtt")))
        if quick { skip("video", "--quick"); return }
        let mp4 = dir.appendingPathComponent("clip.mp4")
        try? Runner.shell(ff, Convert.ffBase + ["-f", "lavfi", "-i", "testsrc=duration=2:size=128x96:rate=10", "-f", "lavfi", "-i", "sine=duration=2",
                                                "-shortest", "-pix_fmt", "yuv420p", mp4.path])
        check("fixture mp4", exists(mp4))
        for ext in ["mov", "mkv", "webm", "gif", "mp3"] { check("mp4 → \(ext)", exists(try conv(mp4, ext))) }
        check("gif → mp4", exists(try conv(dir.appendingPathComponent("clip.gif"), "mp4")))
        for id in ["compress", "strip", "mute", "audio", "snapshot"] {
            check("video \(id)", exists(try tool(id, [mp4])[0]))
        }
        check("video rotate 90° + hflip", try { let p = try Tools.rotatePlan(mp4, degrees: 90, flipH: true); try Runner.execute(p); return try Tools.probe(p.outputs[0], "stream=width", stream: "v:0") == 96 }())
        check("video speed 2× halves duration", try { let p = try Tools.speedPlan(mp4, factor: 2); try Runner.execute(p); return abs(try Tools.duration(p.outputs[0]) - 1) < 0.3 }())
        check("video speed 0.25× (chained tempo)", try { let p = try Tools.speedPlan(mp4, factor: 0.25); try Runner.execute(p); return abs(try Tools.duration(p.outputs[0]) - 8) < 1 }())
        check("video split at 0.5 s → 2 parts that both play", try { let p = try Tools.splitPlan(mp4, at: 0.5); try Runner.execute(p); return try p.outputs.allSatisfy { try Tools.duration($0) > 0.3 } }())
        let odd = dir.appendingPathComponent("odd.gif")
        try? Runner.shell(ff, Convert.ffBase + ["-f", "lavfi", "-i", "testsrc=duration=1:size=129x97:rate=10", odd.path])
        check("odd-sized gif → mp4 (even dimensions forced)", exists(try conv(odd, "mp4")))
        check("gif rotate 90° keeps the palette chain", try { let p = try Tools.rotatePlan(odd, degrees: 90); try Runner.execute(p)
            return try Tools.probe(p.outputs[0], "stream=width", stream: "v:0") < Tools.probe(p.outputs[0], "stream=height", stream: "v:0") }())
        let silent = dir.appendingPathComponent("silent.mp4")
        try? Runner.shell(ff, Convert.ffBase + ["-f", "lavfi", "-i", "testsrc=duration=1:size=128x96:rate=10", "-pix_fmt", "yuv420p", silent.path])
        check("video speed 2× on a clip without audio", try { let p = try Tools.speedPlan(silent, factor: 2); try Runner.execute(p); return abs(try Tools.duration(p.outputs[0]) - 0.5) < 0.3 }())
        check("frames every 0.5 s → folder of 4", try { let p = Tools.framesPlan(mp4, every: 0.5); try Runner.execute(p); return (try FileManager.default.contentsOfDirectory(atPath: p.outputs[0].path)).count == 4 }())
        check("audio bleep keeps duration", try { let p = try Tools.bleepPlan(wav, start: 0.2, end: 0.6); try Runner.execute(p); return abs(try Tools.duration(p.outputs[0]) - 1) < 0.1 }())
        check("audio visualizer → mp4", exists(try tool("visualizer", [wav])[0]))
        check("join two audio files ≈ 2 s", try { let o = try tool("join", [wav, wav])[0]; return abs(try Tools.duration(o) - 2) < 0.3 }())
        check("join wav + mp3 (different codecs) ≈ 2 s", try { let o = try tool("join", [wav, dir.appendingPathComponent("tone.mp3")])[0]; return abs(try Tools.duration(o) - 2) < 0.3 }())
        check("fit video under 200 KB", try { let p = try Tools.fitPlan(mp4, bytes: 200_000); try Runner.execute(p)
            return ((try FileManager.default.attributesOfItem(atPath: p.outputs[0].path)[.size] as? Int) ?? Int.max) <= 200_000 }())
        check("join two clips ≈ 4 s", try { let o = try tool("join", [mp4, mp4])[0]; return abs(try Tools.duration(o) - 4) < 0.5 }())
        check("video crop 64×48", try { let p = try Tools.cropPlan(mp4, rect: CGRect(x: 8, y: 8, width: 64, height: 48)); try Runner.execute(p)
            return try Tools.probe(p.outputs[0], "stream=width", stream: "v:0") == 64 }())
        check("video trim 0.5–1.5 s", try { let p = try Tools.trimPlan(mp4, start: 0.5, end: 1.5); try Runner.execute(p); return abs(try Tools.duration(p.outputs[0]) - 1) < 0.3 }())
        check("video shrink to 40%", try { let p = try Tools.shrinkPlan(mp4, percent: 40); try Runner.execute(p); return exists(p.outputs[0]) }())
        #if canImport(AppKit)
        let still = dir.appendingPathComponent("still.png")
        makePNG(still, w: 320, h: 240)
        check("image + audio → video", try { let o = try tool("slideshow", [still, wav])[0]; return abs(try Tools.duration(o) - 1) < 0.3 }())
        #endif
    }
}
