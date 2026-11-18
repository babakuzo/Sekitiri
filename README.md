# Sekitiri

A meeting recorder for macOS that keeps everything on your Mac. It records
your microphone and the computer's audio (Zoom, Teams, Meet, FaceTime,
WhatsApp, anything that plays sound), transcribes both locally with Parakeet,
and turns the transcript into notes and action items, each tied to the words
it came from.

Nothing is uploaded. Recordings, transcripts and notes are plain files in
folders you choose, and the speech and summary models run on-device.

## What it does

- Records the mic and the computer's audio as separate tracks, so your words
  are labelled as yours. Works with any call app, with no bot joining the call.
- Transcribes while you record, so little is left to do after Stop. Handles
  25 languages, including meetings that switch between English and French.
- Optionally separates the other participants into Speaker 1, Speaker 2 and
  so on, which you can rename.
- Writes notes with Apple Intelligence or a local Qwen 3.5 model, or extracts
  them without any model. Every point links back to the moment in the
  transcript, and you can play the audio from there.
- Warns you during a recording if the microphone or computer audio goes
  silent, so a muted mic doesn't cost you a meeting.
- Imports existing recordings (audio or video files, from the Import Audio
  button, File menu or by dropping them on the meetings list) and processes
  them like any other meeting.
- Lets you mark moments, add your own notes, and later delete the audio while
  keeping the transcript.

## Requirements

- A Mac with Apple silicon
- macOS 15 or later
- Xcode 26 or later (Swift 6.2) to build

On first use, Sekitiri asks for microphone access and for Screen & System
Audio Recording (needed to capture the computer's audio). The speech model,
about 630 MB, downloads once.

## Build and run

```bash
git clone <this repository>
cd <the cloned folder>
swift build
swift test
Tools/build_app.sh
open .local-validation/Sekitiri.app
```

`Tools/build_app.sh` builds a release version, packages it as an app and
signs it for this Mac. See [BUILD.md](BUILD.md) for the architecture, the
folder layout and the packaging details.

Builds you make yourself run on your own Mac. To make a disk image others can
open without a Gatekeeper warning, sign and notarize it with a Developer ID:

```bash
SEKITIRI_SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)" \
SEKITIRI_NOTARY_PROFILE=<notarytool keychain profile> \
Tools/make_dmg.sh
```

The script explains the one-time `notarytool store-credentials` step and
writes `dist/Sekitiri-<version>.dmg`.

## Where your files live

| What | Default location |
|---|---|
| Recordings, transcripts and processing state | `~/Recordings` |
| Notes, as Markdown, with an index | `~/Meetings` |
| Settings | `~/.config/quill/config.json`, `~/.config/meeting-notes/config.json` |

## Credits

Sekitiri started from [quill](https://github.com/humanitas-labs/quill) by
Humanitas Labs. Speech recognition runs on
[FluidAudio](https://github.com/FluidInference/FluidAudio) with NVIDIA's
Parakeet models, and local summaries on
[MLX Swift](https://github.com/ml-explore/mlx-swift-lm). Model and font
licenses are listed in [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).

## License

MIT. See [LICENSE](LICENSE).
