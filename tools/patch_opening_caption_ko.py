#!/usr/bin/env python3
"""오프닝 자막 한글판을 디스크에 **제자리로** 얹는다.

블록 자리는 추정이 아니다.  두 가지가 다 맞았다.

    · `gfx_locate_blocks.find_at` 가 블록마다 **후보를 하나씩만** 내놨다
      (타이틀 때는 재개점이 섞여 나와 `$6640` 에 속았다)
    · 0.8.1 업로드 맵에 **실제 목적지**로 찍혀 있다
      ($5000 3701 회 · $5800 2985 회 · $4000 2703 회)

    A $5000  논리 $023BE57  자리 2183 B  풀림 4096 B   1991년 6월 6일 · 모스크바(앞)
    B $5800  논리 $023C6DF  자리 1078 B  풀림 2048 B   모스크바(끝) · 50년 후
    C $4000  논리 $01FB902  자리 1528 B  풀림 3200 B   2042.12. · 네오고베 시티

쓰는 법
-------
    python tools/patch_opening_caption_ko.py 0.7.24
    python tools/patch_opening_caption_ko.py 0.7.24 --write
"""
from __future__ import annotations

import argparse
import hashlib
import shutil
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path[:0] = [str(ROOT / "tools"), str(ROOT / "extraction" / "patch" / "static")]

import gfx_block_codec as codec  # noqa: E402
import gfx_locate_blocks as loc  # noqa: E402
from build_disc_subtitle_hook import rebuild_mode1_sector  # noqa: E402
import build_opening_caption_ko as caption  # noqa: E402
from gfx_manifest_declare import declare_route_c  # noqa: E402

TRACK02 = "Snatcher CD-ROMantic (Japan) (Track 02) [KO].bin"
RAW, USER, HDR = 2352, 2048, 16
KO_DIR = ROOT / "build" / "gfx" / "captions"

# 블록마다 어느 캡처를 원본으로 삼는가 (그 화면이 떠 있던 순간의 VRAM)
SOURCE = {
    0x5000: "sprite_opening_20260916_212643_vram_f005614.bin",
    0x5800: "sprite_opening_20260916_212643_vram_f008158.bin",
    0x4000: "sprite_neokobe_20260916_214051_vram_f010190.bin",
}


def logical_of(data: bytes) -> bytes:
    out = bytearray()
    for base in range(0, len(data) - RAW + 1, RAW):
        out += data[base + HDR:base + HDR + USER]
    return bytes(out)


def read_logical(data: bytes, logical: int, n: int) -> bytes:
    out = bytearray()
    while n:
        sec, off = divmod(logical, USER)
        take = min(n, USER - off)
        out += data[sec * RAW + HDR + off:sec * RAW + HDR + off + take]
        logical += take
        n -= take
    return bytes(out)


