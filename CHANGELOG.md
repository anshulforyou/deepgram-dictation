# Changelog

All notable changes to this project are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and the project uses
[Semantic Versioning](https://semver.org/).

## [Unreleased]

## [0.2.0] - 2026-10-09

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
- Meeting options: `meetingHotkey`, `meetingMode`, `meetingLanguage`, `transcriptsDir`,
  `keepMeetingAudio`, `recorderApp`, `python`, `detectMeetings`, `autoStopMeetings`,
  `menuHotkey`, `organizeWithClaude`, `claudePath`, `claudeModel`.

## [0.1.0] - 2026-10-09

### Added

- Hold-to-talk dictation via Hammerspoon with Deepgram Nova-3.
- Configurable hotkey (Fn or right-side modifiers), language, model and formatting.
- Dictionary file with Deepgram keyterms and case-insensitive whole-word replacements.
- Wispr Flow dictionary importer.
- Installer and uninstaller; API key stored in the macOS Keychain.
- Unit tests, lint and CI.
