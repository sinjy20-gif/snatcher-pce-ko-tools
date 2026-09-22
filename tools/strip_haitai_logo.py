#!/usr/bin/env python3
"""해태 한글 카드에서 가져온 부팅화면 5,751 B 를 **일본 원본 바이트로 되돌린다.**

왜
--
`build_bios_font_patch.py --haitai-logo` (기본값) 가 해태 카드의 부팅화면을
그대로 복사해 넣는다.  그 5,751 B 는 **남의 저작물이라 재배포에 못 넣는다.**
그런데 기반 BIOS `build/bios_font/Syscard3_galmuri.pce` 부터 이미 박혀 있어서
사슬로 구운 판이 전부 물려받는다 -- 2026-09-22 에 `0.7.29` 배포 zip 까지
그대로 들어갔다.

왜 지우지 않고 **되돌리나**
---------------------------
그 구간은 원래 일본판 부팅화면이 들어 있던 자리다.  0 으로 밀면 부팅화면이
깨진다.  해태 바이트를 **JP 원본 바이트로 바꾸면** 일본판 부팅화면이 그대로
돌아온다 -- BIOS 가 원래 하던 일 그대로다.

왜 글리프를 다시 안 굽나
------------------------
`build_bios_font_patch.py` 를 다시 돌리면 글리프도 다시 나온다.  BIOS 글리프와
디스크는 **같은 `hangul_slot_map.tsv` 에서 함께** 나와야 짝이 맞는데, 지금
디스크는 8/29 판 기반이다.  이 도구는 글리프를 **한 바이트도** 안 건드린다.

    python tools/strip_haitai_logo.py --check                 어디에 남아 있나 본다
    python tools/strip_haitai_logo.py --base --write          기반 BIOS 를 청소
    python tools/strip_haitai_logo.py 0.7.29 --write          구운 판을 청소
"""
from __future__ import annotations

import argparse
import hashlib
import shutil
import sys
from pathlib import Path

if hasattr(sys.stdout, "reconfigure"):
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")

ROOT = Path(__file__).resolve().parents[1]
FIRMWARE = ROOT / "Mesen_2.2.1_Windows" / "Firmware"
JP = FIRMWARE / "[BIOS] Super CD-ROM System (Japan) (v3.0).pce.JP_ORIGINAL"
KR = FIRMWARE / "[BIOS] Super CD-ROM System (Japan) (v3.0).pce.KR_HAITAI"
BASE = ROOT / "build" / "bios_font" / "Syscard3_galmuri.pce"

JP_SHA = "E11527B3B96CE112A037138988CA72FD117A6B0779C2480D9E03EAEBECE3D9CE"

# build_bios_boot_logo.py 의 REGIONS 와 **같은 목록**이어야 한다 (끝 포함).
# 글리프 구간($010038-$025E5F · $03001F-$03C515)은 여기 없다 -- 절대 넣지 말 것.
REGIONS = [
    (0x00297D, 0x002A81, "작은 인덱스 표"),
    (0x0070F1, 0x007184, "BIOS 메뉴 문자열 (DELETE/FORMAT)"),
    (0x007219, 0x007267, "BIOS 메뉴 문자열 (SELECTION)"),
    (0x0074DA, 0x0074DD, "값 하나"),
    (0x02C020, 0x02C3FC, "타일 데이터"),
    (0x02C751, 0x02C77F, "타일 데이터"),
    (0x02CB71, 0x02DBEF, "타일 데이터 (부팅화면 본체)"),
]


def sha(b: bytes) -> str:
    return hashlib.sha256(b).hexdigest().upper()


def classify(rom: bytes, jp: bytes, kr: bytes) -> list[tuple]:
    out = []
    for a, b, note in REGIONS:
        s = rom[a:b + 1]
        what = "HAITAI" if s == kr[a:b + 1] else ("JP" if s == jp[a:b + 1] else "그밖")
        out.append((a, b, note, what))
    return out


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("version", nargs="?", help="build/patch/<판>/ 의 BIOS")
    ap.add_argument("--base", action="store_true", help="기반 BIOS 를 대상으로")
    ap.add_argument("--check", action="store_true", help="보기만 한다")
    ap.add_argument("--write", action="store_true")
    args = ap.parse_args()

    jp, kr = JP.read_bytes(), KR.read_bytes()
    if sha(jp) != JP_SHA:
        sys.exit("JP 원본 해시가 다르다 -- 되돌릴 기준을 믿을 수 없다")

    if args.check and not (args.base or args.version):
        targets = [BASE] + sorted(
            (ROOT / "build" / "patch").glob("*/Syscard3_galmuri_*.pce"))
    elif args.base:
        targets = [BASE]
    elif args.version:
        d = ROOT / "build" / "patch" / args.version
        targets = [p for p in d.glob("Syscard3_galmuri_*.pce")
                   if p.suffix == ".pce"]
        if not targets:
            sys.exit(f"BIOS 가 없다: {d}")
    else:
        sys.exit("판 번호나 --base 를 줄 것 (--check 만 주면 전부 훑는다)")

    total = sum(b - a + 1 for a, b, _ in REGIONS)
    dirty = 0
    for t in targets:
        rom = bytearray(t.read_bytes())
        rows = classify(bytes(rom), jp, kr)
        bad = [r for r in rows if r[3] == "HAITAI"]
        rel = t.relative_to(ROOT)
        if not bad:
            print(f"  깨끗 {rel}")
            continue
        dirty += 1
        n = sum(b - a + 1 for a, b, _, _ in bad)
        print(f"\n★ 해태 {n:,} B / {total:,} B   {rel}")
        for a, b, note, what in rows:
            print(f"     ${a:06X}-${b:06X} {b-a+1:>6,} B  {what:6s}  {note}")
        if args.check or not args.write:
            continue
        backup = t.with_suffix(t.suffix + ".haitai_logo.bak")
        if not backup.exists():
            shutil.copy2(t, backup)
            print(f"     원본 보관 {backup.name}")
        for a, b, _, _ in bad:
            rom[a:b + 1] = jp[a:b + 1]
        t.write_bytes(bytes(rom))
        after = classify(bytes(rom), jp, kr)
        left = [r for r in after if r[3] == "HAITAI"]
        print(f"     되돌림 {n:,} B -> JP 원본 · 남은 해태 구간 {len(left)} 개")
        print(f"     새 SHA-256 {sha(bytes(rom))}")
        if left:
            sys.exit("★ 아직 남았다")

    if args.check:
        print(f"\n해태가 남은 파일 {dirty} 개")
    elif not args.write:
        print("\n(보고만 했다.  --write 로 기록)")


if __name__ == "__main__":
    main()
