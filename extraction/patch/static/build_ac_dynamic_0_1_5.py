#!/usr/bin/env python3
"""Build ac_0.1.5: demand-loaded scene packs backed by Arcade Card RAM.

The proven 0.3.0-uitest renderer, $5E40 lookup, font rules, and 704-byte
SRT4 records are preserved.  Only the $7F88 data supplier changes.  A 64 KiB
slot directory is loaded once; UI/speaker/shared records stay resident while
one scene pack occupies a replaceable AC region.
"""

from __future__ import annotations

import csv
import hashlib
import json
import os
import re
import shutil
import sys
from collections import OrderedDict
from pathlib import Path


ROOT = Path(r"C:\snatcher")
STATIC = ROOT / "extraction" / "patch" / "static"
sys.path.insert(0, str(STATIC))

import build_disc_patch as common  # noqa: E402
import build_speaker_ui_proof as proof  # noqa: E402
import build_track24_loader_proof as track24  # noqa: E402


VERSION = "ac_0.1.5"
BASE = ROOT / "build" / "patch" / "ac_0.1.1"
OUT = ROOT / "build" / "patch" / VERSION
BIOS_MPR_TRANSFER = False
BIOS_DESTINATION_MPR = 2
HELPER_EXEC_MPR_MASK = 0x10
RESIDENT_PACK_NAMES = ("common",)
COALESCE_SMALL_SCENES_MAX_RECORDS = 0
COALESCE_SMALL_SCENES_TARGET = "shared"

RAW_SECTOR_BYTES = 2352
USER_OFFSET = 16
USER_BYTES = 2048
RECORD_BYTES = 704
SLOT_COUNT = 0x4000
DIRECTORY_BYTES = SLOT_COUNT * 4
AC_BYTES = 2 * 1024 * 1024

SECTOR_LOADER = 0x7F88
LOADER_BYTES = 100
CACHE_BASE = 0x5B80
DIRECT_RELATIVE = 33973

BANK69_ISO_BASE = 0x07D800
HELPER = 0x9CD2
HELPER_LIMIT = 0xA000
BIOS_CD_BASE = 0xE006
BIOS_CD_READ = 0xE009
TRACK24_INDEX1_LBA = 235149
TRACK02_INDEX1_LBA = 0x00104E
APPEND_RELATIVE_SECTOR = DIRECT_RELATIVE + SLOT_COUNT
CHUNK_BYTES = 0x2000

# The directory occupies AC $00000-$0FFFF.  State is outside it.  The common
# data follows the state, and the scene base is selected by the builder after
# the actual common-pack size is known.
STATE_BASE = 0x10000
COMMON_DATA_BASE = 0x10010
MAGIC = (0xAC, 0x15, 0x51)


def bank69_iso(cpu: int) -> int:
    if not 0x8000 <= cpu < 0xC000:
        raise ValueError(f"not an MPR4/5 CPU address: ${cpu:04X}")
    return BANK69_ISO_BASE + (cpu & 0x1FFF)


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1 << 20), b""):
            digest.update(chunk)
    return digest.hexdigest().upper()


def align(value: int, unit: int) -> int:
    return (value + unit - 1) // unit * unit


def classify(row: dict[str, str]) -> str:
    """Use existing references only; this is packaging, not text semantics."""
    if row["kind"] in {"ui", "speaker"}:
        return "common"
    blocks: list[str] = []
    for reference in row["reference"].split(","):
        match = re.match(r"([0-9A-F]{6}):", reference)
        if match and match.group(1) not in blocks:
            blocks.append(match.group(1))
    if not blocks:
        return "runtime"
    if len(blocks) > 1:
        return "common"
    return f"scene_{blocks[0]}"


def read_records() -> tuple[list[dict[str, str]], dict[int, bytes]]:
    rows = list(csv.DictReader(
        (BASE / "direct_records.tsv").open("r", encoding="utf-8-sig", newline=""),
        delimiter="\t",
    ))
    raw = (BASE / "ac_backing_store" / "srt4_records_704b.bin").read_bytes()
    if len(raw) != len(rows) * RECORD_BYTES:
        raise RuntimeError("dense record image and direct_records.tsv disagree")
    records: dict[int, bytes] = {}
    for index, row in enumerate(rows):
        slot = int(row["final_slot"], 16)
        payload = raw[index * RECORD_BYTES:(index + 1) * RECORD_BYTES]
        if payload[:4] != b"SDR4" or slot in records:
            raise RuntimeError(f"invalid SRT4 record/slot at row {index}")
        records[slot] = payload
    return rows, records


