#!/usr/bin/env python3
"""Build the SRT4 one-CD-read Korean overlay patch."""

from __future__ import annotations

import argparse
import csv
import hashlib
import json
import os
import shutil
import sys
from pathlib import Path

# 대사만 싣는 실험 스위치.  0.2.26 이 UI 없이 나갔고 그 판은 폐공장에서 끊기지
# 않았다는 소유자 기억을 같은 엔진에서 확인하기 위한 것이다.  기본값은 켜짐이라
# 평소 빌드는 영향을 받지 않는다.
INCLUDE_UI = os.environ.get("SNATCHER_INCLUDE_UI", "1") != "0"


ROOT = Path(r"C:\snatcher")
ROM_DIR = ROOT / "rom(japan)" / "Snatcher CD-ROMantic (Japan)"
SOURCE_TRACK02 = ROM_DIR / "Snatcher CD-ROMantic (Japan) (Track 02).bin"
SOURCE_TRACK24 = ROM_DIR / "Snatcher CD-ROMantic (Japan) (Track 24).bin"
BUILD_ROOT = ROOT / "build" / "patch"
# UI 확장판은 0.2.26 의 레이아웃을 덮어쓰지 않도록 별도 디렉터리를 쓴다.
LAYOUT_DIR = ROOT / "build" / "translation" / "current" / "runtime_layout_direct_ui"

STATIC_DIR = ROOT / "extraction" / "patch" / "static"
TRANSLATION_DIR = ROOT / "extraction" / "translation"
# Studio is the single writable translation workspace.  Building from the
# legacy C:\snatcher\translation mirror silently discarded edits made in the
# portable tool, which made already-reviewed dialogue appear to "revert".
STUDIO_TRANSLATION_DIR = ROOT / "snatcher_tool" / "translation"
UITEST_MASTER = STUDIO_TRANSLATION_DIR / "snatcher_ko_master.tsv"
sys.path[:0] = [str(STATIC_DIR), str(TRANSLATION_DIR)]

import build_direct_overlay_layout as layout  # noqa: E402
import build_disc_patch as common  # noqa: E402
import build_full_overlay_patch as srt3_patch  # noqa: E402
import build_speaker_ui_proof as proof  # noqa: E402
import build_track24_loader_proof as track24  # noqa: E402


EXPECTED_TRACK02_SHA256 = common.EXPECTED_SOURCE_SHA256
EXPECTED_TRACK24_SHA256 = track24.EXPECTED_TRACK24_SHA256
# 0.2.9 is the promoted final build of the user-verified 0.2.6 behavior.
# Its existing output directory intentionally prevents an accidental default
# rebuild from reintroducing the rejected 0.2.7/0.2.8 spacing experiments.
VERSION_DEFAULT = "0.3.0-uitest"

CACHE_BASE = 0x5B80
ASSET_TEXT = CACHE_BASE + layout.TEXT_OFFSET
# Verified SRT4 layout: cache $5B80-$5E3F, runtime $5E40-$5FFF.
RUNTIME_START = 0x5E40
RUNTIME_END = 0x6000

# --- the arena floor -------------------------------------------------------
#
# $5E40-$5FFF is NOT free space.  It reads as $FF on the disc because it is
# RAM the disc image never initialises, and the game bump-allocates scene
# objects through it.  handoff SNATCHER_AC_BASE_SLOTMAP_2026-08-18 section 15.
#
#   $4880  A9 00  LDA #$00 / STA $25      the resident engine sets the arena
#          A9 5C  LDA #$5C / STA $26      floor to $5C00 and grows UPWARD
#
# Joy Division's shopping screen needs 579 B.  With the preloader at $5E40 the
# arena only had $5C00-$5E3F = 576 B, so it overwrote the preloader's first
# byte (PHX, $DA) and the next JSR $5E40 executed $00 = BRK.  Three bytes.
#
# Moving the floor to $5B80 gives it 704 B.  That address is the game's own
# 704-byte record buffer base, and the table sitting there on the disc is
# overwritten by the first record render anyway, so nothing is lost.
#
# Nothing in banks $68/$69/$6A/scene reaches $5C00-$5FFF by absolute address --
# only through this $25/$26 pointer -- which is what makes the floor movable.
#
# This is a stopgap with a measured margin, not a proof: the arena's true
# maximum across the whole game is unknown (section 15.12, PROBE_ARENA).  If a
# screen ever needs more than 704 B the preloader has to leave bank $68.
ARENA_FLOOR_INIT = 0x4880
ARENA_FLOOR_OLD = 0x5C00
ARENA_FLOOR_NEW = CACHE_BASE
ARENA_MIN_BYTES = 704


