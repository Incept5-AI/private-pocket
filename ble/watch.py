# /// script
# requires-python = ">=3.11"
# dependencies = ["bleak>=0.22"]
# ///
"""Watch BLE advertisements for a new device: anything named like Pocket, or any
named non-Apple device not seen during an initial baseline period."""
import asyncio
import sys
import time

from bleak import BleakScanner

BASELINE = 20
LIMIT = float(sys.argv[1]) if len(sys.argv) > 1 else 900
APPLE = 0x004C
IGNORE_MFR = {0x05A7, 0xEC88}  # Sonos speakers, Govee thermometers


async def main():
    seen, start, hits = set(), time.time(), {}

    def cb(dev, adv):
        name = adv.local_name or dev.name or ""
        if time.time() - start < BASELINE:
            seen.add(dev.address)
            return
        apple_only = bool(set(adv.manufacturer_data) & IGNORE_MFR) or (adv.manufacturer_data and set(adv.manufacturer_data) <= {APPLE})
        new = dev.address not in seen and name and not apple_only
        if "pocket" in name.lower() or new:
            hits[dev.address] = (name, adv)

    async with BleakScanner(cb):
        while time.time() - start < LIMIT and not hits:
            await asyncio.sleep(1)
        await asyncio.sleep(3)  # let more adverts for the hit arrive

    if not hits:
        print("TIMEOUT: no new device")
    for addr, (name, adv) in hits.items():
        mfr = {f"0x{k:04x}": v.hex() for k, v in adv.manufacturer_data.items()}
        print(f"FOUND {addr} {name!r} rssi={adv.rssi} services={adv.service_uuids} "
              f"manufacturer={mfr} service_data={ {k: v.hex() for k, v in adv.service_data.items()} }")


asyncio.run(main())
