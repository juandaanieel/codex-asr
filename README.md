# Codex ASR

Dictation for macOS and Ubuntu GNOME using your existing Codex CLI ChatGPT login.
Audio is transcribed in the cloud; no separate OpenAI API key is needed.

Press **Ctrl+Shift+Space**: tap to start and tap again to stop, or hold for at
least 0.4 seconds while speaking and release to stop.

## Changes from the original

This fork extends [iarayad/codex-asr](https://github.com/iarayad/codex-asr),
which provides Ubuntu dictation through IBus:

- **Native macOS app:** menu-bar controls, microphone recording, global shortcut,
  permission controls, and installation in `~/Applications` without sudo.
- **Persistent ASR clipboard:** a floating transcript history available across
  apps and desktops. Open **Show ASR clipboard…**, use **Copy latest**, or
  **Clear all**. History survives restarts and ordinary clipboard changes.
- **System clipboard:** every successful macOS dictation updates the system
  clipboard. Automatic insertion requires Accessibility permission and the
  original field to remain focused; otherwise, the history window appears
  without taking focus and you can press **Cmd+V** yourself.
- **Recording without a detected field:** macOS dictation continues when focus
  changes or field detection fails. **Dictate to ASR clipboard** explicitly
  records without automatic insertion. Ubuntu retains its original focus-change
  cancellation behavior.
- **Server-error recovery:** HTTP 500/502/503/504 responses retry the same audio
  twice, after one and two seconds. Other HTTP errors are not retried.
- **Regression checks:** native shortcut, clipboard persistence, window opening,
  stale-paste, and server-retry tests; Linux-only IBus tests are skipped on macOS.

## macOS setup

Requires macOS 14+, Apple's Command Line Tools (`xcode-select --install`), and
an existing ChatGPT login in `~/.codex/auth.json` (`codex login`).

```bash
bash ./setup.sh
open "$HOME/Applications/Codex ASR.app"
```

Click **ASR** in the menu bar. Select **Enable microphone…** to allow recording
and **Enable Accessibility…** for automatic insertion. The menu's top line
shows recording, transcription, permission, and error status.

Quit before rebuilding; macOS may require granting permissions again afterward.
The app does not start at login automatically.

## Ubuntu setup

Requires GNOME with IBus, a Codex ChatGPT login, and the packages `python3-gi`,
`gir1.2-ibus-1.0`, `pipewire-bin`, and `libnotify-bin`.

```bash
bash ./setup.sh
```

The installer uses sudo to register the IBus component. Log out and back in,
then select **Codex Dictation** from the input-source menu. Use `./install.sh`
for installation without system registration. Diagnose problems with
`codex-asr doctor` or `codex-asr diagnose`.

## Configuration

Optional settings in `~/.config/codex-asr/config.ini`:

```ini
[codex]
language = en
append_space = true
# auth_file = ~/.codex/auth.json
```

Omit `language` for automatic detection. Auth-file precedence is
`CODEX_ASR_AUTH_FILE`, configured `auth_file`, `$CODEX_HOME/auth.json`, then
`~/.codex/auth.json`. Finder-launched apps should use the configuration file
for custom settings. To transcribe an existing file from the checkout:

```bash
/usr/bin/python3 -m codex_asr.cli transcribe audio.wav
```

## Privacy and limitations

Recorded audio is uploaded to `https://chatgpt.com/backend-api/transcribe`, an undocumented
endpoint that may change, and deleted after completion, failure, or cancellation.
If all retries fail, dictate again. Expired logins require `codex login`.

macOS history is stored unencrypted locally until **Clear all**; clearing history
does not clear the system clipboard. Ubuntu does not save transcripts. This is a
personal, AI-assisted project with no support guarantee.

## Development

Backend tests need no network or microphone. Native checks require macOS.

```bash
/usr/bin/python3 -m unittest discover -v
xcrun swiftc -D SHORTCUT_TESTS macos/CodexASR.swift tests/test_macos.swift -o /tmp/codex-asr-shortcut-tests
/tmp/codex-asr-shortcut-tests
```
