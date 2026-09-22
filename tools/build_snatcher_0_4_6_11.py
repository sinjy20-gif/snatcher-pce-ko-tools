#!/usr/bin/env python3
"""Snatcher KO 0.4.6.11: consume the native subtitle trigger fingerprint.

0.4.6.10's resident recognized the one translated voice by the game's
$22A6/$22A7/$22AA ADPCM end fingerprint.  The game does not clear that
fingerprint when the voice ends, so later unrelated voices repeatedly looked
like the same subtitle and could enter the subtitle controller while their
own ADPCM IRQ wait was active.  The result was the confirmed freeze at
008FA4.

After accepting the genuine E6800_0E trigger, clear $22A7.  The subtitle
state has already advanced to 1, so the current subtitle proceeds normally;
when it later returns to idle, the stale fingerprint can no longer retrigger.
SUB 0.4.22 proved this exact STZ $22A7 operation at runtime without an
emulator-side playback-key guard.

The reception repair below is otherwise unchanged from 0.4.6.10.

Three defects across 0.4.6.7 and 0.4.6.8, all fixed here.

Defect C -- the guard could never match, so neither 0.4.6.7 nor 0.4.6.8 ever
armed.  Both sampled $3471/$3472 after JSR $5E40.  But $5E40 is not a plain
character fetch: it carries the game's own reception test at $5E5E-$5E76
(CMP #$34 / CMP #$99 / CMP #$9A) and, leaving that branch, overwrites the
pointer with $5B90 at $5F8A-$5F93.  After the call the pointer is therefore
$5B90, never $3499/$349A.  SUB 0.3.24, the POC that worked, sampled at the
$66E5 exec -- before the call.  0.4.6.10 does the same.  Confirmed at runtime
by SUB 0.3.30: $66F8 still read 4C 3F 68 when it executed.

Defect A -- TAM #$80 swaps BIOS bank 1 over $E000-$FFFF, where the IRQ vector
table lives; bank 1 is blank, so an interrupt taken during the bank-1 window
vectored to $FFFF.  This is what actually crashed 0.4.6.7 at reception.  Fix:
the bank-0 stub does PHP/SEI before the switch and the exit lands on bank 0's
existing PLA/PLP/RTS at $F050, restoring A and the caller's I flag.  0.4.6.8
carried this fix and ran the whole game without crashing, which also shows
$5E40 never reaches into $E000-$FFFF itself.

Defect B -- latent, never actually reached because of C.  The dispatch told
"repair" from "hook" by reading the self-modified $66F9, but $66E5 is the
per-character entry, so the next character of the same string would re-enter
and take the repair branch with the wrong stack contract.  Fix: arming also
restores $66E5 to its original JSR $5E40, so while armed only the
end-of-string $66F8 path can reach bank 1.  The repair restores both hooks.

The 512-byte clean image is unchanged from the one SUB 0.3.24 proved.
"""
from __future__ import annotations

import hashlib
import json
import os
import sys
from pathlib import Path


os.environ["SNATCHER_BUILD_VERSION"] = "0.4.6.11"
ROOT = Path(__file__).resolve().parents[1]
sys.path[:0] = [str(ROOT / "tools"), str(ROOT / "extraction" / "patch" / "static")]

import build_snatcher_0_4_6_0 as base  # noqa: E402
import build_disc_patch as common  # noqa: E402
import build_disc_subtitle_hook as rawdisc  # noqa: E402


OUT = ROOT / "build" / "patch" / "0.4.6.11"
BIOS = OUT / "Syscard3_galmuri_0.4.6.11.pce"
TRACK02_NAME = "Snatcher CD-ROMantic (Japan) (Track 02) [KO].bin"

BIOS_CPU = 0xE000
ALT_BANK = 0x01

# bank-0 stub: PHP / SEI / LDA #$01 / TAM #$80  (6 B in the 8 B cave).
# TAM lands execution at STUB+6 with bank 1 already mapped.
STUB = 0xFFD4
STUB_LAND = STUB + 6          # $FFDA, bank 1, holds JMP dispatch

# bank-1 exit bridge: TAM #$80 back to bank 0, landing on bank 0's existing
# PLA / PLP / RTS.  That restores A, then P (and with it I), then returns.
EXIT_BRIDGE = 0xF04E
EPILOGUE = 0xF050             # bank 0 bytes 68 28 60

REPAIR_CAVE = 0xF054

