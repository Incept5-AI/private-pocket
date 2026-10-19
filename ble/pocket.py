# /// script
# requires-python = ">=3.11"
# dependencies = ["bleak>=0.22"]
# ///
"""Minimal Pocket BLE client (protocol reverse-engineered from a PacketLogger capture).

Commands are ASCII written to 001120a2; replies arrive as ASCII notifications on
001120a3; audio arrives as raw MP3 frames on 001120a1.

    uv run pocket.py [--sk KEY] CMD [CMD ...]     e.g.  uv run pocket.py BAT FW GET&USB
"""
import argparse
import os
import asyncio
import sys

from bleak import BleakClient, BleakScanner

CMD = "001120a2-2233-4455-6677-889912345678"
REPLY = "001120a3-2233-4455-6677-889912345678"
AUDIO = "001120a1-2233-4455-6677-889912345678"
NAME_PREFIX = "PKT01"


async def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--sk", default=os.environ.get("POCKET_SK"), help="session key sent first as APP&SK&<key> (default: $POCKET_SK)")
    ap.add_argument("--wait", type=float, default=1.5, help="seconds to wait for replies per command")
    ap.add_argument("--out", help="write any audio received to this file")
    ap.add_argument("cmds", nargs="+")
    args = ap.parse_args()

    dev = await BleakScanner.find_device_by_filter(
        lambda d, a: (a.local_name or d.name or "").startswith(NAME_PREFIX), timeout=20
    )
    if not dev:
        sys.exit("Pocket not advertising (is it connected to the phone?)")

    replies: asyncio.Queue[str] = asyncio.Queue()
    audio = bytearray()

    async with BleakClient(dev, timeout=20) as client:
        print(f"connected to {dev.name}")
        await client.start_notify(REPLY, lambda _, d: replies.put_nowait(d.decode(errors="replace")))
        await client.start_notify(AUDIO, lambda _, d: audio.extend(d))

        async def send(cmd: str):
            await client.write_gatt_char(CMD, f"APP&{cmd}".encode(), response=True)
            print(f"-> APP&{cmd}")
            try:
                while True:
                    print(f"<- {await asyncio.wait_for(replies.get(), args.wait)}")
            except asyncio.TimeoutError:
                pass

        async def download(cmd: str):
            """APP&U&<date>&<file>: reply MCU&U&<size>, MP3 on AUDIO, then MCU&OFF."""
            audio.clear()
            await client.write_gatt_char(CMD, f"APP&{cmd}".encode(), response=True)
            print(f"-> APP&{cmd}")
            size, done, last = None, False, (len(audio), asyncio.get_running_loop().time())
            while not done:
                try:
                    msg = await asyncio.wait_for(replies.get(), 0.5)
                    print(f"<- {msg}")
                    if msg.startswith("MCU&U&"):
                        size = int(msg.split("&")[2])
                    elif msg == "MCU&OFF":
                        done = True
                except asyncio.TimeoutError:
                    pass
                now = asyncio.get_running_loop().time()
                if len(audio) != last[0]:
                    last = (len(audio), now)
                elif now - last[1] > args.wait:
                    print(f"stalled at {len(audio)} bytes")
                    break
                if size is not None and len(audio) >= size:
                    done = True
            if size is not None:
                print(f"   {len(audio)}/{size} bytes")

        if args.sk:
            await send(f"SK&{args.sk}")
        for c in args.cmds:
            if c.startswith("SLEEP&"):  # local pseudo-command: pause without disconnecting
                await asyncio.sleep(float(c.split("&")[1]))
                continue
            await (download(c) if c.startswith("U&") else send(c))
    if audio:
        print(f"(received {len(audio)} audio bytes)")
        if args.out:
            with open(args.out, "wb") as f:
                f.write(audio)
            print(f"wrote {args.out}")


asyncio.run(main())
