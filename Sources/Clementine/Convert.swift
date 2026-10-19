import Foundation

// Turns (file, target format) into a Plan. Routing, like Tangerine's "249 options":
//   images      ImageIO (jpg png tiff heic), ffmpeg for webp/avif, PDFKit for → pdf
//   audio/video ffmpeg
//   documents   textutil (built in) / pandoc / LibreOffice, PDFKit for pdf → text/images
//   office      LibreOffice (bring your own; ~400 MB)
//   archives    bsdtar (built in; reads rar, zip, tar, tgz; writes zip, tar, tgz)
//   subtitles   ffmpeg
enum Convert {
    static let imageIOWritable: Set<String> = ["jpg", "png", "tiff", "heic", "bmp"]
    static let textutilSet: Set<String> = ["txt", "html", "rtf", "docx"]
    static let ffBase = ["-y", "-hide_banner", "-loglevel", "error", "-nostdin"]

    static func plan(_ input: URL, to target: Format) throws -> Plan {
        guard let from = Formats.identify(input) else { throw ConvertError.unsupported("Unknown file type: \(input.lastPathComponent)") }
        guard Formats.targets(for: from).contains(target) else {
            throw ConvertError.unsupported("\(from.label) → \(target.label) is not a supported conversion")
        }
        let out = Naming.sibling(of: input, ext: target.id)

        switch (from.kind, target.kind) {
        case (.image, .image):
            // macOS 13 ImageIO has no WebP decoder (14 does) and AVIF decode varies:
            // when ImageIO can't open the input, ffmpeg decodes it to PNG first.
            var steps: [Step] = [], temps: [URL] = [], src = input
            if ["webp", "avif"].contains(from.id), !Native.canDecode(input) {
                src = Naming.temp(ext: "png")
                steps.append(.run(.ffmpeg, ffBase + ["-i", input.path, src.path]))
                temps.append(src)
            }
            if imageIOWritable.contains(target.id) {
                steps.append(.native(.image(src, out, ImageOpts())))
                return Plan(steps: steps, outputs: [out], temps: temps)
            }
            // webp / avif output: ImageIO can't encode them. Stage through PNG so
            // HEIC/SVG inputs (which the encoders can't read) still work. Homebrew's
            // ffmpeg bottle doesn't always carry libwebp/libaom, so cwebp / avifenc
            // (tiny, from brew) are the first choice and ffmpeg the fallback.
            let png = Naming.temp(ext: "png")
            let encode: Step
            if target.id == "webp" {
                if EngineLocator.path(for: .cwebp) != nil {
                    encode = .run(.cwebp, ["-quiet", "-q", "85", png.path, "-o", out.path])
                } else if ffmpegEncoders.contains("libwebp") {
                    encode = .run(.ffmpeg, ffBase + ["-i", png.path, "-c:v", "libwebp", "-quality", "85", out.path])
                } else { throw ConvertError.engineMissing(.cwebp) }
            } else {
                if EngineLocator.path(for: .avifenc) != nil {
                    encode = .run(.avifenc, ["-q", "60", "-s", "6", png.path, out.path])
                } else if ffmpegEncoders.contains("libaom-av1") {
                    encode = .run(.ffmpeg, ffBase + ["-i", png.path, "-frames:v", "1", "-c:v", "libaom-av1", "-still-picture", "1", "-crf", "28", "-pix_fmt", "yuv420p", out.path])
                } else { throw ConvertError.engineMissing(.avifenc) }
            }
            steps += [.native(.image(src, png, ImageOpts())), encode]
            return Plan(steps: steps, outputs: [out], temps: temps + [png])

        case (.image, .document) where target.id == "docx":
            return Plan(steps: [.native(.imageToDocx(input, out))], outputs: [out])
        case (.image, .document):
            return Plan(steps: [.native(.imagesToPDF([input], out))], outputs: [out])

        case (.subtitle, .document):
            return Plan(steps: [.native(.subtitleText(input, out))], outputs: [out])

        case (.audio, .audio), (.video, .audio), (.video, .video), (.subtitle, .subtitle):
            return Plan(steps: [.run(.ffmpeg, ffBase + ["-i", input.path] + mediaArgs(target.id, crf: nil) + [out.path])], outputs: [out])

        case (.document, _) where from.id == "pdf":
            return try pdfPlan(input, to: target, out: out)

        case (.document, .document):
            return try docPlan(input, from: from, to: target, out: out)

        case (.spreadsheet, .spreadsheet) where Set([from.id, target.id]).isSubset(of: ["csv", "tsv"]):
            return Plan(steps: [.native(.delimited(input, out, from: from.id == "csv" ? "," : "\t", to: target.id == "csv" ? "," : "\t"))], outputs: [out])

        case (.slides, .image):
            // PowerPoint → PDF (LibreOffice) → one image per slide, the same way PDFs export.
            guard EngineLocator.path(for: .soffice) != nil else { throw ConvertError.engineMissing(.soffice) }
            let pdf = Naming.temp(ext: "pdf")
            let toPDF = officePlan(input, to: Formats.byID["pdf"]!, out: pdf)
            let dir = Naming.sibling(of: input, ext: "", suffix: " slides")
            return Plan(steps: toPDF.steps + [.native(.pdfToImages(pdf, dir: dir, single: nil, ext: target.id))],
                        outputs: [dir], temps: toPDF.temps + [pdf])

        case (.spreadsheet, _), (.slides, _):
            return officePlan(input, to: target, out: out)

        case (.archive, .archive):
            // Re-pack: extract to a temp dir, then create the new archive from it.
            let dir = Naming.temp(ext: "d")
            return Plan(steps: [.native(.mkdir(dir)),
                                .run(.tar, ["-x", "-f", input.path, "-C", dir.path]),
                                .run(.tar, ["-a", "-c", "-f", out.path, "-C", dir.path, "."])],
                        outputs: [out], temps: [dir])

        case (.folder, .archive):
            return Plan(steps: [.run(.tar, ["-a", "-c", "-f", out.path, "-C", input.deletingLastPathComponent().path, "--", input.lastPathComponent])], outputs: [out])

        default:
            throw ConvertError.unsupported("\(from.label) → \(target.label) is not a supported conversion")
        }
    }

