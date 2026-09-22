#!/usr/bin/env python3
"""Build test5: permanent Gibson Korean-token compatibility hook.

The visible/input token sequence stays 깁슨 (83 45 83 6A).  At the common
search comparator entry $B9E0, a small Track-02 resident routine expands that
sequence to the original key ギブスン before both the index and final compare.
This is the disc-patch equivalent of PROBE_GAUDI_SEARCH 0.1.6.
"""
from __future__ import annotations

import hashlib
import json
import os
import shutil
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path[:0] = [str(ROOT / "tools"), str(ROOT / "extraction" / "patch" / "static")]

import build_disc_subtitle_hook as rawdisc
import build_gaudi_keypad_test as keypad

SOURCE = ROOT / "build" / "patch" / "0.7.11"
VERSION = "0.7.11-keypad-test5b-gibson-hook"
OUT = ROOT / "build" / "patch" / VERSION
TRACK02_NAME = "Snatcher CD-ROMantic (Japan) (Track 02) [KO].bin"
SOURCE_BIOS_NAME = "Syscard3_galmuri_0.7.11.pce"
BIOS_NAME = f"Syscard3_galmuri_{VERSION}.pce"
RAW = 2352

# Runtime dump proved CPU bank $7D comes from Track-02 sectors 343-346.
# CPU $B9E0 -> raw $0C6CD0, CPU $BE56 -> raw $0C7146.
HOOK_CPU = 0xB9E0
CAVE_CPU = 0xBE56
HOOK_RAW = 0x0C6CD0
CAVE_RAW = 0x0C7146
HOOK_ORIGINAL = bytes.fromhex("A0 FF AD BA 34")  # LDY #$FF / LDA $34BA


