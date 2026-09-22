#!/usr/bin/env python3
"""전체 ADPCM 음성 마스터용 시작-LBA 색인을 만든다.

현재 자막 팩의 902키만 대상으로 하는 ``build_pack_lba_index.py``와 달리,
이 도구는 ``voice_console_keys.tsv`` 전체 1,055행을 대상으로 한다.
효과음 판정은 ``voice_keys.tsv``의 사용자가 지정한 ``kind=효과음``만 보존하며,
``has_subtitle``나 추정값으로 행을 제거하지 않는다.

native dispatcher가 오인식하지 않도록 같은 시작 LBA에 여러 runtime key가 붙는
경우는 binary lookup 표에서 제외하고 충돌 보고에 남긴다. runtime key가 없는
행도 전체 보고에는 남기되 native lookup 표에는 넣을 수 없다.
"""
from __future__ import annotations

import argparse
import csv
import hashlib
import json
import math
import struct
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
VOICE_KEYS = ROOT / "snatcher_tool" / "translation" / "voice_keys.tsv"
CONSOLE_KEYS = ROOT / "snatcher_tool" / "translation" / "voice_console_keys.tsv"
OUT_BIN = ROOT / "build" / "cutscene_subs" / "adpcm_lba_master_index.bin"
OUT_TSV = ROOT / "build" / "cutscene_subs" / "adpcm_lba_master_index.tsv"
# ★ 충돌 행까지 포함한 전체 대응표.  자막 표 빌더가 LBA 별 묶기에 쓴다.
OUT_ALL_TSV = ROOT / "build" / "cutscene_subs" / "adpcm_lba_all.tsv"
OUT_JSON = ROOT / "build" / "cutscene_subs" / "adpcm_lba_master_index.json"
SECTOR_BYTES = 2048
STRIDE = 9                         # LBA 3 B + runtime key 6 B


def read_tsv(path: Path) -> list[dict[str, str]]:
    with path.open(encoding="utf-8-sig", newline="") as fh:
        return list(csv.DictReader(fh, delimiter="\t"))


def runtime_bytes(value: str) -> bytes | None:
    text = "".join((value or "").split())
    if len(text) != 12:
        return None
    try:
        return bytes.fromhex(text)
    except ValueError:
        return None


RAW_V014 = ROOT / "snatcher_tool" / "logs" / "voice_key_events_raw_v014.tsv"
SATURATED = 0xFF00                 # 이 이상이면 16 비트 포화로 본다


def true_lengths() -> dict[tuple[str, str], int]:
    """수집 로그의 실제 바이트 수.  (sector, rate) -> bytes_captured 최대값.

    `audio_length` 는 16 비트다.  64 KB 를 넘는 음성은 `FFxx` 로 포화하고,
    그 값으로 `start_lba` 를 계산하면 시작 섹터가 뒤로 밀린다.  실측:

        ADPCM_00359E  257,992 B  참 LBA 003520 · 포화값으로는 00357E  (94 섹터)
        ADPCM_0036C9  159,683 B  참 LBA 00367B · 포화값으로는 0036A9  (46 섹터)

    디스패처는 LBA 로 먼저 거르므로 그만큼이 통째로 미스가 된다.
    """
    if not RAW_V014.exists():
        return {}
    best: dict[tuple[str, str], int] = {}
    with RAW_V014.open(encoding="utf-8-sig", newline="") as fh:
        for row in csv.DictReader(fh, delimiter="	"):
            if row.get("audio_type") != "ADPCM" or row.get("event_type") != "END":
                continue
            try:
                n = int(row.get("bytes_captured") or 0)
            except ValueError:
                continue
            key = (row.get("sector", ""), row.get("playback_rate", ""))
            if n > best.get(key, -1):
                best[key] = n
    return best


