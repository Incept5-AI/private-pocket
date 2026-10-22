# Pocket (PKT01) BLE protocol

Reverse-engineered 2026-10-17 from PacketLogger captures of the official iOS app
(sync, Web Sync toggle, button recording, app start/stop, "Clear Offline Copies") talking to
firmware **1.8**, Wi-Fi firmware **V9**. The captures themselves are not published: they hold
the session key and private audio. To make your own, see "Capturing your session key" below.
Verified by replaying from a Mac with `pocket.py`.

## Device

- Advertises as `PKT01_<COLOUR>_<last 4 bytes of MAC>` (e.g. `PKT01_GREY_2617abcd`,
  MAC `f4:4c:26:17:ab:cd`), service UUIDs `0x5536`, `0x2222` in the advert.
- SoC vendor **Actions** (USB VID `0x10d6`, PID `0xb00b`, product string "MSC Sample").
- Connects with **no pairing / bonding**. MTU 247.

## GATT

| Service | Char (value handle on iOS) | Props | Use |
|---|---|---|---|
| `180f` Battery | `2a19` | read, notify | battery % |
| `001120a0-2233-4455-6677-889912345678` | `…a2` (0x2b) | write | **commands** (ASCII) |
| | `…a1` (0x2d) | notify | **audio** — raw MP3 frames (MPEG-2 L3, 16 kHz mono 32 kbps) |
| | `…a3` (0x30) | write-nr, notify | **replies / events** (ASCII) |
| `ffd0` | `ffd1` / `ffd2` / `ffd3` | write / notify | unused by the app in this capture |
| `e49a3001-f69a-11e8-8eb2-f2801f1b9fd1` | `3002` / `3003` | write / notify | unused (likely Actions OTA) |
| `e49a25f8-f69a-11e8-8eb2-f2801f1b9fd1` | `25e0` / `28e1` | write / notify | unused (likely Actions tooling) |

## Message format

`&`-separated ASCII. App → device starts `APP&`, device → app starts `MCU&`.

| App sends | Device replies | Meaning |
|---|---|---|
| `APP&SK&<16 chars>` | `MCU&SK&OK` | session key, sent first after connect; a wrong one drops the connection (see below) |
| `APP&BAT` | `MCU&BAT&99` | battery % |
| `APP&FW` | `MCU&FW&1.8` | firmware version |
| `APP&WF` | `MCU&WF&V9` | Wi-Fi firmware version |
| `APP&MAC` | `MCU&MAC&f44c2617abcd` | MAC |
| `APP&SPACE` | `MCU&SPA&059620&059634` | storage (free & total, MB?) |
| `APP&GET&USB` | `MCU&USB&1` | USB mass-storage (Web Sync) state |
| `APP&USB&0` / `APP&USB&1` | `MCU&USB&0` / `1` | **set** Web Sync off / on |
| `APP&T&YYYYMMDDhhmmss` | `MCU&T&OK` | set device clock |
| `APP&STE` | `MCU&STE&0` | unknown state query |
| `APP&REC&SECEN` | `MCU&REC&CON` | unknown ("secure enable"?) |
| `APP&LIST_DIRS` | `MCU&DIRS&<date>` … then `MCU&DIRS_SUM&<count>` | list day folders that hold recordings |
| `APP&LIST&YYYY-MM-DD` | `MCU&F&<date>&<file>&<secs>` … then `MCU&LIST&<count>` | list recordings for a day (`MCU&LIST&0` = none) |
| `APP&U&<date>&<file>` | `MCU&U&<bytes>`, MP3 on `…a1`, then `MCU&OFF` | **download** a recording |
| `APP&STA` | `MCU&REC&CON`, `MCU&STA&<YYYYMMDDhhmmss>` | **start recording** (timestamp = file name) |
| `APP&STO` | `MCU&STO` | **stop recording** |

