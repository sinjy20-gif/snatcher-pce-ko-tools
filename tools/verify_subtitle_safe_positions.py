#!/usr/bin/env python3
"""Audit subtitle VRAM safety coverage and enforce the release gate.

The subtitle pack is authoritative: every ADPCM runtime key carried by the
pack must have a measured A/B VRAM pair.  Every CD-DA LBA window carried by
the pack must have a verified runtime-position row.  Development audits write
a report and succeed; ``--release`` refuses an incomplete shipping build.
"""
from __future__ import annotations

import argparse
import csv
import json
import struct
import sys
from pathlib import Path

if hasattr(sys.stdout, "reconfigure"):
    sys.stdout.reconfigure(encoding="utf-8")

ROOT = Path(__file__).resolve().parents[1]
BUILD = ROOT / "build" / "cutscene_subs"
PACK = BUILD / "subtitle_pack.bin"
ADPCM_POS = BUILD / "vram_key_bases_pairs.tsv"
ADPCM_SINGLE = BUILD / "vram_key_bases.tsv"
# 안전자리표의 키 이름을 팩이 쓰는 6 B 콘솔 키로 옮기는 다리.
# 팩 색인은 항목 앞 6 B 가 런타임 키다.  안전자리표는 세대에 따라 그 6 B 를
# 12 자 헥사로 적기도 하고(0.3 이하), 마스터 키 이름으로 적기도 한다
# (`ADPCM_003078_6800_0E` · build_vram_key_bases.py 3 세대).  이름 쪽을 거절하면
# 지도를 아무리 모아도 커버리지가 안 움직인다 (2026-09-01 · 50/902 에서 정지).
VOICE_CONSOLE_KEYS = ROOT / "snatcher_tool" / "translation" / "voice_console_keys.tsv"
CDDA_POS = BUILD / "cdda_runtime_safe_positions.tsv"
REPORT_JSON = BUILD / "subtitle_safe_coverage.json"
REPORT_TSV = BUILD / "subtitle_safe_missing.tsv"

VRAM_WORDS = 0x8000
VRAM_BODY_END = 0x1FFF
NEED_WORDS = 19 * 0x40
REQUIRED_ALIGN = 0x100


def rows(path: Path) -> list[dict[str, str]]:
    if not path.is_file():
        return []
    with path.open("r", encoding="utf-8-sig", newline="") as handle:
        return list(csv.DictReader(handle, delimiter="\t"))


def u24(blob: bytes, at: int) -> int:
    return blob[at] | (blob[at + 1] << 8) | (blob[at + 2] << 16)


def parse_pack() -> tuple[set[str], set[tuple[int, int]]]:
    if not PACK.is_file():
        raise SystemExit(f"subtitle pack missing: {PACK}")
    blob = PACK.read_bytes()
    if blob[:4] != b"SNSB" or struct.unpack_from("<H", blob, 4)[0] != 6:
        raise SystemExit("subtitle_pack.bin is not SNSB v6")
    adpcm_count, adpcm_at = struct.unpack_from("<HI", blob, 14)
    cdda_count, cdda_at = struct.unpack_from("<HI", blob, 20)
    adpcm_stride, cdda_stride = blob[42], blob[43]
    if (adpcm_stride, cdda_stride) != (13, 10):
        raise SystemExit(
            f"unsupported subtitle index strides: {adpcm_stride}/{cdda_stride}")

    adpcm = {
        blob[adpcm_at + n * adpcm_stride:adpcm_at + n * adpcm_stride + 6]
        .hex().upper()
        for n in range(adpcm_count)
    }
    cdda = {
        (u24(blob, cdda_at + n * cdda_stride),
         u24(blob, cdda_at + n * cdda_stride + 3))
        for n in range(cdda_count)
    }
    return adpcm, cdda


def parse_hex(value: str, where: str, problems: list[str]) -> int | None:
    try:
        return int(value, 16)
    except (TypeError, ValueError):
        problems.append(f"{where}: invalid hexadecimal address {value!r}")
        return None


def valid_base(base: int, where: str, problems: list[str]) -> bool:
    ok = True
    if base <= VRAM_BODY_END:
        problems.append(f"{where}: ${base:04X} overlaps BAT/SATB body")
        ok = False
    if base % REQUIRED_ALIGN:
        problems.append(f"{where}: ${base:04X} is not ${REQUIRED_ALIGN:04X}-aligned")
        ok = False
    if base + NEED_WORDS > VRAM_WORDS:
        problems.append(f"{where}: ${base:04X}+{NEED_WORDS} words leaves VRAM")
        ok = False
    if base >> 13 != (base + NEED_WORDS - 1) >> 13:
        problems.append(f"{where}: ${base:04X} crosses an 8K pattern bank")
        ok = False
    return ok


def console_key_map() -> dict[str, str]:
    """마스터 키 이름 -> 팩이 쓰는 12 자 런타임 키.  없으면 빈 표."""
    mapping: dict[str, str] = {}
    for row in rows(VOICE_CONSOLE_KEYS):
        name = (row.get("key") or "").strip().upper()
        text = (row.get("runtime_key_hex") or "").replace(" ", "").upper()
        if name and len(text) == 12:
            mapping[name] = text
    return mapping


