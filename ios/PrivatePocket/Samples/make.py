"""Builds SampleMoments/ from manifest.json: each line spoken by a macOS voice, the
turns joined with a short pause, encoded the way the Pocket records (16 kHz mono MP3
at 32 kbps). Run from this folder: uv run --no-project python make.py"""
import json, pathlib, shutil, subprocess, tempfile

root = pathlib.Path(__file__).parent
manifest = json.load(open(root / "manifest.json"))
out = root / "SampleMoments"
out.mkdir(exist_ok=True)
shutil.copy(root / "manifest.json", out / "manifest.json")
voices = {1: "Daniel", 2: "Serena", 3: "Reed"}

for s in manifest["samples"]:
    with tempfile.TemporaryDirectory() as tmp:
        tmp = pathlib.Path(tmp)
        parts = []
        for i, line in enumerate(s["lines"]):
            aiff = tmp / f"{i:03}.aiff"
            subprocess.run(["say", "-v", voices[line["v"]], "-r", "178", "-o", str(aiff), line["t"] + " [[slnc 500]]"], check=True)
            parts.append(aiff)
        listing = tmp / "list.txt"
        listing.write_text("".join(f"file '{p}'\n" for p in parts))
        subprocess.run(["ffmpeg", "-y", "-loglevel", "error", "-f", "concat", "-safe", "0", "-i", str(listing),
                        "-ar", "16000", "-ac", "1", "-codec:a", "libmp3lame", "-b:a", "32k", str(out / s["file"])], check=True)
    print("wrote", s["file"])
