# /// script
# requires-python = ">=3.11"
# dependencies = ["bleak>=0.22"]
# ///
"""Passive BLE scan: list advertising devices, highlight likely Pocket candidates."""
import asyncio
import sys

from bleak import BleakScanner

SECONDS = float(sys.argv[1]) if len(sys.argv) > 1 else 15


async def main():
    found = await BleakScanner.discover(timeout=SECONDS, return_adv=True)
    rows = sorted(found.values(), key=lambda da: -da[1].rssi)
    for dev, adv in rows:
        name = adv.local_name or dev.name or ""
        mfr = {f"0x{k:04x}": v.hex() for k, v in adv.manufacturer_data.items()}
        flag = "  <== candidate" if "pocket" in name.lower() else ""
        print(f"{adv.rssi:>4} dBm  {dev.address}  {name!r}{flag}")
        if adv.service_uuids:
            print(f"           services: {adv.service_uuids}")
        if mfr:
            print(f"           manufacturer: {mfr}")


asyncio.run(main())