def build_packs() -> tuple[bytes, list[dict[str, object]], bytes, int]:
    rows, records = read_records()
    grouped: OrderedDict[str, list[int]] = OrderedDict()
    for resident_name in RESIDENT_PACK_NAMES:
        grouped[resident_name] = []
    for row in rows:
        name = classify(row)
        grouped.setdefault(name, []).append(int(row["final_slot"], 16))
    if COALESCE_SMALL_SCENES_MAX_RECORDS:
        target = COALESCE_SMALL_SCENES_TARGET
        if target not in RESIDENT_PACK_NAMES:
            raise RuntimeError("small-scene coalescing target must be resident")
        grouped.setdefault(target, [])
        small_scenes = [
            name for name, slots in grouped.items()
            if name.startswith("scene_")
            and len(slots) <= COALESCE_SMALL_SCENES_MAX_RECORDS
        ]
        for name in small_scenes:
            grouped[target].extend(grouped.pop(name))
    grouped = OrderedDict((name, slots) for name, slots in grouped.items() if slots)
    if len(grouped) > 31:
        raise RuntimeError(f"pack count {len(grouped)} exceeds compact runtime table limit 31")

    # BIOS CD_READ always transfers whole 2048-byte sectors.  Every resident
    # destination must therefore start after the previous pack's sector-padded
    # transfer extent; packing only the useful 704-byte records allowed a
    # later-loaded pack's padding to overwrite the beginning of its neighbor.
    resident_storage_end = align(COMMON_DATA_BASE, USER_BYTES)
    for name in RESIDENT_PACK_NAMES:
        if name in grouped:
            resident_storage_end = align(
                resident_storage_end + len(grouped[name]) * RECORD_BYTES,
                USER_BYTES,
            )
    scene_base = align(resident_storage_end, 0x10000)
    if scene_base >= AC_BYTES:
        raise RuntimeError("common resident pack leaves no scene region")

    directory = bytearray(b"\xFF" * DIRECTORY_BYTES)
    package_blob = bytearray()
    packages: list[dict[str, object]] = []
    resident_cursor = align(COMMON_DATA_BASE, USER_BYTES)
    for pack_id, (name, slots) in enumerate(grouped.items()):
        data = b"".join(records[slot] for slot in slots)
        is_resident = name in RESIDENT_PACK_NAMES
        transferred_bytes = align(len(data), USER_BYTES)
        capacity = (scene_base - resident_cursor) if is_resident else (AC_BYTES - scene_base)
        if transferred_bytes > capacity:
            raise RuntimeError(
                f"{name} transfers {transferred_bytes} bytes but its AC region holds {capacity}; "
                "split the source scene before building"
            )
        destination = resident_cursor if is_resident else scene_base
        for offset, slot in enumerate(slots):
            entry = slot * 4
            address = destination + offset * RECORD_BYTES
            directory[entry:entry + 3] = address.to_bytes(3, "little")
            directory[entry + 3] = pack_id
        package_blob.extend(bytes((-len(package_blob)) % USER_BYTES))
        packages.append({
            "id": pack_id,
            "name": name,
            "record_count": len(slots),
            "bytes": len(data),
            "transferred_bytes": transferred_bytes,
            "blob_offset": len(package_blob),
            "destination": destination,
            "resident": is_resident,
        })
        package_blob.extend(data)
        if is_resident:
            resident_cursor = align(resident_cursor + len(data), USER_BYTES)

    image = bytes(directory) + bytes(package_blob)
    return bytes(directory), packages, image, scene_base


def emit_cd_base(a: common.Assembler, lba: int) -> None:
    for zp, value in ((0xF8, lba >> 16), (0xF9, lba >> 8), (0xFA, lba), (0xFB, 0), (0xFC, 1)):
        a.emit(0xA9, value, 0x85, zp)
    a.abs(0x20, BIOS_CD_BASE)


