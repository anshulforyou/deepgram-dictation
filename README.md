# deepgram-dictation

**Hold a key, speak, let go. Your words appear wherever your cursor is.**
**Join a Zoom or Google Meet call and it offers to transcribe it. Claude files every transcript
into the right folder.**

A small, open-source dictation and meeting-transcription tool for macOS. It works much like Wispr Flow, but
uses your own [Deepgram](https://deepgram.com) API key. It runs inside
[Hammerspoon](https://www.hammerspoon.org), so there's no background server and no Electron
app, and no account other than your Deepgram one.

> Unofficial project. Not affiliated with Deepgram or Wispr.

## Features

- **Hold-to-talk:** hold **Fn** (or a right-side modifier key), speak, release.
- **Fast:** audio streams to Deepgram while you speak, so text appears about half a second after
  you let go.
- **Meeting transcription:** records in-person meetings from the mic, or online meetings
  (Zoom, Google Meet, Teams, Slack…) from the mic *and* computer audio, then gives you a
  speaker-labelled transcript on your clipboard, ready to paste into Notion, Google Docs or
  anywhere else. No bot joins your call.
- **Meeting detection:** when a call starts, a small prompt asks whether to transcribe it. The
  recording stops on its own when the call ends.
- **Organized by Claude (optional):** each transcript gets a title, summary and action items,
  and is filed into a topic folder with a `meetings.md` index.
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
5. Press **⌃⌥⌘D** to open the menu at your mouse pointer. This helps if the 🎙 icon is hidden
   behind the notch or a crowded menu bar.

Re-running `./install.sh` upgrades the module and leaves your settings, dictionary and key alone.

## Usage

| Action | What happens |
| --- | --- |
| Hold the hotkey | A "🎙 Listening…" badge appears and recording starts |
| Release | Audio is sent to Deepgram ("⏳ Transcribing…"), then the text is pasted |
| Tap for less than 0.3 s | Ignored, so accidental taps don't trigger anything |
| Press another key while holding (e.g. Fn+F5) | Dictation is cancelled |
| 🎙 menu bar icon, or **⌃⌥⌘D** | Enable/disable dictation, start/stop meetings, reload config |

## Meeting transcription

| Meeting | How to start | Records |
| --- | --- | --- |
| **Online** (Zoom, Google Meet, Teams, Slack huddle, Webex, FaceTime…) | Join the call, then click **Transcribe** on the prompt. Or use the 🎙 menu | Microphone + computer audio |
| **In person** (a room, interview, lecture) | Press **⌃⌥⌘M** (again to stop). Or use the 🎙 menu | Microphone only |

### Meeting detection

When a meeting app or a browser tab with a call starts using your microphone, a card in the
top-right corner asks **"Google Meet detected. Transcribe this meeting?"**. Click **Transcribe**,
or ignore it and it goes away. When the call ends (the app releases the mic, or the Meet tab is
closed), the recording stops and is transcribed automatically.

- Detected desktop apps: Zoom, Microsoft Teams, Slack, Webex, Discord, FaceTime, Skype.
- In Chrome, Brave, Edge, Arc, Vivaldi, Opera and Safari, open tabs are checked for Google Meet,
  Zoom, Teams, Slack huddle and Whereby URLs. The first time, macOS asks whether Hammerspoon may
  control your browser. Allow it so tabs can be read. Firefox is matched by window title.
- Nothing is recorded until you click **Transcribe**.

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

- In online meetings the mic is recorded in Apple's voice-processing ("call") mode, the same mode
  Meet and Zoom use. macOS silences plain recordings of a mic that a call app holds in that
  mode. Echo cancellation is a side benefit.
- **No headphones?** Your mic also hears the remote people through the speakers. Those
  duplicate lines are detected and removed automatically.
- **Nothing is lost if something fails.** Recordings are kept until a transcript is saved. Use
  **Retry transcription** in the menu. Reloading Hammerspoon mid-meeting doesn't stop the recording.
- Transcription runs after the meeting ends (not live). It usually takes a few seconds, or
  under a minute for an hour-long meeting.
- Speaker separation works best with a few minutes of real conversation. Very short clips may
  put everyone under one speaker.

### Organizing with Claude

Turn it on in `~/.hammerspoon/init.lua`:

```lua
deepgramDictation.start({
  organizeWithClaude = true,
})
```

After each meeting, the transcript is sent to Claude through the
[Claude Code](https://claude.com/claude-code) CLI you're logged into (`claude -p`, no tools enabled).
Claude:

1. picks the best existing folder in `~/Documents/Meeting Transcripts/` (or names a new one,
   e.g. `Product Launch`, `Hiring`, `Acme Corp`),
2. writes a title, a short summary and action items into the transcript,
3. adds an entry to that folder's `meetings.md`, newest first:

```markdown
# Product Launch meetings

- **2026-10-09 15:14** · [Mobile App Launch Plan Review](2026-10-09%2015-14%20Mobile%20App%20Launch%20Plan%20Review.md) · 2 min
  The team confirmed November 20 for the public release. Marketing needs final screenshots by Friday…
```

Transcripts that couldn't be filed (Claude unavailable, or organizing switched off at the time)
stay at the top of `~/Documents/Meeting Transcripts/`. Use **File N unfiled transcripts with
Claude** in the 🎙 menu, or run
`python3 ~/.hammerspoon/deepgram_dictation/meeting_transcribe.py --refile "<file>.md" --output-dir ~/Documents/Meeting\ Transcripts --organize-with-claude ~/.local/bin/claude`.

Create, rename or merge folders yourself whenever you like. Claude uses the folder names and
their recent meeting titles to decide where new meetings go. If Claude isn't available, the
transcript is still saved (unfiled) and copied, and the notification says why it wasn't filed.
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
| `streaming` | `true` | Stream audio while you speak. `false` uploads the recording after you release (slower) |
| `minSeconds` | `0.3` | Shorter presses are ignored |
| `restoreClipboard` | `true` | Put your previous clipboard back after pasting |
| `showMenubar` | `true` | Show the 🎙 menu bar item |
| `dictionary` | `~/.hammerspoon/deepgram-dictionary.json` | Path to your dictionary |
| `recBinary` | auto-detected | Path to sox's `rec` |
| `keychainName` | `"deepgram-api-key"` | Keychain service name holding the API key |
| `meetingHotkey` | `{ mods = {"ctrl","alt","cmd"}, key = "m" }` | Starts/stops a meeting recording. `false` disables it |
| `meetingMode` | `"inPerson"` | What the meeting hotkey records: `"inPerson"` (mic only) or `"online"` (mic + computer audio) |
| `detectMeetings` | `true` | Offer to transcribe when a call starts |
| `autoStopMeetings` | `true` | Stop and transcribe when a detected call ends |
| `menuHotkey` | `{ mods = {"ctrl","alt","cmd"}, key = "d" }` | Shows the menu at the mouse pointer. `false` disables it |
| `organizeWithClaude` | `false` | File transcripts into topic folders with Claude |
| `claudePath` | auto-detected | Path to the `claude` CLI |
| `claudeModel` | CLI default | Model for organizing, e.g. `"opus"` |
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
| "No speech detected" | Check the input device in System Settings → Sound, and that Hammerspoon has microphone access. The alert says when the mic level was very low |
| First word missing with AirPods | Bluetooth mics take 1-2 s to switch on. Wait for **🎙 Listening…** (it shows **🎧 Connecting mic…** until then) |
| Text is pasted twice | Another dictation app (Wispr Flow, Superwhisper…) is also listening on Fn. Quit it |
| "sox not found" | `brew install sox` |
| Meeting transcript only has your voice | Allow DeepgramRecorder under System Settings → Privacy & Security → **System Audio Recording Only**, then start a new recording |
| "Couldn't start recording" / "Recorder didn't start" | Allow DeepgramRecorder under Privacy & Security → **Microphone** |
| Asked for permissions again after updating | Expected when `DeepgramRecorder.app` is rebuilt with changed code. Allow again |
| "DeepgramRecorder.app not found" | Install the Xcode Command Line Tools, then re-run `./install.sh` |
| Can't see the 🎙 icon | It's hidden by the notch or a full menu bar. Use **⌃⌥⌘D**, hide other icons, or ⌘-drag 🎙 further right. Also check System Settings → Menu Bar allows Hammerspoon |
| No prompt when a Google Meet call starts | Allow Hammerspoon to control your browser (System Settings → Privacy & Security → Automation) |
| Transcript "Not filed" | Make sure `claude` works in Terminal and you're logged in. The reason is in the notification |

## Privacy

Dictation audio is recorded to a temporary file, sent over HTTPS directly to Deepgram's
`/v1/listen` endpoint, and deleted once it has been read. Meeting audio is stored in
`~/Library/Application Support/deepgram-dictation/meetings/` only until its transcript is saved
(unless you set `keepMeetingAudio`). Transcripts stay on your Mac. Nothing goes to any server
other than Deepgram, unless you turn on `organizeWithClaude`, which sends the transcript text
(not audio) to Anthropic through your Claude Code login.
See [Deepgram's data privacy terms](https://deepgram.com/privacy) for how they handle audio.

## How it works

```
Hold key ──► DeepgramRecorder --stream (AVAudioEngine) ──► wss://api.deepgram.com/v1/listen
             (16 kHz PCM, also saved to a temp WAV)          (nova-3, keyterms; transcribes live)
Release  ──► flush the last results (~0.5 s) ──► apply replacements ──► clipboard + ⌘V
             if streaming fails: upload the saved WAV to /v1/listen instead
```

- [`src/deepgram_dictation/core.lua`](src/deepgram_dictation/core.lua): pure logic (config, URL
  building, replacements, response parsing). Has no Hammerspoon dependency and is fully unit tested.
- [`src/deepgram_dictation/init.lua`](src/deepgram_dictation/init.lua): Hammerspoon glue
  (event taps, recording, HTTP, pasting, menu bar).
- [`src/deepgram_dictation/meeting.lua`](src/deepgram_dictation/meeting.lua): meeting start/stop,
  progress, notifications.
- [`src/deepgram_dictation/detector.lua`](src/deepgram_dictation/detector.lua) and
  [`prompt.lua`](src/deepgram_dictation/prompt.lua): meeting detection (which apps use the mic,
  browser tab URLs) and the "Transcribe this meeting?" card.
- [`src/deepgram_dictation/meeting_organize.py`](src/deepgram_dictation/meeting_organize.py):
  filing with Claude and `meetings.md` indexes.
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
