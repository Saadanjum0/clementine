import Foundation
#if canImport(AppKit)
import AppKit
#endif

let args = Array(CommandLine.arguments.dropFirst())
if let verb = args.first, ["--selftest", "convert", "tool", "formats", "engines", "--help", "-h"].contains(verb) {
    exit(CLI.run(args))
}

#if canImport(AppKit)
let app = NSApplication.shared
app.setActivationPolicy(.accessory)

// `--uitest`: drive the real wheel through its event handlers and check what it does.
if args.first == "--uitest" { exit(UITest.run()) }

// `--render out.png`: draw all three wheels to PNG files and quit. CI smoke test
// and the quickest way to look at the UI without dragging anything.
if let i = args.firstIndex(of: "--render") {
    let out = args.indices.contains(i + 1) ? args[i + 1] : "wheel.png"
    let tmp = FileManager.default.temporaryDirectory
    let fake = ["holiday.heic", "logo.png"].map { tmp.appendingPathComponent($0) }
    fake.forEach { _ = FileManager.default.createFile(atPath: $0.path, contents: Data()) }
    var ok = true
    for mode in WheelMode.allCases {
        WheelPanel.shared.show(files: fake, mode: mode, at: NSPoint(x: 600, y: 400), interactive: true)
        let view = WheelPanel.shared.wheel
        view.layoutSubtreeIfNeeded()
        let path = out.replacingOccurrences(of: ".png", with: "-\(mode.title.lowercased()).png")
        if let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
            view.cacheDisplay(in: view.bounds, to: rep)
            if let data = rep.representation(using: .png, properties: [:]) {
                do { try data.write(to: URL(fileURLWithPath: path)); print("wrote \(path)  items=\(view.labels.count)") } catch { ok = false }
            } else { ok = false }
        } else { ok = false }
        ok = ok && !view.labels.isEmpty
    }
    WheelPanel.shared.dismiss()
    exit(ok ? 0 : 1)
}
let delegate = AppDelegate()
app.delegate = delegate

// `--show <files…> [tools|actions|claude]`: open the wheel on these files and stay up (screenshots, manual testing).
if let i = args.firstIndex(of: "--show") {
    let words: Set<String> = ["tools", "actions", "claude"]
    let files = args[(i + 1)...].filter { !words.contains($0) }.map { URL(fileURLWithPath: $0) }
    let mode: WheelMode = args.contains("tools") ? .tools : args.contains("actions") ? .actions : args.contains("claude") ? .claude : .convert
    DispatchQueue.main.async {
        WheelPanel.shared.show(files: files, mode: mode, at: NSPoint(x: 640, y: 420), interactive: true)
    }
}
// `--edit <tool id> <files…>`: open a tool's editor directly (screenshots, manual testing).
if let i = args.firstIndex(of: "--edit"), args.indices.contains(i + 2), let tool = Tools.all.first(where: { $0.id == args[i + 1] }) {
    let files = args[(i + 2)...].map { URL(fileURLWithPath: $0) }
    DispatchQueue.main.async { Editors.open(tool, files) }
}
app.run()
#else
print("The Clementine app needs macOS. The CLI works here:")
exit(CLI.run(["--help"]))
#endif
