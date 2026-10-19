import Foundation

// The Command-drag wheel. Tangerine's tool set, reconstructed from its site, App
// Store copy and third-party studies (docs/RESEARCH.md §2): compress / shrink to %,
// crop, trim, split, join, merge, rotate, metadata view-edit-remove, mute, extract
// audio, snapshot, speed, normalize, silence, mono/stereo, collage, QR, image+audio
// → video, PDF reorder / text, archive extract. Interactive tools open an editor.
struct Tool: Hashable {
    let id: String
    let label: String
    let kinds: Set<Kind>
    var multi = false            // needs 2+ files
    var interactive = false      // opens an editor / dialog instead of running at once
    var pair: Set<Kind>? = nil   // cross-kind: exactly one file of each of these kinds
}

enum Tools {
    static let all: [Tool] = [
        Tool(id: "compress",  label: "Compress",       kinds: [.image, .video, .audio, .document]),
        Tool(id: "shrink",    label: "Shrink to %…",   kinds: [.image, .video, .audio], interactive: true),
        Tool(id: "strip",     label: "Strip Metadata", kinds: [.image, .video, .audio, .document]),
        Tool(id: "metadata",  label: "Metadata…",      kinds: [.image, .video, .audio, .document], interactive: true),
        Tool(id: "crop",      label: "Crop…",          kinds: [.image, .video], interactive: true),
        Tool(id: "trim",      label: "Trim…",          kinds: [.audio, .video], interactive: true),
        Tool(id: "rotate",    label: "Rotate & Flip…", kinds: [.image, .video, .document], interactive: true),
        Tool(id: "adjust",    label: "Edit Photo…",    kinds: [.image], interactive: true),
        Tool(id: "background", label: "Add Background…", kinds: [.image], interactive: true),
        Tool(id: "annotate",  label: "Annotate…",      kinds: [.image], interactive: true),
        Tool(id: "redact",    label: "Redact…",        kinds: [.image], interactive: true),
        Tool(id: "collage",   label: "Collage",        kinds: [.image], multi: true),
        Tool(id: "createpdf", label: "Create PDF",     kinds: [.image], multi: true),
        Tool(id: "qr",        label: "Read QR",        kinds: [.image, .document], interactive: true),
        Tool(id: "ocr",       label: "Read Text",      kinds: [.image]),
        Tool(id: "ocrpdf",    label: "Searchable PDF", kinds: [.image, .document]),
        Tool(id: "fit",       label: "Fit to Size…",   kinds: [.image, .video, .audio], interactive: true),
        Tool(id: "mute",      label: "Mute",           kinds: [.video]),
        Tool(id: "audio",     label: "Extract Audio",  kinds: [.video]),
        Tool(id: "snapshot",  label: "Snapshot",       kinds: [.video]),
        Tool(id: "frames",    label: "Frames…",        kinds: [.video], interactive: true),
        Tool(id: "speed",     label: "Speed…",         kinds: [.video], interactive: true),
        Tool(id: "split",     label: "Split…",         kinds: [.video, .document], interactive: true),
        Tool(id: "join",      label: "Join",           kinds: [.video, .audio], multi: true),
        Tool(id: "channels",  label: "Mono ⇄ Stereo",  kinds: [.audio]),
        Tool(id: "normalize", label: "Normalize",      kinds: [.audio]),
        Tool(id: "silence",   label: "Trim Silence",   kinds: [.audio]),
        Tool(id: "bleep",     label: "Bleep…",         kinds: [.audio], interactive: true),
        Tool(id: "visualizer", label: "Visualizer",    kinds: [.audio]),
        Tool(id: "slideshow", label: "Image + Audio → Video", kinds: [], pair: [.image, .audio]),
        Tool(id: "merge",     label: "Merge",          kinds: [.document], multi: true),
        Tool(id: "reorder",   label: "Reorder Pages…", kinds: [.document], interactive: true),
        Tool(id: "text",      label: "Extract Text",   kinds: [.document]),
        Tool(id: "extract",   label: "Extract",        kinds: [.archive]),
    ]

    static func tool(_ id: String) -> Tool { all.first { $0.id == id }! }

