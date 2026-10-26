import Foundation
import AppKit

@main
struct ShortcutTests {
    @MainActor
    static func main() {
        var shortcut = Shortcut()
        assert(shortcut.press(at: 0, recording: false, busy: false))
        assert(!shortcut.release(at: 0.1, recording: true)) // Tap keeps recording.
        assert(shortcut.press(at: 1, recording: true, busy: false)) // Second tap stops.
        assert(!shortcut.release(at: 1.5, recording: false)) // Holding stop cannot restart.

        assert(shortcut.press(at: 2, recording: false, busy: false))
        assert(!shortcut.press(at: 2.3, recording: true, busy: false)) // Ignore autorepeat.
        assert(shortcut.release(at: 2.5, recording: true)) // Hold stops on release.
        assert(!shortcut.release(at: 3, recording: false)) // Ignore unmatched release.

        assert(!shortcut.press(at: 4, recording: false, busy: true))
        assert(!shortcut.press(at: 4.5, recording: false, busy: false)) // Busy press stays consumed.
        assert(!shortcut.release(at: 5, recording: false))
        assert(shortcut.press(at: 6, recording: false, busy: false))

        shortcut = Shortcut() // Cancelling clears a held shortcut.
        assert(!shortcut.release(at: 7, recording: false))
        assert(shortcut.press(at: 8, recording: false, busy: false))
        print("Shortcut checks passed: tap, hold, repeat, busy, cancellation.")

        _ = NSApplication.shared
        let suite = "local.codex-asr.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let systemClipboardVersion = NSPasteboard.general.changeCount
        let clipboard = TranscriptClipboard(defaults: defaults)
        clipboard.append("First transcript — café")
        clipboard.append("Second transcript\nwith another line")
        let reopened = TranscriptClipboard(defaults: defaults)
        assert(reopened.transcripts == ["Second transcript\nwith another line", "First transcript — café"])
        assert(NSPasteboard.general.changeCount == systemClipboardVersion)
        reopened.loadWindow()
        assert(reopened.window?.title == "ASR clipboard")
        reopened.clear()
        assert(TranscriptClipboard(defaults: defaults).transcripts.isEmpty)
        assert(NSPasteboard.general.changeCount == systemClipboardVersion)
        print("Clipboard checks passed: history, reload, independent system clipboard, window, clear.")
    }
}