def arena_floor_code(floor: int) -> bytes:
    """LDA #lo / STA $25 / LDA #hi / STA $26 -- the eight bytes at $4880."""
    return bytes((0xA9, floor & 0xFF, 0x85, 0x25,
                  0xA9, floor >> 8, 0x85, 0x26))
FONT_WRAPPER = 0x7F50
SECTOR_LOADER = 0x7F88
PRIVATE_BASE = 0x7FEC

STATE_LO = PRIVATE_BASE + 0
STATE_HI = PRIVATE_BASE + 1
READ_STATUS = PRIVATE_BASE + 2
SECTOR_LO = PRIVATE_BASE + 3
SECTOR_MID = PRIVATE_BASE + 4
HASH_LO = PRIVATE_BASE + 5
HASH_HI = PRIVATE_BASE + 6
SOURCE_LEN = PRIVATE_BASE + 7
SIG_XOR = PRIVATE_BASE + 8
SIG_CUMULATIVE = PRIVATE_BASE + 9
SIG_FIRST = PRIVATE_BASE + 10
SIG_SECOND = PRIVATE_BASE + 11
SIG_PENULTIMATE = PRIVATE_BASE + 12
SIG_LAST = PRIVATE_BASE + 13
# PASS_NO is intentionally unused by SRT4.  Keep the symbolic slot available
# for diagnostics; NEXT_LO/NEXT_HI below retain the last successfully loaded
# sector after their temporary next-state value has been consumed.
PASS_NO = PRIVATE_BASE + 14
PROBE_NO = PRIVATE_BASE + 15
NEXT_LO = PRIVATE_BASE + 16
NEXT_HI = PRIVATE_BASE + 17
BASE_HASH_LO = PRIVATE_BASE + 18
BASE_HASH_HI = PRIVATE_BASE + 19

FONT_CALL = 0x648C
RENDERER_ENTRY = 0x66E5
GLYPH_SHIFT = 0x64B3
GLYPH_SHIFT_BYTES = 0x31
ADVANCE_CALL = 0x674A
FRACTIONAL_SPACE_HELPER = (
    CACHE_BASE + layout.FONT_OFFSET + layout.FRACTIONAL_SPACE_HELPER_INDEX * 32
)
ORIGINAL_FONT_CALL = bytes.fromhex("20 C2 69")
ORIGINAL_RENDERER_ENTRY = bytes.fromhex("AD 71 34")
ORIGINAL_ADVANCE_CALL = bytes.fromhex("20 5E 68")
ORIGINAL_GLYPH_SHIFT = bytes.fromhex(
    "AC 76 34 D0 03 4C 92 65 BD 80 3B 4A 7E 81 3B 7E A0 3B "
    "4A 7E 81 3B 7E A0 3B 4A 7E 81 3B 7E A0 3B 4A 7E 81 3B "
    "7E A0 3B 9D 80 3B CA CA 10 DA 4C 92 65"
)


def build_fractional_glyph_shift(origin: int) -> bytes:
    """Add a two-bit glyph shift while the Korean half-cell phase is active."""

    a = common.Assembler(origin)
    a.abs(0xAC, 0x3476)  # LDY $3476 (native 0/4 shift)
    a.abs(0x2C, 0x3470)  # BIT $3470 (bit 7 is our fractional phase)
    a.branch(0x10, "count_ready")  # BPL
    a.emit(0xC8, 0xC8)  # INY / INY: half of one native cursor unit
    a.label("count_ready")
    a.emit(0xC0, 0x00)  # CPY #$00
    a.branch(0xF0, "done")
    a.label("row")
    a.emit(0x5A)  # PHY: restore the same shift count for every row
    a.abs(0xBD, 0x3B80)  # LDA $3B80,X
    a.label("shift")
    a.emit(0x4A)  # LSR A
    a.abs(0x7E, 0x3B81)  # ROR $3B81,X
    a.abs(0x7E, 0x3BA0)  # ROR $3BA0,X
    a.emit(0x88)  # DEY
    a.branch(0xD0, "shift")
    a.abs(0x9D, 0x3B80)  # STA $3B80,X
    a.emit(0x7A, 0xCA, 0xCA)  # PLY / DEX / DEX
    a.branch(0x10, "row")
    a.label("done")
    a.abs(0x4C, 0x6592)
    code = a.finish()
    if len(code) > GLYPH_SHIFT_BYTES:
        raise RuntimeError("fractional glyph shifter exceeds original routine")
    return code + bytes((0xEA,)) * (GLYPH_SHIFT_BYTES - len(code))


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1 << 20), b""):
            digest.update(chunk)
    return digest.hexdigest().upper()