    /// Tools that apply to every file in the batch. PDF tools only apply to PDFs.
    static func available(for inputs: [Format]) -> [Tool] {
        guard !inputs.isEmpty else { return [] }
        let kinds = Set(inputs.map(\.kind))
        let gif = inputs.contains { $0.id == "gif" }             // no audio stream: hide the audio-dependent video tools
        return all.filter { tool in
            if gif, ["mute", "audio", "speed", "join", "bleep", "shrink", "fit"].contains(tool.id) { return false }
            // Join stream-copies video, so clips must share a container; audio of any codec is re-encoded.
            if tool.id == "join", kinds.count != 1 || (kinds == [.video] && Set(inputs.map(\.id)).count != 1) { return false }
            if let pair = tool.pair { return kinds == pair && inputs.count == 2 }
            return inputs.allSatisfy { f in tool.kinds.contains(f.kind) && (f.kind != .document || f.id == "pdf") }
                && (!tool.multi || inputs.count >= 2)
        }
    }

    /// Per-kind count (a tool that serves three kinds counts three times), the way Tangerine counts its "26".
    static var toolCount: Int {
        all.reduce(0) { sum, t in sum + (t.pair == nil ? t.kinds.count : 1) }
    }

    // MARK: plans for the non-interactive tools

    static func plan(_ tool: Tool, inputs: [URL]) throws -> [Plan] {
        switch tool.id {
        case "merge":
            let out = Naming.sibling(of: inputs[0], ext: "pdf", suffix: " merged")
            return [Plan(steps: [.native(.pdfMerge(inputs, out))], outputs: [out])]
        case "collage":
            let out = Naming.sibling(of: inputs[0], ext: "jpg", suffix: " collage")
            return [Plan(steps: [.native(.collage(inputs, out))], outputs: [out])]
        case "createpdf":
            let out = Naming.sibling(of: inputs[0], ext: "pdf", suffix: " combined")
            return [Plan(steps: [.native(.imagesToPDF(inputs, out))], outputs: [out])]
        case "join":
            if inputs.allSatisfy({ Formats.identify($0)?.kind == .audio }) {
                // The concat filter re-encodes, so files of any codec or sample rate join cleanly.
                let ext = Formats.identify(inputs[0])?.id ?? "mp3"
                let out = Naming.sibling(of: inputs[0], ext: ext, suffix: " joined")
                let graph = (0..<inputs.count).map { "[\($0):a]" }.joined() + "concat=n=\(inputs.count):v=0:a=1[a]"
                let args = Convert.ffBase + inputs.flatMap { ["-i", $0.path] } + ["-filter_complex", graph, "-map", "[a]"] + Convert.codecArgs(ext, crf: nil) + [out.path]
                return [Plan(steps: [.run(.ffmpeg, args)], outputs: [out])]
            }
            let out = Naming.sibling(of: inputs[0], ext: "mp4", suffix: " joined")
            let list = Naming.temp(ext: "txt")
            let text = inputs.map { "file '\($0.path.replacingOccurrences(of: "'", with: "'\\''"))'" }.joined(separator: "\n")
            let args = Convert.ffBase + ["-f", "concat", "-safe", "0", "-i", list.path] + Convert.mediaArgs("mp4", crf: nil) + [out.path]
            return [Plan(steps: [.native(.writeText(list, text)), .run(.ffmpeg, args)], outputs: [out], temps: [list])]
        case "slideshow":
            guard let img = inputs.first(where: { Formats.identify($0)?.kind == .image }),
                  let aud = inputs.first(where: { Formats.identify($0)?.kind == .audio }) else { throw ConvertError.unsupported("Needs one image and one audio file") }
            let out = Naming.sibling(of: aud, ext: "mp4")
            let png = Naming.temp(ext: "png")   // ffmpeg can't read HEIC/SVG; ImageIO can
            return [Plan(steps: [.native(.image(img, png, ImageOpts())),
                                 .run(.ffmpeg, Convert.ffBase + ["-loop", "1", "-i", png.path, "-i", aud.path, "-c:v", "libx264", "-tune", "stillimage",
                                                                 "-vf", "scale=trunc(iw/2)*2:trunc(ih/2)*2", "-pix_fmt", "yuv420p", "-c:a", "aac", "-b:a", "192k", "-shortest", out.path])],
                         outputs: [out], temps: [png])]
        default:
            return try inputs.map { try plan(tool, input: $0) }
        }
    }