def write_logical(data: bytearray, logical: int, payload: bytes) -> set[int]:
    touched: set[int] = set()
    pos = 0
    while pos < len(payload):
        sec, off = divmod(logical + pos, USER)
        take = min(len(payload) - pos, USER - off)
        base = sec * RAW + HDR + off
        data[base:base + take] = payload[pos:pos + take]
        touched.add(sec)
        pos += take
    return touched


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("version")
    ap.add_argument("--write", action="store_true")
    ap.add_argument("--no-backup", action="store_true")
    args = ap.parse_args()

    track = ROOT / "build" / "patch" / args.version / TRACK02
    if not track.is_file():
        sys.exit(f"Track 02 가 없다: {track}")
    original = track.read_bytes()
    data = bytearray(original)
    image = logical_of(bytes(data))
    print(f"판 {args.version} · Track 02 {len(data):,} B · 논리 {len(image):,} B")

    plan = []
    for name, base, nbytes, logical, room in caption.BLOCKS:
        stock = (ROOT / "dump" / SOURCE[base]).read_bytes()
        ko_file = KO_DIR / f"vram_ko_{base:04X}.bin"
        if not ko_file.is_file():
            sys.exit(f"한글 VRAM 이 없다: {ko_file}\n"
                     "  먼저 tools/build_opening_caption_ko.py 를 돌릴 것")
        ko = ko_file.read_bytes()
        old_block = stock[base * 2:base * 2 + nbytes]
        new_block = ko[base * 2:base * 2 + nbytes]
        if old_block == new_block:
            sys.exit(f"{name}: 바뀐 것이 없다")

        # ★ 자리는 디스크에서 다시 찾는다.  박아 둔 주소를 믿지 않는다.
        hits = loc.find_at(image, stock, base * 2 // 32)
        if not hits:
            sys.exit(f"{name}: 디스크에서 블록을 못 찾았다")
        sites = sorted(h[0] + h[3] for h in hits)
        found_room = hits[0][1] - hits[0][3]
        if sites[0] != logical or found_room != room:
            print(f"  ⚠ {name}: 찾은 자리 ${sites[0]:07X}/{found_room} B 가"
                  f" 기록(${logical:07X}/{room} B)과 다르다 -- 찾은 값을 쓴다")
        encoded = codec.encode(new_block)
        check, _ = codec.decompress(encoded, 0, max_out=0x10000, max_in=16384)
        if bytes(check) != new_block:
            sys.exit(f"{name}: 우리 인코더가 되풀리지 않는다")
        print(f"  {name}  사본 {len(sites)} 벌 · 자리 {found_room} B · 새 압축 {len(encoded)} B "
              f"(여유 {found_room - len(encoded):+d})")
        if len(encoded) > found_room:
            sys.exit(f"{name}: 새 블록이 자리보다 크다")
        plan.append((name, sites, found_room, encoded, new_block))

    if not args.write:
        print("\n보고만 했다.  실제로 쓰려면 --write")
        return

    backup = track.with_suffix(track.suffix + ".bak_caption")
    if not args.no_backup and not backup.exists():
        shutil.copy2(track, backup)
        print(f"\n  원본 보관 {backup.name}")

    touched: set[int] = set()
    for _name, sites, _room, encoded, _block in plan:
        for site in sites:
            touched |= write_logical(data, site, encoded)
    for sec in sorted(touched):
        blk = bytearray(data[sec * RAW:(sec + 1) * RAW])
        rebuild_mode1_sector(blk)
        data[sec * RAW:(sec + 1) * RAW] = blk
    track.write_bytes(bytes(data))
    print(f"  섹터 {len(touched)} 개를 다시 구웠다")

    final = track.read_bytes()
    for name, sites, room, _encoded, new_block in plan:
        for site in sites:
            got, _ = codec.decompress(read_logical(final, site, room), 0,
                                      max_out=0x10000, max_in=16384)
            if bytes(got) != new_block:
                sys.exit(f"검산 실패: {name} ${site:07X}")
        print(f"  검산 {name} 사본 {len(sites)} 벌 되읽기 OK")

    before, after = logical_of(original), logical_of(final)
    allowed = [(s, s + room) for _n, sites, room, _e, _b in plan for s in sites]
    changed = [i for i in range(len(before)) if before[i] != after[i]]
    stray = [i for i in changed if not any(a <= i < b for a, b in allowed)]
    print(f"  논리 이미지 변경 {len(changed):,} B · 허용 범위 밖 {len(stray)}")
    if stray:
        sys.exit(f"★ 선언 안 한 자리 {len(stray)} B 가 바뀌었다: ${stray[0]:07X}...")
    # ★ 감사가 보는 선언을 남긴다.  이게 없으면 `check_build_invariants` 가
    #   여기서 바꾼 섹터를 "선언 없이 바뀐 섹터" 로 읽어 **거짓 실패**를 낸다.
    declare_route_c(
        track.parent, final, "opening_caption",
        [{"name": name, "logical": f"${site:07X}", "bytes": len(encoded)}
         for name, sites, _room, encoded, _block in plan for site in sites],
        touched)

    print(f"\n  Track 02 SHA-256  {hashlib.sha256(final).hexdigest().upper()}")
    print("  통과: 블록은 게임 해독기로 되풀어 대조 · 선언 밖 변경 0")


if __name__ == "__main__":
    main()
