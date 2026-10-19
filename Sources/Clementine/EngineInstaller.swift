#if canImport(AppKit)
import AppKit

/// "Install Engines…": fetch static binaries into Application Support, no Homebrew.
/// Same sources as Scripts/get-engines.sh. Runs in the background, reports in an alert.
enum EngineInstaller {
    static func run() {
        let dir = EngineLocator.supportDir
        let hud = JobHUD.show("Downloading engines…")
        DispatchQueue.global(qos: .userInitiated).async {
            var lines: [String] = []
            do {
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                #if arch(x86_64)
                let arch = "x86_64", warch = "x86-64", mr = "amd64"
                #else
                let arch = "arm64", warch = "arm64", mr = "arm64"
                #endif
                DispatchQueue.main.async { hud.update("ffmpeg + ffprobe (static)…") }
                for tool in ["ffmpeg", "ffprobe"] {
                    var r = install(tool, from: "https://ffmpeg.martin-riedl.de/redirect/latest/macos/\(mr)/release/\(tool).zip", into: dir)
                    if !r.hasPrefix("\(tool) ✓"), arch == "x86_64" {
                        r = install(tool, from: tool == "ffmpeg" ? "https://evermeet.cx/ffmpeg/getrelease/zip" : "https://evermeet.cx/ffmpeg/getrelease/ffprobe/zip", into: dir)
                    }
                    lines.append(r)
                }
                DispatchQueue.main.async { hud.update("pandoc (GitHub release)…") }
                if let asset = pandocAsset(arch: arch) { lines.append(install("pandoc", from: asset, into: dir)) }
                else { lines.append("pandoc: could not read the GitHub release list") }
                DispatchQueue.main.async { hud.update("cwebp (Google libwebp)…") }
                var webp = "cwebp: no download found"
                for v in ["1.6.0", "1.5.0", "1.4.0"] {
                    let r = install("cwebp", from: "https://storage.googleapis.com/downloads.webmproject.org/releases/webp/libwebp-\(v)-mac-\(warch).tar.gz", into: dir)
                    if r.hasPrefix("cwebp ✓") { webp = r; break }
                }
                lines.append(webp)
            } catch { lines.append(error.localizedDescription) }
            DispatchQueue.main.async {
                hud.close()
                Editors.alert("Engines", lines.joined(separator: "\n") + "\n\nFolder: \(dir.path)")
            }
        }
    }

    private static func pandocAsset(arch: String) -> String? {
        guard let data = try? Data(contentsOf: URL(string: "https://api.github.com/repos/jgm/pandoc/releases/latest")!),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let assets = json["assets"] as? [[String: Any]] else { return nil }
        return assets.compactMap { $0["browser_download_url"] as? String }.first { $0.hasSuffix("-\(arch)-macOS.zip") }
    }

    /// Download an archive, unpack it in a temp dir, copy the one binary named `name` into `dir`.
    private static func install(_ name: String, from url: String, into dir: URL) -> String {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("clementine-engine-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tmp) }
        do {
            try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
            let data = try Data(contentsOf: URL(string: url)!)
            let archive = tmp.appendingPathComponent(url.hasSuffix(".tar.gz") ? "a.tgz" : "a.zip")
            try data.write(to: archive)
            if archive.pathExtension == "tgz" { try Runner.shell("/usr/bin/tar", ["-xzf", archive.path, "-C", tmp.path]) }
            else { try Runner.shell("/usr/bin/ditto", ["-x", "-k", archive.path, tmp.path]) }
            guard let found = FileManager.default.enumerator(at: tmp, includingPropertiesForKeys: nil)?
                    .compactMap({ $0 as? URL }).first(where: { $0.lastPathComponent == name && !$0.hasDirectoryPath }) else {
                return "\(name): archive had no \(name) binary"
            }
            guard MachO.runnable(found.path) else { return "\(name): the download is not a binary for this Mac's CPU" }
            let dest = dir.appendingPathComponent(name)
            try? FileManager.default.removeItem(at: dest)
            try FileManager.default.copyItem(at: found, to: dest)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dest.path)
            try? Runner.shell("/usr/bin/xattr", ["-d", "com.apple.quarantine", dest.path])
            return "\(name) ✓ \(ByteCountFormatter.string(fromByteCount: Int64(data.count), countStyle: .file))"
        } catch {
            return "\(name): \(error.localizedDescription)"
        }
    }
}
#endif