    private static func plan(_ tool: Tool, input: URL) throws -> Plan {
        guard let fmt = Formats.identify(input) else { throw ConvertError.unsupported("Unknown file type") }
        // ImageIO can't encode webp/avif/svg/bmp: tools on those images write PNG.
        let ext = fmt.kind == .image && !Convert.imageIOWritable.contains(fmt.id) ? "png" : fmt.id
        func sib(_ suffix: String, _ e: String = ext) -> URL { Naming.sibling(of: input, ext: e, suffix: suffix) }
        let ff = Convert.ffBase + ["-i", input.path]

        switch (fmt.kind, tool.id) {
        // ---- images (ImageIO) ----
        case (.image, "compress"):
            // Limit: PNG has no quality knob, so it is downscaled to 75%; pngquant would be the upgrade.
            let o = ext == "png" || ext == "tiff" ? ImageOpts(scale: 0.75) : ImageOpts(quality: 0.6)
            return imagePlan(input, sib(" compressed"), o)
        case (.image, "strip"):    return imagePlan(input, sib(" clean"), ImageOpts(strip: true))
        case (.image, "ocr"):      let o = sib("", "txt");             return nativePlan(.ocr(input, o), o)
        case (.image, "ocrpdf"), (.document, "ocrpdf"):
            let o = sib(" searchable", "pdf");                         return nativePlan(.searchablePDF(input, o), o)

        // ---- video (ffmpeg) ----
        case (.video, "compress"):
            return one(ff + Convert.mediaArgs(ext, crf: 28) + [sib(" compressed").path])
        case (.video, "strip"):
            return one(ff + ["-map_metadata", "-1", "-c", "copy"] + [sib(" clean").path])
        case (.audio, "strip"):   // -vn drops embedded cover art too, which carries metadata of its own
            return one(ff + ["-map_metadata", "-1", "-vn", "-c", "copy"] + [sib(" clean").path])
        case (.video, "mute"):
            return one(ff + ["-c:v", "copy", "-an", sib(" muted").path])
        case (.video, "audio"):
            return one(ff + Convert.mediaArgs("mp3", crf: nil) + [sib("", "mp3").path])
        case (.video, "snapshot"):
            return one(ff + ["-frames:v", "1", sib(" frame", "png").path])
        case (.video, "split"):
            return try splitPlan(input, at: try duration(input) / 2)

        // ---- audio (ffmpeg) ----
        case (.audio, "compress"):
            return one(ff + audioArgs(ext, kbps: 128).args + [sib(" compressed", audioArgs(ext, kbps: 128).ext).path])
        case (.audio, "normalize"):
            let rate = Int(try probe(input, "stream=sample_rate", stream: "a:0"))   // loudnorm resamples to 192 kHz otherwise
            return one(ff + ["-af", "loudnorm,aresample=\(rate)"] + Convert.mediaArgs(ext, crf: nil) + [sib(" normalized").path])
        case (.audio, "silence"):
            // Leading silence, then trailing silence via reverse: stop_periods alone cuts at the first internal pause.
            return one(ff + ["-af", "silenceremove=start_periods=1:start_threshold=-50dB,areverse,silenceremove=start_periods=1:start_threshold=-50dB,areverse"]
                       + Convert.mediaArgs(ext, crf: nil) + [sib(" trimmed").path])
        case (.audio, "visualizer"):
            return one(ff + ["-filter_complex", "[0:a]showwaves=s=1280x720:mode=cline:colors=white[v]", "-map", "[v]", "-map", "0:a",
                             "-c:v", "libx264", "-pix_fmt", "yuv420p", "-c:a", "aac", "-b:a", "192k", sib(" visualizer", "mp4").path])
        case (.audio, "channels"):
            let stereo = try probe(input, "stream=channels", stream: "a:0") >= 2
            return one(ff + ["-ac", stereo ? "1" : "2"] + Convert.mediaArgs(ext, crf: nil) + [sib(stereo ? " mono" : " stereo").path])

        // ---- PDF (PDFKit / Quartz) ----
        case (.document, "compress"): let o = sib(" compressed"); return nativePlan(.pdfCompress(input, o), o)
        case (.document, "strip"):    let o = sib(" clean");      return nativePlan(.pdfStrip(input, o), o)
        case (.document, "text"):     let o = sib("", "txt");     return nativePlan(.pdfText(input, o), o)
        case (.document, "split"):
            let dir = Naming.sibling(of: input, ext: "", suffix: " pages")
            return Plan(steps: [.native(.pdfSplit(input, dir: dir))], outputs: [dir])

        // ---- archives (bsdtar) ----
        case (.archive, "extract"):
            let dir = Naming.sibling(of: input, ext: "")
            return Plan(steps: [.native(.mkdir(dir)), .run(.tar, ["-x", "-f", input.path, "-C", dir.path])], outputs: [dir])

        default:
            throw ConvertError.unsupported("\(tool.label) does not apply to \(fmt.label)")
        }
    }

