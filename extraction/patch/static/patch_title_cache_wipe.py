"""Point the scene VM's spawn handler at the engine's title-cache wipe.

The bug
-------
Save -> title -> reload leaves broken tiles, 100% of the time.  The game
re-reads our record cache at ``$5B80`` and our stale record is still there; the
original refreshes that buffer from CD, we fill it once and never touch it.
Filling the header with ``$FF`` makes the game read "no record" and skip.

Where the wipe lives
--------------------
In the engine helper itself.  ``build_ac_dynamic_0_1_14.build_helper_compact``
assembles a ``title_cache_wipe`` stub as part of the Bank 69 cave image and
exports its address in ``helper_symbols.json``.  All this script does is divert
one handler-table entry to it.

Do **not** go back to injecting code into the cave's $FF padding or its scratch
block.  PROBE 0.7.0 showed every byte of $7FC0-$7FFF is written by the BIOS CD
read ($EA9E), so neither is free at runtime -- that is what broke the action
menu in the first three attempts, and "it looks like $FF on the disc" had
already been wrong once at $5B80.

The edit
--------
    $7331   scene-VM handler table, opcode 2:  $73BD -> title_cache_wipe

The stub ends in ``JMP $73BD``, so the original handler still runs.

Addressing
----------
The cave is the tail of the same bank as the scene VM.  At the title spawn
MPR3 = $69 puts that bank at $6000-$7FFF, so the stub's cave address (quoted at
its $A000-window value, e.g. $BExx) is reached at ``address - $4000``.  The
overlay-to-disc mapping was verified by dumping 16 KB live at the title spawn
and finding each 8 KB half exactly once in the built disc:

    $4000-$5FFF  <- Track 02 sectors 247-250    the cache at $5B80
    $6000-$7FFF  <- Track 02 sectors 251-254    scene VM + our cave

Usage
-----
    python patch_title_cache_wipe.py                 0.3.7 -> EXPERIMENT
    python patch_title_cache_wipe.py --verify        check, write nothing
"""
from __future__ import annotations

import argparse
import json
import shutil
from datetime import datetime
import sys
from pathlib import Path

STATIC = Path(__file__).resolve().parent
ROOT = STATIC.parents[2]
sys.path.insert(0, str(STATIC))

from build_disc_patch import rebuild_mode1_sector  # noqa: E402

RAW_SECTOR = 2352
USER_OFFSET = 16
USER_SIZE = 2048

OVERLAY_SECTOR = 251          # $6000-$7FFF comes from sectors 251-254
OVERLAY_BASE = 0x6000
WINDOW_SHIFT = 0x4000         # cave address ($A000 window) -> $6000 window

TRACK02_GLOB = "*(Track 02)*.bin"
SYMBOLS = "helper_symbols.json"
STUB_LABEL = "title_cache_wipe"

TABLE_ENTRY = 0x7331          # scene-VM handler table, opcode 2
SPAWN_HANDLER = 0x73BD

EXPECT_TABLE = bytes([SPAWN_HANDLER & 0xFF, SPAWN_HANDLER >> 8])


