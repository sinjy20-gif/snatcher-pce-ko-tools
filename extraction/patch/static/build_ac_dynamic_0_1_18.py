#!/usr/bin/env python3
"""Build ac_0.1.18: move the one-time AC initialisation off the reception screen.

The problem this solves is where the wait happens, not how long it is
--------------------------------------------------------------------
ac_0.1.14 loads in 5.28 s, and UI 0.1.74 showed the initialisation firing at
frame 3330 - that is, at the reception itself.  The player stands in front of a
finished, static scene and waits.  A five second wait behind a scene transition
would barely register; the same wait while staring at the reception desk is the
worst possible place for it.

    directory   65,536 B   1.88 s   once ever
    residents   45,952 B   1.32 s   once ever
    atlas       22,944 B   0.66 s   once ever
    scene pack  28,672 B   0.82 s   per scene    <- this part is already fine

Everything except the scene pack is one-time work that has no reason to happen
at the reception.  This build makes it happen at the first text render of the
session instead, which is the unskippable chapter-1 opening.

How, without spending a byte
----------------------------
$66E5 fires for every rendered token, Japanese included; the preloader gate
simply rejects the ones that are not Korean.  So the gate's reject path already
runs during the opening - long before any Korean lookup.  Its last instruction
is a three-byte `JMP done`, and the preloader executes with bank $6A mapped, so
that jump can be redirected into Bank 6A and back at no size cost:

    $5E78   4C E6 5F   JMP $5FE6      ->   4C 9C 7F   JMP $7F9C

The $7F88 trampoline slot is 100 bytes of the original CD loader but the
trampoline itself is only 20, leaving $7F9C-$7FEB free.  The redirect target
lives there:

    $7F9C   LDA #<probe / STA $7FEF      point the lookup at an empty slot
            LDA #>probe / STA $7FF0
            JSR $7F88                    trampoline -> helper -> init if needed
            JMP $5FE6                    continue exactly as before

There is deliberately no "already done" flag.  The helper already guards itself
with the AC magic word, so a repeat call costs a bank switch and a handful of
port reads and then returns.  More importantly, that makes the trigger
self-healing: if the very first attempt fails because the CD subsystem is not
ready yet, the next rendered token simply tries again.  A local flag would latch
the failure permanently.

Why the lookup is aimed at an empty slot
----------------------------------------
After initialising, the helper falls through to its normal lookup using the slot
the preloader left at $7FEF/$7FF0.  On this path no hash was computed, so those
bytes are stale.  Pointing them at a slot the directory never fills makes the
lookup take the clean `return_miss` path: no pack load, no cache write, no
record copied over $5B80-$5E3F.

Safety
------
This is the highest blast radius change in the AC series so far, because the
reject path runs for every non-Korean token rather than only during Korean
rendering.  Three things make it safe, all verified against the built image
rather than assumed:

    `done` at $5FE6 opens with LDX #0, so it does not care that the helper
    clobbered X or Y
    `done` pops the BIOS zero page $F8-$FF that it pushed on entry, so the
    helper's use of those bytes is undone exactly as on the normal path
    JSR/RTS and the helper's PHA/PLA are balanced, so the stack `done` unwinds
    is the stack the preloader pushed

Nothing else changes: same compact records, same atlas, same 8 KiB chunks, same
directory.  If this breaks, it breaks visibly and everywhere, and ac_0.1.14 is
the fallback.
"""

from __future__ import annotations

import csv
import json
import shutil
import sys
from pathlib import Path


ROOT = Path(r"C:\snatcher")
STATIC = ROOT / "extraction" / "patch" / "static"
sys.path.insert(0, str(STATIC))

import build_ac_dynamic_0_1_14 as compact  # noqa: E402
import build_disc_patch as common  # noqa: E402
import build_speaker_ui_proof as proof  # noqa: E402


assignment = compact.assignment
dynamic = compact.dynamic

