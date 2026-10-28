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
| `APP&SK&<16 chars>` | `MCU&SK&OK` | session key, sent first after connect (enforcement untested) |
| `APP&BAT` | `MCU&BAT&99` | battery % |
| `APP&FW` | `MCU&FW&1.8` | firmware version |
| `APP&WF` | `MCU&WF&V9` | Wi-Fi firmware version |
| `APP&MAC` | `MCU&MAC&f44c2617abcd` | MAC |
| `APP&SPACE` | `MCU&SPA&059620&059634` | storage (free & total, MB?) |
| `APP&GET&USB` | `MCU&USB&1` | USB mass-storage (Web Sync) state |
| `APP&USB&0` / `APP&USB&1` | `MCU&USB&0` / `1` | **set** Web Sync off / on |
| `APP&T&YYYYMMDDhhmmss` | `MCU&T&OK` | set device clock |
| `APP&STE` | `MCU&STE&0` | unknown state query |
| `APP&REC&SECEN` | `MCU&REC&CON` / `MCU&REC&CALL` | the **side switch**: audio (`CON`) or phone call (`CALL`, contact mic) |
| `APP&LIST_DIRS` | `MCU&DIRS&<date>` … then `MCU&DIRS_SUM&<count>` | list day folders that hold recordings |
| `APP&LIST&YYYY-MM-DD` | `MCU&F&<date>&<file>&<secs>` … then `MCU&LIST&<count>` | list recordings for a day (`MCU&LIST&0` = none) |
| `APP&U&<date>&<file>` | `MCU&U&<bytes>`, MP3 on `…a1`, then `MCU&OFF` | **download** a recording |
| `APP&STA` | `MCU&REC&CON`, `MCU&STA&<YYYYMMDDhhmmss>` | **start recording** (timestamp = file name) |
| `APP&STO` | `MCU&STO` | **stop recording** |

The session key is **required**: without `APP&SK&<key>` the device silently ignores
every command. The captured key replayed fine from a different central (a Mac) in a
later session, so it is static at least across sessions. It is sent in cleartext over
an unpaired link. Keep it in `.env` (`POCKET_SK`), never in this file.

Unsolicited events: `MCU&REC&CON` + `MCU&STA&<timestamp>` when recording starts
(button press), live MP3 streamed on `…a1` while recording, `MCU&STO` on stop.
The `MCU&REC&…` line before the start is the side switch: `CON` for audio, `CALL`
for a phone call through the contact mic. A call recording is named
`PH<YYMMDDhhmmss>` instead, and `LIST_DIRS` does not list it afterwards, so those
files live outside the dated folders and only the live stream captures them.

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

## Capturing your session key

The app needs your Pocket's 16-character session key, which the official app sends as
`APP&SK&<key>` right after connecting. To read it:

1. Install Apple's **Bluetooth logging profile** for iOS (developer.apple.com →
   *Bug Reporting → Profiles and Logs*), approve it in Settings, restart the phone.
2. Install **PacketLogger** (*Additional Tools for Xcode*), plug the phone into the Mac,
   and choose **File → New iOS Trace**.
3. Open the official Pocket app so it connects to the device, then save the trace.
4. Find the ATT write to the `…a2` characteristic that starts `APP&SK&`; the 16
   characters after it are the key. Put it in `ble/.env` as `POCKET_SK` (or type it
   into the app's Add device screen), and remove the logging profile afterwards.
