# deepgram-dictation

**Hold a key, speak, let go. Your words appear wherever your cursor is.**

A small, open-source push-to-talk dictation tool for macOS. It works much like Wispr Flow, but
uses your own [Deepgram](https://deepgram.com) API key. It runs inside
[Hammerspoon](https://www.hammerspoon.org), so there's no background server and no Electron
app, and no account other than your Deepgram one.

> Unofficial project. Not affiliated with Deepgram or Wispr.

## Features

- **Hold-to-talk:** hold **Fn** (or a right-side modifier key), speak, release.
- **Pastes into any app:** your clipboard is restored afterwards.
- **Deepgram Nova-3** with punctuation and smart formatting (numbers, emails, dates).
- **Custom vocabulary:** names and jargon are sent as Deepgram
  [keyterms](https://developers.deepgram.com/docs/keyterm) so they're spelled correctly.
- **Text replacements and snippets:** `btw` → `by the way`, `my email address` → `you@example.com`.
- **Wispr Flow import:** bring your existing Wispr dictionary over with one command.
- **Your key stays in the macOS Keychain**, never in a plain-text file.
- Menu bar toggle to switch dictation on and off.

## Requirements

- macOS (Apple Silicon or Intel)
- [Homebrew](https://brew.sh)
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
4. creates `~/.hammerspoon/deepgram-dictionary.json` from the example, if you don't have one,
5. asks for your Deepgram API key (input is hidden) and saves it to the Keychain.

Then finish the macOS setup:

1. **System Settings → Privacy & Security → Accessibility:** turn on **Hammerspoon**.
   If it was already on, quit and reopen Hammerspoon.
2. **System Settings → Keyboard → "Press 🌐 key to":** set to **Do Nothing**, so Fn doesn't
   open the emoji picker or Apple dictation.
3. Hold **Fn**, say something, release. Allow microphone access when macOS asks.

Re-running `./install.sh` upgrades the module and leaves your settings, dictionary and key alone.

## Usage

| Action | What happens |
| --- | --- |
| Hold the hotkey | A "🎙 Listening…" badge appears and recording starts |
| Release | Audio is sent to Deepgram ("⏳ Transcribing…"), then the text is pasted |
| Tap for less than 0.3 s | Ignored, so accidental taps don't trigger anything |
| Press another key while holding (e.g. Fn+F5) | Dictation is cancelled |
| 🎙 menu bar icon | Enable/disable dictation, reload config |

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

- **`keyterms`**: words Deepgram should listen for and spell exactly like this.
- **`replacements`**: applied to the transcript after Deepgram returns it. Matching is
  case-insensitive and whole-word only (`btw` won't touch `debtwise`). Longer phrases win
  over shorter ones.

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
./uninstall.sh          # removes the module and the init.lua block
./uninstall.sh --purge  # also deletes your dictionary and the Keychain API key
```

Hammerspoon and sox are left installed. Remove them with
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

## Privacy

Audio is recorded to a temporary file, sent over HTTPS directly to Deepgram's
`/v1/listen` endpoint, and deleted once it has been read. Nothing goes to any other server.
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

## Contributing

Contributions are welcome. See [CONTRIBUTING.md](CONTRIBUTING.md) for the dev setup and
[CODE_OF_CONDUCT.md](CODE_OF_CONDUCT.md). Report security issues privately as described in
[SECURITY.md](SECURITY.md).

## License

[MIT](LICENSE)
