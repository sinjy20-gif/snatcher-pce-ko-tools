#!/usr/bin/env python3
"""ac_0.1.11 을 **장소(pack) 단위 씬 팩**으로 나눠 굽는다.

왜
--
지금은 팩이 셋뿐이고 셋 다 상주다 (speaker 6 KB · ui 92 KB · runtime 936 KB).
그래서 첫 조회가 일어나는 자리에서 **1,033 KB 를 한꺼번에 붓는다 -- 32 초.**
그 적재가 UI 창과 겹치면 화면이 깨진다 (0.4.5.7 부터 보고됨).

기계는 이미 다 있다.  `lookup -> load_package` 가 팩 단위 요구시 적재를 하고,
팩마다 자기 주소와 자기 플래그를 갖는다 (0.1.14 주석: "Give each its own
address and it loads once", "Every pack now owns a flag byte").
**팩이 하나로 뭉쳐 있는 것만 문제였다.**

무엇으로 나누나
---------------
마스터의 `pack` 열이 곧 **장소**다 (소유자 확인 2026-08-26).

    74 본부 · 75 국장실 · 76 컴퓨터실 · 6D 주차장 · 71 시내 · 72 장의 환경 A ...

한 장소 안에는 챕터 1·2·3 대사가 다 들어 있다.  그래서 장소로 나누면 그 장소에
있는 동안 다시 읽을 일이 없다 -- 챕터로 나누면 같은 장소를 챕터마다 다시 읽는다.

원래 `classify_runtime_scene` 은 `runtime_text_catalog_*.tsv` 를 봤는데, 스튜디오가
쓴 현역 카탈로그가 보관소로 안 옮겨져서 **씬 배정이 0 행**이었다.  그래서 전부
`runtime` 한 팩으로 떨어졌다.  마스터 `pack` 을 직접 보면 카탈로그가 필요 없다.

실측 (2026-08-26 · 빌드 레코드 10,756)
--------------------------------------
    팩 하나로 정해짐    9,676  (99.3%)
    여러 팩에 걸침         70  -> 상주로 보낸다 (6,720 B)
    pack 못 짚음            0

    제일 큰 씬 팩 scene_76  162,144 B
    씬 팩 13 개 합계        928,896 B
    씬 영역 (나눈 뒤)     1,638,400 B   여유 709 KB

여러 팩에 걸치는 70 개는 `<원문 8자>` `ギリアン？` 처럼 **여러 장소에서
나오는 짧은 대사**다.  빌더가 원문이 같으면 한 레코드로 접기 때문에 한 레코드의
주인이 여러 장소가 된다.  어느 한 장소에 넣으면 다른 장소에서 미스가 나므로
상주로 보낸다.

쓰는 법
-------
    python build_ac_dynamic_0_1_11_packs.py --tag packtest

`--tag` 는 원래 스크립트와 같은 뜻이다.  중간 산출물
`ac_0.1.11-source-<tag>` 를 읽어 팩을 나눈다.
"""
from __future__ import annotations

import csv
import shutil
import sys
from pathlib import Path

ROOT = Path(r"C:\snatcher")
STATIC = ROOT / "extraction" / "patch" / "static"
sys.path.insert(0, str(STATIC))

import build_ac_dynamic_0_1_11 as base                  # noqa: E402

dynamic = base.dynamic
split = base.split
MASTER = ROOT / "snatcher_tool" / "translation" / "snatcher_ko_master.tsv"

# 여러 장소에 걸친 레코드와 장소가 없는 레코드가 가는 곳.  상주다.
SHARED_PACK = "shared"


def master_pack_map() -> dict[str, str]:
    """`text_key:line_no` -> pack.  빌드 레코드의 `reference` 가 이 형식이다."""
    out: dict[str, str] = {}
    with MASTER.open(encoding="utf-8-sig", newline="") as handle:
        for row in csv.DictReader(handle, delimiter="\t"):
            pack = (row.get("pack") or "").strip()
            if not pack:
                continue
            key = "%s:%s" % ((row.get("text_key") or "").strip(),
                             (row.get("line_no") or "").strip())
            out[key] = pack
    return out


_PACK_OF: dict[str, str] | None = None
_STATS = {"scene": 0, "shared_multi": 0, "shared_none": 0, "other": 0}


def classify_by_pack(row: dict[str, str]) -> str:
    global _PACK_OF
    if _PACK_OF is None:
        _PACK_OF = master_pack_map()
        print(f"  마스터 pack 배정 {len(_PACK_OF):,} 줄 읽음")

    refs = [ref for ref in row["reference"].split(",") if ref.startswith("R")]
    if not refs:
        _STATS["other"] += 1
        return split.classify_split_common(row)

    packs = {_PACK_OF.get(ref) for ref in refs}
    packs.discard(None)
    if len(packs) == 1:
        _STATS["scene"] += 1
        return f"scene_{packs.pop()}"
    if len(packs) > 1:
        # 같은 대사가 여러 장소에서 나온다.  한 곳에 넣으면 다른 곳에서 미스다.
        _STATS["shared_multi"] += 1
        return SHARED_PACK
    _STATS["shared_none"] += 1
    return SHARED_PACK


# ⚠ 여기서 dynamic.BASE / OUT / VERSION 을 **건드리지 않는다.**
# 이 모듈은 래퍼(build_snatcher_ko_packsplit.py)가 그 셋을 이미 정한 뒤에
# 임포트된다.  여기서 다시 쓰면 `--tag` 로 잡아 둔 중간 산출물 경로가
# 원본 상수(ac_0.1.11-source)로 되돌아가 버린다 -- 실제로 그렇게 물렸다.


if __name__ == "__main__":
    dynamic.main()
    print()
    print("== 팩 나누기 ==")
    print(f"  장소 팩으로       {_STATS['scene']:6,}")
    print(f"  상주(여러 장소)   {_STATS['shared_multi']:6,}")
    print(f"  상주(장소 없음)   {_STATS['shared_none']:6,}")
    print(f"  그 밖 (ui/speaker) {_STATS['other']:6,}")
    shutil.copy2(
        ROOT / "snatcher_tool" / "translation" / "master_conflict_exclusions.tsv",
        dynamic.OUT / "master_conflict_exclusions.tsv",
    )
