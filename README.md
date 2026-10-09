# deepgram-dictation

**Hold a key, speak, let go. Your words appear wherever your cursor is.**
**Press another key to transcribe a whole meeting, in person or on Zoom / Google Meet.**

A small, open-source dictation and meeting-transcription tool for macOS. It works much like Wispr Flow, but
uses your own [Deepgram](https://deepgram.com) API key. It runs inside
[Hammerspoon](https://www.hammerspoon.org), so there's no background server and no Electron
app, and no account other than your Deepgram one.

> Unofficial project. Not affiliated with Deepgram or Wispr.

## Features

- **Hold-to-talk:** hold **Fn** (or a right-side modifier key), speak, release.
- **Meeting transcription:** records in-person meetings from the mic, or online meetings
  (Zoom, Google Meet, Teams, Slack…) from the mic *and* computer audio, then gives you a
  speaker-labelled transcript on your clipboard, ready to paste into Notion, Google Docs or
  anywhere else. No bot joins your call.
- **Pastes into any app:** your clipboard is restored afterwards.
- **Deepgram Nova-3** with punctuation and smart formatting (numbers, emails, dates).
- **Custom vocabulary:** names and jargon are sent as Deepgram
  [keyterms](https://developers.deepgram.com/docs/keyterm) so they're spelled correctly.
- **Text replacements and snippets:** `btw` → `by the way`, `my email address` → `you@example.com`.
- **Wispr Flow import:** bring your existing Wispr dictionary over with one command.
- **Your key stays in the macOS Keychain**, never in a plain-text file.
- Menu bar toggle to switch dictation on and off.

## Requirements

- macOS (Apple Silicon or Intel). Meeting transcription needs macOS 14.2 or later.
- [Homebrew](https://brew.sh)
- Xcode Command Line Tools (`xcode-select --install`) for meeting transcription. Dictation
  works without them.
- A Deepgram API key: sign up at [console.deepgram.com](https://console.deepgram.com). New
  accounts get free credit.

## Install

```sh
git clone https://github.com/anshulforyou/deepgram-dictation.git
cd deepgram-dictation
./install.sh
```

The installer:

1. installs Hammerspoon and `sox` (for recording audio) via Homebrew, if they're missing,
2. copies the module into `~/.hammerspoon/deepgram_dictation/`,
3. adds a short block to `~/.hammerspoon/init.lua` (your existing config is kept),
4. builds the small `DeepgramRecorder.app` used for meetings into
   `~/Library/Application Support/deepgram-dictation/`,
5. creates `~/.hammerspoon/deepgram-dictionary.json` from the example, if you don't have one,
6. asks for your Deepgram API key (input is hidden) and saves it to the Keychain.

Then finish the macOS setup:

1. **System Settings → Privacy & Security → Accessibility:** turn on **Hammerspoon**.
   If it was already on, quit and reopen Hammerspoon.
2. **System Settings → Keyboard → "Press 🌐 key to":** set to **Do Nothing**, so Fn doesn't
   open the emoji picker or Apple dictation.
3. Hold **Fn**, say something, release. Allow microphone access when macOS asks.
4. Press **⌃⌥⌘M** to try a meeting recording. The first time, allow **DeepgramRecorder** to use
   the **Microphone** and **System Audio Recording**.

Re-running `./install.sh` upgrades the module and leaves your settings, dictionary and key alone.

## Usage

| Action | What happens |
| --- | --- |
| Hold the hotkey | A "🎙 Listening…" badge appears and recording starts |
| Release | Audio is sent to Deepgram ("⏳ Transcribing…"), then the text is pasted |
| Tap for less than 0.3 s | Ignored, so accidental taps don't trigger anything |
| Press another key while holding (e.g. Fn+F5) | Dictation is cancelled |
| 🎙 menu bar icon | Enable/disable dictation, start/stop meetings, reload config |

## Meeting transcription

Start a recording from the 🎙 menu bar icon, or press **⌃⌥⌘M** to start and stop:

| Mode | Records | Use for |
| --- | --- | --- |
| **Online meeting** (hotkey default) | Microphone + computer audio | Zoom, Google Meet, Teams, Slack huddles, webinars |
| **In-person meeting** | Microphone only | Meetings in a room, interviews, lectures |

While recording, the menu bar shows 🔴 and the elapsed time. When you stop:

1. each track is sent to Deepgram Nova-3 with speaker diarization,
2. the tracks are merged into one timeline. In online meetings your mic is labelled **Me** and
   remote people **Speaker 1**, **Speaker 2**, …,
3. the transcript is **copied to your clipboard** and saved as Markdown in
   `~/Documents/Meeting Transcripts/`. A notification tells you when it's ready (click it to
   open the file).

Paste into Notion and the headings and speaker names keep their formatting.

```markdown
# Meeting transcript: Fri 9 Oct 2026, 14:30

- **Duration:** 32:10
- **Recorded:** microphone + computer audio
- **Speakers:** Me, Speaker 1, Speaker 2

---

**Me** · 00:04
Morning! Can everyone hear me?

**Speaker 1** · 00:07
Yes, loud and clear. Let's start with the launch plan.
```

Good to know:

- **No headphones?** Your mic also hears the remote people through the speakers. Those
  duplicate lines are detected and removed automatically.
- **Nothing is lost if something fails.** Recordings are kept until a transcript is saved. Use
  **Retry transcription** in the menu. Reloading Hammerspoon mid-meeting doesn't stop the recording.
- Transcription runs after the meeting ends (not live). It usually takes a few seconds, or
  under a minute for an hour-long meeting.
- Speaker separation works best with a few minutes of conversation. Very short clips may put
  everyone under one speaker.
- **Get consent.** Recording laws vary by place. Tell people when you're transcribing a meeting.

## Configuration

Options go in the `start({...})` call in `~/.hammerspoon/init.lua`:

```lua
deepgramDictation = require("deepgram_dictation")
deepgramDictation.start({
  hotkey = "rightOption",
  language = "multi",
})
```

| Option | Default | Description |
| --- | --- | --- |
| `hotkey` | `"fn"` | `"fn"`, `"rightOption"`, `"rightCommand"`, `"rightControl"`, `"rightShift"` |
| `language` | `"en"` | Any [Deepgram language code](https://developers.deepgram.com/docs/models-languages-overview), or `"multi"` for mixed-language speech |
| `model` | `"nova-3"` | Deepgram model name |
| `smartFormat` | `true` | Format numbers, dates, emails, etc. |
| `minSeconds` | `0.3` | Shorter presses are ignored |
| `restoreClipboard` | `true` | Put your previous clipboard back after pasting |
| `showMenubar` | `true` | Show the 🎙 menu bar item |
| `dictionary` | `~/.hammerspoon/deepgram-dictionary.json` | Path to your dictionary |
| `recBinary` | auto-detected | Path to sox's `rec` |
| `keychainName` | `"deepgram-api-key"` | Keychain service name holding the API key |
| `meetingHotkey` | `{ mods = {"ctrl","alt","cmd"}, key = "m" }` | Starts/stops a meeting recording. `false` disables it |
| `meetingMode` | `"online"` | What the meeting hotkey records: `"online"` (mic + computer audio) or `"inPerson"` (mic only) |
| `meetingLanguage` | same as `language` | Language for meeting transcripts |
| `transcriptsDir` | `~/Documents/Meeting Transcripts` | Where transcripts are saved |
| `keepMeetingAudio` | `false` | Keep the audio after a successful transcription |
| `recorderApp` | `~/Library/Application Support/deepgram-dictation/DeepgramRecorder.app` | Path to the recorder app |
| `python` | auto-detected | Path to `python3` |

Unknown option names raise an error in the Hammerspoon console, so typos don't fail silently.
After editing, reload Hammerspoon from its menu bar icon.

## Dictionary

`~/.hammerspoon/deepgram-dictionary.json` is re-read on every dictation, so edits apply
immediately:

```json
{
  "keyterms": ["Hammerspoon", "Kubernetes", "Jane Doe"],
  "replacements": [
    { "from": "btw", "to": "by the way" },
    { "from": "my email address", "to": "you@example.com" }
  ]
}
```

- **`keyterms`**: words Deepgram should listen for and spell exactly like this. Used for both
  dictation and meetings.
- **`replacements`**: applied to the transcript after Deepgram returns it. Matching is
  case-insensitive and whole-word only (`btw` won't touch `debtwise`). Longer phrases win
  over shorter ones. Dictation only: they aren't applied to meeting transcripts.

### Importing from Wispr Flow

```sh
python3 scripts/import_wispr_dictionary.py
```

This reads Wispr Flow's local database (read-only) and merges its words and snippets into your
dictionary file. Entries you already have are kept. Quit Wispr Flow (and turn off its launch
at login) so both apps don't respond to Fn.

## Updating your API key

```sh
security add-generic-password -U -s deepgram-api-key -a "$USER" -w
```

Then reload Hammerspoon.

## Uninstall

```sh
./uninstall.sh          # removes the module, DeepgramRecorder.app and the init.lua block
./uninstall.sh --purge  # also deletes your dictionary, unfinished recordings and the Keychain API key
```

Saved transcripts are never deleted. Hammerspoon and sox are left installed. Remove them with
`brew uninstall --cask hammerspoon && brew uninstall sox` if you don't need them.

## Troubleshooting

Open the Hammerspoon console (menu bar icon → Console). Lines from this tool start with
`[deepgram-dictation]`.

| Symptom | Fix |
| --- | --- |
| Nothing happens when holding Fn | Accessibility permission is missing or stale: toggle it off and on, then quit and reopen Hammerspoon |
| Emoji picker opens | Set "Press 🌐 key to" to "Do Nothing" |
| "Deepgram API key not found" | Add the key (see [Updating your API key](#updating-your-api-key)) |
| "Deepgram error (401)" | The key is invalid or revoked. Replace it |
| "No speech detected" | Check the input device in System Settings → Sound, and that Hammerspoon has microphone access |
| Text is pasted twice | Another dictation app (Wispr Flow, Superwhisper…) is also listening on Fn. Quit it |
| "sox not found" | `brew install sox` |
| Meeting transcript only has your voice | Allow DeepgramRecorder under System Settings → Privacy & Security → **System Audio Recording Only**, then start a new recording |
| "Couldn't start recording" / "Recorder didn't start" | Allow DeepgramRecorder under Privacy & Security → **Microphone** |
| Asked for permissions again after updating | Expected when `DeepgramRecorder.app` is rebuilt with changed code. Allow again |
| "DeepgramRecorder.app not found" | Install the Xcode Command Line Tools, then re-run `./install.sh` |

## Privacy

Dictation audio is recorded to a temporary file, sent over HTTPS directly to Deepgram's
`/v1/listen` endpoint, and deleted once it has been read. Meeting audio is stored in
`~/Library/Application Support/deepgram-dictation/meetings/` only until its transcript is saved
(unless you set `keepMeetingAudio`). Transcripts stay on your Mac. Nothing goes to any server
other than Deepgram.
See [Deepgram's data privacy terms](https://deepgram.com/privacy) for how they handle audio.

## How it works

```
Hold key ──► sox `rec` → temp WAV (16 kHz mono)
Release  ──► POST to api.deepgram.com/v1/listen (nova-3, keyterms)
         ──► apply replacements ──► clipboard + ⌘V ──► restore clipboard
```

- [`src/deepgram_dictation/core.lua`](src/deepgram_dictation/core.lua): pure logic (config, URL
  building, replacements, response parsing). Has no Hammerspoon dependency and is fully unit tested.
- [`src/deepgram_dictation/init.lua`](src/deepgram_dictation/init.lua): Hammerspoon glue
  (event taps, recording, HTTP, pasting, menu bar).
- [`src/deepgram_dictation/meeting.lua`](src/deepgram_dictation/meeting.lua): meeting start/stop,
  progress, notifications.
- [`recorder/main.swift`](recorder/main.swift): `DeepgramRecorder.app`. It records the mic
  (AVAudioEngine) and computer audio (Core Audio process tap, macOS 14.2+) to separate AAC
  files. It's a separate app so macOS grants it its own audio permissions.
- [`src/deepgram_dictation/meeting_transcribe.py`](src/deepgram_dictation/meeting_transcribe.py):
  uploads each track to Deepgram (diarized), removes echo, labels speakers, and writes the
  Markdown. Standard library only.

## Contributing

Contributions are welcome. See [CONTRIBUTING.md](CONTRIBUTING.md) for the dev setup and
[CODE_OF_CONDUCT.md](CODE_OF_CONDUCT.md). Report security issues privately as described in
[SECURITY.md](SECURITY.md).

## License

[MIT](LICENSE)
