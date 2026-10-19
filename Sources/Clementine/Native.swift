import Foundation

struct ImageOpts {
    var quality: Double? = nil   // 0…1, lossy formats only
    var scale: Double = 1        // 0.5 = half size
    var rotate: Int = 0          // degrees clockwise, multiple of 90
    var flipH = false
    var flipV = false
    var strip = false            // drop EXIF/GPS/etc.
}

/// Add BG settings, in source pixels. Colours are sRGB 0…1 components (Foundation-only, so the CLI builds on Linux).
struct Backdrop {
    enum Fill { case color([Double]), gradient([[Double]]), image(URL), blur }
    var fill: Fill = .gradient([[1, 1, 1], [0.45, 0.78, 1]])
    var padding: Double = 0          // around the picture
    var corners: Double = 0          // picture corner radius
    var shadow: Double = 0           // shadow blur radius
    var ratio: Double? = nil         // canvas width / height; nil = fit the padded picture
}

/// One Annotate mark. Points are 0…1 of the image (origin bottom-left); width is a fraction of the image width.
struct Mark {
    var kind: String                 // "pen" | "highlight" | "arrow" | "box" | "text"
    var points: [[Double]]
    var rgba: [Double]
    var width: Double
    var text = ""
}

enum NativeOp {
    case image(URL, URL, ImageOpts)
    case imagesToPDF([URL], URL)
    case pdfToImages(URL, dir: URL?, single: URL?, ext: String)
    case pdfText(URL, URL)
    case pdfMerge([URL], URL)
    case pdfSplit(URL, dir: URL)
    case pdfCompress(URL, URL)
    case pdfStrip(URL, URL)
    case pdfRotate(URL, URL)
    case docToPDF(URL, URL)
    case delimited(URL, URL, from: String, to: String)
    case mkdir(URL)
    case move(URL, URL)
    case writeText(URL, String)
    case crop(URL, URL, CGRect)                 // rect in source pixels, origin top-left
    case collage([URL], URL)
    case pdfReorder(URL, URL, [Int])            // zero-based page order; omitted pages are dropped
    case pdfSetMeta(URL, URL, [String: String]) // title / author / comment
    case imageSetMeta(URL, URL, [String: String])
    case pdfRotateBy(URL, URL, Int)
    case adjust(URL, URL, [String: Double])     // Edit Photo sliders, see Native.adjusted
    case background(URL, URL, Backdrop)
    case annotate(URL, URL, [Mark])
    case subtitleText(URL, URL)                 // srt / vtt → plain dialogue text
    case pdfTable(URL, URL)                     // pdf → csv: one row per text line, cells split on runs of spaces / tabs
    case redact(URL, URL, Bool, Bool)           // faces, text
    case imageToDocx(URL, URL)
    case ocr(URL, URL)                          // image or pdf → txt (Vision)
    case searchablePDF(URL, URL)                // image or scanned pdf → pdf with an invisible text layer
    case fitImage(URL, URL, Int)                // re-encode until under N bytes

    /// The ops that need only Foundation. True when handled.
    func performPortable() throws -> Bool {
        let fm = FileManager.default
        switch self {
        case .writeText(let u, let text):
            try text.write(to: u, atomically: true, encoding: .utf8)
        case .mkdir(let d):
            try fm.createDirectory(at: d, withIntermediateDirectories: true)
        case .move(let a, let b):
            guard fm.fileExists(atPath: a.path) else { throw ConvertError.failed("LibreOffice produced no output") }
            try fm.moveItem(at: a, to: b)
        case .delimited(let i, let o, let from, let to):
            let text = try String(contentsOf: i, encoding: .utf8)
            try text.replacingOccurrences(of: from, with: to).write(to: o, atomically: true, encoding: .utf8)
        case .subtitleText(let i, let o):
            try Self.dialogue(try String(contentsOf: i, encoding: .utf8)).write(to: o, atomically: true, encoding: .utf8)
        default:
            return false
        }
        return true
    }

    /// Subtitle file → the spoken lines: cue numbers, timings, WEBVTT headers, notes and inline tags removed.
    static func dialogue(_ subs: String) -> String {
        var out: [String] = [], skipping = false
        for raw in subs.replacingOccurrences(of: "\r", with: "").components(separatedBy: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { skipping = false; continue }
            if skipping || line.hasPrefix("WEBVTT") || line.hasPrefix("NOTE") || line.hasPrefix("STYLE") || line.hasPrefix("REGION") { skipping = !line.hasPrefix("WEBVTT"); continue }
            if line.contains("-->") || line.allSatisfy(\.isNumber) { continue }
            let clean = line.replacingOccurrences(of: "<[^>]+>|\\{[^}]+\\}", with: "", options: .regularExpression)
            if !clean.isEmpty, out.last != clean { out.append(clean) }
        }
        return out.joined(separator: "\n") + "\n"
    }
}

#if canImport(AppKit)
import AppKit
import ImageIO
import PDFKit
import Quartz
import UniformTypeIdentifiers
import Vision
import CoreImage
import WebKit

