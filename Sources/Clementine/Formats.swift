import Foundation

// Pure Foundation. The conversion graph mirrors Tangerine's published format
// table (tangerineformac.com, v2.0.1): every category, every "input only" rule.

enum Kind: String, CaseIterable {
    case image, audio, video, document, spreadsheet, slides, archive, subtitle, folder
}

struct Format: Hashable {
    let id: String          // canonical extension, also the wheel label
    let kind: Kind
    let aliases: [String]
    let inputOnly: Bool
    var label: String { id.uppercased() }
}

enum Formats {
    private static func f(_ id: String, _ kind: Kind, _ aliases: [String] = [], inputOnly: Bool = false) -> Format {
        Format(id: id, kind: kind, aliases: aliases, inputOnly: inputOnly)
    }

    static let all: [Format] = [
        f("jpg", .image, ["jpeg"]), f("png", .image), f("webp", .image), f("heic", .image, ["heif"]),
        f("tiff", .image, ["tif"]), f("avif", .image),
        f("bmp", .image), f("svg", .image, inputOnly: true),

        f("mp3", .audio), f("m4a", .audio, ["aac"]), f("wav", .audio), f("flac", .audio), f("ogg", .audio),
        f("opus", .audio), f("aiff", .audio, ["aif"]), f("wma", .audio, inputOnly: true),

        f("mp4", .video, ["m4v"]), f("mov", .video), f("mkv", .video), f("webm", .video), f("gif", .video),
        f("avi", .video, inputOnly: true), f("wmv", .video, inputOnly: true),

        f("pdf", .document), f("docx", .document, ["doc"]), f("md", .document, ["markdown"]), f("txt", .document),
        f("epub", .document), f("html", .document, ["htm"]), f("rtf", .document), f("pages", .document), f("rtfd", .document, inputOnly: true),

        f("xlsx", .spreadsheet), f("ods", .spreadsheet), f("csv", .spreadsheet), f("tsv", .spreadsheet),
        f("xls", .spreadsheet, inputOnly: true),

        f("pptx", .slides), f("ppt", .slides, inputOnly: true),

        f("zip", .archive), f("tar", .archive), f("tgz", .archive, ["gz", "tar.gz"]),
        f("rar", .archive, inputOnly: true),

        f("srt", .subtitle), f("vtt", .subtitle),

        f("folder", .folder, inputOnly: true),
    ]

    static let byID: [String: Format] = Dictionary(uniqueKeysWithValues: all.map { ($0.id, $0) })

    private static let byExt: [String: Format] = {
        var m: [String: Format] = [:]
        for fmt in all { for e in [fmt.id] + fmt.aliases { m[e] = fmt } }
        return m
    }()

    /// Format of a file on disk, by extension. Directories are `folder`.
    static func identify(_ url: URL) -> Format? {
        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue {
            if url.pathExtension.lowercased() == "rtfd" { return byID["rtfd"] }   // a package, but a document
            return url.pathExtension.isEmpty ? byID["folder"] : nil   // bundles (.app) are not folders to us
        }
        return identify(ext: url.pathExtension)
    }

    static func identify(ext: String) -> Format? {
        byExt[ext.lowercased()]
    }

    static func of(_ kind: Kind) -> [Format] { all.filter { $0.kind == kind && !$0.inputOnly } }

    /// Every format `input` can become. Order is the wheel order.
    static func targets(for input: Format) -> [Format] {
        var out: [Format]
        switch input.kind {
        case .image:       out = of(.image) + [byID["pdf"]!, byID["docx"]!]
        case .audio:       out = of(.audio)
        case .video:       out = of(.video) + [byID["mp3"]!]
        case .document:
            if input.id == "pdf" {
                out = ["docx", "pages", "pptx", "xlsx", "jpg", "png", "epub", "txt", "md", "html"].map { byID[$0]! }
            } else {
                out = of(.document)
            }
        case .spreadsheet: out = of(.spreadsheet) + [byID["pdf"]!]
        case .slides:      out = of(.slides) + ["pdf", "jpg", "png"].map { byID[$0]! }
        case .archive, .folder: out = of(.archive)
        case .subtitle:    out = of(.subtitle) + [byID["txt"]!]
        }
        return out.filter { $0 != input }
    }

    /// Targets shared by every file in a batch (Tangerine converts batches to one format).
    static func targets(for inputs: [Format]) -> [Format] {
        guard let first = inputs.first else { return [] }
        let rest = inputs.dropFirst().map { Set(targets(for: $0)) }
        return targets(for: first).filter { t in rest.allSatisfy { $0.contains(t) } }
    }

    /// Total number of (input → output) pairs, for the README and self-test.
    static var conversionCount: Int { all.reduce(0) { $0 + targets(for: $1).count } }
}

enum Naming {
    /// `photo.heic` → `photo.jpg` next to it; `photo 2.jpg` if that exists, and so on.
    static func sibling(of url: URL, ext: String, suffix: String = "") -> URL {
        let dir = url.deletingLastPathComponent()
        let base = url.deletingPathExtension().lastPathComponent + suffix
        func make(_ name: String) -> URL {
            let u = dir.appendingPathComponent(name)
            return ext.isEmpty ? u : u.appendingPathExtension(ext)
        }
        lock.lock(); defer { lock.unlock() }
        var candidate = make(base)
        var n = 2
        while FileManager.default.fileExists(atPath: candidate.path) || handedOut.contains(candidate.path) {
            candidate = make("\(base) \(n)")
            n += 1
        }
        handedOut.insert(candidate.path)   // a batch plans every output before any runs: clip.mp4 + clip.mov → clip.mp3, clip 2.mp3
        return candidate
    }

    // Limit: names stay reserved for the life of the process; a failed job leaves a gap in the numbering.
    private static var handedOut = Set<String>()
    private static let lock = NSLock()

    static func temp(ext: String) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("clementine-\(UUID().uuidString)").appendingPathExtension(ext)
    }
}