def build_renderer_preloader_direct(
    origin: int,
    loader_address: int,
    direct_relative: int,
    maximum_probes: int,
) -> bytes:
    """Load a verified SRT4 text/font slot, normally with one CD read."""

    if not 0 <= direct_relative < 0x10000:
        raise RuntimeError("direct relative sector exceeds 16 bits")
    if not 1 <= maximum_probes <= 0xFF:
        raise RuntimeError("invalid maximum probe count")

    a = common.Assembler(origin)
    a.emit(0xDA, 0x5A)  # PHX / PHY
    a.emit(0xA2, 0x05)
    a.label("save_work_zp")
    a.emit(0xB5, 0x00, 0x48, 0xE8, 0xE0, 0x09)
    a.branch(0x90, "save_work_zp")
    a.emit(0xA2, 0x07)
    a.label("save_bios_zp")
    a.emit(0xB5, 0xF8, 0x48, 0xCA)
    a.branch(0x10, "save_bios_zp")

    # UI 확장판: 내레이션 $3619 와 UI 액션 라벨 $3499/$349A 를 모두 받는다.
    #
    # 원본(0.2.26)은 $3619 만 받았다.  이유는 "UI 한글화가 없으니 $3499 를
    # 받아들이면 일본어를 그대로 두면서 메뉴 항목마다 해시+CD읽기만 하게 된다"
    # 였다.  include_ui=True 로 UI 레코드를 넣으므로 이제 유효하다.
    #
    # 헤더 토큰 $3490-$3496 은 반드시 거부한다 (받으면 그것마다 CD 를 읽는다).
    # 따라서 하위 바이트까지 정확히 본다.
    #   $36/$19  내레이션
    #   $34/$99  UI 라벨 텍스트 시작
    #   $34/$9A  UI 라벨 (일부 메뉴 빌더가 여기서 시작)
    #
    # 크기 제약: 프리로더는 $5E40 에서 시작해 $6000 을 넘을 수 없다.
    # 원본 게이트 25 B, 프리로더 434 B ($5FF2 에서 끝) -> 여유 14 B.
    a.abs(0xAD, 0x3471)
    a.emit(0x85, 0x03)
    a.abs(0xAD, 0x3472)
    a.emit(0x85, 0x04)          # A = 상위 바이트
    a.emit(0xC9, 0x34)
    a.branch(0xF0, "ui_page")   # $34 -> UI 검사
    a.emit(0xC9, 0x36)
    a.branch(0xD0, "reject_pointer")
    a.emit(0xA5, 0x03, 0xC9, 0x19)
    a.branch(0xF0, "pointer_ok")
    a.branch(0x80, "reject_pointer")
    a.label("ui_page")
    a.emit(0xA5, 0x03, 0xC9, 0x99)
    a.branch(0xF0, "pointer_ok")
    a.emit(0xC9, 0x9A)
    a.branch(0xF0, "pointer_ok")
    a.label("reject_pointer")
    a.abs(0x4C, "done")
    a.label("pointer_ok")

    # Compute the same collision-free corpus fingerprint used by SRT3. Source
    # strings in the verified corpus are <=36 bytes.
    for address in (
        HASH_LO,
        HASH_HI,
        SIG_XOR,
        SIG_CUMULATIVE,
    ):
        a.abs(0x9C, address)
    a.emit(0xA0, 0x00)
    a.label("hash_loop")
    a.emit(0xB1, 0x03, 0xC9, 0xFF)
    a.branch(0xF0, "hash_done")
    a.emit(0x85, 0x05)  # current source byte
    a.abs(0x4D, SIG_XOR)
    a.abs(0x8D, SIG_XOR)
    a.emit(0xA5, 0x05, 0x18)
    a.abs(0x6D, HASH_LO)
    a.abs(0x8D, HASH_LO)
    a.abs(0xAD, HASH_HI)
    a.emit(0x69, 0x00, 0x29, 0x3F)
    a.abs(0x8D, HASH_HI)
    a.abs(0xAD, SIG_CUMULATIVE)
    a.emit(0x18)
    a.abs(0x6D, HASH_LO)
    a.abs(0x8D, SIG_CUMULATIVE)
    a.emit(0xC8, 0xC0, 0x40)
    a.branch(0x90, "hash_loop")
    a.abs(0x4C, "no_match")

    a.label("hash_done")
    a.emit(0x98)
    a.abs(0x8D, SOURCE_LEN)

    # baseHash = byteSum + cumulative*65 (mod 16384).
    a.abs(0xAD, SIG_CUMULATIVE)
    a.emit(0x0A, 0x0A, 0x0A, 0x0A, 0x0A, 0x0A, 0x85, 0x05)
    a.abs(0xAD, SIG_CUMULATIVE)
    a.emit(0x4A, 0x4A, 0x85, 0x06, 0x18)
    a.abs(0xAD, HASH_LO)
    a.emit(0x65, 0x05)
    a.abs(0x8D, HASH_LO)
    a.abs(0xAD, HASH_HI)
    a.emit(0x65, 0x06, 0x29, 0x3F)
    a.abs(0x8D, HASH_HI)

    # The table hash uses cumulative*65, not cumulative*64.  The shifts
    # above contribute *64; add the original cumulative byte once more.
    # Keep the full 14-bit carry so the runtime and Python layout builder
    # select exactly the same sector.
    a.emit(0x18)
    a.abs(0xAD, HASH_LO)
    a.abs(0x6D, SIG_CUMULATIVE)
    a.abs(0x8D, HASH_LO)
    a.abs(0xAD, HASH_HI)
    a.emit(0x69, 0x00, 0x29, 0x3F)
    a.abs(0x8D, HASH_HI)

    # TII copies the adjacent 16-bit hash in seven bytes rather than twelve.
    a.emit(
        0x73,
        HASH_LO & 0xFF,
        HASH_LO >> 8,
        BASE_HASH_LO & 0xFF,
        BASE_HASH_LO >> 8,
        0x02,
        0x00,
    )

    a.label("apply_state_hash")
    # Add state*257: low += stateLow; high += stateHigh + stateLow.
    a.emit(0x18)
    a.abs(0xAD, STATE_HI)
    a.abs(0x6D, STATE_LO)
    a.emit(0x85, 0x06, 0x18)
    a.abs(0xAD, HASH_LO)
    a.abs(0x6D, STATE_LO)
    a.abs(0x8D, HASH_LO)
    a.abs(0xAD, HASH_HI)
    a.emit(0x65, 0x06, 0x29, 0x3F)
    a.abs(0x8D, HASH_HI)
    a.abs(0x9C, PROBE_NO)

    a.label("probe_slot")
    a.emit(0x18)
    a.abs(0xAD, HASH_LO)
    a.emit(0x69, direct_relative & 0xFF)
    a.abs(0x8D, SECTOR_LO)
    a.abs(0xAD, HASH_HI)
    a.emit(0x69, (direct_relative >> 8) & 0xFF)
    a.abs(0x8D, SECTOR_MID)
    a.abs(0x20, loader_address)
    a.emit(0xC9, 0x00)
    a.branch(0xF0, "slot_loaded")
    a.abs(0x4C, "search_failed")

    a.label("slot_loaded")
    # Empty slot terminates an open-addressing chain.  Other magic failures
    # are also treated as misses rather than risking a false replacement.
    a.abs(0xAD, CACHE_BASE)
    a.emit(0xC9, layout.MAGIC[0])
    a.branch(0xF0, "signature_start")
    a.abs(0x4C, "search_failed")
    a.label("signature_start")

    checks = (
        (8, STATE_LO),
        (9, STATE_HI),
        (5, SOURCE_LEN),
        (6, SIG_XOR),
        (7, SIG_CUMULATIVE),
    )
    for offset, address in checks:
        a.abs(0xAD, CACHE_BASE + offset)
        a.abs(0xCD, address)
        a.branch(0xD0, "signature_failed_near")
    a.branch(0x80, "signature_checks_ok")
    a.label("signature_failed_near")
    a.abs(0x4C, "probe_mismatch")
    a.label("signature_checks_ok")

    a.abs(0xAD, CACHE_BASE + 10)
    a.abs(0x8D, STATE_LO)
    a.abs(0xAD, CACHE_BASE + 11)
    a.abs(0x8D, STATE_HI)

    # A failed open-addressing lookup still overwrites $5B80-$5E3F, including
    # the live Korean font cache.  Remember the sector of every successful
    # match so the rare MISS path can restore that cache before returning to
    # the original Japanese string.  0000 is the power-on "no cache" marker;
    # appended Track-24 sectors can never use relative sector zero.
    a.abs(0xAD, SECTOR_LO)
    a.abs(0x8D, NEXT_LO)
    a.abs(0xAD, SECTOR_MID)
    a.abs(0x8D, NEXT_HI)

    # The direct sector remains cached while this string is rendered. Point
    # the renderer at the cached text instead of copying it back over the
    # source buffer. This supports translated UI strings longer than $349A's
    # original record and saves enough runtime bytes for the second entry.
    a.emit(0xA9, ASSET_TEXT & 0xFF)
    a.abs(0x8D, 0x3471)
    a.emit(0xA9, ASSET_TEXT >> 8)
    a.abs(0x8D, 0x3472)
    a.abs(0x4C, "done")

    a.label("probe_mismatch")
    a.abs(0xEE, HASH_LO)
    a.branch(0xD0, "probe_no_carry")
    a.abs(0xEE, HASH_HI)
    a.label("probe_no_carry")
    a.abs(0xAD, HASH_HI)
    a.emit(0x29, 0x3F)
    a.abs(0x8D, HASH_HI)
    a.abs(0xEE, PROBE_NO)
    a.abs(0xAD, PROBE_NO)
    a.emit(0xC9, maximum_probes)
    a.branch(0xB0, "search_failed")
    a.abs(0x4C, "probe_slot")

    a.label("search_failed")
    a.abs(0xAD, STATE_LO)
    a.abs(0x0D, STATE_HI)
    a.branch(0xF0, "no_match")
    a.abs(0x9C, STATE_LO)
    a.abs(0x9C, STATE_HI)
    a.emit(
        0x73,
        BASE_HASH_LO & 0xFF,
        BASE_HASH_LO >> 8,
        HASH_LO & 0xFF,
        HASH_LO >> 8,
        0x02,
        0x00,
    )
    a.abs(0x4C, "apply_state_hash")

    a.label("no_match")
    a.abs(0x9C, STATE_LO)
    a.abs(0x9C, STATE_HI)
    # Restore the last verified text/font sector.  This extra CD read occurs
    # only for a genuine miss; normal HIT performance is unchanged.
    a.abs(0xAD, NEXT_HI)
    a.branch(0xF0, "done")
    a.abs(0xAD, NEXT_LO)
    a.abs(0x8D, SECTOR_LO)
    a.abs(0xAD, NEXT_HI)
    a.abs(0x8D, SECTOR_MID)
    a.abs(0x20, loader_address)
    a.label("done")
    a.emit(0xA2, 0x00)
    a.label("restore_bios_zp")
    a.emit(0x68, 0x95, 0xF8, 0xE8, 0xE0, 0x08)
    a.branch(0x90, "restore_bios_zp")
    a.emit(0xA2, 0x08)
    a.label("restore_work_zp")
    a.emit(0x68, 0x95, 0x00, 0xCA, 0xE0, 0x04)
    a.branch(0xD0, "restore_work_zp")
    a.emit(0x7A, 0xFA)
    a.abs(0xAD, 0x3471)
    a.emit(0x60)
    return a.finish()