enum Native {
    static func perform(_ op: NativeOp) throws {
        let fm = FileManager.default
        if try op.performPortable() { return }
        switch op {
        case .mkdir, .move, .delimited, .writeText, .subtitleText:
            break
        case .crop(let i, let o, let rect):
            guard let img = loadImage(i) else { throw ConvertError.failed("Could not read \(i.lastPathComponent)") }
            let r = rect.intersection(CGRect(x: 0, y: 0, width: img.width, height: img.height)).integral
            guard r.width >= 1, r.height >= 1, let cut = img.cropping(to: r) else { throw ConvertError.failed("Crop rectangle is outside the image") }
            let ext = o.pathExtension.lowercased()
            try writeImage(cut, to: o, ext: ext, quality: ext == "jpg" || ext == "heic" ? 0.9 : 1, strip: false, from: i)
        case .collage(let urls, let o):
            try writeImage(try collage(urls), to: o, ext: "jpg", quality: 0.9, strip: true)
        case .pdfReorder(let i, let o, let order):
            let src = try open(i)
            let doc = PDFDocument()
            for n in order where n >= 0 && n < src.pageCount {
                if let p = src.page(at: n) { doc.insert(p, at: doc.pageCount) }
            }
            guard doc.pageCount > 0 else { throw ConvertError.failed("No pages left") }
            try write(doc, to: o)
        case .pdfSetMeta(let i, let o, let fields):
            let doc = try open(i)
            var attrs = doc.documentAttributes ?? [:]
            let keys: [String: PDFDocumentAttribute] = ["title": .titleAttribute, "author": .authorAttribute, "comment": .subjectAttribute]
            for (k, v) in fields { if let key = keys[k] { attrs[key] = v } }
            doc.documentAttributes = attrs
            try write(doc, to: o)
        case .pdfRotateBy(let i, let o, let deg):
            let doc = try open(i)
            for n in 0..<doc.pageCount { doc.page(at: n)?.rotation += deg }
            try write(doc, to: o)
        case .adjust(let i, let o, let params):
            guard let img = loadImage(i) else { throw ConvertError.failed("Could not read \(i.lastPathComponent)") }
            let ext = o.pathExtension.lowercased()
            try writeImage(try adjusted(img, params), to: o, ext: ext, quality: ext == "jpg" || ext == "heic" ? 0.92 : 1, strip: false, from: i)
        case .background(let i, let o, let b):
            guard let img = loadImage(i) else { throw ConvertError.failed("Could not read \(i.lastPathComponent)") }
            try writeImage(try backdrop(img, b), to: o, ext: o.pathExtension.lowercased(), quality: 0.92, strip: false, from: i)
        case .annotate(let i, let o, let marks):
            guard let img = loadImage(i) else { throw ConvertError.failed("Could not read \(i.lastPathComponent)") }
            try writeImage(try annotated(img, marks), to: o, ext: o.pathExtension.lowercased(), quality: 0.92, strip: false, from: i)
        case .pdfTable(let i, let o):
            let doc = try open(i)
            let rows = (0..<doc.pageCount).flatMap { (doc.page(at: $0)?.string ?? "").components(separatedBy: .newlines) }
                .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
                .map { $0.components(separatedBy: "\t").flatMap { $0.components(separatedBy: "  ") }.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty } }
            guard !rows.isEmpty else { throw ConvertError.failed("No text in \(i.lastPathComponent) (a scanned PDF? Run Searchable PDF first)") }
            try csv(rows).write(to: o, atomically: true, encoding: .utf8)
        case .redact(let i, let o, let faces, let text):
            guard let img = loadImage(i) else { throw ConvertError.failed("Could not read \(i.lastPathComponent)") }
            try writeImage(try redacted(img, faces: faces, text: text), to: o, ext: o.pathExtension.lowercased(), quality: 0.92, strip: true)
        case .imageToDocx(let i, let o):
            try imageDocx(i, o)
        case .imageSetMeta(let i, let o, let fields):
            guard let img = loadImage(i) else { throw ConvertError.failed("Could not read \(i.lastPathComponent)") }
            let ext = o.pathExtension.lowercased()
            var props = carriedMetadata(i)                 // keep the photo's own EXIF / GPS; the fields go on top
            props[kCGImageDestinationLossyCompressionQuality] = 0.9
            var tiff = props[kCGImagePropertyTIFFDictionary] as? [CFString: Any] ?? [:]
            if let t = fields["title"] { tiff[kCGImagePropertyTIFFImageDescription] = t }
            if let a = fields["author"] { tiff[kCGImagePropertyTIFFArtist] = a }
            var iptc = props[kCGImagePropertyIPTCDictionary] as? [CFString: Any] ?? [:]
            if let t = fields["title"] { iptc[kCGImagePropertyIPTCObjectName] = t; iptc[kCGImagePropertyIPTCCaptionAbstract] = t }
            if let a = fields["author"] { iptc[kCGImagePropertyIPTCByline] = a }
            props[kCGImagePropertyTIFFDictionary] = tiff
            props[kCGImagePropertyIPTCDictionary] = iptc
            if let c = fields["comment"] {
                var exif = props[kCGImagePropertyExifDictionary] as? [CFString: Any] ?? [:]
                exif[kCGImagePropertyExifUserComment] = c
                props[kCGImagePropertyExifDictionary] = exif
            }
            try writeImage(img, to: o, ext: ext, props: props)
        case .image(let i, let o, let opts):
            try convertImage(i, o, opts)
        case .imagesToPDF(let urls, let o):
            let doc = PDFDocument()
            for (n, u) in urls.enumerated() {
                guard let img = loadImage(u) else { throw ConvertError.failed("Could not read \(u.lastPathComponent)") }
                guard let page = PDFPage(image: NSImage(cgImage: img, size: NSSize(width: img.width, height: img.height))) else { continue }
                doc.insert(page, at: n)
            }
            try write(doc, to: o)
        case .pdfToImages(let i, let dir, let single, let ext):
            let doc = try open(i)
            if let dir { try fm.createDirectory(at: dir, withIntermediateDirectories: true) }
            for n in 0..<doc.pageCount {
                guard let page = doc.page(at: n) else { continue }
                let out = single ?? dir!.appendingPathComponent("page \(n + 1)").appendingPathExtension(ext)
                try writeImage(render(page, dpi: 300), to: out, ext: ext, quality: 0.9, strip: true)
            }
        case .pdfText(let i, let o):
            let doc = try open(i)
            var text = doc.string ?? ""
            if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { text = try ocrText(i) }   // scanned PDF
            try text.write(to: o, atomically: true, encoding: .utf8)
        case .ocr(let i, let o):
            try (try ocrText(i)).write(to: o, atomically: true, encoding: .utf8)
        case .searchablePDF(let i, let o):
            try searchablePDF(i, o)
        case .fitImage(let i, let o, let bytes):
            try fitImage(i, o, under: bytes)
        case .pdfMerge(let urls, let o):
            let doc = PDFDocument()
            for u in urls {
                let src = try open(u)
                for n in 0..<src.pageCount { if let p = src.page(at: n) { doc.insert(p, at: doc.pageCount) } }
            }
            try write(doc, to: o)
        case .pdfSplit(let i, let dir):
            let src = try open(i)
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            for n in 0..<src.pageCount {
                let one = PDFDocument()
                if let p = src.page(at: n) { one.insert(p, at: 0) }
                try write(one, to: dir.appendingPathComponent("page \(n + 1).pdf"))
            }
        case .pdfStrip(let i, let o):
            let doc = try open(i)
            doc.documentAttributes = [:]
            try write(doc, to: o)
        case .pdfRotate(let i, let o):
            let doc = try open(i)
            for n in 0..<doc.pageCount { doc.page(at: n)?.rotation += 90 }
            try write(doc, to: o)
        case .pdfCompress(let i, let o):
            try compressPDF(i, o)
        case .docToPDF(let i, let o):
            // HTML goes through WebKit inside NSAttributedString, which wants the main thread.
            if Thread.isMainThread { try docToPDF(i, o) } else {
                var failure: Error?
                DispatchQueue.main.sync { do { try docToPDF(i, o) } catch { failure = error } }
                if let failure { throw failure }
            }
        }
    }

    /// Can ImageIO open this file at all? (WebP needs macOS 14.)
    static func canDecode(_ url: URL) -> Bool {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil), CGImageSourceGetCount(src) > 0 else { return false }
        return CGImageSourceCopyPropertiesAtIndex(src, 0, nil) != nil
    }

    // MARK: images

    /// Full-resolution CGImage with EXIF orientation applied (or at most `maxPixels` on the long edge). SVG goes through NSImage.
    static func loadImage(_ url: URL, maxPixels: Int? = nil) -> CGImage? {
        if url.pathExtension.lowercased() == "svg" {
            guard let img = NSImage(contentsOf: url) else { return nil }
            let scale: CGFloat = 2   // rasterize at 2× the nominal size
            let size = NSSize(width: max(img.size.width, 1) * scale, height: max(img.size.height, 1) * scale)
            let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width), pixelsHigh: Int(size.height),
                                          bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                          colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
            img.draw(in: NSRect(origin: .zero, size: size))
            NSGraphicsContext.restoreGraphicsState()
            return bitmap.cgImage
        }
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any] ?? [:]
        let w = props[kCGImagePropertyPixelWidth] as? Int ?? 0, h = props[kCGImagePropertyPixelHeight] as? Int ?? 0
        let opts: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                     kCGImageSourceCreateThumbnailWithTransform: true,
                                     kCGImageSourceThumbnailMaxPixelSize: maxPixels ?? max(w, h, 1)]
        return CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary)
    }

    static func convertImage(_ i: URL, _ o: URL, _ opts: ImageOpts) throws {
        guard var img = loadImage(i) else { throw ConvertError.failed("Could not read \(i.lastPathComponent)") }
        if opts.scale != 1 || opts.rotate % 360 != 0 || opts.flipH || opts.flipV { img = try transform(img, opts) }
        let ext = o.pathExtension.lowercased()
        let q = opts.quality ?? (ext == "jpg" || ext == "heic" ? 0.9 : 1)
        try writeImage(img, to: o, ext: ext, quality: q, strip: opts.strip, from: i)
    }

    static func transform(_ img: CGImage, _ opts: ImageOpts) throws -> CGImage {
        let w = Double(img.width) * opts.scale, h = Double(img.height) * opts.scale
        let swap = (opts.rotate / 90) % 2 != 0
        let cw = Int((swap ? h : w).rounded()), ch = Int((swap ? w : h).rounded())
        guard let ctx = CGContext(data: nil, width: max(cw, 1), height: max(ch, 1), bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { throw ConvertError.failed("Could not create bitmap") }
        ctx.interpolationQuality = .high
        ctx.translateBy(x: CGFloat(cw) / 2, y: CGFloat(ch) / 2)
        ctx.rotate(by: -CGFloat(opts.rotate) * .pi / 180)        // CG is y-up: negative = clockwise
        if opts.flipH { ctx.scaleBy(x: -1, y: 1) }
        if opts.flipV { ctx.scaleBy(x: 1, y: -1) }
        ctx.draw(img, in: CGRect(x: -w / 2, y: -h / 2, width: w, height: h))
        guard let out = ctx.makeImage() else { throw ConvertError.failed("Could not render image") }
        return out
    }

    /// `from`: the source file whose EXIF / GPS / IPTC travel with the pixels unless `strip` is set.
    static func writeImage(_ img: CGImage, to url: URL, ext: String, quality: Double, strip: Bool, from source: URL? = nil) throws {
        var props: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: quality]
        if !strip, let source { props.merge(carriedMetadata(source)) { mine, _ in mine } }
        try writeImage(img, to: url, ext: ext, props: props)
    }

    /// The source's EXIF / GPS / TIFF / IPTC dictionaries, minus orientation (loadImage bakes the rotation into the
    /// pixels; left in, viewers would rotate twice) and the stale pixel dimensions.
    static func carriedMetadata(_ url: URL) -> [CFString: Any] {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let p = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any] else { return [:] }
        var out: [CFString: Any] = [:]
        for key in [kCGImagePropertyExifDictionary, kCGImagePropertyGPSDictionary, kCGImagePropertyTIFFDictionary, kCGImagePropertyIPTCDictionary] {
            guard var d = p[key] as? [CFString: Any] else { continue }
            d[kCGImagePropertyTIFFOrientation] = nil
            d[kCGImagePropertyExifPixelXDimension] = nil
            d[kCGImagePropertyExifPixelYDimension] = nil
            out[key] = d
        }
        return out
    }

    static func writeImage(_ img: CGImage, to url: URL, ext: String, props: [CFString: Any]) throws {
        let type: UTType = ["jpg": .jpeg, "png": .png, "tiff": .tiff, "heic": .heic, "gif": .gif, "bmp": .bmp][ext] ?? .png
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, 1, nil) else {
            throw ConvertError.failed("Cannot write \(ext.uppercased()) on this Mac")
        }
        // JPEG has no alpha: flatten onto white so transparent PNGs don't turn black.
        var out = img
        if ext == "jpg", ![CGImageAlphaInfo.none, .noneSkipLast, .noneSkipFirst].contains(img.alphaInfo) {
            if let ctx = CGContext(data: nil, width: img.width, height: img.height, bitsPerComponent: 8, bytesPerRow: 0,
                                   space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) {
                ctx.setFillColor(.white)
                ctx.fill(CGRect(x: 0, y: 0, width: img.width, height: img.height))
                ctx.draw(img, in: CGRect(x: 0, y: 0, width: img.width, height: img.height))
                out = ctx.makeImage() ?? img
            }
        }
        CGImageDestinationAddImage(dest, out, props as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { throw ConvertError.failed("Encoding \(ext.uppercased()) failed") }
    }

    /// A one-page DOCX with the picture on it, packaged by hand: NSAttributedString's Office
    /// writer silently drops image attachments, which left the document empty.
    static func imageDocx(_ i: URL, _ o: URL) throws {
        guard let img = loadImage(i) else { throw ConvertError.failed("Could not read \(i.lastPathComponent)") }
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("docx-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: dir) }
        for sub in ["_rels", "word/_rels", "word/media"] { try fm.createDirectory(at: dir.appendingPathComponent(sub), withIntermediateDirectories: true) }
        // Word reads JPEG and PNG everywhere: photos go in as JPEG, everything else (alpha, HEIC, WebP…) as PNG.
        let ext = ["jpg", "jpeg"].contains(i.pathExtension.lowercased()) ? "jpg" : "png"
        try writeImage(img, to: dir.appendingPathComponent("word/media/image1.\(ext)"), ext: ext, quality: 0.92, strip: true)
        // Fit inside the 6.5 × 9 in text area of a Letter page; 9525 EMU per pixel at 96 dpi.
        let w: Double = Double(img.width) * 9525, h: Double = Double(img.height) * 9525
        let k: Double = min(1, 5_943_600 / w, 8_229_600 / h)
        let cx = Int(w * k), cy = Int(h * k)
        let name = i.lastPathComponent.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: "\"", with: "&quot;")
        let files: [String: String] = [
            "[Content_Types].xml": """
            <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
            <Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types"><Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/><Default Extension="xml" ContentType="application/xml"/><Default Extension="png" ContentType="image/png"/><Default Extension="jpg" ContentType="image/jpeg"/><Override PartName="/word/document.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"/></Types>
            """,
            "_rels/.rels": """
            <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
            <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="word/document.xml"/></Relationships>
            """,
            "word/_rels/document.xml.rels": """
            <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
            <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/image" Target="media/image1.\(ext)"/></Relationships>
            """,
            "word/document.xml": """
            <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
            <w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships" xmlns:wp="http://schemas.openxmlformats.org/drawingml/2006/wordprocessingDrawing" xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main" xmlns:pic="http://schemas.openxmlformats.org/drawingml/2006/picture"><w:body><w:p><w:pPr><w:jc w:val="center"/></w:pPr><w:r><w:drawing><wp:inline distT="0" distB="0" distL="0" distR="0"><wp:extent cx="\(cx)" cy="\(cy)"/><wp:docPr id="1" name="\(name)"/><a:graphic><a:graphicData uri="http://schemas.openxmlformats.org/drawingml/2006/picture"><pic:pic><pic:nvPicPr><pic:cNvPr id="1" name="\(name)"/><pic:cNvPicPr/></pic:nvPicPr><pic:blipFill><a:blip r:embed="rId1"/><a:stretch><a:fillRect/></a:stretch></pic:blipFill><pic:spPr><a:xfrm><a:off x="0" y="0"/><a:ext cx="\(cx)" cy="\(cy)"/></a:xfrm><a:prstGeom prst="rect"><a:avLst/></a:prstGeom></pic:spPr></pic:pic></a:graphicData></a:graphic></wp:inline></w:drawing></w:r></w:p><w:sectPr><w:pgSz w:w="12240" w:h="15840"/><w:pgMar w:top="1440" w:right="1440" w:bottom="1440" w:left="1440" w:header="720" w:footer="720" w:gutter="0"/></w:sectPr></w:body></w:document>
            """,
        ]
        for (path, xml) in files { try xml.write(to: dir.appendingPathComponent(path), atomically: true, encoding: .utf8) }
        try? fm.removeItem(at: o)
        let zip = Process()
        zip.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        zip.currentDirectoryURL = dir
        zip.arguments = ["-q", "-X", "-r", "-nw", o.path, "[Content_Types].xml", "_rels", "word"]   // -nw: the brackets are literal
        try zip.run(); zip.waitUntilExit()
        guard zip.terminationStatus == 0 else { throw ConvertError.failed("zip failed (\(zip.terminationStatus)) writing \(o.lastPathComponent)") }
    }

    static func imageSize(_ url: URL) -> CGSize {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let p = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
              let w = p[kCGImagePropertyPixelWidth] as? Int, let h = p[kCGImagePropertyPixelHeight] as? Int else {
            // SVG (and anything else ImageIO can't open) is rasterised the way Crop will see it.
            return loadImage(url).map { CGSize(width: $0.width, height: $0.height) } ?? .zero
        }
        // Orientation 5-8 swap width and height; loadImage() bakes the rotation in.
        let o = p[kCGImagePropertyOrientation] as? Int ?? 1
        return o >= 5 ? CGSize(width: h, height: w) : CGSize(width: w, height: h)
    }

    /// A grid of all images, each fitted into an equal cell, on white. Square-ish grid.
    static func collage(_ urls: [URL]) throws -> CGImage {
        let cell = 800, gap = 16
        let images = urls.compactMap { loadImage($0, maxPixels: cell) }    // decoded at cell size: 30 photos must not mean 30 full bitmaps
        guard images.count >= 2 else { throw ConvertError.failed("Collage needs two or more readable images") }
        let cols = Int(Double(images.count).squareRoot().rounded(.up))
        let rows = (images.count + cols - 1) / cols
        let w = cols * cell + (cols + 1) * gap, h = rows * cell + (rows + 1) * gap
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
        else { throw ConvertError.failed("Could not create bitmap") }
        ctx.setFillColor(.white)
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        ctx.interpolationQuality = .high
        for (n, img) in images.enumerated() {
            let col = n % cols, row = n / cols
            let s = min(Double(cell) / Double(img.width), Double(cell) / Double(img.height))
            let dw = Double(img.width) * s, dh = Double(img.height) * s
            let x = Double(gap + col * (cell + gap)) + (Double(cell) - dw) / 2
            let y = Double(h - gap - (row + 1) * (cell + gap) + gap) + (Double(cell) - dh) / 2   // CG is y-up
            ctx.draw(img, in: CGRect(x: x, y: y, width: dw, height: dh))
        }
        guard let out = ctx.makeImage() else { throw ConvertError.failed("Could not render collage") }
        return out
    }

    /// Core Image colour adjustments; also used live by the Edit Photo editor.
    /// Edit Photo, Tangerine's controls. Every slider is -100…100 around 0 except exposure (EV, ±3).
    /// Highlights / shadows / whites / blacks share one tone curve; gamma bends the midtones.
    static func adjusted(_ img: CGImage, _ p: [String: Double]) throws -> CGImage {
        func v(_ k: String) -> Double { p[k] ?? 0 }
        var ci = CIImage(cgImage: img)
        func apply(_ name: String, _ params: [String: Any]) {
            guard let f = CIFilter(name: name) else { return }
            f.setValue(ci, forKey: kCIInputImageKey)
            for (k, val) in params { f.setValue(val, forKey: k) }
            ci = f.outputImage ?? ci
        }
        if v("exposure") != 0 { apply("CIExposureAdjust", [kCIInputEVKey: v("exposure")]) }
        if v("brightness") != 0 || v("contrast") != 0 || v("saturation") != 0 {
            apply("CIColorControls", [kCIInputBrightnessKey: v("brightness") / 100 * 0.3,
                                      kCIInputContrastKey: 1 + v("contrast") / 100 * 0.5,
                                      kCIInputSaturationKey: 1 + v("saturation") / 100])
        }
        if ["highlights", "shadows", "whites", "blacks"].contains(where: { v($0) != 0 }) {
            func y(_ base: Double, _ k: String) -> CIVector { CIVector(x: 0, y: CGFloat(min(max(base + v(k) / 100 * 0.15, 0), 1))) }
            apply("CIToneCurve", ["inputPoint0": CIVector(x: 0, y: y(0, "blacks").y), "inputPoint1": CIVector(x: 0.25, y: y(0.25, "shadows").y),
                                  "inputPoint2": CIVector(x: 0.5, y: 0.5), "inputPoint3": CIVector(x: 0.75, y: y(0.75, "highlights").y),
                                  "inputPoint4": CIVector(x: 1, y: y(1, "whites").y)])
        }
        if v("gamma") != 0 { apply("CIGammaAdjust", ["inputPower": pow(2, -v("gamma") / 100)]) }
        if v("temperature") != 0 || v("tint") != 0 {     // a warmer neutral makes the picture warmer
            apply("CITemperatureAndTint", ["inputNeutral": CIVector(x: 6500 + v("temperature") * 40, y: v("tint")), "inputTargetNeutral": CIVector(x: 6500, y: 0)])
        }
        if v("vibrance") != 0 { apply("CIVibrance", ["inputAmount": v("vibrance") / 100]) }
        guard let out = CIContext().createCGImage(ci, from: CGRect(x: 0, y: 0, width: img.width, height: img.height)) else { throw ConvertError.failed("Could not render adjustments") }
        return out
    }

    static func cg(_ c: [Double]) -> CGColor { CGColor(srgbRed: c[0], green: c[1], blue: c[2], alpha: c.count > 3 ? c[3] : 1) }

    /// Add BG: the picture on a colour, gradient, image or blurred copy of itself, with padding,
    /// rounded corners, a soft shadow, and the canvas grown (never cropped) to a ratio.
    static func backdrop(_ img: CGImage, _ b: Backdrop) throws -> CGImage {
        let iw = Double(img.width), ih = Double(img.height)
        var w = iw + 2 * b.padding, h = ih + 2 * b.padding
        if let r = b.ratio, r > 0 { if w / h < r { w = h * r } else { h = w / r } }
        let W = Int(w.rounded()), H = Int(h.rounded())
        guard let ctx = CGContext(data: nil, width: W, height: H, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { throw ConvertError.failed("Could not create bitmap") }
        ctx.interpolationQuality = .high
        let canvas = CGRect(x: 0, y: 0, width: W, height: H)
        func fill(_ bg: CGImage) {    // aspect-fill the canvas
            let s = max(w / Double(bg.width), h / Double(bg.height))
            let bw = Double(bg.width) * s, bh = Double(bg.height) * s
            ctx.draw(bg, in: CGRect(x: (w - bw) / 2, y: (h - bh) / 2, width: bw, height: bh))
        }
        switch b.fill {
        case .color(let c):
            ctx.setFillColor(cg(c)); ctx.fill(canvas)
        case .gradient(let stops):
            let colors = stops.map(cg) as CFArray
            let locs = stops.indices.map { CGFloat($0) / CGFloat(max(stops.count - 1, 1)) }
            ctx.drawLinearGradient(CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: colors, locations: locs)!,
                                   start: CGPoint(x: 0, y: h), end: CGPoint(x: w, y: 0), options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
        case .image(let u):
            ctx.setFillColor(.white); ctx.fill(canvas)
            if let bg = loadImage(u, maxPixels: Int(max(w, h))) { fill(bg) }
        case .blur:
            // Blur a ≤1024 px copy and stretch it: the result is out of focus anyway, and a 48 MP blur would take a GB.
            let small = min(1.0, 1024.0 / max(iw, ih))
            let base = small < 1 ? try transform(img, ImageOpts(scale: small)) : img
            let extent = CGRect(x: 0, y: 0, width: base.width, height: base.height)
            let ci = CIImage(cgImage: base).clampedToExtent().applyingGaussianBlur(sigma: Double(max(base.width, base.height)) / 40).cropped(to: extent)
            ctx.setFillColor(.white); ctx.fill(canvas)
            if let bg = CIContext().createCGImage(ci, from: extent) { fill(bg) }
        }
        let rect = CGRect(x: (w - iw) / 2, y: (h - ih) / 2, width: iw, height: ih)
        let r = min(b.corners, iw / 2, ih / 2)
        let shape = CGPath(roundedRect: rect, cornerWidth: r, cornerHeight: r, transform: nil)
        if b.shadow > 0 {
            ctx.saveGState()
            ctx.setShadow(offset: CGSize(width: 0, height: -b.shadow * 0.35), blur: b.shadow, color: CGColor(gray: 0, alpha: 0.38))
            ctx.addPath(shape); ctx.setFillColor(.black); ctx.fillPath()
            ctx.restoreGState()
        }
        ctx.saveGState()
        ctx.addPath(shape); ctx.clip()
        ctx.draw(img, in: rect)
        ctx.restoreGState()
        guard let out = ctx.makeImage() else { throw ConvertError.failed("Could not render background") }
        return out
    }

    /// Annotate: the marks drawn over the picture at full resolution.
    static func annotated(_ img: CGImage, _ marks: [Mark]) throws -> CGImage {
        let w = img.width, h = img.height
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { throw ConvertError.failed("Could not create bitmap") }
        ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
        drawMarks(marks, in: ctx, size: CGSize(width: w, height: h))
        guard let out = ctx.makeImage() else { throw ConvertError.failed("Could not render annotations") }
        return out
    }

    /// Shared by the Annotate canvas (screen) and the export (pixels): marks are resolution-independent.
    static func drawMarks(_ marks: [Mark], in ctx: CGContext, size: CGSize) {
        func pt(_ p: [Double]) -> CGPoint { CGPoint(x: p[0] * size.width, y: p[1] * size.height) }
        for m in marks where !m.points.isEmpty {
            let lw = max(1, m.width * size.width)
            ctx.saveGState()
            ctx.setLineCap(.round); ctx.setLineJoin(.round); ctx.setLineWidth(lw)
            ctx.setStrokeColor(cg(m.rgba)); ctx.setFillColor(cg(m.rgba))
            switch m.kind {
            case "highlight":
                ctx.setBlendMode(.multiply)
                ctx.setStrokeColor(cg([m.rgba[0], m.rgba[1], m.rgba[2], 0.45]))
                ctx.setLineWidth(lw * 3); ctx.setLineCap(.square)
                ctx.addLines(between: m.points.map(pt)); ctx.strokePath()
            case "box":
                let a = pt(m.points[0]), b = pt(m.points.last!)
                ctx.addPath(CGPath(roundedRect: CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(a.x - b.x), height: abs(a.y - b.y)), cornerWidth: lw, cornerHeight: lw, transform: nil))
                ctx.strokePath()
            case "arrow":
                let a = pt(m.points[0]), b = pt(m.points.last!)
                ctx.move(to: a); ctx.addLine(to: b); ctx.strokePath()
                let ang = atan2(b.y - a.y, b.x - a.x), head = lw * 4.5
                ctx.move(to: b)
                ctx.addLine(to: CGPoint(x: b.x - head * cos(ang - .pi / 7), y: b.y - head * sin(ang - .pi / 7)))
                ctx.addLine(to: CGPoint(x: b.x - head * cos(ang + .pi / 7), y: b.y - head * sin(ang + .pi / 7)))
                ctx.closePath(); ctx.fillPath()
            case "text":
                let p = pt(m.points[0])
                let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: lw * 6, weight: .bold), .foregroundColor: NSColor(cgColor: cg(m.rgba)) ?? .red]
                NSGraphicsContext.saveGraphicsState()
                NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
                NSAttributedString(string: m.text, attributes: attrs).draw(at: p)
                NSGraphicsContext.restoreGraphicsState()
            default:                                        // pen
                ctx.addLines(between: m.points.map(pt)); ctx.strokePath()
            }
            ctx.restoreGState()
        }
    }

    /// Black boxes over detected faces and/or text (Vision; on-device).
    static func redacted(_ img: CGImage, faces: Bool, text: Bool) throws -> CGImage {
        var boxes: [CGRect] = []
        let handler = VNImageRequestHandler(cgImage: img, options: [:])
        if faces {
            let req = VNDetectFaceRectanglesRequest()
            try handler.perform([req])
            boxes += (req.results ?? []).map { $0.boundingBox }
        }
        if text {
            let req = VNRecognizeTextRequest()
            req.recognitionLevel = .fast
            try handler.perform([req])
            boxes += (req.results ?? []).map { $0.boundingBox }
        }
        guard let ctx = CGContext(data: nil, width: img.width, height: img.height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
        else { throw ConvertError.failed("Could not create bitmap") }
        ctx.draw(img, in: CGRect(x: 0, y: 0, width: img.width, height: img.height))
        ctx.setFillColor(CGColor.black)
        for b in boxes {   // Vision boxes are normalised with a bottom-left origin, like Core Graphics
            let r = CGRect(x: b.minX * CGFloat(img.width), y: b.minY * CGFloat(img.height), width: b.width * CGFloat(img.width), height: b.height * CGFloat(img.height))
            ctx.fill(r.insetBy(dx: -r.width * 0.08, dy: -r.height * 0.15))
        }
        guard let out = ctx.makeImage() else { throw ConvertError.failed("Could not render redaction") }
        return out
    }

    /// Recognised lines in reading order (top to bottom, left to right), boxes normalised bottom-left.
    static func recognizedText(_ img: CGImage) throws -> [(String, CGRect)] {
        let req = VNRecognizeTextRequest()
        req.recognitionLevel = .accurate
        req.usesLanguageCorrection = true
        try VNImageRequestHandler(cgImage: img, options: [:]).perform([req])
        let lines = (req.results ?? []).compactMap { o -> (String, CGRect)? in
            guard let c = o.topCandidates(1).first else { return nil }
            return (c.string, o.boundingBox)
        }
        // Rows are bucketed first so the ordering is strict (a tolerance comparator is not transitive on a skewed scan).
        func row(_ r: CGRect) -> Int { Int((1 - r.midY) / 0.015) }
        return lines.sorted { a, b in row(a.1) != row(b.1) ? row(a.1) < row(b.1) : a.1.minX < b.1.minX }
    }

    /// Pages for OCR, one at a time: the image itself, or each PDF page rendered at 200 dpi as it is reached
    /// (a 300-page scan must not become 4 GB of bitmaps). `body` gets (index, count, page, image).
    static func forEachPage(_ url: URL, _ body: (Int, Int, PDFPage?, CGImage) throws -> Void) throws {
        if Formats.identify(url)?.id == "pdf" {
            let doc = try open(url)
            for n in 0..<doc.pageCount {
                guard let page = doc.page(at: n) else { continue }
                try autoreleasepool { try body(n, doc.pageCount, page, render(page)) }
            }
            return
        }
        guard let img = loadImage(url) else { throw ConvertError.failed("Could not read \(url.lastPathComponent)") }
        try body(0, 1, nil, img)
    }

    static func ocrText(_ url: URL) throws -> String {
        var parts: [String] = []
        try forEachPage(url) { n, count, _, img in
            let text = try recognizedText(img).map(\.0).joined(separator: "\n")
            parts.append(count > 1 ? "## Page \(n + 1)\n\(text)" : text)
        }
        return parts.joined(separator: "\n\n")
    }

    /// Draws each page, then its recognised text invisibly on top, so Preview/Spotlight can search and select it.
    static func searchablePDF(_ i: URL, _ o: URL) throws {
        var box = CGRect(x: 0, y: 0, width: 612, height: 792)
        guard let ctx = CGContext(o as CFURL, mediaBox: &box, nil) else { throw ConvertError.failed("Could not create PDF") }
        try forEachPage(i) { _, _, page, img in
            var media = page.map(displayBox) ?? CGRect(x: 0, y: 0, width: img.width, height: img.height)
            let info = [kCGPDFContextMediaBox as String: NSData(bytes: &media, length: MemoryLayout<CGRect>.size)]
            ctx.beginPDFPage(info as CFDictionary)
            if let page { page.draw(with: .mediaBox, to: ctx) } else { ctx.draw(img, in: media) }
            let hasText = !(page?.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            if !hasText {
                for (text, b) in try recognizedText(img) {
                    let r = CGRect(x: media.minX + b.minX * media.width, y: media.minY + b.minY * media.height,
                                   width: b.width * media.width, height: b.height * media.height)
                    let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [.font: NSFont.systemFont(ofSize: max(r.height * 0.8, 2))]))
                    let width = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
                    guard width > 0 else { continue }
                    ctx.saveGState()
                    ctx.setTextDrawingMode(.invisible)
                    ctx.textMatrix = .identity
                    ctx.translateBy(x: r.minX, y: r.minY + r.height * 0.2)
                    ctx.scaleBy(x: r.width / width, y: 1)
                    ctx.textPosition = .zero
                    CTLineDraw(line, ctx)
                    ctx.restoreGState()
                }
            }
            ctx.endPDFPage()
        }
        ctx.closePDF()
    }

    /// JPEG quality steps down, then the image scales down, until the file fits.
    static func fitImage(_ i: URL, _ o: URL, under bytes: Int) throws {
        guard let img = loadImage(i) else { throw ConvertError.failed("Could not read \(i.lastPathComponent)") }
        var scale = 1.0
        for _ in 0..<12 {
            let scaled = scale < 1 ? try transform(img, ImageOpts(scale: scale)) : img
            for q in [0.85, 0.7, 0.55, 0.4] {
                try writeImage(scaled, to: o, ext: "jpg", quality: q, strip: true)
                let size = (try? FileManager.default.attributesOfItem(atPath: o.path)[.size] as? Int) ?? Int.max
                if size <= bytes { return }
            }
            scale *= 0.75
        }
        try? FileManager.default.removeItem(at: o)     // no over-limit leftover next to the original
        throw ConvertError.failed("Could not get under \(ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file))")
    }

    static func redactionCount(_ url: URL) -> Int {
        guard let img = loadImage(url) else { return 0 }
        let handler = VNImageRequestHandler(cgImage: img, options: [:])
        let f = VNDetectFaceRectanglesRequest(), t = VNRecognizeTextRequest()
        t.recognitionLevel = .fast
        try? handler.perform([f, t])
        return (f.results?.count ?? 0) + (t.results?.count ?? 0)
    }

    /// QR / barcode payloads found in an image or on any PDF page (Vision; works on Intel).
    static func barcodes(_ url: URL) throws -> [String] {
        var out: [String] = []
        try forEachPage(url) { _, _, _, img in
            let req = VNDetectBarcodesRequest()
            try VNImageRequestHandler(cgImage: img, options: [:]).perform([req])
            out += (req.results ?? []).compactMap { $0.payloadStringValue }
        }
        return out
    }


    /// Flattened EXIF / TIFF / GPS / IPTC properties as "Section · Key: value" lines.
    static func imageMetadata(_ url: URL) -> [(String, String)] {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [String: Any] else { return [] }
        var out: [(String, String)] = []
        func walk(_ dict: [String: Any], _ prefix: String) {
            for (k, v) in dict.sorted(by: { $0.key < $1.key }) {
                if let d = v as? [String: Any] { walk(d, prefix.isEmpty ? k : "\(prefix) · \(k)") }
                else { out.append((prefix.isEmpty ? k : "\(prefix) · \(k)", "\(v)")) }
            }
        }
        walk(props, "")
        return out
    }

    static func pdfMetadata(_ url: URL) -> [(String, String)] {
        guard let doc = PDFDocument(url: url) else { return [] }
        var out: [(String, String)] = [("Pages", "\(doc.pageCount)"), ("Encrypted", doc.isEncrypted ? "yes" : "no")]
        for (k, v) in doc.documentAttributes ?? [:] {
            out.append(("\(k)".replacingOccurrences(of: "PDFDocument", with: "").replacingOccurrences(of: "Attribute", with: ""), "\(v)"))
        }
        return out
    }

    // MARK: PDF

    static func pdfPageCount(_ url: URL) -> Int { PDFDocument(url: url)?.pageCount ?? 0 }

    static func open(_ url: URL) throws -> PDFDocument {
        guard let d = PDFDocument(url: url) else { throw ConvertError.failed("Could not open \(url.lastPathComponent)") }
        return d
    }

    static func write(_ doc: PDFDocument, to url: URL) throws {
        guard doc.write(to: url) else { throw ConvertError.failed("Could not write \(url.lastPathComponent)") }
    }

    /// The page as displayed: /Rotate 90 or 270 swaps width and height, which bounds(for:) does not reflect
    /// while draw(with:to:) and thumbnail(of:for:) do render upright.
    static func displayBox(_ page: PDFPage) -> CGRect {
        var b = page.bounds(for: .mediaBox)
        if page.rotation % 180 != 0 { b.size = CGSize(width: b.height, height: b.width) }
        return b
    }

    static func render(_ page: PDFPage, dpi: CGFloat = 200) -> CGImage {
        let box = displayBox(page)
        let s = dpi / 72
        let img = page.thumbnail(of: NSSize(width: box.width * s, height: box.height * s), for: .mediaBox)
        return img.cgImage(forProposedRect: nil, context: nil, hints: nil)!
    }

    /// Apple's own "Reduce File Size" Quartz filter, applied while re-drawing each page.
    static func compressPDF(_ i: URL, _ o: URL) throws {
        let doc = try open(i)
        let filterURL = URL(fileURLWithPath: "/System/Library/Filters/Reduce File Size.qfilter")
        guard let filter = QuartzFilter(url: filterURL) else { throw ConvertError.failed("Quartz filter missing") }
        var box = doc.page(at: 0).map(displayBox) ?? CGRect(x: 0, y: 0, width: 612, height: 792)
        guard let ctx = CGContext(o as CFURL, mediaBox: &box, nil) else { throw ConvertError.failed("Could not create PDF") }
        filter.apply(to: ctx)
        for n in 0..<doc.pageCount {
            guard let page = doc.page(at: n) else { continue }
            var b = displayBox(page)
            let info = [kCGPDFContextMediaBox as String: NSData(bytes: &b, length: MemoryLayout<CGRect>.size)]
            ctx.beginPDFPage(info as CFDictionary)
            page.draw(with: .mediaBox, to: ctx)
            ctx.endPDFPage()
        }
        filter.remove(from: ctx)
        ctx.closePDF()
    }

    /// docx / html / rtf / txt → PDF with Core Text, paginated on US Letter. No LibreOffice needed.
    static func docToPDF(_ i: URL, _ o: URL) throws {
        // HTML is imported by WebKit: no scripts and no remote loads, so a saved newsletter cannot phone home.
        let prefs = WebPreferences()
        prefs.isJavaScriptEnabled = false
        prefs.loadsImagesAutomatically = false
        let attributed = try NSAttributedString(url: i, options: [.webPreferences: prefs, .timeout: 10], documentAttributes: nil)
        var page = CGRect(x: 0, y: 0, width: 612, height: 792)
        let inset = page.insetBy(dx: 54, dy: 54)
        guard let ctx = CGContext(o as CFURL, mediaBox: &page, nil) else { throw ConvertError.failed("Could not create PDF") }
        let setter = CTFramesetterCreateWithAttributedString(attributed)
        var pos = 0
        let length = attributed.length
        repeat {
            ctx.beginPDFPage(nil)
            let frame = CTFramesetterCreateFrame(setter, CFRange(location: pos, length: 0), CGPath(rect: inset, transform: nil), nil)
            CTFrameDraw(frame, ctx)
            ctx.endPDFPage()
            let visible = CTFrameGetVisibleStringRange(frame)
            if visible.length == 0 { break }
            pos += visible.length
        } while pos < length
        ctx.closePDF()
    }
}
#else
enum Native {
    static func perform(_ op: NativeOp) throws {
        guard try op.performPortable() else { throw ConvertError.unsupported("This step needs macOS (ImageIO / PDFKit)") }
    }
    static func pdfPageCount(_ url: URL) -> Int { 0 }
    static func canDecode(_ url: URL) -> Bool { false }
    static func imageSize(_ url: URL) -> CGSize { .zero }
}
#endif

extension Native {
    /// CSV text from rows; fields with commas, quotes or newlines are quoted. Portable.
    static func csv(_ rows: [[String]]) -> String {
        rows.map { row in row.map { f in
            f.contains(",") || f.contains("\"") || f.contains("\n") ? "\"" + f.replacingOccurrences(of: "\"", with: "\"\"") + "\"" : f
        }.joined(separator: ",") }.joined(separator: "\n") + "\n"
    }
}
