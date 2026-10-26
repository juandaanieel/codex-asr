import AppKit
import ApplicationServices
import AVFoundation
import Carbon.HIToolbox
import OSLog

// A tap toggles recording; holding the start shortcut stops on release.
struct Shortcut {
    private var isDown = false
    private var startedAt: TimeInterval?

    mutating func press(at time: TimeInterval, recording: Bool, busy: Bool) -> Bool {
        guard !isDown else { return false }
        isDown = true
        startedAt = !recording && !busy ? time : nil
        return !busy
    }

    mutating func release(at time: TimeInterval, recording: Bool) -> Bool {
        defer {
            isDown = false
            startedAt = nil
        }
        guard isDown, recording, let start = startedAt else { return false }
        return time - start >= 0.4
    }
}

// Compare both the frontmost application and its focused control before pasting.
struct FocusTarget {
    let pid: pid_t
    let element: AXUIElement

    static func capture() -> FocusTarget? {
        guard let application = NSWorkspace.shared.frontmostApplication,
              application.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return nil }
        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(
            AXUIElementCreateApplication(application.processIdentifier),
            kAXFocusedUIElementAttribute as CFString, &value
        )
        guard result == .success, let value else { return nil }
        let element = value as! AXUIElement
        var role: CFTypeRef?
        AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &role)
        var selectionIsSettable = DarwinBoolean(false)
        AXUIElementIsAttributeSettable(element, kAXSelectedTextAttribute as CFString, &selectionIsSettable)
        let textRoles = [kAXTextFieldRole, kAXTextAreaRole, kAXComboBoxRole]
        guard textRoles.contains(role as? String ?? "") || selectionIsSettable.boolValue else { return nil }
        return FocusTarget(pid: application.processIdentifier, element: element)
    }

    var isCurrent: Bool {
        guard let current = Self.capture() else { return false }
        return current.pid == pid && CFEqual(current.element, element)
    }
}