def build_rows(repair: bool = False) -> tuple[list[dict], dict]:
    master = read_tsv(VOICE_KEYS)
    console = read_tsv(CONSOLE_KEYS)
    # ★ 2026-09-03: 보정을 끌 수 있게 했다.  스트리밍 음성은 디스패처가 찾아야 하는
    #   것이 '음성 전체의 시작'이 아니라 '재생 직전에 적재된 청크의 시작'이라
    #   실측 바이트로 되짚으면 오히려 너무 앞을 가리킬 수 있다.
    lengths = true_lengths() if repair else {}
    repaired = 0
    kinds = {row.get("key", ""): (row.get("kind") or "").strip() for row in master}

    rows: list[dict] = []
    missing_runtime: list[str] = []
    for row in console:
        key = row.get("key", "")
        runtime = runtime_bytes(row.get("runtime_key_hex", ""))
        if runtime is None:
            missing_runtime.append(key)
            continue
        try:
            end_sector = int(key.split("_")[1], 16)
            audio_length = int(row["audio_length"], 16)
        except (KeyError, ValueError, IndexError) as exc:
            raise SystemExit(f"잘못된 voice_console_keys 행: {key}: {exc}") from exc
        # ★ 포화된 길이는 실측 바이트로 바꾼다 (2026-09-02).
        if audio_length >= SATURATED:
            parts = key.split("_")
            real = lengths.get((parts[1], parts[3])) if len(parts) >= 4 else None
            if real:
                audio_length = real
                repaired += 1
        start_lba = end_sector - math.ceil(audio_length / SECTOR_BYTES)
        if not 0 <= start_lba < 1 << 24:
            raise SystemExit(f"시작 LBA 범위 초과: {key} -> {start_lba:X}")
        rows.append({
            "key": key,
            "lba": start_lba,
            "runtime": runtime,
            "kind": kinds.get(key, ""),
            "has_subtitle": row.get("has_subtitle", ""),
        })

    by_lba: dict[int, list[dict]] = {}
    for row in rows:
        by_lba.setdefault(row["lba"], []).append(row)
    collisions = {lba: group for lba, group in by_lba.items() if len(group) > 1}
    unique = [group[0] for lba, group in sorted(by_lba.items()) if lba not in collisions]

    # ★ 전체 대응표를 따로 낸다 (2026-09-02).  충돌로 이진 조회표에서 빠진 행도
    #   자막 표 빌더는 알아야 한다 -- 같은 LBA 를 한 버킷으로 묶어 함께 싣기 위해서다.
    OUT_ALL_TSV.parent.mkdir(parents=True, exist_ok=True)
    with OUT_ALL_TSV.open("w", encoding="utf-8", newline="") as fh:
        w = csv.writer(fh, delimiter="\t", lineterminator="\n")
        w.writerow(("start_lba", "runtime_key_hex", "key", "kind", "has_subtitle",
                    "in_binary_index"))
        drop = {row["key"] for group in collisions.values() for row in group}
        for row in sorted(rows, key=lambda r: (r["lba"], r["key"])):
            w.writerow((f"{row['lba']:06X}", row["runtime"].hex(" ").upper(),
                        row["key"], row["kind"], row["has_subtitle"],
                        "0" if row["key"] in drop else "1"))

    stats = {
        "length_repair": repair,
        "repaired_rows": repaired,
        "master_rows": len(master),
        "console_rows": len(console),
        "runtime_rows": len(rows),
        "missing_runtime_rows": len(missing_runtime),
        "unique_runtime_keys": len({row["runtime"] for row in rows}),
        "unique_lba_entries": len(unique),
        "collision_lbas": len(collisions),
        "collision_rows": sum(len(group) for group in collisions.values()),
        "explicit_effect_rows": sum(row["kind"] == "효과음" for row in rows),
        "explicit_dialogue_rows": sum(row["kind"] == "대사" for row in rows),
        "untyped_rows": sum(not row["kind"] for row in rows),
        "missing_runtime_keys": missing_runtime,
        "collision_details": {
            f"{lba:06X}": [row["key"] for row in group]
            for lba, group in sorted(collisions.items())
        },
    }
    return unique, stats