    /// Encoder names the installed ffmpeg was built with (Homebrew bottles vary).
    static let ffmpegEncoders: Set<String> = {
        guard let ff = EngineLocator.path(for: .ffmpeg) else { return [] }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: ff)
        p.arguments = ["-hide_banner", "-encoders"]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return [] }
        let text = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        p.waitUntilExit()
        // Lines look like " A....D aac              AAC (Advanced Audio Coding)"
        return Set(text.split(separator: "\n").compactMap { line -> String? in
            let parts = line.split(separator: " ", omittingEmptySubsequences: true)
            return parts.count > 1 && parts[0].count == 6 ? String(parts[1]) : nil
        })
    }()

    static let evenSize = "scale=trunc(iw/2)*2:trunc(ih/2)*2"     // libx264 + yuv420p reject odd dimensions (common for GIFs)

    /// ffmpeg flags for an output extension: codec flags plus the format's own video filter (even dimensions
    /// for H.264, the palette chain for GIF), with `vf` run first. One -vf only: ffmpeg keeps just the last.
    static func mediaArgs(_ ext: String, crf: Int?, vf: String? = nil) -> [String] {
        let own: String?
        switch ext {
        case "mp4", "mov", "mkv": own = evenSize
        case "gif": own = "fps=12,scale=480:-1:flags=lanczos,split[a][b];[a]palettegen[p];[b][p]paletteuse"
        default: own = nil
        }
        let chain = [vf, own].compactMap { $0 }
        return codecArgs(ext, crf: crf) + (chain.isEmpty ? [] : ["-vf", chain.joined(separator: ",")])
    }

    /// Codec flags only, for callers that build a -filter_complex (which cannot be combined with -vf).
    /// `crf` overrides quality for Compress.
    static func codecArgs(_ ext: String, crf: Int?) -> [String] {
        let q = String(crf ?? 23)
        switch ext {
        case "mp3":  return ["-vn", "-c:a", "libmp3lame", "-q:a", "2"]
        case "m4a":  return ["-vn", "-c:a", "aac", "-b:a", "192k"]
        case "wav":  return ["-vn", "-c:a", "pcm_s16le"]
        case "aiff": return ["-vn", "-c:a", "pcm_s16be"]
        case "flac": return ["-vn", "-c:a", "flac"]
        case "ogg":  // ffmpeg's built-in vorbis encoder is broken; Opus-in-Ogg is a standard .ogg
            if ffmpegEncoders.contains("libvorbis") { return ["-vn", "-c:a", "libvorbis", "-q:a", "5"] }
            if ffmpegEncoders.contains("libopus")   { return ["-vn", "-c:a", "libopus", "-b:a", "160k"] }
            return ["-vn", "-c:a", "flac"]
        case "opus": return ["-vn", "-c:a", "libopus", "-b:a", "128k"]
        case "mp4", "mov", "mkv":
            return ["-c:v", "libx264", "-preset", "fast", "-crf", q, "-pix_fmt", "yuv420p", "-c:a", "aac", "-b:a", "160k", "-movflags", "+faststart"]
        case "webm":
            return ["-c:v", "libvpx-vp9", "-crf", String(crf ?? 32), "-b:v", "0", "-c:a", "libopus"]
        case "gif":
            return ["-loop", "0"]
        default:     return []
        }
    }

    private static func pdfPlan(_ input: URL, to target: Format, out: URL) throws -> Plan {
        switch target.id {
        case "jpg", "png":
            if Native.pdfPageCount(input) <= 1 {
                return Plan(steps: [.native(.pdfToImages(input, dir: nil, single: out, ext: target.id))], outputs: [out])
            }
            let dir = Naming.sibling(of: input, ext: "", suffix: " pages")
            return Plan(steps: [.native(.pdfToImages(input, dir: dir, single: nil, ext: target.id))], outputs: [dir])
        case "txt":
            return Plan(steps: [.native(.pdfText(input, out))], outputs: [out])
        case "docx" where EngineLocator.path(for: .soffice) != nil:
            return officePlan(input, to: target, out: out, extra: ["--infilter=writer_pdf_import"])
        case "pptx":
            guard EngineLocator.path(for: .soffice) != nil else { throw ConvertError.engineMissing(.soffice) }
            return officePlan(input, to: target, out: out, extra: ["--infilter=impress_pdf_import"])
        case "pages":                                   // PDF → Word → Pages
            let docx = Naming.temp(ext: "docx")
            let a = try pdfPlan(input, to: Formats.byID["docx"]!, out: docx)
            let b = try pagesPlan(docx, from: Formats.byID["docx"]!, to: target, out: out)
            return Plan(steps: a.steps + b.steps, outputs: [out], temps: a.temps + b.temps + [docx])
        case "xlsx":                                    // PDF text lines → CSV rows → LibreOffice spreadsheet
            guard EngineLocator.path(for: .soffice) != nil else { throw ConvertError.engineMissing(.soffice) }
            let csv = Naming.temp(ext: "csv")
            let b = officePlan(csv, to: target, out: out)
            return Plan(steps: [.native(.pdfTable(input, csv))] + b.steps, outputs: [out], temps: [csv] + b.temps)
        default:
            // Text-only route: PDF → plain text → pandoc. Layout and images are lost.
            // Limit: LibreOffice (above) keeps layout for docx; install it for better results.
            let txt = Naming.temp(ext: "txt")
            return Plan(steps: [.native(.pdfText(input, txt)),
                                .run(.pandoc, ["-f", "markdown", "-s", txt.path, "-o", out.path])],
                        outputs: [out], temps: [txt])
        }
    }

    private static func docPlan(_ input: URL, from: Format, to target: Format, out: URL) throws -> Plan {
        if from.id == "pages" || target.id == "pages" { return try pagesPlan(input, from: from, to: target, out: out) }
        if from.id == "rtfd" {                          // only textutil reads RTFD: through HTML, then the usual route
            let html = Naming.temp(ext: "html")
            let rest = try docPlan(html, from: Formats.byID["html"]!, to: target, out: out)
            return Plan(steps: [.run(.textutil, ["-convert", "html", "-output", html.path, input.path])] + rest.steps,
                        outputs: [out], temps: [html] + rest.temps)
        }
        if target.id == "pdf" {
            if from.id == "md" || from.id == "epub" {        // LibreOffice can't open epub and renders md as plain text
                let html = Naming.temp(ext: "html")
                return Plan(steps: [.run(.pandoc, ["-s", input.path, "-o", html.path]), .native(.docToPDF(html, out))],
                            outputs: [out], temps: [html])
            }
            if EngineLocator.path(for: .soffice) != nil { return officePlan(input, to: target, out: out) }
            return Plan(steps: [.native(.docToPDF(input, out))], outputs: [out])
        }
        if textutilSet.contains(from.id), textutilSet.contains(target.id) {
            return Plan(steps: [.run(.textutil, ["-convert", target.id, "-output", out.path, input.path])], outputs: [out])
        }
        // Markdown out: plain GitHub Markdown, no metadata block or pandoc span syntax.
        let args = target.id == "md" ? ["-t", "gfm-raw_html", input.path, "-o", out.path] : ["-s", input.path, "-o", out.path]
        return Plan(steps: [.run(.pandoc, args)], outputs: [out])
    }

    /// Pages.app, driven by AppleScript: the only thing that reads or writes .pages.
    /// Exports Word or PDF directly; every other target goes through a Word file.
    static func pagesPlan(_ input: URL, from: Format, to target: Format, out: URL) throws -> Plan {
        guard EngineLocator.path(for: .pages) != nil else { throw ConvertError.engineMissing(.pages) }
        // Paths travel as argv, never spliced into the script source: a crafted file name cannot become AppleScript.
        func script(_ lines: [String], _ paths: [URL]) -> Step {
            .run(.osascript, (["on run argv"] + lines + ["end run"]).flatMap { ["-e", $0] } + ["--"] + paths.map(\.path))
        }
        if from.id == "pages" {
            let direct = target.id == "pdf" || target.id == "docx"
            let mid = direct ? out : Naming.temp(ext: "docx")
            let export = script(["tell application \"Pages\"", "set d to open (POSIX file (item 1 of argv))",
                                 "export d to (POSIX file (item 2 of argv)) as \(target.id == "pdf" ? "PDF" : "Microsoft Word")",
                                 "close d saving no", "end tell"], [input, mid])
            if direct { return Plan(steps: [export], outputs: [out]) }
            let rest = try docPlan(mid, from: Formats.byID["docx"]!, to: target, out: out)
            return Plan(steps: [export] + rest.steps, outputs: [out], temps: [mid] + rest.temps)
        }
        // → .pages: Pages opens Word, RTF and plain text; everything else becomes Word first.
        var steps: [Step] = [], temps: [URL] = [], src = input
        if !["docx", "rtf", "txt"].contains(from.id) {
            src = Naming.temp(ext: "docx")
            let pre = try docPlan(input, from: from, to: Formats.byID["docx"]!, out: src)
            steps = pre.steps
            temps = pre.temps + [src]
        }
        steps.append(script(["tell application \"Pages\"", "set d to open (POSIX file (item 1 of argv))", "save d in (POSIX file (item 2 of argv))", "close d saving no", "end tell"], [src, out]))
        return Plan(steps: steps, outputs: [out], temps: temps)
    }

    /// LibreOffice writes `<basename>.<ext>` into --outdir; we stage in a temp dir and move.
    static func officePlan(_ input: URL, to target: Format, out: URL, extra: [String] = []) -> Plan {
        let dir = Naming.temp(ext: "d")
        // LibreOffice has no "tsv" filter: ask for CSV with a tab (9) as the separator and rename the result.
        let tsv = target.id == "tsv"
        let filter = tsv ? "csv:Text - txt - csv (StarCalc):9,34,76" : target.id
        let produced = dir.appendingPathComponent(input.deletingPathExtension().lastPathComponent).appendingPathExtension(tsv ? "csv" : target.id)
        return Plan(steps: [.native(.mkdir(dir)),
                            .run(.soffice, ["--headless"] + extra + ["--convert-to", filter, "--outdir", dir.path, input.path]),
                            .native(.move(produced, out))],
                    outputs: [out], temps: [dir])
    }
}
