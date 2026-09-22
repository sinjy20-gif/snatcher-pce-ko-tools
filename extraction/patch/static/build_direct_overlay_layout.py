#!/usr/bin/env python3
"""Build the one-read SRT4 Korean overlay table.

SRT3 stores a compact lookup bucket and a separate text/font asset.  That is
space efficient, but every translated line needs two synchronous CD reads.
SRT4 uses a 16K open-addressed sector table.  Each occupied sector contains
the routing signature, Korean text, and its complete local font pack, so the
normal successful path needs a single CD read.
"""

from __future__ import annotations

import argparse
import csv
import os
import hashlib
import json
import shutil
import sys
from pathlib import Path


ROOT = Path(r"C:\snatcher")
STATIC_DIR = ROOT / "extraction" / "patch" / "static"
TRANSLATION_DIR = ROOT / "extraction" / "translation"
DEFAULT_OUT = ROOT / "build" / "translation" / "current" / "runtime_layout_direct"
LEGACY_SUBDIR = "srt3_source"

sys.path[:0] = [str(STATIC_DIR), str(TRANSLATION_DIR)]

import build_full_overlay_layout as srt3  # noqa: E402
import build_track24_loader_proof as track24  # noqa: E402


FORMAT = "SRT4"
SLOT_COUNT = 0x4000
SLOT_MASK = SLOT_COUNT - 1
MAGIC = b"SDR4"

# Lift speaker names by one scanline along with the UI labels.
SPEAKER_LIFT = os.environ.get("SNATCHER_SPEAKER_LIFT", "0") == "1"
# Record kinds drawn in the UI band, which is one scanline above the BODY
# baseline.  BODY dialogue stays where it is -- that baseline is correct.
LIFTED_KINDS = {"ui", "speaker"} if SPEAKER_LIFT else {"ui"}

# The remainder of the sector deliberately preserves SRT3's asset layout.
TEXT_OFFSET = srt3.ASSET_HEADER_SIZE
TEXT_CAPACITY = srt3.ASSET_TEXT_CAPACITY
FONT_OFFSET = srt3.ASSET_FONT_OFFSET
FONT_BYTES = srt3.FONT_BYTES
READ_BYTES = srt3.ASSET_READ_BYTES
FRACTIONAL_SPACE_HELPER_INDEX = srt3.FRACTIONAL_SPACE_HELPER_INDEX
FRACTIONAL_SPACE_HELPER = srt3.FRACTIONAL_SPACE_HELPER

# First proof target: the four-item reception action menu.  A normal SRT4
# sector carries one source string, so opening this menu used four synchronous
# Track-24 reads.  These rows receive a compact menu-session payload instead:
# the first item still works through the normal SRT4 route, while the renderer
# can select the other three strings from the already loaded cache.
MENU_SESSION_REFS = (
    "ui:UI0001",  # 見る       -> 보다
    "ui:UI0002",  # 調べる     -> 조사하다 (current TSV spelling is preserved)
    "ui:UI0003",  # 聞く       -> 묻다
    "ui:UI0004",  # 話す       -> 대화하다
)
MENU_MARKER = b"UI"
MENU_TEXT_BLOB_OFFSET = 0x20
MENU_INDEX_OFFSET = 0x40
MENU_INDEX_ENTRY_SIZE = 3  # source first byte, source byte length, text offset
UI_HANGUL_Y_SHIFT = -1