def encode(rows: list[dict]) -> bytes:
    out = bytearray()
    for row in rows:
        lba = row["lba"]
        out += bytes(((lba >> 16) & 0xFF, (lba >> 8) & 0xFF, lba & 0xFF))
        out += row["runtime"]
    return bytes(out)


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--out-bin", type=Path, default=OUT_BIN)
    ap.add_argument("--out-tsv", type=Path, default=OUT_TSV)
    ap.add_argument("--out-json", type=Path, default=OUT_JSON)
    # ★★ 2026-09-03: 기본값을 **껌**으로 뒤집었다.
    #
    #   보정은 AD_PLAY 모형이다 -- 클립 전체를 읽고 재생하므로 헤드가
    #   start+전체길이 에 선다.  그런데 AD_CPLAY(스트리밍)는 **32 섹터만**
    #   선적재하고 시작하고($229D=$20), 포화값 0xFFxx 는 정확히 32 섹터로
    #   올림된다 -> **보정을 끈 값이 구조적으로 맞다.**
    #
    #   실측 (0.5.138 트레이스)   len=FFC3 -> 32섹터   READ 003123 + 32 = 003143  ✓
    #   실측 (0.4.6.70 실기)      003123 자막이 화면에 떴다
    #
    #             보정 켬   보정 껌
    #   디렉터리 968 중 색인에 없는 것   154        0
    #   LBA 충돌로 잃는 항목             12         0
    #   비스트리밍 음성이 바뀌는 수       -         0   (회귀 위험 없음)
    #
    #   ⚠ 옵션으로 두었더니 기준판을 다시 구울 때마다 켬으로 돌아가 149 건이
    #     조용히 다시 막혔다 (09-03 에 실제로 발생).  그래서 기본값을 바꾼다.
    ap.add_argument("--length-repair", action="store_true",
                    help="옛 포화 길이 보정을 다시 켠다 (권장하지 않음)")
    ap.add_argument("--no-length-repair", action="store_true",
                    help="포화 길이를 실측 바이트로 바꾸지 않는다 (포화값 그대로 쓴다)")
    args = ap.parse_args()

    rows, stats = build_rows(repair=args.length_repair)
    blob = encode(rows)
    args.out_bin.parent.mkdir(parents=True, exist_ok=True)
    args.out_bin.write_bytes(blob)

    with args.out_tsv.open("w", encoding="utf-8", newline="") as fh:
        writer = csv.writer(fh, delimiter="\t", lineterminator="\n")
        writer.writerow(("start_lba", "runtime_key_hex", "key", "kind", "has_subtitle"))
        for row in rows:
            writer.writerow((f"{row['lba']:06X}", row["runtime"].hex(" ").upper(),
                             row["key"], row["kind"], row["has_subtitle"]))

    info = {
        "format": "LBA 3 B MSB first + runtime key 6 B",
        "stride": STRIDE,
        "source": [str(VOICE_KEYS.relative_to(ROOT)),
                   str(CONSOLE_KEYS.relative_to(ROOT))],
        "start_lba_formula": "sector - ceil(audio_length / 2048)",
        "length_repair": args.length_repair,
        "sha256": hashlib.sha256(blob).hexdigest().upper(),
        "stats": stats,
    }
    args.out_json.write_text(json.dumps(info, ensure_ascii=False, indent=2) + "\n",
                             encoding="utf-8")

    print(f"전체 ADPCM 마스터 {stats['master_rows']}행")
    print(f"  runtime key {stats['runtime_rows']}행 · 고유 {stats['unique_runtime_keys']}개")
    print(f"  explicit 효과음 {stats['explicit_effect_rows']}행 · 대사 {stats['explicit_dialogue_rows']}행")
    print(f"  native lookup {stats['unique_lba_entries']}개 · LBA 충돌 {stats['collision_lbas']}개")
    print(f"  runtime 누락 {stats['missing_runtime_rows']}행")
    print(f"  포화 길이 보정 {'켬' if stats['length_repair'] else '★껌'} · 보정된 행 {stats['repaired_rows']}")
    print(f"  -> {args.out_bin}")
    print(f"  -> {args.out_tsv}")
    print(f"  -> {args.out_json}")


if __name__ == "__main__":
    main()
