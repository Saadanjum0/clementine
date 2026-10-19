import Foundation

// Engines are separate programs or native frameworks. Discovery order:
// bundled (Contents/Resources/engine/<name>), Homebrew Intel prefix (/usr/local),
// Homebrew Apple silicon prefix (/opt/homebrew), then PATH. A bundled binary is only
// used if it has a slice for the CPU we are running on, so an arm64-only bundle is
// skipped on an Intel Mac instead of failing with "Bad CPU type".
enum EngineID: String, CaseIterable {
    case ffmpeg, pandoc, soffice, cwebp, avifenc, tar, zip, textutil, osascript, pages, native

    var installHint: String {
        switch self {
        case .ffmpeg:  return "brew install ffmpeg"
        case .pandoc:  return "brew install pandoc"
        case .soffice: return "brew install --cask libreoffice"
        case .cwebp:   return "brew install webp   (or an ffmpeg built with libwebp)"
        case .avifenc: return "brew install libavif   (or an ffmpeg built with libaom)"
        case .pages:   return "install Pages from the Mac App Store (free)"
        default:       return "(built into macOS)"
        }
    }
}

enum EngineLocator {
    static var extraDirs: [String] = []   // tests / CLI override

    /// Where "Install Engines…" and Scripts/get-engines.sh put static binaries. No Homebrew needed.
    static var supportDir: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Clementine/engine", isDirectory: true)
    }

    static func path(for id: EngineID) -> String? {
        let fm = FileManager.default
        var candidates: [String] = []
        if id == .pages {
            return ["/Applications/Pages.app/Contents/MacOS/Pages", "/System/Applications/Pages.app/Contents/MacOS/Pages"].first { fm.isExecutableFile(atPath: $0) }
        }
        if id == .soffice {
            candidates += ["/Applications/LibreOffice.app/Contents/MacOS/soffice",
                           (NSHomeDirectory() as NSString).appendingPathComponent("Applications/LibreOffice.app/Contents/MacOS/soffice")]
        }
        if let res = Bundle.main.resourceURL {
            candidates.append(res.appendingPathComponent("engine/\(id.rawValue)").path)
        }
        // Engines the user installed (Homebrew, /usr/local) outrank the unsigned builds Clementine downloads for itself.
        let own = extraDirs + ["/usr/local/bin", "/opt/homebrew/bin", "/usr/local/opt/ffmpeg/bin", "/opt/homebrew/opt/ffmpeg/bin"]
        candidates += own.map { $0 + "/" + id.rawValue }
        candidates.append(supportDir.appendingPathComponent(id.rawValue).path)
        var dirs = ["/usr/bin", "/bin"]
        dirs += (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map(String.init)
        candidates += dirs.map { $0 + "/" + id.rawValue }
        return candidates.first { fm.isExecutableFile(atPath: $0) && MachO.runnable($0) }
    }

    static func require(_ id: EngineID) throws -> String {
        guard let p = path(for: id) else { throw ConvertError.engineMissing(id) }
        return p
    }
}

enum MachO {
    #if arch(arm64)
    static let hostCPU: UInt32 = 0x0100_000C
    #else
    static let hostCPU: UInt32 = 0x0100_0007
    #endif

    /// True unless the file is a Mach-O that has no slice for this CPU.
    static func runnable(_ path: String) -> Bool {
        guard let fh = FileHandle(forReadingAtPath: path),
              let data = try? fh.read(upToCount: 4096), data.count >= 8 else { return true }
        let b = [UInt8](data)
        func be(_ o: Int) -> UInt32 { UInt32(b[o]) << 24 | UInt32(b[o+1]) << 16 | UInt32(b[o+2]) << 8 | UInt32(b[o+3]) }
        func le(_ o: Int) -> UInt32 { UInt32(b[o+3]) << 24 | UInt32(b[o+2]) << 16 | UInt32(b[o+1]) << 8 | UInt32(b[o]) }
        switch be(0) {
        case 0xCAFE_BABE, 0xCAFE_BABF:
            let stride = be(0) == 0xCAFE_BABF ? 32 : 20
            for i in 0..<min(Int(be(4)), 32) where 8 + i * stride + 4 <= b.count {
                if be(8 + i * stride) == hostCPU { return true }
            }
            return false
        case 0xCFFA_EDFE, 0xCEFA_EDFE:
            return le(4) == hostCPU
        default:
            return true
        }
    }
}

enum ConvertError: LocalizedError {
    case engineMissing(EngineID)
    case unsupported(String)
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .engineMissing(let e): return "\(e.rawValue) is not installed. Run: \(e.installHint)"
        case .unsupported(let s):   return s
        case .failed(let s):        return s
        }
    }
}

/// One unit of work: an external program, or a native framework call.
enum Step {
    case run(EngineID, [String])
    case native(NativeOp)
}

struct Plan {
    var steps: [Step]
    var outputs: [URL]          // what the user gets; reported when done
    var temps: [URL] = []       // deleted afterwards
}

enum Runner {
    /// Runs every step in order. Throws on the first failure, with stderr in the message.
    static func execute(_ plan: Plan) throws {
        defer { plan.temps.forEach { try? FileManager.default.removeItem(at: $0) } }
        for step in plan.steps {
            switch step {
            case .run(let id, let args):
                let exe = try EngineLocator.require(id)
                try shell(exe, args)
            case .native(let op):
                try Native.perform(op)
            }
        }
    }

    static func shell(_ exe: String, _ args: [String]) throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: exe)
        p.arguments = args
        let err = Pipe()
        p.standardError = err
        p.standardOutput = FileHandle.nullDevice
        try p.run()
        let errData = err.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else {
            let text = String(data: errData, encoding: .utf8) ?? ""
            let tail = text.split(separator: "\n").suffix(3).joined(separator: " ")
            throw ConvertError.failed("\(URL(fileURLWithPath: exe).lastPathComponent) failed (\(p.terminationStatus)): \(tail)")
        }
    }
}
