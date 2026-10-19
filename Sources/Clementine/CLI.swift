import Foundation

/// `Clementine convert photo.heic --to jpg`, `Clementine tool compress a.mp4`,
/// `Clementine formats`, `Clementine engines`, `Clementine --selftest`.
enum CLI {
    static func run(_ args: [String]) -> Int32 {
        setvbuf(stdout, nil, _IONBF, 0)     // CI pipes: show every line before a crash
        switch args.first {
        case "--selftest":
            return SelfTest.run(quick: args.contains("--quick")) ? 0 : 1
        case "formats":
            for k in Kind.allCases where k != .folder {
                let ins = Formats.all.filter { $0.kind == k }.map { $0.id + ($0.inputOnly ? "*" : "") }
                print("\(k.rawValue): \(ins.joined(separator: " "))")
            }
            print("* input only · \(Formats.conversionCount) conversion paths · \(Tools.toolCount) tools · \(FileAction.allCases.count) actions")
            return 0
        case "engines":
            for id in EngineID.allCases where id != .native {
                print("\(id.rawValue): \(EngineLocator.path(for: id) ?? "missing → \(id.installHint)")")
            }
            return 0
        case "convert":
            guard let i = args.firstIndex(of: "--to"), i + 1 < args.count, let fmt = Formats.identify(ext: args[i + 1]) else {
                print("usage: Clementine convert <files…> --to <ext>"); return 2
            }
            let files = args[1..<i].map { URL(fileURLWithPath: $0) }
            return execute(files.map { (f: URL) -> () throws -> [Plan] in { [try Convert.plan(f, to: fmt)] } })
        case "tool":
            guard args.count >= 3, let tool = Tools.all.first(where: { $0.id == args[1] }) else {
                print("usage: Clementine tool <\(Tools.all.map(\.id).joined(separator: "|"))> <files…>"); return 2
            }
            let files = args[2...].map { URL(fileURLWithPath: $0) }
            return execute([{ try Tools.plan(tool, inputs: files) }])
        default:
            print("""
            Clementine – the zero-click file converter, for Intel and Apple silicon Macs
              Clementine                      run the menu-bar app
              Clementine convert <files…> --to <ext>
              Clementine tool <id> <files…>
              Clementine formats | engines | --selftest [--quick]
            """)
            return 0
        }
    }

    private static func execute(_ makers: [() throws -> [Plan]]) -> Int32 {
        var status: Int32 = 0
        for make in makers {
            do {
                for plan in try make() {
                    try Runner.execute(plan)
                    plan.outputs.forEach { print($0.path) }
                }
            } catch {
                print("error: \(error.localizedDescription)")
                status = 1
            }
        }
        return status
    }
}