RENDERER_HOOK = 0x66E5        # JSR $5E40 -> JSR $FFD4
RENDERER_EXIT = 0x66F8        # JMP $683F, redirected to JMP $FFD4 while armed
NORMAL_FETCH = 0x5E40         # still reachable: it lives under MPR2

ORIGINAL_HOOK = bytes((0x20, 0x40, 0x5E))
ORIGINAL_EXIT = bytes((0x4C, 0x3F, 0x68))
EPILOGUE_BYTES = bytes((0x68, 0x28, 0x60))


STATE_MAGIC = base.boot.TRANSLATION_MAGIC + bytes(range(base.boot.TRANSLATION_PACKS))
STATE_BYTES = len(STATE_MAGIC)


def build_loader(rows):
    """0.4.6.0's loader with the one-shot guard moved off the AC port latch.

    0.4.6.4 through 0.4.6.9 wrote a magic byte into Arcade Card port-3's base
    address latch ($1A32) and read it back to decide "already preloaded".  That
    latch has no connection to the payload it guards, and it is not cleared by
    a console reset in several emulator cores.  Observed on RetroArch:

        0.4.6.4 first boot   long load, Korean text  (preload ran)
        0.4.6.4 after reset  no load, straight to title, no translation
                             (latch survived, AC memory did not)

    The guard now reads the published state block back out of AC memory at
    $010000 instead.  That block is written only by the publish step, which
    runs only after all four payloads have loaded successfully, and the disc
    payload itself holds FF there -- so the magic is present if and only if a
    complete preload really happened.  If AC is cleared, the magic goes with
    it and the preload runs again, which is exactly what reset should do.

    Read-back is symmetric with the existing publish: both do LDA #$00 /
    JSR $BF32 and then walk $1A00.  $BF32 only programs port 0 ($1A02-$1A09),
    so it needs no window beyond the Bank69 helper already mapped here.
    """
    a = base.boot.collection.r3.base.Assembler(base.boot.collection.r3.base.CAVE)

    # --- resident decision entry at $FEC4 ---
    a.abs(0xAD, base.STATE); a.emit(0xC9, 0xFF); a.branch(0xF0, "resident_reset")
    a.emit(0xC9, 0xFE); a.branch(0xF0, "resident_idle")
    a.emit(0xC9, 0x02); a.branch(0xF0, "resident_active")
    a.emit(0xC9, 0x00); a.branch(0xD0, "resident_ret")
    a.abs(0xAD, 0x22A6); a.branch(0xD0, "resident_idle")
    a.abs(0xAD, 0x22A7); a.emit(0xC9, 0x68); a.branch(0xD0, "resident_idle")
    a.abs(0xAD, 0x22AA); a.emit(0xC9, 0x0E); a.branch(0xD0, "resident_idle")
    a.abs(0xAD, 0x180D); a.emit(0x29, 0x20); a.branch(0xF0, "resident_idle")
    a.emit(0xA9, 1); a.abs(0x8D, base.STATE)
    # Consume the matched E6800_0E fingerprint.  The game leaves these ADPCM
    # end bytes stale across later playback sessions; without this, 008FA4
    # falsely starts the same subtitle again and deadlocks in its IRQ wait.
    a.abs(0x9C, 0x22A7)
    a.emit(0x60)
    a.label("resident_active")
    a.abs(0xAD, 0x180D); a.emit(0x29, 0x20); a.branch(0xD0, "resident_still")
    a.emit(0xA9, 3); a.abs(0x8D, base.STATE); a.emit(0x60)
    a.label("resident_still"); a.emit(0xA9, 2, 0x60)
    a.label("resident_reset"); a.abs(0x9C, base.STATE)
    a.label("resident_idle"); a.emit(0xA9, 0)
    a.label("resident_ret"); a.emit(0x60)

    # --- early CD_READ wrapper, unchanged from 0.4.6.0 ---
    a.label("boot_hook")
    a.emit(0x48)
    a.emit(0x43, base.MPR5, 0xC9, base.HELPER_BANK); a.branch(0xD0, "ordinary_read")
    a.emit(0x43, base.MPR6, 0xC9, base.REENTRY_BANK); a.branch(0xD0, "ordinary_read")
    a.emit(0x68); a.abs(0x4C, base.ORIGINAL_CD_READ)
    a.label("ordinary_read")
    a.emit(0x68); a.abs(0x20, base.ORIGINAL_CD_READ)
    a.emit(0x08, 0x48, 0xDA, 0x5A)
    # boot_done is past relative-branch range, so the error path needs JMP.
    a.emit(0xC9, 0); a.branch(0xF0, "cd_read_ok")
    a.abs(0x4C, "boot_done")
    a.label("cd_read_ok")
    a.emit(0x78)

    a.emit(0x43, base.MPR5, 0x48, 0x43, base.MPR6, 0x48)
    a.emit(0xA9, base.HELPER_BANK, 0x53, base.MPR5)
    for offset, value in enumerate((0x20, 0x12)):
        a.abs(0xAD, base.LOAD_BLOB + offset); a.emit(0xC9, value)
        a.branch(0xD0, "bail")

    # --- the guard, rebuilt: read the published state block out of AC ---
    # Looped rather than unrolled; the cave is 280 B and the old unrolled form
    # of this plus the publish below overran it.
    a.emit(0xA9, 0x00); a.abs(0x20, base.SET_STATE_ADDRESS)
    a.emit(0xA2, 0x00)                                   # LDX #0
    a.label("guard_loop")
    a.abs(0xAD, base.boot.AC_DATA)                       # LDA $1A00
    a.abs(0xDD, "state_table")                           # CMP state_table,X
    a.branch(0xD0, "preload_needed")
    a.emit(0xE8, 0xE0, STATE_BYTES)                      # INX / CPX #6
    a.branch(0xD0, "guard_loop")
    # Every byte matched: a complete preload is already in AC.  Fall through.
    # restore_windows remains within BRA range.  Using BRA here recovers one
    # byte needed by the three-byte fingerprint consume operation above.
    a.label("bail"); a.branch(0x80, "restore_windows")

    a.label("preload_needed")
    a.emit(0xA9, base.REENTRY_BANK, 0x53, base.MPR6)

    # Y는 load_one 안에서 정확히 8 증가한다. 고정 4행을 나열하지 않고 rows
    # 전체를 순회하면 native bundle 같은 후속 payload를 BIOS 코드 증가 없이
    # 선적재할 수 있다.
    if not rows or len(rows) * 8 > 0xFF:
        raise SystemExit(f"preload row count out of range: {len(rows)}")
    a.emit(0xA0, 0x00)
    a.label("preload_loop")
    a.abs(0x20, "load_one"); a.branch(0xD0, "load_failed")
    a.emit(0xC0, len(rows) * 8); a.branch(0xD0, "preload_loop")

    # Publish the state block.  This is now also what the guard reads, so the
    # "already loaded" answer and the thing that makes it true are one fact.
    a.emit(0xA9, 0); a.abs(0x20, base.SET_STATE_ADDRESS)
    a.emit(0xA2, 0x00)                                   # LDX #0
    a.label("publish_loop")
    a.abs(0xBD, "state_table")                           # LDA state_table,X
    a.abs(0x8D, base.boot.AC_DATA)                       # STA $1A00
    a.emit(0xE8, 0xE0, STATE_BYTES)                      # INX / CPX #6
    a.branch(0xD0, "publish_loop")
    # (0.4.6.4-0.4.6.9 wrote the $1A32 latch here; nothing replaces it.)
    # load_failed and restore_windows are consecutive labels, so successful
    # publish can fall through too.  The old BRA-to-next-instruction wasted
    # two bytes; removing it supplies the other two bytes required above.
    a.label("load_failed")
    a.label("restore_windows")
    a.emit(0x68, 0x53, base.MPR6, 0x68, 0x53, base.MPR5)
    a.label("boot_done")
    a.emit(0x7A, 0xFA, 0x68, 0x28, 0x60)

    a.label("load_one"); a.emit(0xA2, 0)
    a.label("load_copy"); a.abs(0xB9, "load_table"); a.emit(0x9D); a.word(base.VARS)
    a.emit(0xC8, 0xE8, 0xE0, 8); a.branch(0xD0, "load_copy")
    # LOAD_BLOB의 반환 규약은 A의 성공/실패 값만 보장하고 Y 보존은 보장하지
    # 않는다. preload_loop가 다음 8 B 행을 가리키려면 복사 뒤의 Y를 지켜야 한다.
    # PHY는 플래그를 바꾸지 않지만 PLY는 N/Z를 바꾼다. 호출자는 BNE로 실패를
    # 판정하므로 PLY 뒤 CMP #0으로 LOAD_BLOB의 A 결과에 맞춰 Z를 복원한다.
    a.emit(0x5A)                                         # PHY
    a.abs(0x20, base.LOAD_BLOB)
    a.emit(0x7A, 0xC9, 0x00, 0x60)                       # PLY / CMP #0 / RTS
    a.label("load_table")
    for row in rows:
        sector, dest = row["relative_sector"], row["destination"]
        a.emit(sector & 0xFF, sector >> 8, row["full_chunks"], row["final_sectors"],
               dest & 0xFF, (dest >> 8) & 0xFF, (dest >> 16) & 0xFF, 0)
    # The published state block, shared by the guard and the publish step so
    # the two can never disagree about what "already loaded" looks like.
    a.label("state_table")
    a.emit(*STATE_MAGIC)
    code = a.finish()
    base.BOOT_HOOK = a.labels["boot_hook"]
    base.LOADER_LABELS = dict(a.labels)
    return code