def write_tsv(path: Path, rows: list[dict[str, str]]) -> None:
    if not rows:
        path.write_text("", encoding="utf-8")
        return
    with path.open("w", encoding="utf-8-sig", newline="") as handle:
        writer = csv.DictWriter(handle, fieldnames=list(rows[0]), delimiter="\t", lineterminator="\n")
        writer.writeheader()
        writer.writerows(rows)


def build(version: str, force: bool, review_only: bool = False) -> Path:
    output_dir = BUILD_ROOT / version
    if output_dir.exists():
        if not force:
            raise SystemExit(f"build already exists: {output_dir} (use --force)")
        shutil.rmtree(output_dir)
    output_dir.mkdir(parents=True)

    if sha256_file(SOURCE_TRACK02) != EXPECTED_TRACK02_SHA256:
        raise RuntimeError("unexpected Track 02 SHA-256")
    if sha256_file(SOURCE_TRACK24) != EXPECTED_TRACK24_SHA256:
        raise RuntimeError("unexpected Track 24 SHA-256")

    layout_manifest = layout.build(
        UITEST_MASTER,
        STUDIO_TRANSLATION_DIR / "speaker_name_standard.tsv",
        STUDIO_TRANSLATION_DIR / "ui_text.tsv",
        LAYOUT_DIR,
        srt3_patch.layout.DEFAULT_COMPILED,
        clean=True,
        # Always regenerate the source asset layout from the current TSV/font
        # inputs.  Reusing the previous SRT3 layout made SRT4 silently carry
        # forward experimental F041 fractional-space data after that feature
        # had been reverted in the codec.  The direct table metadata was new,
        # but the text/font payloads were stale -- particularly visible in UI
        # menus, whose first custom glyphs then rendered as blocks.
        source_layout=None,
        review_only=review_only,
        # UI 확장판: menu_session_cache 를 켠다.  네 액션 라벨이 하나의
        # compact payload(텍스트 + 합집합 폰트팩)로 묶여 한 번의 CD 읽기로 온다.
        #
        # SNATCHER_INCLUDE_UI=0 으로 끄면 대사만 실린다 -- 0.2.26 이 그랬고,
        # 소유자 기억으로 그 판은 폐공장에서 끊기지 않았다.  밀림이 대사가 아니라
        # 메뉴에서 온다는 것을 같은 엔진·같은 데이터로 가리기 위한 실험 스위치다
        # (§4.1: 메뉴 한 화면이 레코드를 13건 재구성한다).  기본값은 켜짐.
        include_ui=INCLUDE_UI,
    )
    direct_user = (LAYOUT_DIR / "direct_user_sectors.bin").read_bytes()
    user_sectors = [
        direct_user[index:index + track24.USER_DATA_SIZE]
        for index in range(0, len(direct_user), track24.USER_DATA_SIZE)
    ]
    if len(user_sectors) != layout.SLOT_COUNT:
        raise RuntimeError("bad SRT4 direct sector count")

    starts, original_disc_sectors = track24.disc_track_starts()
    track24_sectors = SOURCE_TRACK24.stat().st_size // track24.RAW_SECTOR_SIZE
    first_appended_lba = starts[24] + track24_sectors
    if first_appended_lba != original_disc_sectors:
        raise RuntimeError("Track 24 is not the final source track")
    track02_index1_lba = starts[2] + 225
    track24_index1_lba = starts[24] + 225
    direct_relative = first_appended_lba - track24_index1_lba
    if direct_relative + layout.SLOT_COUNT - 1 >= 0x10000:
        raise RuntimeError("SRT4 table exceeds the 16-bit relative CD range")

    loader_code = srt3_patch.build_sector_loader(
        SECTOR_LOADER,
        track24_index1_lba,
        track02_index1_lba,
    )
    maximum_probes = int(layout_manifest["maximum_successful_probes"])
    preloader_code = build_renderer_preloader_direct(
        RUNTIME_START,
        SECTOR_LOADER,
        direct_relative,
        maximum_probes,
    )
    wrapper_code = srt3_patch.build_font_wrapper(FONT_WRAPPER)
    fractional_shift_code = build_fractional_glyph_shift(GLYPH_SHIFT)
    fractional_helper_code = layout.FRACTIONAL_SPACE_HELPER
    if RUNTIME_START + len(preloader_code) > RUNTIME_END:
        raise RuntimeError(
            f"runtime ends at ${RUNTIME_START + len(preloader_code):04X}, beyond ${RUNTIME_END:04X}"
        )
    if FONT_WRAPPER + len(wrapper_code) > SECTOR_LOADER:
        raise RuntimeError("font wrapper overlaps sector loader")
    arena_bytes = RUNTIME_START - ARENA_FLOOR_NEW
    if arena_bytes < ARENA_MIN_BYTES:
        raise RuntimeError(
            f"arena floor ${ARENA_FLOOR_NEW:04X} leaves the game only "
            f"{arena_bytes} B before the preloader at ${RUNTIME_START:04X}; "
            "the shopping screen alone needs 579 B (handoff section 15)")
    if SECTOR_LOADER + len(loader_code) > PRIVATE_BASE:
        raise RuntimeError("sector loader overlaps private state")

    patches = [
        common.Patch(
            "font_call",
            common.bank6a_iso(FONT_CALL),
            ORIGINAL_FONT_CALL,
            bytes((0x20, FONT_WRAPPER & 0xFF, FONT_WRAPPER >> 8)),
            FONT_CALL,
        ),
        common.Patch(
            "renderer_preload_call",
            common.bank6a_iso(RENDERER_ENTRY),
            ORIGINAL_RENDERER_ENTRY,
            bytes((0x20, RUNTIME_START & 0xFF, RUNTIME_START >> 8)),
            RENDERER_ENTRY,
        ),
        common.Patch(
            "fractional_glyph_shift",
            common.bank6a_iso(GLYPH_SHIFT),
            ORIGINAL_GLYPH_SHIFT,
            fractional_shift_code,
            GLYPH_SHIFT,
        ),
        common.Patch(
            "fractional_space_advance_call",
            common.bank6a_iso(ADVANCE_CALL),
            ORIGINAL_ADVANCE_CALL,
            bytes((0x20, FRACTIONAL_SPACE_HELPER & 0xFF, FRACTIONAL_SPACE_HELPER >> 8)),
            ADVANCE_CALL,
        ),
        common.Patch(
            "fractional_space_helper_init",
            common.bank68_iso(FRACTIONAL_SPACE_HELPER),
            bytes((0xFF,)) * len(fractional_helper_code),
            fractional_helper_code,
            FRACTIONAL_SPACE_HELPER,
        ),
        common.Patch(
            "sector_loader",
            common.bank6a_iso(SECTOR_LOADER),
            bytes((0xFF,)) * len(loader_code),
            loader_code,
            SECTOR_LOADER,
        ),
        common.Patch(
            "renderer_preloader_direct",
            common.bank68_iso(RUNTIME_START),
            bytes((0xFF,)) * len(preloader_code),
            preloader_code,
            RUNTIME_START,
        ),
        common.Patch(
            "arena_floor",
            common.bank68_iso(ARENA_FLOOR_INIT),
            arena_floor_code(ARENA_FLOOR_OLD),
            arena_floor_code(ARENA_FLOOR_NEW),
            ARENA_FLOOR_INIT,
        ),
        common.Patch(
            "font_wrapper",
            common.bank6a_iso(FONT_WRAPPER),
            bytes((0xFF,)) * len(wrapper_code),
            wrapper_code,
            FONT_WRAPPER,
        ),
        common.Patch(
            "private_state_init",
            common.bank6a_iso(PRIVATE_BASE),
            bytes((0xFF,)) * (0x8000 - PRIVATE_BASE),
            bytes((0x00,)) * (0x8000 - PRIVATE_BASE),
            PRIVATE_BASE,
        ),
    ]
    for patch in patches:
        actual = proof.read_user_bytes(SOURCE_TRACK02, patch.iso_offset, len(patch.old))
        if actual != patch.old:
            raise RuntimeError(f"preflight mismatch for {patch.name} at ${patch.iso_offset:06X}")

    patched02 = output_dir / f"Snatcher CD-ROMantic (Japan) (Track 02) [KO {version}].bin"
    modified02 = proof.apply_patches_streaming(SOURCE_TRACK02, patched02, patches)

    patched24 = output_dir / f"Snatcher CD-ROMantic (Japan) (Track 24) [KO {version}].bin"
    shutil.copyfile(SOURCE_TRACK24, patched24)
    appended = bytearray()
    for index, user_data in enumerate(user_sectors):
        lba = first_appended_lba + index
        sector = track24.make_mode1_sector(lba, user_data)
        track24.verify_mode1_sector(sector, lba)
        appended.extend(sector)
    with patched24.open("ab") as handle:
        handle.write(appended)

    cue = output_dir / f"Snatcher CD-ROMantic (Japan) [KO {version}].cue"
    staged = track24.stage_cue(cue, patched02, patched24)
    shutil.copyfile(LAYOUT_DIR / "direct_records.tsv", output_dir / "direct_records.tsv")
    shutil.copyfile(LAYOUT_DIR / "assets.tsv", output_dir / "assets.tsv")
    shutil.copyfile(LAYOUT_DIR / "runtime_layout.json", output_dir / "runtime_layout.json")
    (output_dir / "track24_appended_raw.bin").write_bytes(appended)

    patch_rows = [
        {
            "name": patch.name,
            "cpu_address": f"{patch.cpu_address:04X}" if patch.cpu_address is not None else "",
            "iso_offset": f"{patch.iso_offset:06X}",
            "length": str(len(patch.new)),
            "old_hex": patch.old.hex(" ").upper(),
            "new_hex": patch.new.hex(" ").upper(),
        }
        for patch in patches
    ]
    write_tsv(output_dir / "track02_patches.tsv", patch_rows)

    manifest = {
        "version": version,
        "status": "full-generated-translation-track24-direct-runtime",
        "optimization": "SRT4 one-read direct source/text/font sectors",
        "korean_spacing": "8140 native full-cell; each Korean space counts as one of 18 cells",
        "translation_policy": (
            ("review O dialogue plus context-only 예외처리 rows; speaker rows; UI native"
             if layout.srt3.REVIEW_EXCEPTIONS else
             "review O dialogue (예외처리 ships nothing); speaker rows; UI native")
            if review_only else "all generated dialogue; speaker rows; UI native"
        ),
        "source_track02_sha256": EXPECTED_TRACK02_SHA256,
        "source_track24_sha256": EXPECTED_TRACK24_SHA256,
        "patched_track02_sha256": sha256_file(patched02),
        "patched_track24_sha256": sha256_file(patched24),
        "cue": cue.name,
        "cue_tracks": staged,
        "first_appended_lba": first_appended_lba,
        "track24_index1_lba": track24_index1_lba,
        "direct_relative_sector": direct_relative,
        "direct_sectors": layout.SLOT_COUNT,
        "appended_sectors": len(user_sectors),
        "appended_raw_bytes": len(appended),
        "expected_average_cd_reads_per_hit": layout_manifest["average_successful_probes"],
        "expected_p95_cd_reads_per_hit": layout_manifest["p95_successful_probes"],
        "maximum_cd_reads_per_hit": maximum_probes,
        "runtime": {
            "sector_loader": f"{SECTOR_LOADER:04X}",
            "sector_loader_bytes": len(loader_code),
            "renderer_preloader": f"{RUNTIME_START:04X}",
            "renderer_preloader_bytes": len(preloader_code),
            "font_wrapper": f"{FONT_WRAPPER:04X}",
            "font_wrapper_bytes": len(wrapper_code),
            "fractional_space_helper": f"{FRACTIONAL_SPACE_HELPER:04X}",
            "fractional_glyph_shift": f"{GLYPH_SHIFT:04X}",
            "private_state": f"{PRIVATE_BASE:04X}-7FFF",
            "cache": f"{CACHE_BASE:04X}-{CACHE_BASE + layout.READ_BYTES - 1:04X}",
        },
        "layout": layout_manifest,
        "modified_track02_sectors": [f"{sector:06X}" for sector in sorted(modified02)],
    }
    (output_dir / "manifest.json").write_text(
        json.dumps(manifest, ensure_ascii=False, indent=2) + "\n",
        encoding="utf-8",
    )
    (output_dir / "TEST_IN_MESEN.txt").write_text(
        "Load the KO cue and power-cycle. Do not load a save state from another build.\n"
        "Open the blue reception action menu containing 보다 / 조사핟 / 대화하다 / 묻다.\n"
        "Expected: the first opening may load once; moving the cursor and reopening the same menu should not pause per item.\n"
        "Also confirm normal dialogue and unrelated Japanese menus still render normally.\n",
        encoding="utf-8-sig",
    )
    return output_dir


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--version", default=VERSION_DEFAULT)
    parser.add_argument("--force", action="store_true")
    parser.add_argument("--review-only", action="store_true")
    args = parser.parse_args()
    out = build(args.version, args.force, args.review_only)
    print(out)


if __name__ == "__main__":
    main()