def raw_offset(cpu_addr: int) -> int:
    """CPU address in the $6000-$7FFF overlay -> byte offset in the raw track."""
    if not OVERLAY_BASE <= cpu_addr < OVERLAY_BASE + 0x2000:
        raise ValueError(f"${cpu_addr:04X} is outside the overlay window")
    user = (OVERLAY_SECTOR * USER_SIZE) + (cpu_addr - OVERLAY_BASE)
    return (user // USER_SIZE) * RAW_SECTOR + USER_OFFSET + (user % USER_SIZE)


def read_at(data: bytes, cpu_addr: int, length: int) -> bytes:
    start = raw_offset(cpu_addr)
    return data[start:start + length]


def write_at(data: bytearray, cpu_addr: int, payload: bytes) -> int:
    start = raw_offset(cpu_addr)
    data[start:start + len(payload)] = payload
    return start // RAW_SECTOR


def find_one(directory: Path, pattern: str) -> Path:
    matches = sorted(directory.glob(pattern))
    if len(matches) != 1:
        raise SystemExit(
            f"expected one {pattern} in {directory}, found {len(matches)}")
    return matches[0]


def stub_address(source: Path) -> int:
    symbols_path = source / SYMBOLS
    if not symbols_path.exists():
        raise SystemExit(f"{symbols_path} is missing -- rebuild stage 3")
    labels = json.loads(symbols_path.read_text(encoding="utf-8")).get("labels", {})
    if STUB_LABEL not in labels:
        raise SystemExit(
            f"{SYMBOLS} has no '{STUB_LABEL}' label.  This build predates the "
            "stub; rebuild with the current build_ac_dynamic_0_1_14.py.")
    return int(labels[STUB_LABEL], 16)


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source", default=str(ROOT / "build" / "patch" / "0.3.7"))
    parser.add_argument("--tag", default=None,
                        help="experiment name.  It goes in the output folder "
                             "AND in the .cue filename, so Mesen's title bar "
                             "says which build is running.  Defaults to a "
                             "timestamp -- every build gets its own name.")
    parser.add_argument("--out", default=None)
    parser.add_argument("--verify", action="store_true",
                        help="check the source disc and write nothing")
    args = parser.parse_args()

    source = Path(args.source)
    if not source.is_dir():
        raise SystemExit(f"source build not found: {source}")
    track02 = find_one(source, TRACK02_GLOB)
    data = bytearray(track02.read_bytes())

    cave_addr = stub_address(source)
    target = cave_addr - WINDOW_SHIFT
    new_table = bytes([target & 0xFF, target >> 8])

    print(f"source   {track02}")
    print(f"stub     {STUB_LABEL} at ${cave_addr:04X} "
          f"(${target:04X} while MPR3=$69)")
    print(f"table    ${TABLE_ENTRY:04X}  ${SPAWN_HANDLER:04X} -> ${target:04X}")

    table = read_at(bytes(data), TABLE_ENTRY, 2)
    if table == new_table:
        raise SystemExit("  STOP: already patched")
    if table != EXPECT_TABLE:
        raise SystemExit(
            f"  STOP: table entry is {table.hex(' ')}, "
            f"expected {EXPECT_TABLE.hex(' ')} (${SPAWN_HANDLER:04X})")
    if not OVERLAY_BASE <= target < OVERLAY_BASE + 0x2000:
        raise SystemExit(
            f"  STOP: ${target:04X} is outside the overlay window -- the cave "
            "moved, or WINDOW_SHIFT is wrong")
    print("  preconditions ok")

    if args.verify:
        print("--verify: nothing written")
        return

    sector = write_at(data, TABLE_ENTRY, new_table)
    start = sector * RAW_SECTOR
    chunk = bytearray(data[start:start + RAW_SECTOR])
    rebuild_mode1_sector(chunk)
    data[start:start + RAW_SECTOR] = chunk
    print(f"  rebuilt EDC/ECC for sector {sector}")

    tag = args.tag or datetime.now().strftime("%m%d-%H%M")
    # Name the output after the source build, not after a hardcoded 0.3.7 --
    # that default silently mislabelled anything built from another version.
    # Beside the source, not at a fixed place: builds after 0.3.8.2 live under
    # EXPERIMENT, and the patched disc belongs next to the build it came from.
    out = Path(args.out) if args.out else (source.parent / f"{source.name}-{tag}")
    out.mkdir(parents=True, exist_ok=True)
    for item in sorted(source.iterdir()):
        if item == track02:
            continue
        if item.is_dir():
            shutil.copytree(item, out / item.name, dirs_exist_ok=True)
        else:
            shutil.copy2(item, out / item.name)
    (out / track02.name).write_bytes(bytes(data))

    # Mesen's title bar shows the cue's name, and every build so far has been
    # called "[KO 0.3.7]" -- there was no way to tell which experiment was on
    # screen.  Retag the cue (it points at the .bin files, nothing points at it).
    cue = find_one(out, "*.cue")
    tagged = cue.with_name(cue.stem + f" ({tag})" + cue.suffix)
    cue.rename(tagged)

    print(f"\nwrote    {out / track02.name}")
    print(f"         {tagged.name}   <- open this one")


if __name__ == "__main__":
    main()
