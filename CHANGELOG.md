# Changelog

All notable changes to this project are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and the project uses
[Semantic Versioning](https://semver.org/).

## [Unreleased]

### Added

- Filing into [grandma](https://github.com/anshulforyou/grandma): with `grandmaHome`, meetings go
  to the matching sweater's `meetings/` folder with an index and an INDEX.md pointer, and each one
  gets a memory proposal for `grandma review`.
- Dictation cleanup with Claude (`cleanup`): removes repeated words and false starts, applies
  spoken self-corrections, and fixes misheard words and names before pasting. Falls back to the
  raw transcript when Claude is slow or answers with something that isn't a cleanup.
- `names` in the dictionary, and names read from grandma memory once a day: spelled correctly by
  cleanup and listened for by Deepgram.
- `keepDictations`: keeps recent dictations to review, flag from the menu, and replay with
  `make eval-dictation`.

## [0.2.0] - 2026-10-11

### Added

- Meeting transcription: record in-person meetings (mic) or online meetings (mic + computer
  audio via a Core Audio process tap) and get a speaker-labelled Markdown transcript on the
  clipboard and in `~/Documents/Meeting Transcripts`.
- `DeepgramRecorder.app`, a small native recorder built by `install.sh`.
- Echo removal when remote audio plays through the speakers.
- Retry for failed transcriptions; recordings survive Hammerspoon reloads.
- Meeting detection: a prompt offers to transcribe when Zoom, Teams, Slack, Webex, FaceTime or a
  browser tab on Google Meet/Zoom/Teams starts using the mic; detected meetings stop and
  transcribe automatically when the call ends.
- Optional organizing with Claude (Claude Code CLI): title, summary and action items, filed into
  topic folders with a `meetings.md` index per folder.
- `⌃⌥⌘D` opens the menu at the mouse pointer, for when the menu bar icon is hidden.
- Dictation streams audio to Deepgram's live API while the key is held: text arrives ~0.5 s after
  release instead of ~2.5-3.5 s. Falls back to uploading the recording if streaming fails.
  `streaming = false` restores the old behaviour.
- Dictation captures audio with AVAudioEngine instead of sox. sox only delivered noise from
  AirPods; sox is now only used when streaming is off. Shows "🎧 Connecting mic…" until a
  Bluetooth mic is actually live.
- "No speech detected" explains when the mic level was very low.
- Fixed your own voice missing from online-meeting transcripts (and some "No speech detected"):
  while a call app is active the mic reports several channels (MacBook mic array: 3, AirPods: 9),
  and AVAudioConverter's downmix turned those into pure zeros. The recorder now takes the first
  channel. A watchdog notes in the transcript if the mic ever delivers only digital silence.
- The recorder never uses voice processing: enabling it alongside a call app cut off the call
  app's microphone. CPU use while recording dropped from ~12-17% to ~1-2% of one core.
- A floating pill while a meeting is recorded, showing the meeting and elapsed time, with pause
  and stop buttons. Draggable; `showMeetingIndicator = false` hides it.
- Pausing a meeting recording. Paused time isn't recorded or sent to Deepgram, and the
  transcript notes how long it was paused.
- Meeting tracks stay aligned when the system audio tap skips time: the recorder writes audio by
  timestamp, and transcription re-aligns the tracks from the speaker echo the mic picks up.
- Echo removal also works word by word, so remote speech blended into your own sentences (when
  the call plays through the speakers) isn't labelled "Me".
- A transcript warning when an online meeting's computer audio captured almost nothing.
- "File N unfiled transcripts with Claude" menu item and `meeting_transcribe.py --refile`, for
  transcripts made while Claude was unavailable.
- Meeting options: `meetingHotkey`, `meetingMode`, `meetingLanguage`, `transcriptsDir`,
  `keepMeetingAudio`, `recorderApp`, `python`, `detectMeetings`, `autoStopMeetings`,
  `menuHotkey`, `showMeetingIndicator`, `organizeWithClaude`, `claudePath`, `claudeModel`.

## [0.1.0] - 2026-10-09

### Added

- Hold-to-talk dictation via Hammerspoon with Deepgram Nova-3.
- Configurable hotkey (Fn or right-side modifiers), language, model and formatting.
- Dictionary file with Deepgram keyterms and case-insensitive whole-word replacements.
- Wispr Flow dictionary importer.
- Installer and uninstaller; API key stored in the macOS Keychain.
- Unit tests, lint and CI.
