# Changelog

All notable changes to this project are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and the project uses
[Semantic Versioning](https://semver.org/).

## [Unreleased]

### Added

- `bridgeBluetoothMic`: with AirPods, the first words of a dictation are no longer lost while
  they switch into call mode (1 to 3 s). The built-in mic covers that start-up, and the AirPods
  take over once they send audio. Each dictation records when that happened (`handoverMs`).

- Filing into [grandma](https://github.com/anshulforyou/grandma): with `grandmaHome`, meetings go
  to the matching sweater's `meetings/` folder with an index and an INDEX.md pointer, and each one
  gets a memory proposal for `grandma review`.
- Dictation cleanup with Claude (`cleanup`): removes repeated words and false starts, applies
  spoken self-corrections, and fixes misheard words and names before pasting. Falls back to the
  raw transcript when Claude is slow or answers with something that isn't a cleanup.
- `names` in the dictionary, and names read from grandma memory once a day: spelled correctly by
  cleanup and listened for by Deepgram.
- `keepDictations`: keeps recent dictations to review, flag from the menu, and replay with
  `make eval-dictation`. **Retry last dictation** transcribes the newest one again.
- A standby recorder with the mic set up but off: recording starts about 0.2 s after the key
  goes down instead of 0.4 s, or up to 2 s after the Mac has been idle, so first words aren't lost.
- `tailSeconds`: recording continues 0.5 s after release, so the last word isn't cut off.
- Asking grandma about the screen (`screenAssist`): hold Fn+Control and ask. She writes replies
  where you're typing or answers in a panel, from a screenshot of the display under the mouse
  (Claude Sonnet). A rose glow runs round the screen's edges while she looks. `make eval-screen`
  checks her answers on made-up screens.
- Screen questions know you (with `grandmaHome`): a compact profile generated from your global
  memory goes with every question, a sweater or project you name goes with it, and grandma can
  open one herself when the screen is about it.
- Grandma fills in forms: ask her to fill something in, check the fields and values she plans,
  press Return, and she fills it with Claude's computer use. She only types the values you
  confirmed and never presses Return or clicks a button, link or checkbox, so saving stays yours.
  Esc or any touch stops her. `make test-fill` checks it on a real form.
- Grandma learns from what you say to her (with `grandmaHome`): each day's screen questions, fills
  and corrections become memory proposals for `grandma review`, "grandma, remember ..." becomes one
  right away, and with `learnStyle` your dictations teach `global/style.md` how you write, never
  what about.
- Sounds: soft notes and needle taps when you ask grandma something, while she thinks, when she
  answers, fills or notes something, when something fails, and when an in-person meeting starts, and
  when a transcript is saved. Silent while a call that meeting detection sees could hear them. `sounds`, `soundVolume`, `soundsOff`, and
  `dictationSounds` for a tick on plain dictation.

### Fixed

- Meeting proposals no longer send sweater memory files named like credentials to Claude.

### Changed

- Renamed from deepgram-dictation to **grandma-yawn**, the voice of
  [grandma](https://github.com/anshulforyou/grandma), with an animated header made from grandma's
  mascot. Existing installs keep working: the Hammerspoon module, Keychain entries and support
  folder keep their names.
- The badge is grandma's yarn instead of words: a strand waving while she listens, winding into a
  ball while it's transcribed, grandma knitting in a round bubble while she thinks, a stitch per
  step while she fills, a stitch dropped on the ball when she notes something, and a sagging strand
  on a slow connection. It shows as soon as the key is down, and from one to the next the pill
  morphs and crossfades. Errors are still words.
- The dictation stays on the clipboard after pasting (`restoreClipboard` now defaults to `false`),
  so ⌘V still has it when focus moved while you spoke.
- A stream that falls behind on a slow connection no longer pastes a partial transcript: the whole
  recording is uploaded instead, with a "Slow connection" badge. If Deepgram can't be reached, the
  recording is kept for a retry.

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