def adpcm_positions(problems: list[str]) -> set[str]:
    result: set[str] = set()
    names = console_key_map()
    unmapped = 0
    for index, row in enumerate(rows(ADPCM_POS), 2):
        key = (row.get("key") or "").replace(" ", "").upper()
        where = f"{ADPCM_POS.name}:{index} {key or '(empty key)'}"
        if len(key) != 12 and key in names:
            key = names[key]          # 이름으로 적힌 세대 -- 콘솔 키로 옮긴다
        if len(key) != 12:
            # 이름인데 콘솔 키 표에 없으면 아직 수집이 안 된 음성이다.
            # 한 줄씩 쏟아내면 진짜 문제가 묻히므로 세어서 한 줄로 알린다.
            if key.startswith("ADPCM_"):
                unmapped += 1
                continue
            problems.append(f"{where}: runtime key must be 6 bytes")
            continue
        a = parse_hex(row.get("base_a", ""), where + " A", problems)
        b = parse_hex(row.get("base_b", ""), where + " B", problems)
        if a is None or b is None:
            continue
        ok = valid_base(a, where + " A", problems)
        ok = valid_base(b, where + " B", problems) and ok
        if a == b:
            problems.append(f"{where}: A and B are the same address")
            ok = False
        if a >> 13 != b >> 13:
            problems.append(f"{where}: A and B use different pattern banks")
            ok = False
        if key in result:
            problems.append(f"{where}: duplicate runtime key")
            ok = False
        if ok:
            result.add(key)
    if unmapped:
        print(f"  안전자리표의 키 {unmapped} 개가 voice_console_keys.tsv 에 없다"
              f" -- 아직 수집이 안 된 음성이다")
    # 현재 native directory가 실제로 싣는 것은 base_a 하나다. pair가 없는 키는
    # $100 정렬 단일표의 안전 base를 release fallback으로 인정한다.
    for index, row in enumerate(rows(ADPCM_SINGLE), 2):
        key = (row.get("key") or "").replace(" ", "").upper()
        where = f"{ADPCM_SINGLE.name}:{index} {key or '(empty key)'}"
        if len(key) != 12 and key in names:
            key = names[key]
        if len(key) != 12 or key in result:
            continue
        base = parse_hex(row.get("base", ""), where, problems)
        if base is None or not valid_base(base, where, problems):
            continue
        # helper는 $79xx를 CD-DA blank 자리로 취급하므로 ADPCM에는 못 쓴다.
        if (base >> 8) == 0x79:
            problems.append(f"{where}: $79xx is reserved for CD-DA blank restore")
            continue
        result.add(key)
    return result


def cdda_positions(problems: list[str]) -> set[tuple[int, int]]:
    result: set[tuple[int, int]] = set()
    for index, row in enumerate(rows(CDDA_POS), 2):
        where = f"{CDDA_POS.name}:{index}"
        try:
            window = (int(row.get("lba_from", "")), int(row.get("lba_to", "")))
        except ValueError:
            problems.append(f"{where}: invalid LBA window")
            continue
        if window[1] <= window[0]:
            problems.append(f"{where}: empty/reversed LBA window {window}")
            continue
        if (row.get("status") or "").strip().lower() != "verified":
            continue
        base = parse_hex(row.get("vram_base", ""), where, problems)
        if base is None or not valid_base(base, where, problems):
            continue
        if window in result:
            problems.append(f"{where}: duplicate LBA window {window}")
            continue
        result.add(window)
    return result


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--release", action="store_true",
        help="exit nonzero when any packed subtitle lacks a verified safe position",
    )
    args = parser.parse_args()

    packed_adpcm, packed_cdda = parse_pack()
    problems: list[str] = []
    mapped_adpcm = adpcm_positions(problems)
    mapped_cdda = cdda_positions(problems)
    missing_adpcm = sorted(packed_adpcm - mapped_adpcm)
    missing_cdda = sorted(packed_cdda - mapped_cdda)

    missing_rows = [
        {"audio_type": "ADPCM", "key": key, "lba_from": "", "lba_to": ""}
        for key in missing_adpcm
    ] + [
        {"audio_type": "CDDA", "key": "", "lba_from": str(a), "lba_to": str(b)}
        for a, b in missing_cdda
    ]
    BUILD.mkdir(parents=True, exist_ok=True)
    with REPORT_TSV.open("w", encoding="utf-8", newline="") as handle:
        writer = csv.DictWriter(
            handle,
            fieldnames=("audio_type", "key", "lba_from", "lba_to"),
            delimiter="\t", lineterminator="\n",
        )
        writer.writeheader()
        writer.writerows(missing_rows)

    report = {
        "policy": "release fails unless every packed subtitle has a verified safe VRAM position",
        "release_mode": args.release,
        "adpcm": {
            "packed_keys": len(packed_adpcm),
            "mapped_keys": len(packed_adpcm & mapped_adpcm),
            "missing_keys": len(missing_adpcm),
        },
        "cdda": {
            "packed_windows": len(packed_cdda),
            "mapped_windows": len(packed_cdda & mapped_cdda),
            "missing_windows": len(missing_cdda),
        },
        "invalid_position_rows": len(problems),
        "complete": not missing_rows and not problems,
        "missing_report": str(REPORT_TSV.relative_to(ROOT)).replace("\\", "/"),
        "problems": problems,
    }
    REPORT_JSON.write_text(
        json.dumps(report, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")

    print(
        f"ADPCM safe {report['adpcm']['mapped_keys']}/{report['adpcm']['packed_keys']}"
        f" · missing {len(missing_adpcm)}")
    print(
        f"CD-DA safe {report['cdda']['mapped_windows']}/{report['cdda']['packed_windows']}"
        f" · missing {len(missing_cdda)}")
    if problems:
        print(f"invalid position rows {len(problems)}")
        for problem in problems[:10]:
            print("  - " + problem)
    print(REPORT_JSON)
    if report["complete"]:
        print("PASS: release safety coverage is complete")
        return 0
    if args.release:
        print("BLOCKED: release build requires complete safe-position coverage")
        return 1
    print("DEVELOPMENT: incomplete coverage is reported but does not block work")
    return 0


if __name__ == "__main__":
    sys.exit(main())