def sha256(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest().upper()


def cumulative_signature(source: bytes) -> tuple[int, int, int]:
    xor_value = 0
    running = 0
    cumulative = 0
    for value in source:
        xor_value ^= value
        running = (running + value) & 0xFF
        cumulative = (cumulative + running) & 0xFF
    return len(source), xor_value, cumulative


def direct_hash(state: int, source: bytes) -> int:
    """Hash reproduced by the compact HuC6280 preloader.

    The coefficients were selected from a deterministic search over cheap
    shift/add combinations.  On the current 5,059-record corpus this yields
    an average successful probe count of about 1.20 and a maximum of six.
    """

    _, _, cumulative = cumulative_signature(source)
    return (sum(source) + state * 257 + cumulative * 65) & SLOT_MASK


def edge_signature(source: bytes) -> tuple[int, int, int, int]:
    if not source:
        return 0, 0, 0, 0
    first = source[0]
    second = source[1] if len(source) > 1 else first
    penultimate = source[-2] if len(source) > 1 else first
    last = source[-1]
    return first, second, penultimate, last


def shift_glyph_up_one_scanline(glyph: bytes) -> bytes:
    """Move one 16x16 1bpp glyph up one scanline without changing its size."""

    if len(glyph) != 32:
        raise ValueError(f"expected one 32-byte glyph, got {len(glyph)} bytes")
    return glyph[2:] + b"\x00\x00"


def shift_ui_hangul_font(font: bytearray, hangul_count: int) -> None:
    """Lift only Hangul slots; F040-F042 punctuation/helper slots stay native."""

    for index in range(hangul_count):
        start = (3 + index) * 32
        end = start + 32
        font[start:end] = shift_glyph_up_one_scanline(bytes(font[start:end]))


def build_menu_session_payloads(records: list[dict[str, str]]) -> dict[str, bytes]:
    """Return one cacheable payload per target menu source.

    Each payload has the currently requested text at the normal $5B90 offset,
    plus the other menu texts and a tiny first-byte/length index.  They all
    share one union font pack, so a cache hit never needs another CD read.
    """

    by_ref = {record["reference"]: record for record in records}
    missing = [ref for ref in MENU_SESSION_REFS if ref not in by_ref]
    if missing:
        raise RuntimeError(f"menu-session proof rows missing: {missing}")
    group = [by_ref[ref] for ref in MENU_SESSION_REFS]
    # BIOS 판은 한글을 시스템 카드 글리프로 내보내므로 메뉴 세션도 구울 것이 없다.
    # (srt3.BIOS_HANGUL 은 build_full_overlay_layout 의 같은 스위치다.)
    glyphs = () if srt3.BIOS_HANGUL else srt3.ordered_hangul(
        [record["ko_text"] for record in group])
    if len(glyphs) > srt3.FONT_GLYPH_CAPACITY - 4:
        raise RuntimeError("menu-session glyph union exceeds cache font capacity")
    found = srt3.parse_bdf(srt3.FONT_BDF, {ord(char) for char in glyphs})
    missing_glyphs = [char for char in glyphs if ord(char) not in found]
    if missing_glyphs:
        raise RuntimeError(f"menu-session missing Galmuri glyphs: {missing_glyphs}")
    custom = {char: bytes(srt3.HANGUL_CODES[index]) for index, char in enumerate(glyphs)}
    encoded_by_ref = {
        record["reference"]: srt3.encode_game_text(record["ko_text"], custom)
        for record in group
    }

    font = bytearray(srt3.period_glyph() + bytes(32) + srt3.ellipsis_glyph())
    for char in glyphs:
        font.extend(srt3.glyph_1bpp_left_shifted(*found[ord(char)]))
    font.extend(bytes(srt3.FONT_BYTES - len(font)))
    shift_ui_hangul_font(font, len(glyphs))
    helper = srt3.FRACTIONAL_SPACE_HELPER_INDEX * 32
    font[helper:helper + 32] = srt3.FRACTIONAL_SPACE_HELPER

    results: dict[str, bytes] = {}
    for active in group:
        active_ref = active["reference"]
        offsets: dict[str, int] = {active_ref: TEXT_OFFSET}
        cursor = MENU_TEXT_BLOB_OFFSET
        payload = bytearray(track24.USER_DATA_SIZE)
        for record in group:
            ref = record["reference"]
            if ref == active_ref:
                continue
            encoded = encoded_by_ref[ref]
            offsets[ref] = cursor
            payload[cursor:cursor + len(encoded)] = encoded
            cursor += len(encoded)
        if cursor > MENU_INDEX_OFFSET:
            raise RuntimeError("menu-session text blob overlaps its index")

        source = bytes.fromhex(active["source_hex"])
        source_len, xor_value, cumulative = cumulative_signature(source)
        payload[0:4] = MAGIC
        payload[4] = len(encoded_by_ref[active_ref])
        payload[5] = source_len
        payload[6] = xor_value
        payload[7] = cumulative
        payload[8:10] = int(active["state"], 16).to_bytes(2, "little")
        payload[10:12] = int(active["next_state"], 16).to_bytes(2, "little")
        payload[12:16] = MENU_MARKER + bytes((len(group), 0))
        payload[TEXT_OFFSET:TEXT_OFFSET + len(encoded_by_ref[active_ref])] = encoded_by_ref[active_ref]
        for index, record in enumerate(group):
            source = bytes.fromhex(record["source_hex"])
            offset = MENU_INDEX_OFFSET + index * MENU_INDEX_ENTRY_SIZE
            payload[offset:offset + MENU_INDEX_ENTRY_SIZE] = bytes(
                (source[0], len(source), offsets[record["reference"]])
            )
        payload[FONT_OFFSET:FONT_OFFSET + len(font)] = font
        results[active_ref] = bytes(payload)
    return results


def write_tsv(path: Path, rows: list[dict[str, str]]) -> None:
    if not rows:
        path.write_text("", encoding="utf-8")
        return
    with path.open("w", encoding="utf-8-sig", newline="") as handle:
        writer = csv.DictWriter(
            handle,
            fieldnames=list(rows[0]),
            delimiter="\t",
            lineterminator="\n",
        )
        writer.writeheader()
        writer.writerows(rows)


def build(
    master: Path,
    speakers: Path,
    ui_text: Path,
    out_dir: Path,
    compiled_dir: Path,
    clean: bool,
    source_layout: Path | None = None,
    review_only: bool = False,
    include_ui: bool = True,
) -> dict:
    if clean and out_dir.exists():
        shutil.rmtree(out_dir)
    out_dir.mkdir(parents=True, exist_ok=True)

    owns_legacy = source_layout is None
    legacy_dir = out_dir / LEGACY_SUBDIR if owns_legacy else source_layout
    if owns_legacy:
        # SRT3 버킷은 여기서 만들어 곧바로 지우던 중간물이다 (아래 unlink 참고).
        # SRT4 가 받는 것은 lookup_records.tsv 뿐이고, 런타임은 16K 슬롯 하나를
        # 읽는다 -- 버킷을 워킹램에 올려 훑지 않는다.  그런데도 SRT3 의
        # 704 B / 레코드 77 개 한도가 SRT4 빌드를 죽이고 있었다.  안 실을
        # 버킷이므로 한도로 멈추지 않게 하고, 2 MB 섹터도 아예 안 쓴다.
        legacy_manifest = srt3.build(
            master,
            speakers,
            ui_text,
            legacy_dir,
            compiled_dir,
            clean=True,
            review_only=review_only,
            include_ui=include_ui,
            ship_buckets=False,
            # SRT4's serialized record format has no wildcard-state lookup.
            # Preserve every contextual state instead of importing SRT3's
            # compact FFFF wildcard records as false root (0000) records.
            collapse_identical=False,
        )
    else:
        required = (
            legacy_dir / "lookup_records.tsv",
            legacy_dir / "asset_user_sectors.bin",
            legacy_dir / "assets.tsv",
            legacy_dir / "runtime_layout.json",
        )
        missing = [str(path) for path in required if not path.exists()]
        if missing:
            raise RuntimeError(f"incomplete source SRT3 layout: {missing}")
        legacy_manifest = json.loads((legacy_dir / "runtime_layout.json").read_text(encoding="utf-8"))

    with (legacy_dir / "lookup_records.tsv").open(
        "r", encoding="utf-8-sig", newline=""
    ) as handle:
        records = list(csv.DictReader(handle, delimiter="\t"))
    asset_data = (legacy_dir / "asset_user_sectors.bin").read_bytes()
    if len(asset_data) % track24.USER_DATA_SIZE:
        raise RuntimeError("unaligned SRT3 asset sectors")

    slots: list[bytes | None] = [None] * SLOT_COUNT
    rows: list[dict[str, str]] = []
    probe_counts: list[int] = []

    for record in records:
        source = bytes.fromhex(record["source_hex"])
        if not source or len(source) > 0xFF:
            raise RuntimeError(f"invalid source length: {record['reference']}")

        raw_state = int(record["state"], 16)
        if raw_state == srt3.WILDCARD_STATE and record["kind"] == "dialogue":
            raise RuntimeError(
                "SRT4 cannot consume a collapsed wildcard record; rebuild its "
                "SRT3 source with collapse_identical=False"
            )
        # Speaker/UI wildcard records are valid from root.  The SRT3 builder
        # has already rejected conflicting root dialogue records.
        state = 0 if raw_state == srt3.WILDCARD_STATE else raw_state
        next_state = int(record["next_state"], 16)
        asset_index = int(record["asset_index"])
        start = asset_index * track24.USER_DATA_SIZE
        payload = bytearray(asset_data[start:start + track24.USER_DATA_SIZE])
        if len(payload) != track24.USER_DATA_SIZE or payload[:4] != b"AST2":
            raise RuntimeError(f"bad source asset {asset_index}")

        # UI uses the same renderer and SRT4 format as BODY.  Preserve that
        # architecture and adjust only the UI record's local Hangul bitmaps,
        # matching the previously validated static-UI baseline alignment.
        hangul_glyph_count = payload[5]
        # Speaker names are drawn in the UI band, not on the BODY baseline, so
        # they need the same one-scanline lift the UI labels get.  They never
        # got it -- the test was `kind == "ui"` alone -- and all 55 of them sat
        # a pixel low against the labels beside them (2026-08-16, owner, 국장).
        #
        # Off by default so 0.3.3-0.3.8.6 still reproduce; 0.3.8.7 turns it on.
        if record["kind"] in LIFTED_KINDS:
            font = bytearray(payload[FONT_OFFSET:FONT_OFFSET + FONT_BYTES])
            shift_ui_hangul_font(font, hangul_glyph_count)
            payload[FONT_OFFSET:FONT_OFFSET + FONT_BYTES] = font

        source_len, xor_value, cumulative = cumulative_signature(source)
        first, second, penultimate, last = edge_signature(source)
        text_len = payload[4]
        payload[0:4] = MAGIC
        payload[4] = text_len
        payload[5] = source_len
        payload[6] = xor_value
        payload[7] = cumulative
        payload[8:10] = state.to_bytes(2, "little")
        payload[10:12] = next_state.to_bytes(2, "little")
        payload[12:16] = bytes((first, second, penultimate, last))

        # The one-read runtime executes the fractional-space helper directly
        # from the loaded sector cache.  Do not rely on a previously generated
        # SRT3 asset cache to contain it: older source layouts left this final
        # font slot blank, which made a successful lookup overwrite the helper
        # at $5E20 with zeroes.
        helper_offset = FONT_OFFSET + FRACTIONAL_SPACE_HELPER_INDEX * 32
        payload[helper_offset:helper_offset + len(FRACTIONAL_SPACE_HELPER)] = (
            FRACTIONAL_SPACE_HELPER
        )

        primary = direct_hash(state, source)
        slot = primary
        probes = 1
        while slots[slot] is not None:
            slot = (slot + 1) & SLOT_MASK
            probes += 1
            if probes > SLOT_COUNT:
                raise RuntimeError("SRT4 direct table is full")
        slots[slot] = bytes(payload)
        probe_counts.append(probes)
        rows.append(
            {
                "primary_slot": f"{primary:04X}",
                "final_slot": f"{slot:04X}",
                "probe_count": str(probes),
                "state": f"{state:04X}",
                "next_state": f"{next_state:04X}",
                "source_length": str(source_len),
                "source_xor": f"{xor_value:02X}",
                "source_cumulative": f"{cumulative:02X}",
                "source_edges": f"{first:02X} {second:02X} {penultimate:02X} {last:02X}",
                "source_hex": source.hex(" ").upper(),
                "asset_index": str(asset_index),
                "kind": record["kind"],
                "reference": record["reference"],
                "ko_text": record["ko_text"],
                "hangul_y_shift": str(UI_HANGUL_Y_SHIFT
                                      if record["kind"] in LIFTED_KINDS else 0),
            }
        )

    # The menu-session payloads exist solely for the experimental Korean UI
    # path.  With UI disabled, their proof rows are intentionally absent.
    session_payloads = build_menu_session_payloads(rows) if include_ui else {}
    for row in rows:
        replacement = session_payloads.get(row["reference"])
        if replacement is not None:
            slots[int(row["final_slot"], 16)] = replacement
            row["menu_session"] = "reception-action-v1"
        else:
            row["menu_session"] = ""

    empty = bytes(track24.USER_DATA_SIZE)
    direct_path = out_dir / "direct_user_sectors.bin"
    with direct_path.open("wb") as handle:
        for payload in slots:
            handle.write(payload if payload is not None else empty)

    # Verify every route through the serialized table, including the probe
    # chain and the compact signature that the runtime checks.
    serialized = direct_path.read_bytes()
    for row in rows:
        source = bytes.fromhex(row["source_hex"])
        state = int(row["state"], 16)
        source_len, xor_value, cumulative = cumulative_signature(source)
        edges = bytes(edge_signature(source))
        slot = direct_hash(state, source)
        for _ in range(max(probe_counts)):
            payload = serialized[
                slot * track24.USER_DATA_SIZE:(slot + 1) * track24.USER_DATA_SIZE
            ]
            if payload[:4] == bytes(4):
                raise RuntimeError(f"route terminated before match: {row['reference']}")
            if (
                payload[:4] == MAGIC
                and int.from_bytes(payload[8:10], "little") == state
                and payload[5] == source_len
                and payload[6] == xor_value
                and payload[7] == cumulative
                and (
                    payload[12:16] == edges
                    or (
                        row["reference"] in MENU_SESSION_REFS
                        and payload[12:14] == MENU_MARKER
                    )
                )
            ):
                break
            slot = (slot + 1) & SLOT_MASK
        else:
            raise RuntimeError(f"route did not match: {row['reference']}")

    write_tsv(out_dir / "direct_records.tsv", rows)
    shutil.copyfile(legacy_dir / "assets.tsv", out_dir / "assets.tsv")

    occupied = len(records)
    manifest = {
        "format": FORMAT,
        "description": "16K open-addressed one-read source/text/font sectors",
        "source_layout": str(legacy_dir),
        "review_only": bool(legacy_manifest.get("review_only", False)),
        "reviewed_source_rows": int(legacy_manifest.get("reviewed_source_rows", 0)),
        "review_exception_rows": int(legacy_manifest.get("review_exception_rows", 0)),
        "review_marked_rows": int(legacy_manifest.get("review_marked_rows", 0)),
        "normalized_root_conflicts": int(legacy_manifest.get("normalized_root_conflicts", 0)),
        "normalized_sequence_conflicts": int(legacy_manifest.get("normalized_sequence_conflicts", 0)),
        "translation_master": legacy_manifest.get("translation_master", str(master)),
        "translation_master_sha256": legacy_manifest.get(
            "translation_master_sha256", sha256(master.read_bytes())
        ),
        "speaker_name_standard": legacy_manifest.get("speaker_name_standard", str(speakers)),
        "speaker_name_standard_sha256": legacy_manifest.get(
            "speaker_name_standard_sha256", sha256(speakers.read_bytes())
        ),
        "ui_text": legacy_manifest.get("ui_text", str(ui_text)),
        "ui_text_sha256": legacy_manifest.get("ui_text_sha256", sha256(ui_text.read_bytes())),
        "slot_count": SLOT_COUNT,
        "slot_mask": f"{SLOT_MASK:04X}",
        "occupied_slots": occupied,
        "load_factor": occupied / SLOT_COUNT,
        "hash": "(byte_sum + state*257 + cumulative*65) modulo 16384",
        "average_successful_probes": sum(probe_counts) / len(probe_counts),
        "maximum_successful_probes": max(probe_counts),
        "p95_successful_probes": sorted(probe_counts)[int(len(probe_counts) * 0.95)],
        "text_offset": TEXT_OFFSET,
        "text_capacity": TEXT_CAPACITY,
        "font_offset": FONT_OFFSET,
        "font_bytes": FONT_BYTES,
        "ui_hangul_y_shift": UI_HANGUL_Y_SHIFT,
        "ui_hangul_shift_policy": "UI SRT4 local Hangul glyph slots only; BODY and punctuation unchanged",
        "read_bytes": READ_BYTES,
        "record_count": len(records),
        "menu_session_cache": {
            "enabled": include_ui,
            "target": "reception-action-v1",
            "references": list(MENU_SESSION_REFS),
            "index_offset": f"{MENU_INDEX_OFFSET:02X}",
        },
        "asset_count": legacy_manifest["asset_count"],
        "track24_added_sectors": SLOT_COUNT,
        "track24_added_raw_bytes": SLOT_COUNT * track24.RAW_SECTOR_SIZE,
        "files": {
            "direct_user_sectors.bin": {
                "bytes": direct_path.stat().st_size,
                "sha256": sha256(serialized),
            }
        },
    }
    (out_dir / "runtime_layout.json").write_text(
        json.dumps(manifest, ensure_ascii=False, indent=2) + "\n",
        encoding="utf-8",
    )

    # The direct table contains everything needed by the patch.  Remove the
    # large temporary SRT3 sector files but keep its small audit manifests.
    if owns_legacy:
        for name in ("lookup_user_sectors.bin", "asset_user_sectors.bin", "track24_overlay_user.bin"):
            candidate = legacy_dir / name
            if candidate.exists():
                candidate.unlink()
    return manifest


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--master", type=Path, default=srt3.DEFAULT_MASTER)
    parser.add_argument("--speakers", type=Path, default=srt3.DEFAULT_SPEAKERS)
    parser.add_argument("--ui", type=Path, default=srt3.DEFAULT_UI)
    parser.add_argument("--compiled-dir", type=Path, default=srt3.DEFAULT_COMPILED)
    parser.add_argument("--out", type=Path, default=DEFAULT_OUT)
    parser.add_argument(
        "--source-layout",
        type=Path,
        help="optional SRT3 audit layout; it must have been built without wildcard collapse",
    )
    parser.add_argument("--clean", action="store_true")
    parser.add_argument("--review-only", action="store_true")
    args = parser.parse_args()
    manifest = build(
        args.master,
        args.speakers,
        args.ui,
        args.out,
        args.compiled_dir,
        args.clean,
        args.source_layout,
        args.review_only,
    )
    print(
        f"SRT4 records={manifest['record_count']} slots={manifest['slot_count']} "
        f"avg_probe={manifest['average_successful_probes']:.3f} "
        f"max_probe={manifest['maximum_successful_probes']}"
    )


if __name__ == "__main__":
    main()