    // MARK: plans for the editors (Editors.swift collects the parameters)

    /// Shrink to a percentage of the original size.
    static func shrinkPlan(_ input: URL, percent: Double) throws -> Plan {
        guard let fmt = Formats.identify(input) else { throw ConvertError.unsupported("Unknown file type") }
        let p = min(max(percent, 1), 100) / 100
        let tag = " \(Int(p * 100))%"
        switch fmt.kind {
        case .image:
            let ext = Convert.imageIOWritable.contains(fmt.id) ? fmt.id : "png"
            let o = Naming.sibling(of: input, ext: ext, suffix: tag)
            return imagePlan(input, o, ImageOpts(quality: fmt.id == "jpg" || fmt.id == "heic" ? max(0.3, p) : nil, scale: p.squareRoot()))
        case .video:
            let bps = try probe(input, "format=bit_rate")
            let target = max(Int(Double(bps) * p), 150_000)
            let o = Naming.sibling(of: input, ext: fmt.id, suffix: tag)
            return one(Convert.ffBase + ["-i", input.path, "-c:v", fmt.id == "webm" ? "libvpx-vp9" : "libx264", "-b:v", String(target),
                                         "-maxrate", String(target), "-bufsize", String(target * 2), "-pix_fmt", "yuv420p", "-vf", Convert.evenSize,
                                         "-c:a", fmt.id == "webm" ? "libopus" : "aac", "-b:a", "96k", o.path])
        case .audio:
            let bps = try probe(input, "format=bit_rate")
            let kbps = max(Int(Double(bps) * p / 1000), 32)
            let a = audioArgs(fmt.id, kbps: kbps)
            let o = Naming.sibling(of: input, ext: a.ext, suffix: tag)
            return one(Convert.ffBase + ["-i", input.path] + a.args + [o.path])
        default:
            throw ConvertError.unsupported("Shrink does not apply to \(fmt.label)")
        }
    }

