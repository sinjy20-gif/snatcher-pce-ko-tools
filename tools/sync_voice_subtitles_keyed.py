#!/usr/bin/env python3
"""스튜디오 표에서 `voice_subtitles_keyed.tsv` 를 다시 만든다 (2026-09-02).

원칙
----
**마스터(스튜디오 표)가 언제나 최신이고 정본이다.**  파생물은 그것을 따라간다.
승계하지 않는다 -- 마스터에 없는 행은 없는 것이다.

왜 필요한가
-----------
팩 빌더는 `voice_subtitles_keyed.tsv` 를 읽는데, 그 파일을 만드는
`build_voice_keys.py` 는 **자기 출력을 정본으로 읽는다**:

    if OUT_SUBS.exists():
        old_subs = read_tsv(OUT_SUBS)      # "이전에 만든 열쇠 표가 있으면 그쪽이 정본"

그 도구의 목적은 `event_id`(재생 한 번) -> `key`(음성 자체) **이관**이었고,
이관이 끝난 지금은 스튜디오 편집을 들여올 길이 없다.  그래서 조용히 낡는다.

    실측 2026-09-02
        voice_subtitles.tsv        21:43  2,213 행   스튜디오가 저장
        voice_subtitles_keyed.tsv  08:28  2,166 행   팩이 읽음
        자막이 다른 행 117 · 마스터에만 53 · 파생에만 6 (전부 옛 분할의 꼬리 조각)

두 표는 **첫 열 이름만 다르다** (`event_id` vs `key`).  나머지 아홉 열은 같고
식별자 값도 같은 형태(`ADPCM_003078_6800_0E`)다.  그래서 변환이 이름 하나다.

    python tools/sync_voice_subtitles_keyed.py            보고만
    python tools/sync_voice_subtitles_keyed.py --write    반영 (백업 먼저)
"""
from __future__ import annotations

import argparse
import csv
import io
import shutil
import sys
from datetime import datetime
from pathlib import Path

if hasattr(sys.stdout, "reconfigure"):
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")

ROOT = Path(__file__).resolve().parents[1]
TRANS = ROOT / "snatcher_tool" / "translation"
SRC = TRANS / "voice_subtitles.tsv"          # 스튜디오가 저장하는 정본
DST = TRANS / "voice_subtitles_keyed.tsv"    # 팩 빌더가 읽는 파생물


def read(path: Path) -> tuple[list[str], list[dict]]:
    rows = list(csv.DictReader(
        io.StringIO(path.read_bytes().decode("utf-8-sig")), delimiter="\t"))
    return (list(rows[0].keys()) if rows else []), rows


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--write", action="store_true")
    args = ap.parse_args()

    if not SRC.exists():
        raise SystemExit(f"정본이 없다: {SRC}")
    src_cols, src_rows = read(SRC)
    if not src_rows:
        raise SystemExit("정본이 비었다 -- 덮지 않는다")
    if src_cols[0] != "event_id":
        raise SystemExit(f"정본의 첫 열이 event_id 가 아니다: {src_cols[0]}")

    dst_cols, dst_rows = read(DST) if DST.exists() else ([], [])
    if dst_cols and dst_cols[1:] != src_cols[1:]:
        raise SystemExit("두 표의 열 구성이 다르다 -- 손으로 확인할 것\n"
                         f"  정본  {src_cols}\n  파생  {dst_cols}")

    old = {(r["key"], r["part"]): r.get("ko_text", "") for r in dst_rows}
    new = {(r["event_id"], r["part"]): r.get("ko_text", "") for r in src_rows}
    changed = sum(1 for k in old.keys() & new.keys() if old[k] != new[k])
    added = len(new.keys() - old.keys())

    print(f"정본 {len(src_rows):,}행 · 파생 {len(dst_rows):,}행")
    print(f"  자막이 바뀐 행 {changed:,} · 새로 들어올 행 {added:,}"
          f" · 사라질 행 {len(old.keys() - new.keys()):,}")
    for k in sorted(old.keys() - new.keys()):
        print(f"     사라짐  {k[0]} part {k[1]}  {old[k][:34]}")

    if not args.write:
        print("\n--write 를 주면 반영한다.  마스터가 정본이므로 승계는 하지 않는다.")
        return

    if DST.exists():
        stamp = datetime.now().strftime("%Y%m%d_%H%M%S")
        shutil.copy2(DST, DST.with_suffix(f".tsv.bak_sync_{stamp}"))

    out_cols = ["key"] + src_cols[1:]
    buf = io.StringIO()
    w = csv.DictWriter(buf, fieldnames=out_cols, delimiter="\t",
                       lineterminator="\n", extrasaction="ignore")
    w.writeheader()
    for r in src_rows:
        row = dict(r)
        row["key"] = row.pop("event_id")
        w.writerow(row)
    DST.write_text(buf.getvalue(), encoding="utf-8")
    print(f"\n기록 {DST.name}  {len(src_rows):,}행")


if __name__ == "__main__":
    main()