def build_code() -> tuple[bytes, dict[str, int]]:
    Assembler = base.boot.collection.r3.base.Assembler
    a = Assembler(REPAIR_CAVE)

    # Both entries arrive with P pushed and bank 1 mapped.  $66E5 arrives via
    # JSR (return address below P); $66F8 arrives via JMP (no return address
    # of its own -- exactly like the JMP $683F it replaces, $683F being a bare
    # RTS).  Either way the exit is PHA / LDA #0 / TAM, so the epilogue's
    # PLA / PLP / RTS unwinds the correct number of bytes.
    a.label("dispatch")
    a.abs(0xAD, RENDERER_EXIT + 1); a.emit(0xC9, STUB & 0xFF)
    a.branch(0xF0, "repair")

    # ---- hook path ----
    # The guard MUST run before JSR $5E40.  $5E40 carries the game's own
    # reception test at $5E5E-$5E76 (CMP #$34 / CMP #$99 / CMP #$9A) and, on
    # the way out of that branch, overwrites the pointer:
    #     $5F8A  LDA #$90 / STA $3471
    #     $5F8F  LDA #$5B / STA $3472
    # Reading $3471/$3472 after the call therefore sees $5B90 and never
    # $3499/$349A.  0.4.6.7 and 0.4.6.8 both read it after the call, so
    # neither of them ever armed.  SUB 0.3.24, the POC that worked, sampled
    # the pointer at the $66E5 exec -- before the call -- and that is what
    # this now matches.
    a.label("hook")
    a.abs(0xAD, 0x3472); a.emit(0xC9, 0x34)
    a.branch(0xD0, "fetch")
    a.abs(0xAD, 0x3471)
    a.emit(0xC9, 0x99); a.branch(0xF0, "arm")
    a.emit(0xC9, 0x9A); a.branch(0xD0, "fetch")

    a.label("arm")
    # Redirect the end-of-string exit to the stub ...
    a.emit(0xA9, STUB & 0xFF); a.abs(0x8D, RENDERER_EXIT + 1)
    a.emit(0xA9, STUB >> 8); a.abs(0x8D, RENDERER_EXIT + 2)
    # ... and unhook $66E5 for the duration.  Without this, the next character
    # of the very same string re-enters here and falls into "repair" with the
    # wrong stack.  That is what crashed 0.4.6.7.
    a.emit(0xA9, ORIGINAL_HOOK[1]); a.abs(0x8D, RENDERER_HOOK + 1)
    a.emit(0xA9, ORIGINAL_HOOK[2]); a.abs(0x8D, RENDERER_HOOK + 2)

    # Now do what $66E5 came here to do, for this character too.
    a.label("fetch")
    a.abs(0x20, NORMAL_FETCH)                 # JSR $5E40 -> A = fetched byte
    a.emit(0x48)                              # PHA: this is what PLA restores
    a.emit(0xA9, 0x00); a.abs(0x4C, EXIT_BRIDGE)

    # ---- repair path: reached only from $66F8, only while armed ----
    a.label("repair")
    a.emit(0xDA, 0x5A)                        # PHX / PHY
    # Put both hooks back before touching anything else, so a fault later
    # cannot leave the renderer permanently redirected.
    a.emit(0xA9, ORIGINAL_EXIT[1]); a.abs(0x8D, RENDERER_EXIT + 1)
    a.emit(0xA9, ORIGINAL_EXIT[2]); a.abs(0x8D, RENDERER_EXIT + 2)
    a.emit(0xA9, STUB & 0xFF); a.abs(0x8D, RENDERER_HOOK + 1)
    a.emit(0xA9, STUB >> 8); a.abs(0x8D, RENDERER_HOOK + 2)

    # Mesen byte VRAM $2C00 is VDC word $1600.  Sixteen 32-byte rows: every
    # fourth row is empty, the others open with $FFFF; rows 0..2 continue with
    # fifteen $8000 words, rows 3..15 with fifteen zero words.
    a.emit(0x03, 0x00, 0x13, 0x00, 0x23, 0x16)   # ST0/ST1/ST2 -> MAWR $1600
    a.emit(0x03, 0x02)                            # ST0 -> select VWR
    a.emit(0xA2, 0x00)                            # LDX #0 (row)
    a.label("row")
    a.emit(0x8A, 0x29, 0x03, 0xC9, 0x03)
    a.branch(0xF0, "empty_head")
    a.emit(0xA9, 0xFF); a.abs(0x8D, 0x0002); a.abs(0x8D, 0x0003)
    a.branch(0x80, "tail_select")
    a.label("empty_head")
    a.emit(0x9C); a.word(0x0002); a.emit(0x9C); a.word(0x0003)
    a.label("tail_select")
    a.emit(0xA0, 0x0F, 0xE0, 0x03)
    a.branch(0xB0, "zero_tail")
    a.label("pattern_tail")
    a.emit(0x9C); a.word(0x0002)
    a.emit(0xA9, 0x80); a.abs(0x8D, 0x0003)
    a.emit(0x88); a.branch(0xD0, "pattern_tail")
    a.branch(0x80, "next_row")
    a.label("zero_tail")
    a.emit(0x9C); a.word(0x0002); a.emit(0x9C); a.word(0x0003)
    a.emit(0x88); a.branch(0xD0, "zero_tail")
    a.label("next_row")
    a.emit(0xE8, 0xE0, 0x10); a.branch(0xD0, "row")

    a.emit(0x7A, 0xFA)                        # PLY / PLX
    a.emit(0x48)                              # PHA: placeholder for the PLA
    a.emit(0xA9, 0x00); a.abs(0x4C, EXIT_BRIDGE)

    return a.finish(), dict(a.labels)


