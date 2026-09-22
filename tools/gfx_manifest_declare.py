#!/usr/bin/env python3
"""route C 제자리 치환의 **매니페스트 선언**을 한 곳에서 누적한다.

`check_build_invariants.py` 의 `check_track02_baseline()` 은 Track 02 에서
바뀐 섹터를 전부 뽑아 `manifest.json` 의 `route_c.sectors_touched` 와 대조한다.
거기 없는 섹터가 하나라도 있으면 **실패**다 (Track02->BIOS 훅 오염을 잡는 그물).

그래서 Track 02 를 제자리로 고치는 도구는 전부 이 함수를 불러야 한다.
`patch_gfx_screen.py` 는 제 안에 같은 코드를 갖고 있었고, 타이틀 메뉴와 오프닝
자막 패처 둘은 그게 없어서 **감사가 거짓 실패로 떨어졌다** (2026-09-22 환경 B
인계서 §2-4 가 지적한 구멍이 이것이다).

⚠ 하드링크를 **먼저 끊는다.**  기준판에서 링크로 받아온 매니페스트를 제자리에
  쓰면 같은 inode 인 기준판까지 같이 바뀐다 (2026-09-09 에 0.6.5 를 오염시켰다).
"""
from __future__ import annotations

import hashlib
import json
from pathlib import Path


def declare_route_c(out_dir: Path, track02: bytes, screen: str,
                    blocks: list[dict], touched: set[int]) -> bool:
    """`route_c` 선언에 화면 하나를 **더한다**.  덮지 않는다.

    out_dir   build/patch/<판>/
    track02   방금 쓴 Track 02 실물 바이트 (해시를 이걸로 다시 낸다)
    screen    화면 이름 (`title_menu` · `opening_caption` ...)
    blocks    [{"name":..., "logical":"$0123456", "bytes":123}, ...]
    touched   이번에 다시 구운 raw 섹터 번호
    """
    man_path = out_dir / "manifest.json"
    if not man_path.is_file():
        print("  ⚠ 매니페스트가 없다 -- route_c 선언을 못 남겼다")
        return False

    man = json.loads(man_path.read_text(encoding="utf-8"))
    man["track02_sha256"] = hashlib.sha256(track02).hexdigest().upper()

    rc = man.get("route_c") or {}
    rc_blocks = list(rc.get("blocks", []))
    rc_blocks += [dict(b, screen=screen) for b in blocks]
    man["route_c"] = {
        "what": rc.get(
            "what",
            "전면 그래픽 화면을 디스크에서 제자리 치환 (훅 0 · 런타임 코드 0 B)"),
        **({"base": rc["base"]} if "base" in rc else {}),
        "screens": sorted(set(rc.get("screens", [])) | {screen}),
        "blocks": rc_blocks,
        "sectors_touched": sorted(set(rc.get("sectors_touched", [])) | touched),
    }

    text = json.dumps(man, ensure_ascii=False, indent=2) + "\n"
    man_path.unlink()                       # ★ 링크를 먼저 끊는다
    man_path.write_text(text, encoding="utf-8")
    print(f"  매니페스트 갱신: track02_sha256 + route_c[{screen}] "
          f"섹터 {len(touched)} 개 누적 (링크 끊고 새 파일)")
    return True
