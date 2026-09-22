#!/usr/bin/env python3
"""매니페스트의 Track 02 장부를 **디스크 실물에서 다시 맞춘다.**

왜 있나
-------
`patch_gaudi_keypad_native.py` 와 `patch_title_menu_sprite_ko.py` 는 디스크만 고치고
매니페스트를 안 건드린다.  그래서 그 둘을 마지막에 돌리면 감사가 이렇게 운다
(2026-09-15, 0.7.23):

    ★ track02 해시   매니페스트 ... != ...   -> 판과 팩이 다른 세대다
    ★ Track02 기준    선언 없이 바뀐 섹터 [19 개]

둘 다 **장부 문제**지 디스크 파손이 아니다.  그래도 감사가 ★ 를 띄우면 진짜 실패와
구별이 안 되므로 맞춰 둔다.

무엇을 하나
-----------
    · `track02_sha256` 을 실물 해시로 다시 쓴다
    · 기준판과 바이트로 비교해 **바뀐 섹터를 직접 세어** `route_c.sectors_touched`
      에 합친다 (도구들이 보고한 숫자를 믿지 않는다 -- 다른 출처로 검산)

    python tools/sync_manifest_track02.py 0.7.23
    python tools/sync_manifest_track02.py 0.7.23 --write
"""
from __future__ import annotations

import argparse
import hashlib
import json
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
TRACK02 = "Snatcher CD-ROMantic (Japan) (Track 02) [KO].bin"
RAW = 2352

if hasattr(sys.stdout, "reconfigure"):
    sys.stdout.reconfigure(encoding="utf-8")


def changed_sectors(base: bytes, now: bytes) -> list[int]:
    if len(base) != len(now):
        raise SystemExit(f"길이가 다르다: 기준 {len(base):,} · 지금 {len(now):,}")
    return [i for i in range(len(now) // RAW)
            if base[i * RAW:(i + 1) * RAW] != now[i * RAW:(i + 1) * RAW]]


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("version")
    ap.add_argument("--baseline", default=None,
                    help="기준판 폴더 이름 (기본: manifest 의 route_c.base 나 base)")
    ap.add_argument("--write", action="store_true")
    args = ap.parse_args()

    folder = ROOT / "build" / "patch" / args.version
    path = folder / "manifest.json"
    if not path.is_file():
        raise SystemExit(f"매니페스트가 없다: {path}")
    manifest = json.loads(path.read_text(encoding="utf-8"))

    base_name = args.baseline or manifest.get("base") or manifest.get("route_c", {}).get("base")
    base_track = ROOT / "build" / "patch" / str(base_name) / TRACK02
    now_track = folder / TRACK02
    if not now_track.is_file():
        raise SystemExit(f"Track 02 가 없다: {now_track}")

    now = now_track.read_bytes()
    digest = hashlib.sha256(now).hexdigest().upper()
    before = (manifest.get("track02_sha256") or "").upper()
    print(f"판 {args.version} · 기준 {base_name}")
    print(f"  track02_sha256  {before[:16]} -> {digest[:16]}"
          + ("  (이미 맞다)" if before == digest else ""))

    route = manifest.setdefault("route_c", {})
    listed = sorted(set(route.get("sectors_touched") or []))
    if base_track.is_file():
        sectors = changed_sectors(base_track.read_bytes(), now)
        missing = sorted(set(sectors) - set(listed))
        print(f"  기준과 다른 섹터 {len(sectors)} 개 · 장부에 적힌 것 {len(listed)} 개"
              f" · 빠진 것 {len(missing)} 개")
        if missing:
            print("    " + " ".join(str(s) for s in missing[:24])
                  + (" ..." if len(missing) > 24 else ""))
        merged = sorted(set(listed) | set(sectors))
    else:
        print(f"  ⚠ 기준판 Track 02 가 없다 ({base_track}) -- 섹터는 그대로 둔다")
        merged = listed

    if not args.write:
        print("\n읽기 전용이다.  실제로 쓰려면 --write")
        return

    manifest["track02_sha256"] = digest
    route["sectors_touched"] = merged
    path.write_text(json.dumps(manifest, ensure_ascii=False, indent=2) + "\n",
                    encoding="utf-8")
    print(f"\n썼다.  sectors_touched {len(listed)} -> {len(merged)}")


if __name__ == "__main__":
    main()
