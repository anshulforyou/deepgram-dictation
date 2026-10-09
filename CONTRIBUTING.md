# Contributing

Thanks for helping improve deepgram-dictation. Bug reports, docs fixes, and features are all
welcome.

## Ground rules

- Be kind. This project follows the [Code of Conduct](CODE_OF_CONDUCT.md).
- For anything bigger than a small fix, open an issue first so we can agree on the approach.
- Keep the tool small: no extra runtime dependencies beyond Hammerspoon and sox, and no
  servers.
- Never commit API keys, personal dictionaries, or audio recordings.

## Development setup

```sh
xcode-select --install   # Swift compiler, for recorder/
brew install lua@5.4 luarocks shellcheck
luarocks --lua-version 5.4 install --local busted
luarocks --lua-version 5.4 install --local luacheck
```

Hammerspoon embeds Lua 5.4, so test against 5.4.

To try your changes live, run `./install.sh --no-deps` (it copies `src/` into
`~/.hammerspoon/`), then reload Hammerspoon and watch its console.

## Project layout

| Path | Purpose |
| --- | --- |
| `src/deepgram_dictation/core.lua` | Pure logic, with no `hs.*` calls. Put anything testable here |
| `src/deepgram_dictation/init.lua` | Hammerspoon glue: event taps, recording, HTTP, paste |
| `src/deepgram_dictation/meeting.lua` | Hammerspoon glue for meeting recording |
| `src/deepgram_dictation/meeting_transcribe.py` | Meeting pipeline: Deepgram, echo removal, Markdown (stdlib only) |
| `src/deepgram_dictation/meeting_organize.py` | Filing transcripts with the Claude Code CLI, `meetings.md` indexes |
| `src/deepgram_dictation/detector.lua`, `prompt.lua` | Meeting detection and the "Transcribe this meeting?" card |
| `recorder/` | `DeepgramRecorder.app` (Swift) and its build script |
| `spec/` | Lua unit tests ([busted](https://lunarmodules.github.io/busted/)) |
| `scripts/import_wispr_dictionary.py` | Wispr Flow dictionary importer (stdlib only) |
| `tests/` | Python unit tests and the install/uninstall smoke test |

## Checks

```sh
make lint   # luacheck + shellcheck
make test   # Lua specs, Python tests, install smoke test
```

CI runs the same checks on every pull request. They must pass before merging.

## Pull requests

1. Fork the repo and create a branch from `main`.
2. Add or update tests for any change to `core.lua` or the importer.
3. Update `README.md` if you change behaviour or config options, and add a line under
   **Unreleased** in `CHANGELOG.md`.
4. Keep commits focused, with messages that explain *why*.
5. Open the PR and fill in the template. Include manual test notes for anything in `init.lua`,
   `meeting.lua`, `detector.lua`, `prompt.lua` or `recorder/`, since those layers can only be
   tested by hand.

Rebuilding `DeepgramRecorder.app` with changed code changes its ad-hoc signature, so macOS
asks for Microphone and System Audio Recording permission again. That's expected.

Set `DEEPGRAM_STREAM_DEBUG=1` when running `DeepgramRecorder --stream` by hand to log every
message Deepgram sends (with timestamps) to stderr.

## Reporting bugs

Use the bug report template. Include your macOS version, Hammerspoon version, your config
(without the API key), and the `[deepgram-dictation]` lines from the Hammerspoon console.