    /// Get the file under `bytes`: images re-encode, audio and video pick a bitrate from the duration.
    static func fitPlan(_ input: URL, bytes: Int) throws -> Plan {
        guard let fmt = Formats.identify(input) else { throw ConvertError.unsupported("Unknown file type") }
        let tag = " ≤" + ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file).replacingOccurrences(of: " ", with: "")
        switch fmt.kind {
        case .image:
            let o = Naming.sibling(of: input, ext: "jpg", suffix: tag)
            return Plan(steps: [.native(.fitImage(input, o, bytes))], outputs: [o])
        case .video:
            let seconds = try duration(input)
            let target = max(Int(Double(bytes) * 8 * 0.92 / seconds) - 96_000, 150_000)
            let o = Naming.sibling(of: input, ext: fmt.id, suffix: tag)
            return one(Convert.ffBase + ["-i", input.path, "-c:v", fmt.id == "webm" ? "libvpx-vp9" : "libx264", "-b:v", String(target),
                                         "-maxrate", String(target), "-bufsize", String(target * 2), "-pix_fmt", "yuv420p", "-vf", Convert.evenSize,
                                         "-c:a", fmt.id == "webm" ? "libopus" : "aac", "-b:a", "96k", o.path])
        case .audio:
            let seconds = try duration(input)
            let kbps = min(max(Int(Double(bytes) * 8 * 0.95 / seconds / 1000), 32), 320)
            let a = audioArgs(fmt.id, kbps: kbps)
            let o = Naming.sibling(of: input, ext: a.ext, suffix: tag)
            return one(Convert.ffBase + ["-i", input.path] + a.args + [o.path])
        default:
            throw ConvertError.unsupported("Fit to Size does not apply to \(fmt.label)")
        }
    }

    /// Crop to a rectangle given in pixels of the file's own frame.
    static func cropPlan(_ input: URL, rect: CGRect) throws -> Plan {
        guard let fmt = Formats.identify(input) else { throw ConvertError.unsupported("Unknown file type") }
        let r = rect.integral
        switch fmt.kind {
        case .image:
            let o = Naming.sibling(of: input, ext: Convert.imageIOWritable.contains(fmt.id) ? fmt.id : "png", suffix: " cropped")
            return Plan(steps: [.native(.crop(input, o, r))], outputs: [o])
        case .video:
            let w = Int(r.width) / 2 * 2, h = Int(r.height) / 2 * 2
            let o = Naming.sibling(of: input, ext: fmt.id, suffix: " cropped")
            return one(Convert.ffBase + ["-i", input.path] + Convert.mediaArgs(fmt.id, crf: nil, vf: "crop=\(w):\(h):\(Int(r.minX)):\(Int(r.minY))") + [o.path])
        default:
            throw ConvertError.unsupported("Crop does not apply to \(fmt.label)")
        }
    }

    /// Crop to a fraction of the frame (0…1), so one rectangle fits a whole batch. Video lets ffmpeg evaluate
    /// it against the displayed size: iw/ih are post-rotation, while ffprobe reports the stored (unrotated) size.
    static func cropPlan(_ input: URL, fraction f: CGRect) throws -> Plan {
        guard let fmt = Formats.identify(input) else { throw ConvertError.unsupported("Unknown file type") }
        if fmt.kind == .video {
            let o = Naming.sibling(of: input, ext: fmt.id, suffix: " cropped")
            let expr = "crop=trunc(iw*\(f.width)/2)*2:trunc(ih*\(f.height)/2)*2:iw*\(f.minX):ih*\(f.minY)"
            return one(Convert.ffBase + ["-i", input.path] + Convert.mediaArgs(fmt.id, crf: nil, vf: expr) + [o.path])
        }
        let s = Native.imageSize(input)
        return try cropPlan(input, rect: CGRect(x: f.minX * s.width, y: f.minY * s.height, width: f.width * s.width, height: f.height * s.height))
    }

    /// Keep [start, end] seconds. Video is re-encoded for frame accuracy; audio is stream-copied.
    static func trimPlan(_ input: URL, start: Double, end: Double) throws -> Plan {
        guard let fmt = Formats.identify(input), end > start else { throw ConvertError.unsupported("Bad trim range") }
        let o = Naming.sibling(of: input, ext: fmt.id, suffix: " trimmed")
        let base = Convert.ffBase + ["-ss", String(start), "-i", input.path, "-t", String(end - start)]
        if fmt.kind == .audio { return one(base + ["-c", "copy", o.path]) }
        return one(base + Convert.mediaArgs(fmt.id, crf: nil) + [o.path])
    }

    /// Rotate by 90/180/270 and/or mirror. Images via ImageIO, video via ffmpeg filters, PDF via page rotation.
    static func rotatePlan(_ input: URL, degrees: Int, flipH: Bool = false, flipV: Bool = false) throws -> Plan {
        guard let fmt = Formats.identify(input) else { throw ConvertError.unsupported("Unknown file type") }
        let tag = (degrees % 360 != 0 ? " rotated" : "") + (flipH || flipV ? " flipped" : "")
        switch fmt.kind {
        case .image:
            let o = Naming.sibling(of: input, ext: Convert.imageIOWritable.contains(fmt.id) ? fmt.id : "png", suffix: tag.isEmpty ? " copy" : tag)
            return imagePlan(input, o, ImageOpts(rotate: degrees, flipH: flipH, flipV: flipV))
        case .video:
            var filters: [String] = []
            switch degrees % 360 { case 90: filters.append("transpose=1"); case 180: filters.append("transpose=1,transpose=1"); case 270: filters.append("transpose=2"); default: break }
            if flipH { filters.append("hflip") }
            if flipV { filters.append("vflip") }
            let o = Naming.sibling(of: input, ext: fmt.id, suffix: tag.isEmpty ? " copy" : tag)
            return one(Convert.ffBase + ["-i", input.path] + Convert.mediaArgs(fmt.id, crf: nil, vf: filters.isEmpty ? nil : filters.joined(separator: ",")) + [o.path])
        case .document:
            guard degrees % 360 != 0 else { throw ConvertError.unsupported("PDF pages can be rotated, not flipped") }
            let o = Naming.sibling(of: input, ext: "pdf", suffix: " rotated")
            return Plan(steps: [.native(.pdfRotateBy(input, o, degrees))], outputs: [o])
        default:
            throw ConvertError.unsupported("Rotate does not apply to \(fmt.label)")
        }
    }

    /// Two files: before and after `seconds` (stream copy). Part 2 seeks on the input side, so it starts
    /// at the keyframe before the cut and plays; an output-side -ss with -c copy drops frames until the next keyframe.
    static func splitPlan(_ input: URL, at seconds: Double) throws -> Plan {
        guard let fmt = Formats.identify(input) else { throw ConvertError.unsupported("Unknown file type") }
        let a = Naming.sibling(of: input, ext: fmt.id, suffix: " part 1"), b = Naming.sibling(of: input, ext: fmt.id, suffix: " part 2")
        let ff = Convert.ffBase + ["-i", input.path]
        return Plan(steps: [.run(.ffmpeg, ff + ["-t", String(seconds), "-c", "copy", a.path]),
                            .run(.ffmpeg, Convert.ffBase + ["-ss", String(seconds), "-i", input.path, "-c", "copy", b.path])], outputs: [a, b])
    }

    /// One PNG every `every` seconds into a "<name> frames" folder.
    static func framesPlan(_ input: URL, every: Double) -> Plan {
        let dir = Naming.sibling(of: input, ext: "", suffix: " frames")
        return Plan(steps: [.native(.mkdir(dir)),
                            .run(.ffmpeg, Convert.ffBase + ["-i", input.path, "-vf", "fps=1/\(max(every, 0.1))", dir.path.replacingOccurrences(of: "%", with: "%%") + "/frame-%03d.png"])],   // image2 reads % as a pattern
                    outputs: [dir])
    }

    /// Playback speed factor (0.25…4). Audio tempo is chained in the 0.5…2 range ffmpeg allows per stage.
    static func speedPlan(_ input: URL, factor: Double) throws -> Plan {
        guard let fmt = Formats.identify(input), factor > 0 else { throw ConvertError.unsupported("Bad speed factor") }
        var tempo: [String] = [], remaining = factor
        while remaining > 2 { tempo.append("atempo=2"); remaining /= 2 }
        while remaining < 0.5 { tempo.append("atempo=0.5"); remaining *= 2 }
        tempo.append("atempo=\(remaining)")
        let label = factor == factor.rounded() ? "\(Int(factor))x" : "\(factor)x"
        let o = Naming.sibling(of: input, ext: fmt.id, suffix: " \(label)")
        let video = "[0:v]setpts=PTS/\(factor),\(Convert.evenSize)[v]"
        let silent = (try? probe(input, "stream=channels", stream: "a:0")) == nil      // screen recordings, muted clips
        let graph = silent ? [video, "-map", "[v]", "-an"] : [video + ";[0:a]\(tempo.joined(separator: ","))[a]", "-map", "[v]", "-map", "[a]"]
        return one(Convert.ffBase + ["-i", input.path, "-filter_complex"] + graph + Convert.codecArgs(fmt.id, crf: nil) + [o.path])
    }

    /// Replace [start, end] with a 1 kHz tone.
    static func bleepPlan(_ input: URL, start: Double, end: Double) throws -> Plan {
        guard let fmt = Formats.identify(input), end > start else { throw ConvertError.unsupported("Bad bleep range") }
        let o = Naming.sibling(of: input, ext: fmt.id, suffix: " bleeped")
        // The tone is gated by an expression: with enable= it is only lowered inside the range and passes at full
        // volume outside it. normalize=0 keeps amix from halving the whole file.
        let graph = "[0:a]volume=0:enable='between(t,\(start),\(end))'[m];[1:a]volume='0.4*between(t,\(start),\(end))':eval=frame[b];[m][b]amix=inputs=2:duration=first:dropout_transition=0:normalize=0[a]"
        return one(Convert.ffBase + ["-i", input.path, "-f", "lavfi", "-i", "sine=frequency=1000", "-filter_complex", graph, "-map", "[a]"]
                   + Convert.codecArgs(fmt.id, crf: nil) + [o.path])
    }

    static func reorderPlan(_ input: URL, order: [Int]) -> Plan {
        let o = Naming.sibling(of: input, ext: "pdf", suffix: " reordered")
        return Plan(steps: [.native(.pdfReorder(input, o, order))], outputs: [o])
    }

    /// Write a copy with these metadata fields set (title / author / comment).
    static func metadataPlan(_ input: URL, fields: [String: String]) throws -> Plan {
        guard let fmt = Formats.identify(input) else { throw ConvertError.unsupported("Unknown file type") }
        switch fmt.kind {
        case .image:
            let o = Naming.sibling(of: input, ext: Convert.imageIOWritable.contains(fmt.id) ? fmt.id : "png", suffix: " tagged")
            return Plan(steps: [.native(.imageSetMeta(input, o, fields))], outputs: [o])
        case .document:
            let o = Naming.sibling(of: input, ext: "pdf", suffix: " tagged")
            return Plan(steps: [.native(.pdfSetMeta(input, o, fields))], outputs: [o])
        case .audio, .video:
            let o = Naming.sibling(of: input, ext: fmt.id, suffix: " tagged")
            var args = Convert.ffBase + ["-i", input.path]
            for (k, v) in fields { args += ["-metadata", "\(k)=\(v)"] }
            return one(args + ["-c", "copy", o.path])
        default:
            throw ConvertError.unsupported("Metadata does not apply to \(fmt.label)")
        }
    }

    // MARK: helpers

    private static func imagePlan(_ i: URL, _ o: URL, _ opts: ImageOpts) -> Plan {
        Plan(steps: [.native(.image(i, o, opts))], outputs: [o])
    }
    private static func nativePlan(_ op: NativeOp, _ out: URL) -> Plan { Plan(steps: [.native(op)], outputs: [out]) }
    private static func one(_ args: [String]) -> Plan {
        Plan(steps: [.run(.ffmpeg, args)], outputs: [URL(fileURLWithPath: args.last!)])
    }

    /// Lossy formats keep their codec at the new bitrate; lossless ones become MP3.
    static func audioArgs(_ ext: String, kbps: Int) -> (args: [String], ext: String) {
        switch ext {
        case "m4a":  return (["-vn", "-c:a", "aac", "-b:a", "\(kbps)k"], "m4a")
        case "opus": return (["-vn", "-c:a", "libopus", "-b:a", "\(kbps)k"], "opus")
        case "ogg":  return (Array(Convert.mediaArgs("ogg", crf: nil).dropLast(2)) + ["-b:a", "\(kbps)k"], "ogg")
        default:     return (["-vn", "-c:a", "libmp3lame", "-b:a", "\(kbps)k"], "mp3")
        }
    }

    /// Seconds, via ffprobe (ships with ffmpeg).
    static func duration(_ url: URL) throws -> Double {
        let d = try probe(url, "format=duration")
        guard d > 0 else { throw ConvertError.failed("Could not read duration") }
        return d
    }

    /// One numeric field from ffprobe, e.g. "format=bit_rate" or "stream=channels" (+ stream "a:0").
    static func probe(_ url: URL, _ entries: String, stream: String? = nil) throws -> Double {
        let probe = URL(fileURLWithPath: try EngineLocator.require(.ffmpeg)).deletingLastPathComponent().appendingPathComponent("ffprobe").path
        let p = Process()
        p.executableURL = URL(fileURLWithPath: probe)
        p.arguments = ["-v", "error"] + (stream.map { ["-select_streams", $0] } ?? []) + ["-show_entries", entries, "-of", "csv=p=0", url.path]
        let pipe = Pipe(); p.standardOutput = pipe; p.standardError = FileHandle.nullDevice
        try p.run(); p.waitUntilExit()
        let s = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard let d = Double(s.split(separator: "\n").first ?? ""), d > 0 else { throw ConvertError.failed("ffprobe could not read \(entries)") }
        return d
    }
}

// The Control-drag wheel: Tangerine 2.0's six file actions.
enum FileAction: String, CaseIterable {
    case airdrop, float, copy, move, copyPath, terminal

    var label: String {
        switch self {
        case .airdrop: return "AirDrop"
        case .float: return "Float"
        case .copy: return "Copy"
        case .move: return "Move…"
        case .copyPath: return "Copy Path"
        case .terminal: return "Terminal"
        }
    }
}
