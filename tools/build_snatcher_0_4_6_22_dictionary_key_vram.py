#!/usr/bin/env python3
"""Combine reviewed dictionary data with the proven SEI-open HQ key-VRAM path."""
from __future__ import annotations

import hashlib
import json
import shutil
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "tools"))
import build_disc_subtitle_hook as hook  # noqa: E402

BASE = ROOT / "build" / "patch" / "0.4.6.21-reviewed-dictionary"
OUT = ROOT / "build" / "patch" / "0.4.6.22-dictionary-key-vram"
TRACK02 = "Snatcher CD-ROMantic (Japan) (Track 02) [KO].bin"
TRACK24 = "Snatcher CD-ROMantic (Japan) (Track 24) [KO].bin"
OLD_RESIDENT = ROOT / "build" / "cutscene_subs" / "resident_controller_native_poll_0_8_4.bin"
NEW_RESIDENT = ROOT / "build" / "cutscene_subs" / "resident_controller_native_poll_0_8_5.bin"
HELPER = ROOT / "build" / "cutscene_subs" / "subtitle_vram_helper.bin"
RAW, USER = 2352, 16
TRACK02_HELPER_HEAD = bytes.fromhex("A9002032BFAD001AC9ACD035")
TRACK02_HELPER_CODE_BYTES = 631


def sha(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest().upper()


def rebuild(data: bytearray, at: int) -> int:
    sector = at // RAW
    start = sector * RAW
    raw = bytearray(data[start:start + RAW])
    hook.rebuild_mode1_sector(raw)
    data[start:start + RAW] = raw
    return sector


def main() -> None:
    if not BASE.is_dir():
        raise SystemExit(f"dictionary preload base missing: {BASE}")
    old, new = OLD_RESIDENT.read_bytes(), NEW_RESIDENT.read_bytes()
    helper = HELPER.read_bytes()
    if len(old) != len(new) != 151 or old[:4] != b"\x08\x78\xA9\x3F" or new[:4] != b"\x08\xEA\xA9\x3F":
        raise SystemExit("resident is not the exact SEI-open one-byte pair")
    if len(helper) != 448 or helper[:3] != b"SUB":
        raise SystemExit("dynamic helper is not the expected 448-byte payload")
    if OUT.exists():
        raise SystemExit(f"output already exists (refusing overwrite): {OUT}")

    shutil.copytree(BASE, OUT)
    track02 = OUT / TRACK02
    data02 = bytearray(track02.read_bytes())
    head = data02.find(TRACK02_HELPER_HEAD)
    if head < 0 or data02.find(TRACK02_HELPER_HEAD, head + 1) >= 0:
        raise SystemExit("Track-02 resident neighbourhood fingerprint must be unique")
    resident_at = head + TRACK02_HELPER_CODE_BYTES
    if bytes(data02[resident_at:resident_at + len(old)]) != old:
        raise SystemExit("Track-02 resident is not the expected SEI-closed baseline")
    data02[resident_at:resident_at + len(new)] = new
    sector02 = rebuild(data02, resident_at)
    track02.write_bytes(data02)

    preload = json.loads((OUT / "bios_preload.json").read_text(encoding="utf-8"))
    rows = preload["rows"]
    helper_row = next(row for row in rows if row["name"] == "subtitle_helper")
    append_first_relative = min(int(row["relative_sector"]) for row in rows)
    local_sector = int(preload["track24_base_bytes"]) // RAW + (
        int(helper_row["relative_sector"]) - append_first_relative)
    track24 = OUT / TRACK24
    data24 = bytearray(track24.read_bytes())
    at24 = local_sector * RAW + USER
    previous = bytes(data24[at24:at24 + len(helper)])
    if previous[:3] != b"SUB" or previous == helper:
        raise SystemExit("Track-24 helper is not the expected static baseline")
    data24[at24:at24 + len(helper)] = helper
    sector24 = rebuild(data24, at24)
    track24.write_bytes(data24)

    manifest_path = OUT / "manifest.json"
    manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
    manifest.update({
        "version": "0.4.6.22-dictionary-key-vram",
        "dictionary_fixes": "root-state aliases for six affected pages + 야미 택시 -> 불법 택시",
        "resident_delta": "7F4A: SEI 78 -> NOP EA only",
        "subtitle_helper": "dynamic key VRAM save/restore/SATB wipe",
        "subtitle_renderer": "load lua/SUB/0.4.93-hq-key-vram.lua",
        "scope": "HQ collected 50 keys; A-base only; unmapped subtitle keys are skipped",
        "track02_resident_sector_rebuilt": sector02,
        "track24_helper_file_sector": local_sector,
        "track24_helper_sector_rebuilt": sector24,
        "track02_sha256": sha(bytes(data02)),
        "track24_sha256": sha(bytes(data24)),
    })
    manifest_path.write_text(json.dumps(manifest, ensure_ascii=False, indent=2), encoding="utf-8")
    (OUT / "TEST_IN_MESEN.txt").write_text(
        "0.4.6.22-dictionary-key-vram\n\n"
        "Power-cycle, open this CUE, then load exactly:\n"
        "  C:/snatcher/lua/SUB/0.4.93-hq-key-vram.lua\n\n"
        "Contains the reviewed dictionary fixes and the proven HQ A-base key-VRAM\n"
        "verification path. Do not load another subtitle/probe Lua alongside it.\n",
        encoding="utf-8",
    )
    print(f"dictionary + key VRAM: Track02 sector {sector02}, Track24 sector {sector24}")
    print(OUT / "Snatcher CD-ROMantic (Japan) [KO].cue")


if __name__ == "__main__":
    main()