The session key is **required for commands**: without `APP&SK&<key>` the device silently
ignores every command. It is set in pairing mode and static after that (see
[Session key and pairing](#session-key-and-pairing)). It is sent in cleartext over an
unpaired link. Keep it in `.env` (`POCKET_SK`), never in this file.

Unsolicited events: `MCU&REC&CON` + `MCU&STA&<timestamp>` when recording starts
(button press), live MP3 streamed on `…a1` while recording, `MCU&STO` on stop. These
arrive **with or without a session key**. A recording started by the button with the
card sitting on the back of the phone announced `MCU&REC&CALL` and a file named
`PH<YYMMDDhhmmss>` instead (the contact-mic "call" mode), and `LIST_DIRS` did not list
it afterwards, so those files live outside the dated folders.

## Observed sync flow

connect → enable notify on a1, a3 → `SK` → `BAT` `GET&USB` `FW` `SPACE` `WF` `MAC`
→ `LIST` for each of the last ~7 days and next 2 → `U` for each new file.

A 10 s recording (40,350 bytes) downloaded in ~0.7 s (~58 KB/s).

## Deleting recordings

There is **no delete command** over BLE; the official app has no delete-from-device
(its "Clear Offline Copies" only clears the phone cache — verified in a capture).
Pocket support's sanctioned method is deleting over USB, and it works cleanly:

1. `APP&USB&1` over BLE, then **re-plug** the cable (the setting only applies on connect).
2. Delete files under `RECORD/<date>/` on the mounted exFAT volume, then eject.
3. **Unplug.** While the cable is attached the device reports `MCU&SPA&000000&000000`
   and does not answer `LIST` / `LIST_DIRS` — USB holds the storage.
4. After unplugging, `LIST` reflects the deletion immediately (no stale index).

Tested 2026-10-17: deleted `20261017164256.mp3` over USB → `MCU&LIST&008`, file gone.
`SPACE` stays `059620&059634`, so its units are coarser than the 6 KB freed (MB, or GB×1000).

## Session key and pairing

Tested 2026-10-22 on firmware 1.8 from a Mac with `bleak`:

- **Pairing mode sets the key.** Hold the side button for 5 s until the light blinks
  blue (the official app's "Pair your Pocket" step). The device then accepts
  **whatever 16-character key the next connection sends**, answers `MCU&SK&OK`, and
  requires that key from then on. There is no challenge, pairing prompt or account
  check on the device; the "already assigned" check the official app shows lives in
  Pocket's cloud. Nothing else is needed: with the connection kept open and no further
  command, the light went from blinking to solid blue within the first minute. Right
  after the key the device sends `MCU&WIFIO`, and `MCU&WIFIC` about 15 s later (its
  Wi-Fi coming up and giving up, it seems).
- **Outside pairing mode a wrong key drops the connection** immediately, with no reply.
  The key set in pairing mode kept working across later connections.
- **No key still gets the live stream.** A central that only enables notifications on
  `…a1` and `…a3` receives `MCU&STA&<name>` and `MCU&STO` for button-started recordings
  and the full live MP3 on `…a1`, and can read the standard Battery Service
  (`180f`/`2a19`). Commands get no reply. The device dropped such a connection about
  12 s after `MCU&STO`.

So a third-party app pairs exactly as the official one does: hold the button, send a
key of its own. That is what Private Pocket's **Pair** button does, and the official app
simply needs to pair again afterwards. The Mac tools take the key from `.env`.

### Reading the official app's key instead

If you want the key the official app already uses (both apps then share it, though only
one can be connected at a time), it is sent in clear text as `APP&SK&<key>` on every
connection:

1. Install Apple's **Bluetooth logging profile** for iOS (developer.apple.com →
   *Bug Reporting → Profiles and Logs*), approve it in Settings, restart the phone.
2. Install **PacketLogger** (*Additional Tools for Xcode*), plug the phone into the Mac,
   and choose **File → New iOS Trace**.
3. Open the official Pocket app so it connects to the device, then save the trace.
4. Find the ATT write to the `…a2` characteristic that starts `APP&SK&`; the 16
   characters after it are the key. Put it in `ble/.env` as `POCKET_SK` (or type it
   into the app's Add device screen), and remove the logging profile afterwards.
