#!/usr/bin/env python3
"""Move Gaudi's delete key to the end of the last letter group.

Bank $7D is loaded from Track-02 sectors 343..346 at CPU $A000-$BFFF.
The last four keypad entries are ordinary one-byte key codes:

    0.7.15  $BB28  1B 09 0B 0A   = ー, delete, ゜, ゛
    new             1B 0A 0B 09   = letter, letter, letter, delete

Only the table entries are swapped.  The input dispatcher is verified before
writing: $09 must still branch to delete and $0A/$0B to the modifier handler.
"""
from __future__ import annotations

import argparse
import hashlib
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path[:0] = [str(ROOT / "tools"), str(ROOT / "extraction" / "patch" / "static")]

from build_disc_subtitle_hook import rebuild_mode1_sector  # noqa: E402

TRACK02 = "Snatcher CD-ROMantic (Japan) (Track 02) [KO].bin"
RAW, USER, HDR = 2352, 2048, 16
BANK_SECTOR, BANK_CPU = 343, 0xA000
TABLE_CPU = 0xBB28
OLD = bytes.fromhex("1B 09 0B 0A")
NEW = bytes.fromhex("1B 0A 0B 09")

# CMP #$09 -> delete; the old CMP #$0A/$0B branches went to the modifier
# handler.  Those two codes are now ordinary Korean keycodes, so the branch
# slots are NOP-filled and execution falls through to the common input path.
DISPATCH_CPU = 0xB8D4
DISPATCH = bytes.fromhex("C9 09 F0 A6 C9 0A D0 03 4C A9 BB C9 0B D0 03 4C A9 BB")
DISPATCH_ORDINARY = bytes.fromhex("EA" * len(DISPATCH[4:]))


def raw_of_cpu(cpu: int) -> int:
    offset = cpu - BANK_CPU
    if not 0 <= offset < 0x2000:
        raise ValueError(f"CPU address outside bank $7D: ${cpu:04X}")
    sector, inside = divmod(offset, USER)
    return (BANK_SECTOR + sector) * RAW + HDR + inside


def sha(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest().upper()


def patch_track(source: Path, target: Path) -> dict:
    data = bytearray(source.read_bytes())
    dispatch_raw = raw_of_cpu(DISPATCH_CPU)
    if data[dispatch_raw:dispatch_raw + len(DISPATCH)] != DISPATCH:
        got = data[dispatch_raw:dispatch_raw + len(DISPATCH)].hex(" ").upper()
        raise RuntimeError(f"key dispatcher mismatch at ${DISPATCH_CPU:04X}: {got}")

    table_raw = raw_of_cpu(TABLE_CPU)
    if data[table_raw:table_raw + len(OLD)] != OLD:
        got = data[table_raw:table_raw + len(OLD)].hex(" ").upper()
        raise RuntimeError(f"key table mismatch at ${TABLE_CPU:04X}: {got}")
    data[table_raw:table_raw + len(NEW)] = NEW

    sector = table_raw // RAW
    base = sector * RAW
    block = bytearray(data[base:base + RAW])
    rebuild_mode1_sector(block)
    data[base:base + RAW] = block
    target.write_bytes(data)

    final = target.read_bytes()
    if final[table_raw:table_raw + len(NEW)] != NEW:
        raise RuntimeError("key table write-back verification failed")
    return {
        "sha256": sha(final),
        "sector": sector,
        "table_cpu": f"{TABLE_CPU:04X}",
        "table_raw": f"{table_raw:X}",
        "before": OLD.hex(" ").upper(),
        "after": NEW.hex(" ").upper(),
        "layout": ["$1B letter", "$0A letter", "$0B letter", "$09 delete"],
    }


def patch_dispatcher(source: Path, target: Path) -> dict:
    """Make $0A/$0B fall through to ordinary input instead of modifiers."""
    data = bytearray(source.read_bytes())
    dispatch_raw = raw_of_cpu(DISPATCH_CPU)
    got = bytes(data[dispatch_raw:dispatch_raw + len(DISPATCH)])
    if got != DISPATCH:
        raise RuntimeError(
            f"modifier dispatcher mismatch at ${DISPATCH_CPU:04X}: "
            f"{got.hex(' ').upper()}"
        )
    start = dispatch_raw + 4
    data[start:start + len(DISPATCH_ORDINARY)] = DISPATCH_ORDINARY
    sector = dispatch_raw // RAW
    block = bytearray(data[sector * RAW:(sector + 1) * RAW])
    rebuild_mode1_sector(block)
    data[sector * RAW:(sector + 1) * RAW] = block
    target.write_bytes(data)
    final = target.read_bytes()
    if final[dispatch_raw:dispatch_raw + 4] != DISPATCH[:4]:
        raise RuntimeError("delete branch was altered while patching dispatcher")
    if final[dispatch_raw + 4:dispatch_raw + len(DISPATCH)] != DISPATCH_ORDINARY:
        raise RuntimeError("ordinary-key dispatcher write-back verification failed")
    return {
        "cpu": f"{DISPATCH_CPU:04X}",
        "raw": f"{dispatch_raw:X}",
        "before": DISPATCH.hex(" ").upper(),
        "after": (DISPATCH[:4] + DISPATCH_ORDINARY).hex(" ").upper(),
        "sector": sector,
        "meaning": "$09 delete; $0A/$0B ordinary Korean input",
    }


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("version")
    ap.add_argument("--write", action="store_true")
    args = ap.parse_args()
    track = ROOT / "build" / "patch" / args.version / TRACK02
    if not track.is_file():
        raise SystemExit(f"Track 02 missing: {track}")
    table_raw = raw_of_cpu(TABLE_CPU)
    current = track.read_bytes()[table_raw:table_raw + len(OLD)]
    print(f"${TABLE_CPU:04X} raw ${table_raw:X}: {current.hex(' ').upper()} -> {NEW.hex(' ').upper()}")
    if not args.write:
        print("report only; pass --write to modify the track")
        return
    info = patch_track(track, track)
    print(f"sector {info['sector']} rebuilt")
    print(f"Track 02 SHA-256 {info['sha256']}")


if __name__ == "__main__":
    main()
