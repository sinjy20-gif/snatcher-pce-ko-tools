#!/usr/bin/env python3
"""가우디 **전체 검색표**(이름 16 + 퀴즈 4)를 구운 판의 동굴에 얹는다.

왜 따로 있나
------------
`apply_gaudi_to_build.py` 가 넣는 것은 **깁슨 하나짜리 옛 훅**(97 B)이다.
그걸로는 자판이 한글이어도 **검색이 하나도 안 걸린다** (2026-09-22 실기).

진짜 표는 `build_gaudi_search_table_packed.py` 가 만드는데, 그쪽의
`repatch_from_0715_with_quiz()` 는 **0.7.15 블롭이 이미 동굴에 있다고 가정**해서
갓 구운 판에는 못 쓴다.  여기서는 동굴에 무엇이 있든 **최종 블롭을 바로 쓴다.**

    깁슨 훅만 (97 B)      -> 검색 0 건          <- apply_gaudi_to_build.py 까지만
    이름 16 + 퀴즈 4      -> 0.7.20~0.7.24 판   <- 이 도구

⚠ 순서: `apply_gaudi_to_build.py` 가 **먼저** 돌아야 한다.  그게 `$B9E0` 에
  `JSR $BE56` 를 심는다.  이 도구는 그 훅이 있는지 먼저 확인한다.

검산
----
만든 블롭을 **0.7.24 의 동굴과 바이트로 대조**한다.  0.7.24 는 실기로 확인된
마지막 판이다 -- 내 코드가 두 번 같은 답을 내는 자기검산이 아니라 **다른 출처**다.

    python tools/apply_gaudi_search_full.py 0.8.1
    python tools/apply_gaudi_search_full.py 0.8.1 --write
"""
from __future__ import annotations

import argparse
import hashlib
import sys
from pathlib import Path

if hasattr(sys.stdout, "reconfigure"):
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")

ROOT = Path(__file__).resolve().parents[1]
sys.path[:0] = [str(ROOT / "tools"), str(ROOT / "extraction" / "patch" / "static")]

import build_disc_subtitle_hook as rawdisc                  # noqa: E402
import build_gaudi_keypad_test as keypad                    # noqa: E402
import build_gaudi_search_table_packed as search            # noqa: E402

TRACK02 = "Snatcher CD-ROMantic (Japan) (Track 02) [KO].bin"
RAW = 2352
REFERENCE = "0.7.24"          # 실기로 확인된 마지막 판 -- 검산 상대


def sha(b: bytes) -> str:
    return hashlib.sha256(b).hexdigest().upper()


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("version")
    ap.add_argument("--write", action="store_true")
    args = ap.parse_args()

    track = ROOT / "build" / "patch" / args.version / TRACK02
    if not track.is_file():
        sys.exit(f"Track 02 가 없다: {track}")

    data = bytearray(track.read_bytes())
    if data[search.HOOK_RAW:search.HOOK_RAW + 5] != search.HOOK_INSTALLED:
        sys.exit(f"★ 훅이 ${search.HOOK_RAW:07X} 에 없다 -- "
                 "apply_gaudi_to_build.py 를 먼저 돌릴 것")

    enc, _ = keypad.token_maps()
    blob, code_size, table_size = search.make_blob(
        mappings=search.ALL_MAPPINGS, enc=enc)
    cap = search.CAVE_CAPACITY
    if len(blob) > cap:
        sys.exit(f"★ 블롭 {len(blob)} B 가 동굴 {cap} B 를 넘는다")

    prev = bytes(data[search.CAVE_RAW:search.CAVE_RAW + cap])
    now = len([b for b in prev if b])
    print(f"판 {args.version}")
    print(f"  동굴 ${search.CAVE_RAW:07X} · 용량 {cap} B · 지금 0 아닌 바이트 {now}")
    print(f"  새 블롭 {len(blob)} B (코드 {code_size} + 표 {table_size}) "
          f"· 여유 {cap - len(blob)} B")
    print(f"  이름 {len(search.NAME_MAPPINGS)} + 퀴즈 {len(search.QUIZ_MAPPINGS)}")

    # ★ 다른 출처로 검산 -- 실기로 확인된 0.7.24 의 동굴과 바이트 대조
    ref = ROOT / "build" / "patch" / REFERENCE / TRACK02
    if ref.is_file():
        with open(ref, "rb") as f:
            f.seek(search.CAVE_RAW)
            ref_cave = f.read(cap)
        same = ref_cave == blob.ljust(cap, b"\x00")
        print(f"  검산 {REFERENCE} 동굴과 {'바이트 동일 ★' if same else '★다르다'}")
        if not same:
            n = sum(1 for a, b in zip(ref_cave, blob.ljust(cap, b'\x00')) if a != b)
            print(f"       다른 바이트 {n} 개 -- 표나 자판 배열이 그 판과 다르다")
    else:
        print(f"  ⚠ {REFERENCE} 가 없어 검산 못 함")

    if not args.write:
        print("\n(보고만 했다.  --write 로 기록)")
        return

    data[search.CAVE_RAW:search.CAVE_RAW + cap] = blob.ljust(cap, b"\x00")
    sector = search.CAVE_RAW // RAW
    base = sector * RAW
    block = bytearray(data[base:base + RAW])
    rawdisc.rebuild_mode1_sector(block)
    data[base:base + RAW] = block
    track.write_bytes(bytes(data))

    back = track.read_bytes()[search.CAVE_RAW:search.CAVE_RAW + len(blob)]
    if back != blob:
        sys.exit("★ 되읽기 검산 실패")
    print(f"  섹터 {sector} 다시 구움 · 되읽기 OK")
    print(f"  Track 02 SHA-256 {sha(bytes(data))}")


if __name__ == "__main__":
    main()
