# Private Pocket (iOS)

The SwiftUI app. It talks to the Pocket over Bluetooth using
[`../../ble/PROTOCOL.md`](../../ble/PROTOCOL.md). There's no Pocket account and nothing
goes to Pocket's cloud. See the [top-level README](../../README.md) for the overview.

## Tabs

- **Recorder.** Stays connected while the app is open. It has a record button with a timer,
  and while recording a **Live** panel shows the streaming state and the transcript as it
  arrives (on-device `SpeechAnalyzer`, or server Whisper in 15 s slices). At stop, the
  streamed copy becomes the recording if its length matches what the Pocket reports;
  otherwise the file is downloaded. Below that: Download new recordings, device details
  and the protocol log.
- **Recordings.** Named by place and time, searchable, and filterable by Pocket. Each
  recording has a player and three tabs:
  - **Analysis:** who spoke and for how long, the names and merges the analysis suggests,
    the analysis itself (overview, people, key points with times, decisions, action items,
    open questions, dynamics) and "Ask about this recording".
  - **Transcript:** colour-coded turns; tap a time to play from there, a name to rename.
    Transcribe again in another language, or find speakers again.
  - **Details:** title, place, Pocket, file.
- **Ask.** Questions about one recording or all of them in a date range. Long transcripts
  are read in parts and the answers combined.
- **Translate.** Listen with the iPhone's microphone or through the Pocket (which starts,
  and saves, a recording), and see each phrase translated after the speaker pauses. On the
  phone (Parakeet, or Apple's recognisers for other languages, then Apple Translation) or
  on the server (Whisper, then the language model with the last lines as context). ⋯ →
  Get ready for offline use downloads what the phone needs. Optional read-aloud.
- **Settings.**
  - Devices: add by scanning, and per-device name, key, clock, auto-download and auto-transcribe.
  - Stay connected.
  - USB drive: free up space.
  - Speech to text and Language model: each on the iPhone or on a server. On the iPhone,
    speech to text is Parakeet (default) or Apple's.
  - Speakers (on the iPhone or a server), languages, location, and the analysis
    instructions (and whether it runs after each transcription).

## Storage

`Documents/Recordings/<device id>/<yyyy-MM-dd>/<yyyyMMddHHmmss>.mp3` plus a `.json`
sidecar holding the title, place, transcript, word times, speaker turns and summary. The
sidecar also stores `pocket`: the Pocket's name and advertised id, so a recording still
knows its device after the device is removed from Settings. Recordings are visible in
Files → On My iPhone → Private Pocket. File names are UTC, as on the device. Session keys
and server keys are kept in the Keychain.

## Build

```bash
xcodegen generate && open PrivatePocket.xcodeproj   # set your team, run
# or, without an Apple ID in Xcode:
cp signing.env.example signing.env && ./sign-install.sh
```

`gen-defaults.sh` runs before each build. It turns `../../ble/.env` (see
`.env.example`) into the gitignored `Generated/DefaultDevice.swift`: the first Pocket
and its key, and optionally a default server. With no server, speech to text and
summaries default to the iPhone.

## Caveats

- The Pocket talks to one central at a time. If the official app (or the Mac tools) is
  connected, this app won't find it.
- Apple's on-device language model analyses well enough to read, but it does not find
  names and invents "same person" findings, so merges are only offered from a server
  model's analysis.
- Mounting the Pocket over USB-C on an iPhone is untested. It works on a Mac.