def raw_offset(cpu: int) -> tuple[int, int]:
    iso = common.bank6a_iso(cpu)
    sector, within = divmod(iso, rawdisc.USER_SIZE)
    return sector, sector * rawdisc.RAW_SECTOR + rawdisc.USER_OFFSET + within


def patch_track02(path: Path) -> list[int]:
    data = bytearray(path.read_bytes())

    sector, at = raw_offset(RENDERER_HOOK)
    got = bytes(data[at:at + 3])
    if got != ORIGINAL_HOOK:
        raise SystemExit(f"$66E5 mismatch: expected {ORIGINAL_HOOK.hex(' ')}, got {got.hex(' ')}")
    data[at:at + 3] = bytes((0x20, STUB & 0xFF, STUB >> 8))

    # $66F8 stays JMP $683F on disc; only the running game rewrites it.
    exit_sector, exit_at = raw_offset(RENDERER_EXIT)
    got = bytes(data[exit_at:exit_at + 3])
    if got != ORIGINAL_EXIT:
        raise SystemExit(f"$66F8 mismatch: expected {ORIGINAL_EXIT.hex(' ')}, got {got.hex(' ')}")

    touched = sorted({sector, exit_sector})
    for item in touched:
        start = item * rawdisc.RAW_SECTOR
        raw = bytearray(data[start:start + rawdisc.RAW_SECTOR])
        rawdisc.rebuild_mode1_sector(raw)
        data[start:start + rawdisc.RAW_SECTOR] = raw
    path.write_bytes(data)
    return touched