VERSION = "ac_0.1.18"
TRIGGER = 0x7F9C            # first free byte after the 20-byte trampoline
PRELOADER = 0x5E40
PRELOADER_BYTES = 448
RAW, HDR, USER = 2352, 16, 2048

compact.PORT_POC = False
compact.CHUNK_BYTES = 0x2000
dynamic.CHUNK_BYTES = 0x2000
dynamic.VERSION = VERSION
dynamic.OUT = ROOT / "build" / "patch" / VERSION


def find_reject(code: bytes) -> tuple[int, int]:
    """Return (offset of the gate's `JMP done`, the done address)."""
    gate = code.find(bytes((0xC9, 0x34, 0xF0)))
    if gate < 0:
        raise RuntimeError("gate signature CMP #$34 / BEQ not found in the preloader")
    tail = code.find(bytes((0xC9, 0x9A, 0xF0)), gate)
    if tail < 0:
        raise RuntimeError("gate signature CMP #$9A / BEQ not found")
    reject = tail + 4
    if code[reject] != 0x4C:
        raise RuntimeError(
            f"expected JMP at the gate's reject path, found {code[reject]:02X}")
    return reject, code[reject + 1] | (code[reject + 2] << 8)


def build_trigger(done: int, probe_slot: int) -> bytes:
    probe = dynamic.DIRECT_RELATIVE + probe_slot
    a = common.Assembler(TRIGGER)
    a.emit(0xA9, probe & 0xFF); a.abs(0x8D, 0x7FEF)
    a.emit(0xA9, probe >> 8); a.abs(0x8D, 0x7FF0)
    a.abs(0x20, dynamic.SECTOR_LOADER)
    a.abs(0x4C, done)
    return a.finish()


def first_empty_slot(directory: bytes) -> int:
    for slot in range(0x4000):
        if directory[slot * 4 + 3] == 0xFF:
            return slot
    raise RuntimeError("the directory has no empty slot to aim the probe at")


