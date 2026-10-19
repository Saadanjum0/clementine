#if canImport(AppKit)
import AppKit

// The Option-drag wheel: hand the dragged file(s) to the Claude desktop app in a new chat.
// No API key and no network code here: Clementine opens the files with Claude.app, the
// same way Finder's "Open With → Claude" does. Claude asks the user to confirm the upload,
// attaches the files to a new conversation, and the action's prompt waits on the clipboard.

enum ClaudeAction: String, CaseIterable {
    case ask, summarize, translate, chat

    var label: String {
        switch self {
        case .ask: return "Ask…"
        case .summarize: return "Summarize"
        case .translate: return "Translate…"
        case .chat: return "New Chat"
        }
    }
}

enum Claude {
    static let bundleID = "com.anthropic.claudefordesktop"
    static let maxFiles = 20                       // Claude's per-message attachment limit

    enum Outcome { case cancelled, done(String), failed(Error) }

    /// Kinds Claude reads as content; anything else (audio, video, archives, folders) can still go
    /// to a chat, but only with the user's own question.
    static func readable(_ f: Format) -> Bool {
        switch f.kind {
        case .image, .subtitle: return true
        case .document: return f.id != "pages"
        case .spreadsheet, .slides: return true
        default: return false
        }
    }

    static func actions(for formats: [Format]) -> [ClaudeAction] {
        guard !formats.isEmpty else { return [] }
        return formats.allSatisfy(readable) ? ClaudeAction.allCases : [.ask, .chat]
    }

    static let languages = ["English", "Spanish", "French", "German", "Italian", "Portuguese", "Dutch", "Arabic", "Urdu", "Hindi", "Chinese", "Japanese", "Korean", "Turkish", "Other…"]

    /// Where Claude.app is, wherever it was installed (Launch Services, by bundle id, so
    /// "Claude Science" or a renamed copy are not confused with it). Nil when not installed.
    static var appURL: URL? { NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) }

    /// The text for an action, asking the user first where it needs input. Nil = cancelled.
    static func prompt(for action: ClaudeAction, _ urls: [URL]) -> String?? {
        let name = urls.count == 1 ? urls[0].lastPathComponent : "\(urls.count) files"
        switch action {
        case .chat:
            return .some(nil)
        case .ask:
            guard let p = PromptDialog.ask("Ask Claude about \(name)", placeholder: "What do you want to know or do with this file?") else { return nil }
            return p
        case .summarize:
            return "Summarize this file. Start with a two-sentence overview, then the key points as a short bulleted list. Keep the file's own language."
        case .translate:
            let remembered = UserDefaults.standard.string(forKey: "translateLang") ?? "English"
            let opts = languages.sorted { a, _ in a == remembered }
            guard let i = Editors.choose("Translate \(name)", "Into which language?", options: opts, button: "Translate") else { return nil }
            var lang = opts[i]
            if lang == "Other…" {
                guard let other = PromptDialog.ask("Translate \(name) to which language?", placeholder: "Swahili", singleLine: true) else { return nil }
                lang = other
            }
            UserDefaults.standard.set(lang, forKey: "translateLang")
            return "Translate the full content of this file into \(lang). Preserve structure, headings and formatting. Output only the translation."
        }
    }

    /// Opens the files in a new Claude chat. Dialogs run first on the main thread; `done` reports back.
    static func perform(_ action: ClaudeAction, _ urls: [URL], progress: @escaping (String) -> Void, done: @escaping (Outcome) -> Void) {
        // Files can move between the drag and the drop; Claude would get nothing for them.
        let files = urls.filter { FileManager.default.fileExists(atPath: $0.path) }
        guard !files.isEmpty else { done(.failed(ConvertError.failed("The file was moved or deleted before it reached Claude."))); return }
        guard files.count <= maxFiles else {
            done(.failed(ConvertError.failed("Claude takes up to \(maxFiles) files per message; this drop had \(files.count). Drop them in smaller batches.")))
            return
        }
        guard let prompt = prompt(for: action, files) else { done(.cancelled); return }
        guard let app = appURL else { notInstalled(files, prompt: prompt, done: done); return }

        if let prompt { copy(prompt) }
        progress("Opening Claude…")
        let config = NSWorkspace.OpenConfiguration()
        config.activates = true                     // also un-hides / un-minimizes it; Claude restores its window itself
        config.promptsUserIfNeeded = true
        NSWorkspace.shared.open(files, withApplicationAt: app, configuration: config) { _, error in
            DispatchQueue.main.async {
                if let error {
                    done(.failed(ConvertError.failed("Couldn't open Claude: \(error.localizedDescription)")))
                    return
                }
                // Claude shows its own "Open … in Claude?" upload confirmation; then the files sit in a new chat.
                done(.done(prompt == nil ? "In Claude, click Open to attach the file" : "In Claude, click Open, then ⌘V to paste the prompt"))
            }
        }
    }

    /// No Claude.app: offer the download, or claude.ai in the browser with the files shown in Finder to drag in.
    private static func notInstalled(_ files: [URL], prompt: String?, done: @escaping (Outcome) -> Void) {
        let alert = NSAlert()
        alert.messageText = "The Claude app isn't installed"
        alert.informativeText = "The Claude wheel opens files in the Claude desktop app. Install it, or use claude.ai in your browser: Clementine shows the file in Finder so you can drag it into the chat" + (prompt == nil ? "." : ", and copies the prompt.")
        alert.addButton(withTitle: "Download Claude")
        alert.addButton(withTitle: "Use claude.ai")
        alert.addButton(withTitle: "Cancel")
        WheelPanel.shared.orderOut(nil)              // the wheel floats above modal alerts
        NSApp.activate(ignoringOtherApps: true)
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            NSWorkspace.shared.open(URL(string: "https://claude.ai/download")!)
            done(.cancelled)
        case .alertSecondButtonReturn:
            if let prompt { copy(prompt) }
            NSWorkspace.shared.open(URL(string: "https://claude.ai/new")!)
            NSWorkspace.shared.activateFileViewerSelecting(files)
            done(.done(prompt == nil ? "Drag the file into claude.ai" : "Drag the file into claude.ai, then ⌘V the prompt"))
        default:
            done(.cancelled)
        }
    }

    private static func copy(_ s: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(s, forType: .string)
    }
}

enum PromptDialog {
    static func ask(_ title: String, placeholder: String, singleLine: Bool = false) -> String? {
        let alert = NSAlert()
        alert.messageText = title
        alert.addButton(withTitle: "Send")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        if singleLine {
            let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 360, height: 24))
            field.placeholderString = placeholder
            alert.accessoryView = field
            alert.window.initialFirstResponder = field
            guard alert.runModal() == .alertFirstButtonReturn else { return nil }
            let s = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            return s.isEmpty ? placeholder : s
        }
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 420, height: 100))
        let text = NSTextView(frame: scroll.bounds)
        text.font = NSFont.systemFont(ofSize: 13)
        text.isRichText = false
        text.autoresizingMask = [.width]
        scroll.documentView = text
        scroll.borderType = .bezelBorder
        scroll.hasVerticalScroller = true
        alert.informativeText = placeholder
        alert.accessoryView = scroll
        alert.window.initialFirstResponder = text
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        let s = text.string.trimmingCharacters(in: .whitespacesAndNewlines)
        return s.isEmpty ? nil : s
    }
}

#endif