@MainActor
final class TranscriptClipboard: NSWindowController {
    private let defaults: UserDefaults
    private static let storageKey = "transcriptHistory"
    private(set) var transcripts: [String]
    private let textView = NSTextView()
    private let copyButton = NSButton(title: "Copy latest", target: nil, action: #selector(copyLatest))
    private let clearButton = NSButton(title: "Clear all", target: nil, action: #selector(clear))

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        transcripts = defaults.stringArray(forKey: Self.storageKey) ?? []
        super.init(window: nil)
        createWindow()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func createWindow() {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 400),
            styleMask: [.titled, .closable, .resizable, .utilityWindow], backing: .buffered, defer: false
        )
        panel.title = "ASR clipboard"
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.minSize = NSSize(width: 380, height: 240)
        panel.isReleasedWhenClosed = false
        panel.center()
        window = panel

        let content = panel.contentView!
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        textView.isEditable = false
        textView.isSelectable = true
        textView.isVerticallyResizable = true
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.textContainerInset = NSSize(width: 10, height: 10)
        textView.font = .systemFont(ofSize: 14)
        scroll.documentView = textView

        let caption = NSTextField(wrappingLabelWithString: "Newest first. Saved on this Mac until cleared. Select text to copy any passage.")
        caption.textColor = .secondaryLabelColor
        copyButton.target = self
        clearButton.target = self
        let buttons = NSStackView(views: [copyButton, clearButton])
        buttons.spacing = 8
        for view in [caption, scroll, buttons] {
            view.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(view)
        }
        NSLayoutConstraint.activate([
            caption.topAnchor.constraint(equalTo: content.topAnchor, constant: 12),
            caption.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 12),
            caption.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -12),
            scroll.topAnchor.constraint(equalTo: caption.bottomAnchor, constant: 10),
            scroll.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 12),
            scroll.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -12),
            scroll.bottomAnchor.constraint(equalTo: buttons.topAnchor, constant: -10),
            buttons.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 12),
            buttons.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -12)
        ])
        refresh()
    }

    func append(_ text: String, copyingTo pasteboard: NSPasteboard) {
        transcripts.insert(text, at: 0)
        defaults.set(transcripts, forKey: Self.storageKey)
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        refresh()
    }

    @objc private func copyLatest() {
        guard let text = transcripts.first else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    @objc func clear() {
        transcripts.removeAll()
        defaults.removeObject(forKey: Self.storageKey)
        refresh()
    }

    private func refresh() {
        textView.string = transcripts.joined(separator: "\n\n────────────────────\n\n")
        copyButton.isEnabled = !transcripts.isEmpty
        clearButton.isEnabled = !transcripts.isEmpty
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let logger = Logger(subsystem: "local.codex-asr.macos", category: "dictation")
    private var statusItem: NSStatusItem!
    private let status = NSMenuItem(title: "Ready — Ctrl+Shift+Space", action: nil, keyEquivalent: "")
    private let recordItem = NSMenuItem(title: "Start dictation", action: #selector(toggle), keyEquivalent: "")
    private let cancelItem = NSMenuItem(title: "Cancel dictation", action: #selector(cancel), keyEquivalent: "")
    private var recorder: AVAudioRecorder?
    private var audioURL: URL?
    private var target: FocusTarget?
    private var process: Process?
    private var generation = 0
    private var shortcut = Shortcut()
    private var hotKey: EventHotKeyRef?
    private var eventHandler: EventHandlerRef?
    private var focusObserver: NSObjectProtocol?
    private let clipboard = TranscriptClipboard()

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.image = NSImage(systemSymbolName: "mic", accessibilityDescription: "Codex ASR")
        statusItem.button?.title = "ASR"
        statusItem.button?.toolTip = "Codex ASR — Ctrl+Shift+Space"
        let menu = NSMenu()
        menu.autoenablesItems = false
        status.isEnabled = false
        menu.addItem(status)
        menu.addItem(.separator())
        for item in [recordItem, cancelItem] {
            item.target = self
            menu.addItem(item)
        }
        cancelItem.isEnabled = false
        menu.addItem(.separator())
        for (title, action) in [
            ("Show ASR clipboard…", #selector(showClipboard)),
            ("Dictate to ASR clipboard", #selector(dictateToClipboard)),
            ("Enable microphone…", #selector(enableMicrophone)),
            ("Enable Accessibility…", #selector(enableAccessibility)),
            ("Quit Codex ASR", #selector(quit))
        ] {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = self
            menu.addItem(item)
        }
        statusItem.menu = menu
        focusObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.target != nil else { return }
                self.target = nil
                self.setStatus("Target changed — transcript will go to ASR clipboard", symbol: "doc.on.clipboard")
            }
        }
        do {
            try registerShortcut()
        } catch {
            fail(error.localizedDescription)
        }
        if AVCaptureDevice.authorizationStatus(for: .audio) != .authorized {
            setStatus("Enable microphone from this menu", symbol: "mic.slash")
        } else {
            setStatus("Ready — Ctrl+Shift+Space", symbol: "mic")
        }
        if CommandLine.arguments.contains("--smoke-test") {
            print("Menu initialized; shortcut registered: \(hotKey != nil)")
            print("Microphone permission: \(AVCaptureDevice.authorizationStatus(for: .audio).rawValue)")
            print("Accessibility permission: \(AXIsProcessTrusted())")
            NSApp.terminate(nil)
        } else {
            DispatchQueue.main.async { self.showMenu() }
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showMenu()
        return false
    }

    private func showMenu() {
        NSApp.activate(ignoringOtherApps: true)
        statusItem.menu?.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
    }

    private func registerShortcut() throws {
        var events = [
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed)),
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyReleased))
        ]
        let context = Unmanaged.passUnretained(self).toOpaque()
        let installed = InstallEventHandler(GetApplicationEventTarget(), { _, event, context in
            guard let event, let context else { return OSStatus(eventNotHandledErr) }
            MainActor.assumeIsolated {
                let delegate = Unmanaged<AppDelegate>.fromOpaque(context).takeUnretainedValue()
                delegate.handleShortcut(pressed: GetEventKind(event) == UInt32(kEventHotKeyPressed))
            }
            return noErr
        }, events.count, &events, context, &eventHandler)
        guard installed == noErr else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(installed))
        }
        let registered = RegisterEventHotKey(
            UInt32(kVK_Space), UInt32(controlKey | shiftKey),
            EventHotKeyID(signature: 0x43415352, id: 1),
            GetApplicationEventTarget(), 0, &hotKey
        )
        guard registered == noErr else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(registered), userInfo: [
                NSLocalizedDescriptionKey: "Cannot register Ctrl+Shift+Space (status \(registered)). Check whether another app uses it."
            ])
        }
    }

    private func handleShortcut(pressed: Bool) {
        logger.info("Shortcut pressed=\(pressed) recording=\(self.recorder != nil) transcribing=\(self.process != nil)")
        let time = ProcessInfo.processInfo.systemUptime
        let shouldToggle = pressed
            ? shortcut.press(at: time, recording: recorder != nil, busy: process != nil)
            : shortcut.release(at: time, recording: recorder != nil)
        if shouldToggle { toggle() }
    }

    @objc private func enableMicrophone() {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            setStatus("Microphone enabled — ready", symbol: "mic")
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { [weak self] granted in
                DispatchQueue.main.async {
                    self?.setStatus(granted ? "Microphone enabled — ready" : "Microphone permission denied", symbol: "mic")
                }
            }
        default:
            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")!)
        }
    }

    @objc private func enableAccessibility() {
        AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary)
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }

    @objc private func toggle() {
        guard process == nil else { return }
        if recorder != nil {
            stopAndTranscribe()
            return
        }
        startRecording(toClipboard: false)
    }

    @objc private func showClipboard() {
        clipboard.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func dictateToClipboard() {
        guard recorder == nil, process == nil else { return }
        startRecording(toClipboard: true)
    }

    private func startRecording(toClipboard: Bool) {
        guard AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else {
            enableMicrophone()
            setStatus("Enable microphone, then start again", symbol: "mic.slash")
            return
        }
        let focused = !toClipboard && AXIsProcessTrusted() ? FocusTarget.capture() : nil
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("codex-asr-\(UUID().uuidString).wav")
        do {
            let recording = try AVAudioRecorder(url: url, settings: [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: 24000.0,
                AVNumberOfChannelsKey: 1,
                AVLinearPCMBitDepthKey: 16,
                AVLinearPCMIsFloatKey: false,
                AVLinearPCMIsBigEndianKey: false
            ])
            guard recording.record() else {
                throw NSError(domain: "CodexASR", code: 1, userInfo: [NSLocalizedDescriptionKey: "Could not start the microphone."])
            }
            recorder = recording
            audioURL = url
            target = focused
            setStatus(focused == nil ? "Listening to ASR clipboard — tap again to stop" : "Listening — tap again or release hold", symbol: "mic.fill")
            recordItem.title = "Stop and transcribe"
            cancelItem.isEnabled = true
        } catch {
            try? FileManager.default.removeItem(at: url)
            fail(error.localizedDescription)
        }
    }

    private func stopAndTranscribe() {
        guard let recording = recorder, let url = audioURL else { return }
        recording.stop()
        recorder = nil
        if target?.isCurrent != true { target = nil }
        let job = Process()
        job.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        job.arguments = ["-c", """
        import sys
        from pathlib import Path
        from codex_asr.config import load_config
        from codex_asr.transcribe import transcribe

        try:
            config = load_config()
            text = transcribe(Path(sys.argv[1]), config)
        except (OSError, RuntimeError) as error:
            print(error, file=sys.stderr)
            sys.exit(1)
        sys.stdout.write(text + (" " if text and config.append_space else ""))
        """, url.path]
        var environment = ProcessInfo.processInfo.environment
        environment["PYTHONPATH"] = Bundle.main.resourceURL!.path
        job.environment = environment
        let output = Pipe()
        let errors = Pipe()
        job.standardOutput = output
        job.standardError = errors
        do {
            try job.run()
        } catch {
            fail(error.localizedDescription)
            return
        }
        process = job
        let requestGeneration = generation
        recordItem.isEnabled = false
        setStatus("Transcribing…", symbol: "ellipsis.bubble")
        Task {
            let result = await Task.detached { () -> Result<String, Error> in
                defer { try? FileManager.default.removeItem(at: url) }
                let data = output.fileHandleForReading.readDataToEndOfFile()
                let errorData = errors.fileHandleForReading.readDataToEndOfFile()
                job.waitUntilExit()
                guard job.terminationStatus == 0 else {
                    let message = String(decoding: errorData, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
                    return .failure(NSError(domain: "CodexASR", code: Int(job.terminationStatus), userInfo: [NSLocalizedDescriptionKey: message]))
                }
                return .success(String(decoding: data, as: UTF8.self))
            }.value
            guard requestGeneration == generation else { return }
            process = nil
            audioURL = nil
            let focused = target
            target = nil
            recordItem.title = "Start dictation"
            recordItem.isEnabled = true
            cancelItem.isEnabled = false
            switch result {
            case .success(let text):
                guard !text.isEmpty else {
                    setStatus("No speech detected", symbol: "mic")
                    return
                }
                clipboard.append(text, copyingTo: .general)
                guard AXIsProcessTrusted() else {
                    setStatus("Copied — enable Accessibility for automatic paste", symbol: "doc.on.clipboard")
                    clipboard.window?.orderFrontRegardless()
                    return
                }
                guard focused?.isCurrent == true else {
                    setStatus("Copied — press Cmd+V to paste", symbol: "doc.on.clipboard")
                    clipboard.window?.orderFrontRegardless()
                    return
                }
                let source = CGEventSource(stateID: .privateState)
                let down = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_ANSI_V), keyDown: true)!
                let up = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_ANSI_V), keyDown: false)!
                down.flags = .maskCommand
                up.flags = .maskCommand
                down.post(tap: .cghidEventTap)
                up.post(tap: .cghidEventTap)
                setStatus("Paste sent — saved to ASR clipboard", symbol: "mic")
            case .failure(let error):
                fail(error.localizedDescription)
            }
        }
    }

    @objc private func cancel() {
        generation += 1
        recorder?.stop()
        recorder = nil
        if let url = audioURL { try? FileManager.default.removeItem(at: url) }
        audioURL = nil
        if let process, process.isRunning { process.terminate() }
        process = nil
        target = nil
        shortcut = Shortcut()
        recordItem.title = "Start dictation"
        recordItem.isEnabled = true
        cancelItem.isEnabled = false
        setStatus("Ready — Ctrl+Shift+Space", symbol: "mic")
    }

    private func setStatus(_ text: String, symbol: String) {
        logger.info("Status: \(text, privacy: .public)")
        status.title = text
        statusItem.button?.image = NSImage(systemSymbolName: symbol, accessibilityDescription: text)
        statusItem.button?.toolTip = "Codex ASR — \(text)"
    }

    private func fail(_ message: String) {
        logger.error("Dictation failed: \(message, privacy: .public)")
        cancel()
        setStatus("Dictation failed — try again", symbol: "exclamationmark.bubble")
        let alert = NSAlert()
        alert.messageText = "Codex ASR"
        alert.informativeText = message
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    @objc private func quit() { NSApp.terminate(nil) }

    func applicationWillTerminate(_ notification: Notification) {
        cancel()
        if let hotKey { UnregisterEventHotKey(hotKey) }
        if let eventHandler { RemoveEventHandler(eventHandler) }
        if let focusObserver { NSWorkspace.shared.notificationCenter.removeObserver(focusObserver) }
    }
}

#if !SHORTCUT_TESTS
@main
struct CodexASR {
    static func main() {
        let application = NSApplication.shared
        let delegate = AppDelegate()
        application.delegate = delegate
        application.setActivationPolicy(.accessory)
        application.run()
        withExtendedLifetime(delegate) {}
    }
}
#endif