def emit_set_ac_from_vars(a: common.Assembler, lo: int, mid: int, hi: int) -> None:
    for variable, port in ((lo, 0x1A02), (mid, 0x1A03), (hi, 0x1A04)):
        a.abs(0xAD, variable); a.abs(0x8D, port)
    a.emit(0xA9, 1); a.abs(0x8D, 0x1A07)
    a.abs(0x9C, 0x1A08)
    a.emit(0xA9, 0x11); a.abs(0x8D, 0x1A09)


def emit_set_ac_constant(a: common.Assembler, address: int) -> None:
    for value, port in ((address, 0x1A02), (address >> 8, 0x1A03), (address >> 16, 0x1A04)):
        a.emit(0xA9, value); a.abs(0x8D, port)
    a.emit(0xA9, 1); a.abs(0x8D, 0x1A07)
    a.abs(0x9C, 0x1A08)
    a.emit(0xA9, 0x11); a.abs(0x8D, 0x1A09)


def build_helper(packages: list[dict[str, object]], scene_base: int) -> tuple[bytes, int]:
    # Writable scratch at the end of the Bank69 cave.
    scratch = HELPER_LIMIT - 0x20
    (CUR_LO, CUR_HI, LEFT, FINAL_LO, FINAL_HI, DEST_LO, DEST_MID, DEST_HI,
     STATUS, PACK_ID, REC_LO, REC_MID, REC_HI) = range(scratch, scratch + 13)
    table_address = scratch - len(packages) * 8
    resident_count = len(RESIDENT_PACK_NAMES)

    metadata = bytearray()
    for package in packages:
        byte_length = int(package["bytes"])
        full_chunks, final_bytes = divmod(byte_length, CHUNK_BYTES)
        if full_chunks > 255:
            raise RuntimeError(f"pack {package['name']} needs too many 8 KiB chunks")
        relative_sector = APPEND_RELATIVE_SECTOR + DIRECTORY_BYTES // USER_BYTES + int(package["blob_offset"]) // USER_BYTES
        destination = int(package["destination"])
        metadata.extend((
            relative_sector & 0xFF, relative_sector >> 8, full_chunks,
            final_bytes & 0xFF, final_bytes >> 8,
            destination & 0xFF, (destination >> 8) & 0xFF, (destination >> 16) & 0xFF,
        ))

    a = common.Assembler(HELPER)
    # Is the 64 KiB directory initialized?
    a.emit(0xA9, 0); a.abs(0x20, "set_state_address")
    for expected in MAGIC:
        a.abs(0xAD, 0x1A00); a.emit(0xC9, expected); a.branch(0xD0, "init_directory")
    a.abs(0x4C, "lookup")

    a.label("init_directory")
    for variable, value in (
        (CUR_LO, APPEND_RELATIVE_SECTOR), (CUR_HI, APPEND_RELATIVE_SECTOR >> 8),
        (LEFT, DIRECTORY_BYTES // CHUNK_BYTES), (FINAL_LO, 0), (FINAL_HI, 0),
        (DEST_LO, 0), (DEST_MID, 0), (DEST_HI, 0),
    ):
        a.emit(0xA9, value); a.abs(0x8D, variable)
    a.abs(0x20, "load_blob")
    a.emit(0xC9, 0); a.branch(0xF0, "init_ok")
    a.abs(0x4C, "return_miss")
    a.label("init_ok")
    a.emit(0xA9, 0); a.abs(0x20, "set_state_address")
    for value in (*MAGIC, *((0xFF,) * (resident_count + 1))):
        a.emit(0xA9, value); a.abs(0x8D, 0x1A00)

    a.label("lookup")
    # Existing preloader passes direct_relative + slot at $7FEF/$7FF0.
    a.emit(0x38); a.abs(0xAD, 0x7FEF); a.emit(0xE9, DIRECT_RELATIVE & 0xFF, 0x85, 0xF8)
    a.abs(0xAD, 0x7FF0); a.emit(0xE9, DIRECT_RELATIVE >> 8, 0x85, 0xF9)
    a.emit(0x06, 0xF8, 0x26, 0xF9, 0x06, 0xF8, 0x26, 0xF9)
    a.emit(0xA5, 0xF8); a.abs(0x8D, DEST_LO)
    a.emit(0xA5, 0xF9); a.abs(0x8D, DEST_MID)
    a.abs(0x9C, DEST_HI)
    emit_set_ac_from_vars(a, DEST_LO, DEST_MID, DEST_HI)
    for variable in (REC_LO, REC_MID, REC_HI, PACK_ID):
        a.abs(0xAD, 0x1A00); a.abs(0x8D, variable)
    a.abs(0xAD, PACK_ID); a.emit(0xC9, 0xFF); a.branch(0xD0, "valid_pack")
    a.abs(0x4C, "return_miss")
    a.label("valid_pack")

    # Each resident package has its own flag. Scene/runtime packages share one
    # replaceable AC region and therefore one active-package flag.
    a.emit(0xC9, resident_count); a.branch(0xB0, "scene_flag")
    a.emit(0x18, 0x69, 3); a.abs(0x20, "set_state_address")
    a.abs(0x4C, "check_flag")
    a.label("scene_flag")
    a.emit(0xA9, 3 + resident_count); a.abs(0x20, "set_state_address")
    a.label("check_flag")
    a.abs(0xAD, 0x1A00); a.abs(0xCD, PACK_ID); a.branch(0xD0, "load_package")
    a.abs(0x4C, "copy_record")

    # Load the selected package metadata (8 bytes per package).
    a.label("load_package")
    a.abs(0xAD, PACK_ID); a.emit(0x0A, 0x0A, 0x0A, 0xA8)
    for variable in (CUR_LO, CUR_HI, LEFT, FINAL_LO, FINAL_HI, DEST_LO, DEST_MID, DEST_HI):
        a.abs(0xB9, table_address); a.abs(0x8D, variable); a.emit(0xC8)
    a.abs(0x20, "load_blob")
    a.emit(0xC9, 0); a.branch(0xF0, "pack_loaded")
    a.abs(0x4C, "return_miss")
    a.label("pack_loaded")
    a.abs(0xAD, PACK_ID); a.emit(0xC9, resident_count); a.branch(0xB0, "mark_scene")
    a.emit(0x18, 0x69, 3); a.abs(0x20, "set_state_address")
    a.abs(0xAD, PACK_ID); a.abs(0x8D, 0x1A00)
    a.abs(0x4C, "copy_record")
    a.label("mark_scene")
    a.emit(0xA9, 3 + resident_count); a.abs(0x20, "set_state_address")
    a.abs(0xAD, PACK_ID); a.abs(0x8D, 0x1A00)

    a.label("copy_record")
    emit_set_ac_from_vars(a, REC_LO, REC_MID, REC_HI)
    a.emit(0xF3); a.word(0x1A00); a.word(CACHE_BASE); a.word(RECORD_BYTES)
    a.emit(0xA9, 0); a.abs(0x4C, "return_status")
    a.label("return_miss")
    a.emit(0xA9, 1)
    a.label("return_status")
    # Match the original CD loader: BIOS calls may disturb the active source
    # pointer, so recreate it before the $5E40 lookup resumes.
    a.emit(0x48)
    a.abs(0xAD, 0x3471); a.emit(0x85, 0x03)
    a.abs(0xAD, 0x3472); a.emit(0x85, 0x04)
    a.emit(0x68, 0x60)

    # Generic Track24 -> auto-incrementing AC transfer.  ac_0.1.5 used a
    # caller-managed MPR2 window.  ac_0.1.7 selects the BIOS's documented
    # destination type #2, which owns save/map/restore of MPR2 itself.
    a.label("load_blob")
    emit_set_ac_from_vars(a, DEST_LO, DEST_MID, DEST_HI)
    if not BIOS_MPR_TRANSFER:
        a.emit(0x43, 0x04, 0x48, 0xA9, 0x40, 0x53, 0x04)
    emit_cd_base(a, TRACK24_INDEX1_LBA)
    a.abs(0x9C, STATUS)
    a.label("full_test")
    a.abs(0xAD, LEFT); a.branch(0xF0, "final_test")
    full_args = (
        ((0xF8, CHUNK_BYTES // USER_BYTES), (0xF9, 0), (0xFA, 0x40), (0xFB, 0), (0xFC, 0))
        if BIOS_MPR_TRANSFER else
        ((0xF8, CHUNK_BYTES), (0xF9, CHUNK_BYTES >> 8), (0xFA, 0), (0xFB, 0x40), (0xFC, 0))
    )
    for zp, value in full_args:
        a.emit(0xA9, value, 0x85, zp)
    a.abs(0xAD, CUR_HI); a.emit(0x85, 0xFD)
    a.abs(0xAD, CUR_LO); a.emit(0x85, 0xFE)
    a.emit(0xA9, BIOS_DESTINATION_MPR if BIOS_MPR_TRANSFER else 0, 0x85, 0xFF); a.abs(0x20, BIOS_CD_READ)
    a.emit(0xC9, 0); a.branch(0xD0, "blob_failed")
    a.emit(0x18); a.abs(0xAD, CUR_LO); a.emit(0x69, 4); a.abs(0x8D, CUR_LO)
    a.abs(0xAD, CUR_HI); a.emit(0x69, 0); a.abs(0x8D, CUR_HI)
    a.abs(0xCE, LEFT); a.abs(0x4C, "full_test")
    a.label("final_test")
    a.abs(0xAD, FINAL_LO); a.abs(0x0D, FINAL_HI); a.branch(0xF0, "blob_restore")
    if BIOS_MPR_TRANSFER:
        # Package data is sector padded on disc; reading the final 1-3 sectors
        # may write padding after the useful bytes but never crosses its AC
        # region.  Compute ceil(final_bytes / 2048) in the builder.
        # PACK_ID selects the count through a compact byte table appended after
        # metadata.  Keep this generated lookup local to the helper image.
        final_count_table = table_address - len(packages)
        a.abs(0xAE, PACK_ID)
        a.abs(0xBD, final_count_table); a.emit(0x85, 0xF8)
        for zp, value in ((0xF9, 0), (0xFA, 0x40), (0xFB, 0), (0xFC, 0)):
            a.emit(0xA9, value, 0x85, zp)
    else:
        a.abs(0xAD, FINAL_LO); a.emit(0x85, 0xF8)
        a.abs(0xAD, FINAL_HI); a.emit(0x85, 0xF9)
        for zp, value in ((0xFA, 0), (0xFB, 0x40), (0xFC, 0)):
            a.emit(0xA9, value, 0x85, zp)
    a.abs(0xAD, CUR_HI); a.emit(0x85, 0xFD)
    a.abs(0xAD, CUR_LO); a.emit(0x85, 0xFE)
    a.emit(0xA9, BIOS_DESTINATION_MPR if BIOS_MPR_TRANSFER else 0, 0x85, 0xFF); a.abs(0x20, BIOS_CD_READ)
    a.emit(0xC9, 0); a.branch(0xF0, "blob_restore")
    a.label("blob_failed")
    a.emit(0xA9, 1); a.abs(0x8D, STATUS)
    a.label("blob_restore")
    if not BIOS_MPR_TRANSFER:
        a.emit(0x68, 0x53, 0x04)
    emit_cd_base(a, TRACK02_INDEX1_LBA)
    a.abs(0xAD, STATUS); a.emit(0x60)

    # A = low-byte offset within AC state page $10000.
    a.label("set_state_address")
    a.abs(0x8D, 0x1A02)
    a.abs(0x9C, 0x1A03)
    a.emit(0xA9, 1); a.abs(0x8D, 0x1A04); a.abs(0x8D, 0x1A07)
    a.abs(0x9C, 0x1A08)
    a.emit(0xA9, 0x11); a.abs(0x8D, 0x1A09)
    a.emit(0x60)

    code = a.finish()
    first_table_address = final_count_table if BIOS_MPR_TRANSFER else table_address
    if HELPER + len(code) > first_table_address:
        raise RuntimeError(
            f"dynamic helper ${HELPER:04X}-${HELPER + len(code):04X} overlaps "
            f"metadata table at ${first_table_address:04X}"
        )
    if BIOS_MPR_TRANSFER:
        final_counts = bytes(
            ((int(package["bytes"]) % CHUNK_BYTES + USER_BYTES - 1) // USER_BYTES)
            for package in packages
        )
        image = code + bytes((0xFF,)) * (final_count_table - (HELPER + len(code))) + final_counts + metadata
    else:
        image = code + bytes((0xFF,)) * (table_address - (HELPER + len(code))) + metadata
    image += bytes((0xFF,)) * (scratch - (HELPER + len(image))) + bytes(13)
    if HELPER + len(image) > HELPER_LIMIT:
        raise RuntimeError("Bank69 helper exceeds the verified 814-byte cave")
    return image, len(code)


def build_trampoline() -> bytes:
    """$7F88 -> 뱅크 $69 를 $A000 에 걸고 헬퍼를 부른 뒤 되돌린다.

    ★ 뱅크가 바뀌어 있는 동안 인터럽트를 막는다 (2026-08-19).

    안 막으면 이렇게 된다: `TAM` 으로 $A000-$BFFF 가 우리 헬퍼 뱅크($69)로
    바뀐 상태에서 IRQ 가 들어오면, 핸들러는 그 창이 여전히 게임 데이터
    뱅크($6C)인 줄 알고 읽는다.  실제로는 헬퍼 코드가 들어 있으므로 쓰레기를
    읽고 그리로 뛴다.

    조이 디비전 "쇼핑하기" 진행불가가 이것이었다.  실측 근거:
        폭주 PC 가 I/O 페이지($0005 · $0041) -> BRK 무한루프
        폭주 직전 IRQ2 가 명령어마다 터진다 (스택 푸시 417 만 회)
        그때 렌더러 원문 포인터가 $A001 -- 바로 그 교체 창 안이다
        원본 디스크 정상 · BIOS 무관 · 0.3.9 도 죽음(이 코드가 그때도 있었다)

    `SEI`/`CLI` 2 바이트다.  트램펄린은 100 바이트 자리에 20 바이트가 비어 있다.

    ★ `SEI`/`CLI` 가 아니라 `PHP`/`PLP` 를 쓴다 (소유자 지적, 2026-08-19).
      `CLI` 는 **무조건 여는 것**이라, 이 트램펄린이 인터럽트가 막힌 상태에서
      불린 적이 한 번이라도 있으면 그때 잘못 열어버린다.  "항상 열린 상태로만
      불린다"는 것은 확인된 적이 없다 -- 관측한 것은 "폭주 직전에는 열려 있었다"
      뿐이다.  들어올 때의 I 플래그를 그대로 복원하는 쪽이 맞다.  1 바이트 더 든다.

      순서: PHP -> SEI -> (뱅크 교체 · 헬퍼 · 뱅크 복원) -> PLP -> 상태 적재
      PLP 를 상태 적재보다 **앞에** 둔다.  그래야 반환 직전의 N/Z 가 `LDA $7FEE`
      의 결과로 남아 호출자가 보던 것과 같아진다.
    """
    a = common.Assembler(SECTOR_LOADER)
    a.emit(0x08)                                   # PHP -- 들어올 때의 I 플래그 보존
    a.emit(0x78)                                   # SEI -- 뱅크 교체 구간 보호
    a.emit(0x43, HELPER_EXEC_MPR_MASK, 0x48)
    a.emit(0xA9, 0x69, 0x53, HELPER_EXEC_MPR_MASK)
    a.abs(0x20, HELPER)
    a.abs(0x8D, 0x7FEE)  # preserve status without clobbering X
    a.emit(0x68, 0x53, HELPER_EXEC_MPR_MASK)
    a.emit(0x28)                                   # PLP -- 뱅크를 되돌린 뒤 원래대로
    a.abs(0xAD, 0x7FEE); a.emit(0x60)
    code = a.finish()
    if len(code) > LOADER_BYTES:
        raise RuntimeError("$7F88 trampoline exceeds original loader")
    return code + bytes((0xEA,)) * (LOADER_BYTES - len(code))


def stage_cue(track02_path: Path, track24_path: Path) -> Path:
    """Write the output CUE, hardlinking every track the build does not modify.

    Only Track 02 (three patched sectors) and Track 24 (base image plus the
    appended AC payload) differ from the source disc.  The other 21 tracks are
    byte-identical, so they are hardlinked rather than copied: a build folder
    then costs ~200 MB of real disk instead of ~600 MB.

    A silent fallback to copy is what turns a 200 MB build into a 600 MB one
    without anyone noticing, so a failed link raises instead.  Set
    SNATCHER_ALLOW_TRACK_COPY=1 to copy anyway (needed only if the output lands
    on a different volume or a filesystem without hardlinks).
    """

    allow_copy = os.environ.get("SNATCHER_ALLOW_TRACK_COPY") == "1"
    source_cue = next(BASE.glob("*.cue"))
    pattern = re.compile(r'^FILE "([^"]+)" BINARY$')
    lines: list[str] = []
    linked = copied = 0
    linked_bytes = 0
    for line in source_cue.read_text(encoding="ascii").splitlines():
        match = pattern.match(line)
        if not match:
            lines.append(line)
            continue
        source = BASE / match.group(1)
        if "Track 02" in source.name:
            target = track02_path
        elif "Track 24" in source.name:
            target = track24_path
        else:
            target = OUT / source.name
            if not target.exists():
                try:
                    target.hardlink_to(source)
                except OSError as exc:
                    if not allow_copy:
                        raise RuntimeError(
                            f"could not hardlink {source.name} into {OUT.name} ({exc}). "
                            "The output must sit on the same NTFS volume as the source "
                            "build. Set SNATCHER_ALLOW_TRACK_COPY=1 to copy instead — "
                            "that costs ~450 MB extra per build."
                        ) from exc
                    shutil.copy2(source, target)
                    copied += 1
                else:
                    linked += 1
                    linked_bytes += source.stat().st_size
            else:
                linked += 1
                linked_bytes += target.stat().st_size
        lines.append(f'FILE "{target.name}" BINARY')
    cue = OUT / f"Snatcher CD-ROMantic (Japan) [KO {VERSION}].cue"
    cue.write_text("\n".join(lines) + "\n", encoding="ascii")
    own = track02_path.stat().st_size + track24_path.stat().st_size
    print(f"tracks          : {linked} hardlinked ({linked_bytes / 2**20:,.0f} MB shared)"
          + (f", {copied} COPIED" if copied else ""))
    print(f"real disk cost  : {own / 2**20:,.0f} MB (Track 02 + Track 24 only)")
    return cue


def main() -> None:
    OUT.mkdir(parents=True, exist_ok=True)
    directory, packages, image, scene_base = build_packs()
    helper, helper_code_bytes = build_helper(packages, scene_base)
    trampoline = build_trampoline()

    source02 = next(path for path in BASE.glob("*.bin") if "Track 02" in path.name)
    old_loader = proof.read_user_bytes(source02, common.bank6a_iso(SECTOR_LOADER), LOADER_BYTES)
    source_helper = proof.read_user_bytes(source02, bank69_iso(HELPER), len(helper))
    if any(value != 0xFF for value in source_helper):
        raise RuntimeError(f"Bank69 helper cave is not empty in {BASE}")
    target02 = OUT / f"Snatcher CD-ROMantic (Japan) (Track 02) [KO {VERSION}].bin"
    proof.apply_patches_streaming(source02, target02, [
        common.Patch("dynamic_ac_loader", common.bank6a_iso(SECTOR_LOADER), old_loader, trampoline, SECTOR_LOADER),
        common.Patch("dynamic_ac_helper", bank69_iso(HELPER), source_helper, helper, HELPER),
    ])

    source24 = next(path for path in BASE.glob("*.bin") if "Track 24" in path.name)
    target24 = OUT / f"Snatcher CD-ROMantic (Japan) (Track 24) [KO {VERSION}].bin"
    shutil.copyfile(source24, target24)
    padded = image + bytes((-len(image)) % USER_BYTES)
    first_lba = 269122 + SLOT_COUNT
    appended = bytearray()
    for offset in range(0, len(padded), USER_BYTES):
        lba = first_lba + offset // USER_BYTES
        sector = track24.make_mode1_sector(lba, padded[offset:offset + USER_BYTES])
        track24.verify_mode1_sector(sector, lba)
        appended.extend(sector)
    with target24.open("ab") as handle:
        handle.write(appended)

    cue = stage_cue(target02, target24)
    for name in ("direct_records.tsv", "assets.tsv", "runtime_layout.json"):
        shutil.copy2(BASE / name, OUT / name)
    pack_dir = OUT / "ac_dynamic_packs"
    pack_dir.mkdir(exist_ok=True)
    (pack_dir / "slot_directory.bin").write_bytes(directory)
    (pack_dir / "disc_package_image.bin").write_bytes(image)

    subtitle_bytes = globals().get("SUBTITLE_AC_BYTES", 0)
    subtitle_base = globals().get("SUBTITLE_AC_BASE", AC_BYTES)

    manifest = {
        "version": VERSION,
        "base_build": str(BASE),
        "change": (
            f"demand-loaded AC scene packs via BIOS-managed MPR{BIOS_DESTINATION_MPR} destination mode"
            if BIOS_MPR_TRANSFER else
            "replace only $7F88 data supply with demand-loaded AC scene packs"
        ),
        "transfer_mode": (
            f"BIOS CD_READ destination type ${BIOS_DESTINATION_MPR:02X}, bank $40"
            if BIOS_MPR_TRANSFER else "caller-mapped MPR2"
        ),
        "lua_required": False,
        "directory_bytes": len(directory),
        "directory_initial_cd_chunks": len(directory) // CHUNK_BYTES,
        "common_data_base": f"{COMMON_DATA_BASE:05X}",
        "scene_data_base": f"{scene_base:05X}",
        # 자막 예약 구역이 있으면 씬 구역의 천장은 AC 끝이 아니라 그 바닥이다.
        # 예약을 올리지 않는 옛 체인에서는 기본값이 AC_BYTES 라 종전과 같다.
        "scene_capacity_bytes": subtitle_base - scene_base,
        "subtitle_reserve_base": f"{subtitle_base:05X}",
        "subtitle_reserve_bytes": subtitle_bytes,
        # 컷신 자막이 실행 중 쓸 RAM.  스테이지 3 이 올려 주면 찍는다
        # (PROBE_DEAD_RAM_0.1.1 실측, CD_PLAY 게이트).  값이 없으면 생략된다.
        **({"subtitle_ram_code": globals().get("SUBTITLE_RAM_CODE_TEXT")}
           if globals().get("SUBTITLE_RAM_CODE_TEXT") else {}),
        **({"subtitle_ram_code_bytes": globals().get("SUBTITLE_RAM_CODE_BYTES")}
           if globals().get("SUBTITLE_RAM_CODE_BYTES") else {}),
        **({"subtitle_ram_buffers": globals().get("SUBTITLE_RAM_BUFFERS_TEXT")}
           if globals().get("SUBTITLE_RAM_BUFFERS_TEXT") else {}),
        "package_count": len(packages),
        "resident_pack_names": list(RESIDENT_PACK_NAMES),
        "coalesce_small_scenes_max_records": COALESCE_SMALL_SCENES_MAX_RECORDS,
        "coalesce_small_scenes_target": COALESCE_SMALL_SCENES_TARGET,
        "packages": packages,
        "helper_code_bytes": helper_code_bytes,
        "helper_image_bytes": len(helper),
        "patched_track02_sha256": sha256_file(target02),
        "patched_track24_sha256": sha256_file(target24),
        "cue": cue.name,
        "preserved": ["$5E40 preloader", "$66E5 BODY/UI hook", "$7F50 font wrapper", "704-byte SRT4 records"],
    }
    (OUT / "manifest.json").write_text(json.dumps(manifest, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    (OUT / "TEST_IN_MESEN.txt").write_text(
        f"{VERSION}\n\nLoad {cue.name} and power-cycle. No Lua is required.\n"
        "Expected: the first Korean lookup loads the 64 KiB directory plus only its scene pack.\n"
        "UI/speaker/shared data remains resident after its first use; one scene pack is replaced on demand.\n"
        "Verify the opening, reception first dialogue, UI, and a save loaded into another scene.\n",
        encoding="utf-8-sig",
    )
    print(json.dumps(manifest, ensure_ascii=False, indent=2))


if __name__ == "__main__":
    main()
