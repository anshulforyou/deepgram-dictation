# Security Policy

## Reporting a vulnerability

Please **do not** open a public issue for security problems. Instead, report them privately
through GitHub's
[private vulnerability reporting](https://github.com/anshulforyou/deepgram-dictation/security/advisories/new).

Include a description, steps to reproduce, and the impact. You should get an initial reply
within 7 days.

## Scope

Things we especially care about:

- the Deepgram API key leaking (to logs, files, process arguments, or other hosts)
- audio or transcripts being kept on disk or sent anywhere other than Deepgram
- the installer or uninstaller modifying files outside `~/.hammerspoon`

## Handling your API key

- The key is stored in the macOS Keychain and read at runtime. It is never written to disk by
  this project.
- If you think your key has leaked, revoke it in the
  [Deepgram console](https://console.deepgram.com) and add a new one with
  `security add-generic-password -U -s deepgram-api-key -a "$USER" -w`.