def patch_track02(path: Path, patches: list[tuple[int, bytes]]) -> set[int]:
    sectors: set[int] = set()
    with path.open("r+b") as handle:
        for cpu, data in patches:
            for index, value in enumerate(data):
                user = (common.bank68_iso(cpu + index) if cpu < 0x6000
                        else common.bank6a_iso(cpu + index))
                sectors.add(user // USER)
                handle.seek((user // USER) * RAW + HDR + (user % USER))
                handle.write(bytes((value,)))
        for sector in sorted(sectors):
            handle.seek(sector * RAW)
            raw = bytearray(handle.read(RAW))
            common.rebuild_mode1_sector(raw)
            handle.seek(sector * RAW)
            handle.write(bytes(raw))
    return sectors


if __name__ == "__main__":
    dynamic.main()

    track02 = next(p for p in dynamic.OUT.glob("*.bin") if "Track 02" in p.name)
    directory = (dynamic.OUT / "ac_dynamic_packs" / "slot_directory.bin").read_bytes()
    probe_slot = first_empty_slot(directory)

    preloader = bytes(proof.read_user_bytes(
        track02, common.bank68_iso(PRELOADER), PRELOADER_BYTES))
    reject, done = find_reject(preloader)
    reject_cpu = PRELOADER + reject

    trigger = build_trigger(done, probe_slot)
    slot_end = dynamic.SECTOR_LOADER + dynamic.LOADER_BYTES
    if TRIGGER + len(trigger) > slot_end:
        raise SystemExit(
            f"trigger ${TRIGGER:04X}-${TRIGGER + len(trigger) - 1:04X} overruns "
            f"the loader slot ending at ${slot_end - 1:04X}")
    existing = bytes(proof.read_user_bytes(track02, common.bank6a_iso(TRIGGER), len(trigger)))
    if set(existing) != {0xEA}:
        raise SystemExit(
            f"${TRIGGER:04X} is not trampoline padding: {existing.hex().upper()}")

    sectors = patch_track02(track02, [
        (reject_cpu, bytes((0x4C, TRIGGER & 0xFF, TRIGGER >> 8))),
        (TRIGGER, trigger),
    ])

    check_reject = bytes(proof.read_user_bytes(track02, common.bank68_iso(reject_cpu), 3))
    check_trigger = bytes(proof.read_user_bytes(track02, common.bank6a_iso(TRIGGER), len(trigger)))
    if check_reject != bytes((0x4C, TRIGGER & 0xFF, TRIGGER >> 8)) or check_trigger != trigger:
        raise SystemExit("post-patch read-back does not match what was written")

    manifest_path = dynamic.OUT / "manifest.json"
    manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
    manifest["early_trigger"] = {
        "purpose": "run the one-time AC init at the first rendered token, not at the reception",
        "reject_patched_at": f"{reject_cpu:04X}",
        "reject_was": f"JMP {done:04X}",
        "reject_now": f"JMP {TRIGGER:04X}",
        "trigger_at": f"{TRIGGER:04X}",
        "trigger_bytes": len(trigger),
        "trigger_code": trigger.hex().upper(),
        "returns_to": f"{done:04X}",
        "probe_slot": f"{probe_slot:04X}",
        "probe_value": f"{dynamic.DIRECT_RELATIVE + probe_slot:04X}",
        "preloader_size_change": 0,
        "resectored": sorted(f"{s:06X}" for s in sectors),
    }
    manifest["patched_track02_sha256"] = dynamic.sha256_file(track02)
    manifest["helper_free_bytes"] = compact.build_helper_compact.free_bytes
    manifest["chunk_bytes"] = compact.CHUNK_BYTES
    manifest["compact_records"] = {
        "record_bytes": compact.COMPACT_BYTES,
        "record_count": compact.build_packs_compact.record_count,
        "atlas_glyphs": compact.build_packs_compact.atlas_glyphs,
        "atlas_bytes": compact.build_packs_compact.atlas_bytes,
        "template_ac": f"{compact.TEMPLATE_AC:05X}",
        "atlas_ac": f"{compact.ATLAS_AC:05X}",
        "initial_cd_chunks": compact.build_packs_compact.init_chunks,
        "byte_exact_verified": compact.build_packs_compact.record_count,
    }
    manifest_path.write_text(
        json.dumps(manifest, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")

    with (dynamic.OUT / "runtime_scene_assignment.tsv").open(
            "w", encoding="utf-8-sig", newline="") as handle:
        fields = ("reference", "scene", "method", "runtime_seq", "scene_seq",
                  "sequence_distance", "catalog")
        writer = csv.DictWriter(handle, fieldnames=fields, delimiter="\t")
        writer.writeheader()
        writer.writerows(assignment.RUNTIME_EVIDENCE)
    shutil.copy2(
        ROOT / "snatcher_tool" / "translation" / "master_conflict_exclusions.tsv",
        dynamic.OUT / "master_conflict_exclusions.tsv")
    shutil.copy2(
        ROOT / "lua" / "UI 0.1.74.lua",
        dynamic.OUT / "UI 0.1.74.lua")

    print(f"\nreject   ${reject_cpu:04X}  JMP ${done:04X}  ->  JMP ${TRIGGER:04X}"
          f"   (preloader unchanged in size)")
    print(f"trigger  ${TRIGGER:04X}-${TRIGGER + len(trigger) - 1:04X}  {len(trigger)} B"
          f"   {trigger.hex().upper()}")
    print(f"probe    slot ${probe_slot:04X} (empty)  ->  $7FEF/$7FF0 = "
          f"${dynamic.DIRECT_RELATIVE + probe_slot:04X}")
    print(f"sectors  {sorted(f'{s:06X}' for s in sectors)}")
    print(f"track02  {manifest['patched_track02_sha256']}")
