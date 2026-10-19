<p align="center"><img src="assets/logo.png" width="160" alt="Private Pocket logo"></p>

<h1 align="center">Private Pocket</h1>

A local-first, open-source companion app for the [Pocket](https://heypocket.com) voice
recorder. It's for people who love the hardware but need their recordings to stay on
their own devices.

Pocket is a genuinely nice recorder. It's a thin card with a 62 GB drive (thousands of
hours of speech) and a light that tells everyone in the room when it is recording. One button press and you're recording. The official app and cloud add excellent
transcription, summaries and search, and for most people they are the right choice.

Some people can't send audio to any cloud: lawyers, clinicians, journalists, anyone
bound by client confidentiality or EU/UK data-residency rules, or anyone who'd simply rather
not. Private Pocket talks to the recorder directly over Bluetooth and keeps everything on
the iPhone. Optionally, it uses a server **you** choose.

> Not affiliated with, endorsed by or supported by Open Vision Engineering, Inc. (Pocket).
> "Pocket" is their trademark, used here only to say which device this works with.

## What it does

- **Record and stream.** Start and stop the Pocket from the phone, or use its button.
  While the phone is connected, the Pocket streams its audio live, so the recording is
  saved and transcribed as you speak, with no download afterwards.
- **Sync over Bluetooth.** Download any recordings the phone doesn't have yet, at about
  40–60 KB/s (an hour of audio in about five minutes). No cable, Wi-Fi or account needed.
- **Transcribe.** Choose Apple's on-device speech recognition (`SpeechAnalyzer`) in the
  language you pick, or any OpenAI-compatible Whisper server, which can detect the language itself.
- **Speakers.** Optionally sends audio to a diarisation server to label who spoke when.
  You can name the speakers ("Speaker 2" → "Daniel").
- **Summarise and ask.** Summaries and questions across one recording or a date range
  ("who was mentioned?", "which restaurant was it?"). These use Apple Intelligence
  (`FoundationModels`) on the phone, or any OpenAI-compatible model server.
- **Organised.** Recordings are named by where and when they were made (from the phone's
  location; the Pocket has no GPS), are searchable, and record which Pocket made them.
  Several Pockets are supported.
- **Free up space.** Bluetooth has no delete command, so the app guides the USB-C route:
  it shows which files on the Pocket's drive are safely backed up, then deletes those.

## What leaves the phone

| Setting | Audio | Transcripts | Anything to Pocket's cloud |
|---|---|---|---|
| Everything "On this iPhone" (default with no server configured) | stays on the phone | stays on the phone | no |
| Speech to text on a server | to **your** server | — | no |
| Language model on a server | — | to **your** server | no |
| Speakers on | to **your** diarisation server | — | no |

Place names use Apple's geocoder (coordinates only), and can be turned off.

## Requirements

- An iPhone on iOS 27, built with Xcode 27 and [XcodeGen](https://github.com/yonaskolb/XcodeGen).
  On-device summaries need Apple Intelligence.
- A Pocket recorder. Tested on firmware 1.8 / Wi-Fi V9 with two cards.
- Your Pocket's **session key**. The device ignores every command without it. It's a
  one-time capture of what the official app sends; see
  [Capturing your session key](ble/PROTOCOL.md#capturing-your-session-key).

## Getting started

```bash
git clone https://github.com/incept5-ai/private-pocket && cd private-pocket
cp ble/.env.example ble/.env          # optional: your Pocket, key and server defaults
cd ios/PrivatePocket
xcodegen generate && open PrivatePocket.xcodeproj    # set your team, run on your phone
```

You can skip `.env` and add the Pocket in **Settings → Devices → Add device** instead.
If Xcode has no Apple ID signed in, `sign-install.sh` builds unsigned and signs with an
existing development profile (see `signing.env.example`).

**Important:** the Pocket talks to one phone at a time. If the official app is installed
with Bluetooth on, it may connect first and sync recordings to its cloud as designed. Use
one app or the other.

## Using your own server

Any OpenAI-compatible endpoint works: `…/v1/audio/transcriptions` (with
`verbose_json` and word timestamps, e.g. whisper.cpp or faster-whisper servers) and
`…/v1/chat/completions` (vLLM, llama.cpp, Ollama, LM Studio…). Speaker labels need a
`POST …/v1/audio/diarize` that takes a multipart `file` and returns
`{"segments": [{"start": 0.0, "end": 2.1, "speaker": 0}, …]}`. Set the server in the app,
or bake in defaults through `ble/.env` (`SERVER_URL`, `STT_MODEL`, `LLM_MODEL`,
`DIARIZE_URLS`, `SERVER_KEY`).

## Repository

| Path | What |
|---|---|
| [`ble/PROTOCOL.md`](ble/PROTOCOL.md) | The Bluetooth protocol: commands, audio, sync, live streaming, USB delete |
| `ble/*.py` | Small Mac tools (Python + [bleak](https://github.com/hbldh/bleak), run with `uv run`): scan, dump services, send commands, download |
| [`ios/PrivatePocket`](ios/PrivatePocket) | The SwiftUI app |

## How this was built

We built it by watching the Bluetooth traffic between our own phone and our own Pocket,
using Apple's PacketLogger, so that a different app could work with the device. No
firmware was decompiled, and no Pocket code, assets or credentials are included. The
protocol turned out to be refreshingly simple: plain-text commands and ordinary MP3 audio.
That's a credit to Pocket's engineering. It's what makes a small independent client like
this possible.

## Caveats

- A Pocket firmware update could change the protocol. Tested on 1.8.
- The session key is a shared secret sent without Bluetooth pairing. Treat it like a
  password and keep it out of screenshots and repos (`ble/.env` is gitignored).
- With Web Sync (USB access) on, anyone who plugs the Pocket into a computer can read
  the recordings. The app shows the setting and lets you switch it off.

## Credits

- **[Pocket](https://heypocket.com)** (Open Vision Engineering, Inc., San Francisco) made the
  recorder. It's good hardware built on open, sensible formats (MP3 files, an ordinary USB
  drive, plain-text Bluetooth commands), and that's the only reason a project like this is possible.
  If you don't need everything kept local, their app and service are the easy choice.
- **Actions** (炬芯科技 Actions Technology, Zhuhai, China). The Pocket identifies over USB
  as an Actions device (vendor ID `0x10d6`). Actions makes Bluetooth audio chips of
  this kind, and its tidy GATT layout underpins the protocol described in `ble/`.
- **The Qwen team** (Alibaba, China): open-weight models such as Qwen3.6, used in the
  examples here, work very well as a self-hosted model for summaries and questions.
- **Whisper** (OpenAI) and **whisper.cpp** for self-hosted speech to text, Apple's
  `SpeechAnalyzer` and `FoundationModels` for the on-device versions,
  [bleak](https://github.com/hbldh/bleak) for the Mac tools, and
  [XcodeGen](https://github.com/yonaskolb/XcodeGen).

## License

[MIT](LICENSE)