def blank(image: bytearray, offset: int, length: int) -> bool:
    return image[offset:offset + length] == bytes((0xFF,)) * length


def main() -> None:
    # base.main() does `boot.build_loader = build_loader`, resolving that name
    # from base's globals, so replacing it here is what installs the new guard.
    base.build_loader = build_loader
    base.main()
    code, labels = build_code()

    image = bytearray(BIOS.read_bytes())
    alt = ALT_BANK * 0x2000

    # The epilogue is existing BIOS code, not a cave; verify it is what we
    # think before routing returns through it.
    epi_at = EPILOGUE - BIOS_CPU
    if bytes(image[epi_at:epi_at + 3]) != EPILOGUE_BYTES:
        raise SystemExit(
            f"BIOS bank 0 ${EPILOGUE:04X} is not PLA/PLP/RTS: "
            f"{bytes(image[epi_at:epi_at + 3]).hex(' ')}"
        )

    stub = bytes((0x08, 0x78, 0xA9, ALT_BANK, 0x53, 0x80))  # PHP/SEI/LDA/TAM
    stub_at = STUB - BIOS_CPU
    if not blank(image, stub_at, 8):
        raise SystemExit(f"BIOS bank 0 stub cave ${STUB:04X} is not blank")
    image[stub_at:stub_at + len(stub)] = stub

    land_at = alt + STUB_LAND - BIOS_CPU
    land = bytes((0x4C, labels["dispatch"] & 0xFF, labels["dispatch"] >> 8))
    if not blank(image, land_at, 3):
        raise SystemExit(f"bank {ALT_BANK:02X} landing bridge ${STUB_LAND:04X} is not blank")
    image[land_at:land_at + 3] = land

    bridge_at = alt + EXIT_BRIDGE - BIOS_CPU
    if not blank(image, bridge_at, 2):
        raise SystemExit(f"bank {ALT_BANK:02X} exit bridge ${EXIT_BRIDGE:04X} is not blank")
    image[bridge_at:bridge_at + 2] = bytes((0x53, 0x80))  # TAM #$80 -> bank 0

    code_at = alt + REPAIR_CAVE - BIOS_CPU
    if not blank(image, code_at, len(code)):
        raise SystemExit(f"bank {ALT_BANK:02X} code cave ${REPAIR_CAVE:04X} is not blank")
    if REPAIR_CAVE <= EXIT_BRIDGE < REPAIR_CAVE + len(code):
        raise SystemExit("code cave overlaps the exit bridge")
    image[code_at:code_at + len(code)] = code

    BIOS.write_bytes(image)
    bios_hash = hashlib.sha256(image).hexdigest().upper()

    bios_info_path = OUT / "bios_preload.json"
    bios_info = json.loads(bios_info_path.read_text(encoding="utf-8"))
    bios_info["sha256"] = bios_hash.lower()
    bios_info["bios_sha256"] = bios_hash
    bios_info["reception_repair_bank"] = f"{ALT_BANK:02X}"
    bios_info["reception_repair_entry"] = f"{labels['repair']:04X}"
    bios_info_path.write_text(
        json.dumps(bios_info, ensure_ascii=False, indent=2), encoding="utf-8"
    )

    track02 = OUT / TRACK02_NAME
    touched = patch_track02(track02)

    manifest_path = OUT / "manifest.json"
    manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
    manifest.update({
        "subtitle_trigger_fix": "consume E6800_0E fingerprint after genuine start",
        "subtitle_trigger_consume": "STZ $22A7 immediately after STATE=1",
        "subtitle_trigger_proof": "SUB 0.4.22 runtime success; 008FA4 progressed",
        "reception_repair": "SUB 0.3.24 exact clean pattern, native reception-only",
        "reception_guard": "$3471/$3472 == $3499/$349A at $66E5",
        "reception_hook": f"66E5->{STUB:04X} -> bank {ALT_BANK:02X}:{labels['dispatch']:04X}",
        "reception_exit_hook": f"66F8->{STUB:04X} while armed only",
        "reception_repair_entry": f"{labels['repair']:04X}",
        "reception_repair_bytes": len(code),
        "reception_vram": "Mesen byte $2C00-$2DFF / VDC word $1600-$16FF",
        "fixed_vs_0467": [
            "guard now sampled BEFORE JSR $5E40; $5E40 rewrites $3471/$3472 to $5B90",
            "arming unhooks $66E5 so re-entry cannot take the repair stack path",
            "PHP/SEI around the bank-1 window; exit via bank0 $F050 PLA/PLP/RTS",
        ],
        "track02_rebuilt_sectors": touched,
        "bios_sha256": bios_hash,
        "track02_sha256": hashlib.sha256(track02.read_bytes()).hexdigest().upper(),
    })
    manifest["bios_preload"] = bios_info
    manifest_path.write_text(
        json.dumps(manifest, ensure_ascii=False, indent=2), encoding="utf-8"
    )

    print("\n0.4.6.11 subtitle trigger consume + reception repair")
    print(f"  bank 0 ${STUB:04X}: {stub.hex(' ').upper()}  -> land ${STUB_LAND:04X}")
    print(f"  bank {ALT_BANK:02X} ${REPAIR_CAVE:04X}: {len(code)} B; "
          f"dispatch ${labels['dispatch']:04X} repair ${labels['repair']:04X}")
    print(f"  exit bridge ${EXIT_BRIDGE:04X} -> bank 0 ${EPILOGUE:04X} PLA/PLP/RTS")
    print(f"  Track02 sectors rebuilt: {touched}")
    print(f"  -> {OUT}")


if __name__ == "__main__":
    main()
