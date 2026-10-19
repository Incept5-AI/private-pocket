# /// script
# requires-python = ">=3.11"
# dependencies = ["bleak>=0.22"]
# ///
"""Read-only GATT enumeration: connect, list services/characteristics/descriptors,
read values only where the characteristic advertises 'read'. Never writes,
never subscribes, never pairs."""
import asyncio
import sys

from bleak import BleakClient, BleakScanner

NAME_PREFIX = sys.argv[1] if len(sys.argv) > 1 else "PKT01"


def show(data: bytes) -> str:
    text = "".join(chr(b) if 32 <= b < 127 else "." for b in data)
    return f"{data.hex()}  |{text}|"


async def main():
    dev = await BleakScanner.find_device_by_filter(
        lambda d, a: (a.local_name or d.name or "").startswith(NAME_PREFIX), timeout=20
    )
    if not dev:
        sys.exit(f"no device starting with {NAME_PREFIX!r}")
    print(f"connecting to {dev.name} {dev.address}")
    async with BleakClient(dev, timeout=20) as client:
        print(f"connected, mtu={client.mtu_size}")
        for svc in client.services:
            print(f"\nSERVICE {svc.uuid}  {svc.description}")
            for ch in svc.characteristics:
                print(f"  CHAR {ch.uuid}  handle={ch.handle}  [{', '.join(ch.properties)}]  {ch.description}")
                if "read" in ch.properties:
                    try:
                        print(f"       value: {show(await client.read_gatt_char(ch))}")
                    except Exception as e:
                        print(f"       read failed: {e}")
                for d in ch.descriptors:
                    try:
                        val = show(await client.read_gatt_descriptor(d.handle))
                    except Exception as e:
                        val = f"read failed: {e}"
                    print(f"       DESC {d.uuid} {d.description}: {val}")


asyncio.run(main())
