# Codex ASR

> [!NOTE]
> I built this for my own use, and an AI coding agent wrote all of the code and
> documentation. I've only tested it on my own machine. It's shared as-is, with
> no support or maintenance planned.

Dictation for macOS and Ubuntu GNOME that uses your existing Codex CLI login
instead of an OpenAI API key. macOS uses a native menu-bar app; Ubuntu uses an
IBus input method that works on Wayland.

Each utterance is recorded locally and uploaded to the endpoint
Codex Desktop uses for dictation:

```text
https://chatgpt.com/backend-api/transcribe
```

This endpoint is undocumented and was reverse-engineered from Codex Desktop. A
future Codex release could change or remove it.

## macOS

Requires macOS 14 or later, Apple's Command Line Tools (`xcode-select --install`),
and an existing ChatGPT login in `~/.codex/auth.json`. No Homebrew packages or
Python dependencies are needed.

```bash
bash ./setup.sh
open "$HOME/Applications/Codex ASR.app"
```

The installer builds a native Swift app and copies the Python transcription
backend into its bundle. It installs locally in `~/Applications` without sudo.

The menu opens when you launch the app. Reopen **Codex ASR** from Spotlight or
Finder to show it again, or click **ASR** in the menu bar.

From the app menu:

1. Select **Enable microphone…** and allow recording.
2. Select **Enable Accessibility…** and enable **Codex ASR** in System Settings.
3. Focus a text field and press **Ctrl+Shift+Space**: tap to start and tap again
   to stop, or hold for at least 0.4 seconds while speaking and release to stop.

The icon changes while recording and transcribing. Dictation works even when
macOS cannot identify a text field or Accessibility permission is unavailable.
Every transcript is saved to the separate **ASR clipboard**, accessible through
**Show ASR clipboard…** in the menu. Its floating window stays available across
applications and desktops. Transcripts are stored locally across app restarts
until you select **Clear all**. Select any passage to copy it, or use **Copy latest**.

When the original text field is still focused, the app also sends Cmd+V to insert
the transcript. This replaces the normal macOS clipboard contents. If the target
changes or cannot be identified, the transcript stays in the ASR clipboard and
the normal clipboard is unchanged. Switching applications keeps dictation running
and disables automatic insertion for that recording. Moving the cursor within
the same control inserts at its current position.

Use **Dictate to ASR clipboard** to record without automatic insertion; press
Ctrl+Shift+Space or select **Stop and transcribe** to finish. Accessibility
permission is needed only for automatic insertion.

Audio files are deleted after transcription or cancellation.
The app does not launch at login automatically. Quit it from its menu.

The bundled backend reads the same configuration file as the CLI, including
`language`, `auth_file`, and `append_space`. Finder-launched apps do not inherit
terminal environment variables; use `auth_file` in the config for a custom login.
Quit the app before rebuilding. Rebuilding an ad-hoc-signed app may require
granting its permissions again.

If Accessibility is enabled in System Settings but the rebuilt app still asks
for it, quit the app and clear its stale approval:

```bash
tccutil reset Accessibility local.codex-asr.macos
```

Reopen the app and enable Accessibility again. This resets only Codex ASR's
Accessibility approval; it preserves the microphone grant and other apps.

File transcription remains available from the checkout:

```bash
/usr/bin/python3 -m codex_asr.cli transcribe audio.wav
```

The CLI `doctor`, `diagnose`, and `engine` commands are Linux-only; the macOS app
handles its recording and permission checks.

If recording stops without inserting text, check the menu's top status line.
To inspect recording/transcription state changes and errors without logging
audio, transcripts, or tokens:

```bash
log show --last 5m --info --predicate 'subsystem == "local.codex-asr.macos"'
```

## Ubuntu requirements

- Ubuntu with GNOME and IBus
- The Codex CLI, logged in with ChatGPT (`codex login status` should report
  `Logged in using ChatGPT`)
- System packages: `python3-gi`, `gir1.2-ibus-1.0`, `pipewire-bin` (for
  `pw-record`) and `libnotify-bin` (for `notify-send`)

## Ubuntu install

```bash
bash ./setup.sh
```

`setup.sh` does the following:

1. Installs the engine to `~/.local/lib/codex-asr` and the `codex-asr` command to
   `~/.local/bin`.
2. Runs `codex-asr doctor`.
3. Uses sudo to copy the IBus component into `/usr/share/ibus/component`, since
   Ubuntu's IBus does not scan the user component directory.
4. Adds **Codex Dictation** to your GNOME input sources and leaves your
   existing sources in place.

Log out and back in, then select **Codex Dictation** from the input menu in
the top bar. To skip the sudo and GNOME steps, run `./install.sh`, which only
does step 1.

## Ubuntu usage

Press **Ctrl+Shift+Space** to dictate:

- **Tap** once to start recording and again to stop.
- **Hold** for at least 0.4 seconds while speaking, then release to stop.

Recording starts as soon as you press the shortcut. The transcript is inserted
at the cursor. If focus changes while you are recording, the recording is
cancelled. If focus changes while a transcript is pending, the transcript is
discarded so it cannot end up in the wrong window.

## Ubuntu troubleshooting

```bash
codex-asr doctor                  # check dependencies and the Codex login
codex-asr diagnose                # record 5 seconds and transcribe them end to end
codex-asr transcribe audio.wav    # transcribe an existing file
```

## Configuration

Configuration is optional and goes in `~/.config/codex-asr/config.ini`:

```ini
[codex]
# Language hint; omit to auto-detect.
language = en
# Add a space after each transcript.
append_space = true
# auth_file = ~/.codex/auth.json
```

The auth file is chosen in this order: the `CODEX_ASR_AUTH_FILE` environment
variable, `auth_file` in the config, `$CODEX_HOME/auth.json`, and then
`~/.codex/auth.json`.

## Privacy

On every request, the engine reads `tokens.access_token` and the account ID
from the Codex auth file. It never writes, copies, logs or refreshes the token.
If the login is expired or rejected, it tells you to run `codex login`.

Audio is saved to a temporary WAV file, uploaded to ChatGPT and deleted once
the request finishes. The macOS app saves transcript history in its local app
preferences until **Clear all** is selected in the ASR clipboard window. These
transcripts are stored unencrypted; automatic insertion and **Copy latest** also
place text on the system clipboard. Clearing ASR history does not clear the
system clipboard. The Ubuntu engine does not save transcripts. Audio is transcribed in the
cloud, so do not dictate secrets or use this anywhere cloud transcription is not
allowed.

## Development

The Python backend tests need no network or microphone. IBus engine tests run
on Linux; they are skipped on macOS.

```bash
/usr/bin/python3 -m unittest discover -v
```

Check native shortcuts and persistent clipboard behavior on macOS:

```bash
xcrun swiftc -D SHORTCUT_TESTS macos/CodexASR.swift tests/test_macos.swift -o /tmp/codex-asr-shortcut-tests
/tmp/codex-asr-shortcut-tests
```
