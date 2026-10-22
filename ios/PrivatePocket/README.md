# Private Pocket (iOS)

The SwiftUI app. It talks to the Pocket over Bluetooth using
[`../../ble/PROTOCOL.md`](../../ble/PROTOCOL.md). There's no Pocket account and nothing
goes to Pocket's cloud. See the [top-level README](../../README.md) for the overview.

## Tabs

- **Recorder.** Stays connected while the app is open. If the Pocket is not paired yet, a
  **Pair** section shows the one step (hold the side button for 5 s until it blinks blue,
  tap Pair); recordings started with the button already stream in before that. It has a
  record button with a timer, and while recording a **Live** panel shows the streaming
  state and the transcript as it arrives (on-device `SpeechAnalyzer`, or server Whisper in
  15 s slices). At stop, the streamed copy becomes the recording if its length matches
  what the Pocket reports; otherwise the file is downloaded (unpaired: the streamed copy
  is kept as is). Recordings made while the phone was away are fetched by themselves on
  every connection (per-device setting). Below that: Fetch missed recordings now, device
  details and the protocol log.
- **Recordings.** Named by place and time, searchable, and filterable by Pocket. Each
  recording has a player, a title, a location, a transcript in a chosen language (with speakers if
  enabled, which you can rename), a summary, and "Ask about this recording".
- **Ask.** Questions about one recording or all of them in a date range. Long transcripts
  are read in parts and the answers combined.
- **Settings.**
  - Devices: add by scanning (no key needed; pair from the Recorder tab), and per-device
    name, key, clock, auto-download and auto-transcribe.
  - Stay connected.
  - USB drive: free up space.
  - Speech to text and Language model: each on the iPhone or on a server.
  - Speakers, languages, location and summary instructions.

## Storage

`Documents/Recordings/<device id>/<yyyy-MM-dd>/<yyyyMMddHHmmss>.mp3` plus a `.json`
sidecar holding the title, place, transcript, word times, speaker turns and summary. The
sidecar also stores `pocket`: the Pocket's name and advertised id, so a recording still
knows its device after the device is removed from Settings. Recordings are visible in
Files → On My iPhone → Private Pocket. File names are UTC, as on the device. Session keys
and server keys are kept in the Keychain.

## Build

```bash
./gen-defaults.sh && xcodegen generate && open PrivatePocket.xcodeproj   # set your team, run
# or, without an Apple ID in Xcode:
cp signing.env.example signing.env && ./sign-install.sh
```

`gen-defaults.sh` runs before each build. It turns `../../ble/.env` (see
`.env.example`) into the gitignored `Generated/DefaultDevice.swift`: the first Pocket
(with its key, if you have one), and optionally a default server. With no server, speech to text and
summaries default to the iPhone.

## Caveats

- The Pocket talks to one central at a time. If the official app (or the Mac tools) is
  connected, this app won't find it.
- In the background the app leaves a pending connection that iOS completes whenever the
  Pocket is in range, and iOS relaunches the app for Bluetooth events if it was
  terminated (state restoration), so recordings stream in without the app open. Swiping
  the app away in the app switcher stops that until it is opened again.
- Mounting the Pocket over USB-C on an iPhone is untested. It works on a Mac.
