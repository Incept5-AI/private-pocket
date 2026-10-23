# Private Pocket (iOS)

The SwiftUI app. It talks to the Pocket over Bluetooth using
[`../../ble/PROTOCOL.md`](../../ble/PROTOCOL.md). There's no Pocket account and nothing
goes to Pocket's cloud. See the [top-level README](../../README.md) for the overview.

## Tabs

- **Pocket.** The card itself, drawn in its own colour (from the Bluetooth name) with a
  light that mirrors the real one: blue when paired and ready, blinking blue when it needs
  pairing, amber while recording. Under it, what it is doing and battery and storage, the
  latter in hours of recording. If the Pocket is not paired yet, a **Pair** section shows
  the one step (hold the side button for 5 s until it blinks blue; the app pairs by
  itself, and Pair now tries at once); recordings started with the button already stream
  in before that, and keep doing so if the Pocket ever rejects the key. A round amber
  button is the side button's twin, and while recording the section shows the timer, the
  streaming state and the transcript as it arrives (on-device `SpeechAnalyzer`, or server
  Whisper in 15 s slices). At stop, the streamed copy becomes the recording if its length
  matches what the Pocket reports; otherwise the file is fetched (unpaired: the streamed
  copy is kept as is). Recordings made while the phone was away are fetched by themselves
  on every connection (per-device setting). Then today's recordings. The ⋯ menu has Get
  recordings now, Pocket details (battery, storage, firmware, protocol log), Connect or
  Disconnect, and Add another Pocket. The light, the status pill and the buttons use
  Liquid Glass.
- **While recording, everywhere.** A bar above the tab bar (an iOS 26 tab accessory) shows
  the light, the timer, the latest words and Stop on every tab. Outside the app the Pocket
  lives in the Dynamic Island and on the Lock Screen as a Live Activity
  (`PrivatePocketWidgets`): light and battery while connected, amber with the timer and
  words while recording, "Saved · 2 min" for a moment after. iOS only lets an app start a
  Live Activity in the foreground, which is why it is kept while connected rather than
  started at each recording; it can be turned off in Settings. Its Stop button runs
  `StopRecordingIntent` in the app. One Control Center toggle (`ControlWidget`) starts
  and stops the card; its on/off state reaches the extension through the shared
  Keychain group (`SharedState`), and the app asks Control Center to refresh whenever
  the light changes. Live Activity intents are among the kinds Control Center performs
  in the app itself, which is what lets them reach the Bluetooth link.
  "Start recording on Private Pocket" is an App Shortcut for Siri and the Action button.
- **Recordings.** Named by place and time, searchable, and filterable by Pocket, grouped
  into Today, Yesterday and dated days. Each recording has a player with ±15 s and a glass
  play button, a title, a location, the transcript as paragraphs (speaker turns, or runs
  of words between pauses) that follow the audio as it plays, the current word in amber
  and a tap on any paragraph playing from there, a summary, and "Ask about this
  recording". Transcribe, find speakers, summarise and share live in the ⋯ menu.
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

Two targets: the app (`App/`) and the widget extension (`Widgets/`), with `Shared/`
compiled into both (the Live Activity's attributes and intent, and how a Pocket looks).
`sign-install.sh` signs the extension with its own entitlements before the app.

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

## Look

The app is dark-only, in the palette `Shared/Brand.swift` defines: a graphite ground,
cyan for anything you can tap, the card's own amber for recording, blue for work and
pink for life. The status light's colours are the device's and are never restyled. The
app icon is the card with its light.

## Sample moments

Settings → Try it → Sample moments adds eight short spoken conversations, one of each
kind, dated over the last few hours. Each goes through speech to text, the reading,
Moments and Insights exactly as a recording from the Pocket would, on this iPhone or
on your server, and shows whether it was read as the kind it was meant to be. Remove
them from the same page.

## Screens

Four tabs. **Pocket**: the card, drawn at its real proportions with the real light on
it, the screen glowing in the light's colour, the timer and the live words while it
records, the amber shutter, and today's moments. **Moments**: every recording as a
card on a time rail, with what kind of conversation it was. Open one and you get one screen, in this order:
the speakers, identified where they named themselves; a summary written to you; to-dos,
each with Add to Reminders; events, each with Add to Calendar; the transcript, following
the audio from the player pinned at the bottom; and a field to ask anything about it.
Tap any sentence or item to hear the words behind it. Nothing needs starting: every
recording is transcribed and read as it lands. **Now** opens on the right thing for the hour and runs on into the tape: every moment as a band in the colour of its kind, by day, with Day, Week, Month and Year scales and a rail for finding a date. **Threads** are kept: each new conversation is read against a thread's story, so its page shows what changed and when, what is open by age and what lapsed; a subject that comes back after a quiet is flagged on Now and in the room, threads can be renamed, merged and split, and Record pressed on a thread records into it. **People** is a map of who you talk to and what stands between you. **You** is the mirror. **Ask the tape** is the search tab: a question gets an answer with the clips it drew on. Record lives above the tabs, with the Pocket's state. The first launch opens a swipe-only walkthrough of the card itself, and its Pair page finds and adds your Pocket while you hold the button: nothing to type, and no taps to add it. The first moment with a to-do said plainly asks once whether to put to-dos in Reminders from now on, and the same for dates and Calendar. Anything that goes wrong is a line at the top in plain words, never an alert. Settings opens with where things run, and has Export everything. Every reminder and event the app makes links back to its moment, and whatever you change in Reminders or Calendar, a tick, a new wording, a moved date or a removal, comes back to the moment.