def sha(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest().upper()


class Asm:
    def __init__(self, origin: int):
        self.origin = origin
        self.code = bytearray()
        self.labels: dict[str, int] = {}
        self.fixups: list[tuple[int, str]] = []

    @property
    def pc(self) -> int:
        return self.origin + len(self.code)

    def emit(self, *values: int) -> None:
        self.code.extend(values)

    def label(self, name: str) -> None:
        self.labels[name] = self.pc

    def branch(self, opcode: int, target: str) -> None:
        self.emit(opcode, 0)
        self.fixups.append((len(self.code) - 1, target))

    def finish(self) -> bytes:
        for operand, target in self.fixups:
            dest = self.labels[target]
            next_pc = self.origin + operand + 1
            delta = dest - next_pc
            if not -128 <= delta <= 127:
                raise RuntimeError(f"branch out of range: {target} ({delta})")
            self.code[operand] = delta & 0xFF
        return bytes(self.code)


def make_cave() -> bytes:
    a = Asm(CAVE_CPU)

    # Both Korean and already-expanded forms have lead $83 in cells 0 and 1.
    a.emit(0xAD, 0x3E, 0x36, 0xC9, 0x83)       # LDA $363E / CMP #$83
    a.branch(0xD0, "done")                     # BNE done
    a.emit(0xAD, 0x40, 0x36, 0xC9, 0x83)       # LDA $3640 / CMP #$83
    a.branch(0xD0, "done")

    a.emit(0xAD, 0x3F, 0x36, 0xC9, 0x45)       # Korean token 깁?
    a.branch(0xF0, "check_ko_second")           # BEQ
    a.emit(0xC9, 0x4D)                          # already original ギ?
    a.branch(0xD0, "done")
    a.emit(0xAD, 0x41, 0x36, 0xC9, 0x75)       # ブ trail
    a.branch(0xD0, "done")
    a.branch(0x80, "write_original")            # BRA

    a.label("check_ko_second")
    a.emit(0xAD, 0x41, 0x36, 0xC9, 0x6A)       # Korean token 슨
    a.branch(0xD0, "done")

    a.label("write_original")
    original = bytes.fromhex("83 4D 83 75 83 58 83 93 FF 40")
    for offset, value in enumerate(original):
        a.emit(0xA9, value, 0x8D, (0x363E + offset) & 0xFF,
               ((0x363E + offset) >> 8) & 0xFF)  # LDA #value / STA abs

    # Reproduce the three overwritten entry bytes and finish their instruction.
    a.label("done")
    a.emit(0xA0, 0xFF)                          # LDY #$FF
    a.emit(0xAD, 0xBA, 0x34)                    # LDA $34BA
    a.emit(0x60)                                # RTS
    return a.finish()


def stage() -> tuple[Path, Path]:
    if not SOURCE.is_dir():
        raise SystemExit(f"source build missing: {SOURCE}")
    if OUT.exists():
        raise SystemExit(f"output already exists (refusing overwrite): {OUT}")
    OUT.mkdir(parents=True)
    for entry in SOURCE.iterdir():
        if entry.name in {TRACK02_NAME, SOURCE_BIOS_NAME, "manifest.json"}:
            continue
        dest = OUT / entry.name
        if entry.is_dir():
            shutil.copytree(entry, dest, copy_function=os.link)
        else:
            os.link(entry, dest)
    return SOURCE / TRACK02_NAME, SOURCE / SOURCE_BIOS_NAME


def patch_track(source: Path, target: Path) -> dict:
    data = bytearray(source.read_bytes())
    cave = make_cave()
    if data[HOOK_RAW:HOOK_RAW + len(HOOK_ORIGINAL)] != HOOK_ORIGINAL:
        raise RuntimeError(
            f"hook mismatch at {HOOK_RAW:X}: "
            f"{data[HOOK_RAW:HOOK_RAW+len(HOOK_ORIGINAL)].hex(' ')}")
    if any(data[CAVE_RAW:CAVE_RAW + len(cave)]):
        raise RuntimeError(f"code cave is not blank at {CAVE_RAW:X}, len={len(cave)}")

    # Replace both complete entry instructions.  The cave reproduces them;
    # two NOPs carry the JSR return address cleanly to the following CMP #$01.
    data[HOOK_RAW:HOOK_RAW + 5] = bytes(
        (0x20, CAVE_CPU & 0xFF, CAVE_CPU >> 8, 0xEA, 0xEA))
    data[CAVE_RAW:CAVE_RAW + len(cave)] = cave

    touched = {HOOK_RAW // RAW, CAVE_RAW // RAW}
    for sector in sorted(touched):
        at = sector * RAW
        block = bytearray(data[at:at + RAW])
        rawdisc.rebuild_mode1_sector(block)
        data[at:at + RAW] = block
    target.write_bytes(data)
    return {
        "sha256": sha(data),
        "sectors": sorted(touched),
        "hook_cpu": f"{HOOK_CPU:04X}",
        "hook_raw": f"{HOOK_RAW:X}",
        "cave_cpu": f"{CAVE_CPU:04X}",
        "cave_raw": f"{CAVE_RAW:X}",
        "cave_size": len(cave),
        "mapping": {"깁슨": "ギブスン"},
    }


def main() -> None:
    source_track, source_bios = stage()
    bios_info = keypad.patch_bios(source_bios, OUT / BIOS_NAME)
    track_info = patch_track(source_track, OUT / TRACK02_NAME)

    manifest = json.loads((SOURCE / "manifest.json").read_text(encoding="utf-8"))
    route_c = dict(manifest.get("route_c", {}))
    route_c["sectors_touched"] = sorted(set(route_c.get("sectors_touched", [])) |
                                         set(track_info["sectors"]))
    manifest.update({
        "version": VERSION,
        "bios": BIOS_NAME,
        "base": str(SOURCE),
        "route_c": route_c,
        "bios_sha256": bios_info["sha256"],
        "track02_sha256": track_info["sha256"],
        "experiment": "Gaudi Gibson runtime search-key compatibility hook",
        "gaudi_gibson_hook_test": {"bios": bios_info, "track02": track_info},
    })
    (OUT / "manifest.json").write_text(
        json.dumps(manifest, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    (OUT / "TEST_IN_MESEN_GIBSON_HOOK.txt").write_text(
        f"{VERSION}\n\n"
        f"Use this folder's CUE and {BIOS_NAME}, then Power Cycle.\n"
        "Do not run a Lua search probe for the functional test.\n\n"
        "Input 깁슨 and press 결정.\n"
        "Expected: Gibson person file opens.\n\n"
        "This build contains only the Gibson compatibility mapping.\n",
        encoding="utf-8")
    print(f"built {OUT}")
    print(f"BIOS    {bios_info['sha256']}")
    print(f"Track02 {track_info['sha256']}")
    print(f"hook ${HOOK_CPU:04X} -> ${CAVE_CPU:04X}, cave {track_info['cave_size']} bytes")
    print("sectors " + ",".join(str(n) for n in track_info["sectors"]))


if __name__ == "__main__":
    main()
