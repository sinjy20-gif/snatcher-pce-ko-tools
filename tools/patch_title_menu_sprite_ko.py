#!/usr/bin/env python3
"""타이틀 메뉴 스프라이트 한글판을 디스크에 **제자리로** 얹는다.

블록 자리는 **추정이 아니라 프로브로 확정**했다
(`lua/GFX/0.7.4-block-to-vram-title.lua` -- 압축 해제기 `$7061` 호출마다 MAWR 기록).

    MAWR $6000  193 회   -> 블록 A   VRAM $6000-$67FF  (풀림 4096 B)
    MAWR $6800  222 회   -> 블록 B   VRAM $6800-$6EFF  (풀림 3584 B)
    MAWR $6640    0 회   ★ 처음에 블록 A 로 잡았던 자리.  **재개점이었다.**

⚠ 이 코덱은 아무 타일 경계에서나 이어 풀린다.  그래서 `find_at` 이 재개점을
  블록 시작처럼 내놓는다 ($664 $66C $66D $66E $66F ...).  풀어서 그림이 맞는 것은
  근거가 아니다 -- 올리는 순간(MAWR)을 봐야 한다.

쓰는 법
-------
    python tools/patch_title_menu_sprite_ko.py 0.7.22            보고만
    python tools/patch_title_menu_sprite_ko.py 0.7.22 --write
"""
from __future__ import annotations

import argparse
import shutil
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path[:0] = [str(ROOT / "tools"), str(ROOT / "extraction" / "patch" / "static")]

import gfx_block_codec as codec  # noqa: E402
import gfx_locate_blocks as loc  # noqa: E402
from build_disc_subtitle_hook import rebuild_mode1_sector  # noqa: E402
from gfx_manifest_declare import declare_route_c  # noqa: E402

TRACK02 = "Snatcher CD-ROMantic (Japan) (Track 02) [KO].bin"
RAW, USER, HDR = 2352, 2048, 16
DUMP = ROOT / "dump"
STAMP = "title_menu_20260914_235434"
KO_VRAM = ROOT / "build" / "gfx" / "title_menu" / "left" / "vram_ko.bin"

# (이름, 시작 워드, 풀림 바이트)   -- 프로브가 확인한 목적지만 쓴다
BLOCKS = [("A $6000", 0x6000, 4096), ("B $6800", 0x6800, 3584)]
COPIES = 2


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
        base = sec * RAW + HDR + off
        out += data[base:base + take]
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
    stock = (DUMP / f"{STAMP}_vram_full.bin").read_bytes()
    ko = KO_VRAM.read_bytes()
    if len(stock) != 0x10000 or len(ko) != 0x10000:
        sys.exit("64 KB VRAM 이 아니다")

    original = track.read_bytes()
    data = bytearray(original)
    image = logical_of(bytes(data))
    print(f"판 {args.version} · Track 02 {len(data):,} B · 논리 {len(image):,} B")

    plan = []
    for name, word, nbytes in BLOCKS:
        start_tile = word * 2 // 32            # VRAM 은 바이트 주소 · 타일 = 32 B
        hits = loc.find_at(image, stock, start_tile)
        if not hits:
            sys.exit(f"{name}: 디스크에서 블록을 못 찾았다 (tile ${start_tile:03X})")
        room = hits[0][1] - hits[0][3]
        sites = sorted(h[0] + h[3] for h in hits)
        old_block = stock[word * 2:word * 2 + nbytes]
        new_block = ko[word * 2:word * 2 + nbytes]
        if old_block == new_block:
            sys.exit(f"{name}: 바뀐 것이 없다")
        encoded = codec.encode(new_block)
        check, _ = codec.decompress(encoded, 0, max_out=0x10000, max_in=16384)
        if bytes(check) != new_block:
            sys.exit(f"{name}: 우리 인코더가 되풀리지 않는다")
        print(f"  {name}  사본 {len(sites)} 벌 · 자리 {room} B · 새 압축 {len(encoded)} B "
              f"(여유 {room - len(encoded):+d})")
        if len(encoded) > room:
            sys.exit(f"{name}: 새 블록이 자리보다 크다")
        if len(sites) != COPIES:
            print(f"    ⚠ 사본이 {len(sites)} 벌이다 (예상 {COPIES})")
        plan.append((name, sites, room, encoded, new_block))

    if not args.write:
        print("\n보고만 했다.  실제로 쓰려면 --write")
        return

    backup = track.with_suffix(track.suffix + ".bak_title_sprite")
    if not args.no_backup and not backup.exists():
        shutil.copy2(track, backup)
        print(f"\n  원본 보관 {backup.name}")

    touched: set[int] = set()
    for _, sites, _, encoded, _ in plan:
        for site in sites:
            touched |= write_logical(data, site, encoded)
    for sec in sorted(touched):
        blk = bytearray(data[sec * RAW:(sec + 1) * RAW])
        rebuild_mode1_sector(blk)
        data[sec * RAW:(sec + 1) * RAW] = blk
    track.write_bytes(bytes(data))
    print(f"  섹터 {len(touched)} 개를 다시 구웠다")

    # --- 되읽어 검산 --------------------------------------------------------
    final = track.read_bytes()
    for name, sites, room, _, new_block in plan:
        for site in sites:
            blob = read_logical(final, site, room)
            got, _ = codec.decompress(blob, 0, max_out=0x10000, max_in=16384)
            if bytes(got) != new_block:
                sys.exit(f"검산 실패: {name} ${site:07X} 가 새 블록으로 안 풀린다")
        print(f"  검산 {name} 사본 {len(sites)} 벌 되읽기 OK")

    # 우리가 선언한 자리 밖은 한 바이트도 안 바뀌어야 한다
    before, after = logical_of(original), logical_of(final)
    allowed = [(s, s + room) for _, sites, room, _, _ in plan for s in sites]
    stray = [i for i in range(len(before))
             if before[i] != after[i] and not any(a <= i < b for a, b in allowed)]
    print(f"  논리 이미지 변경 {sum(1 for i in range(len(before)) if before[i] != after[i]):,} B "
          f"· 허용 범위 밖 {len(stray)}")
    if stray:
        sys.exit(f"★ 선언 안 한 자리 {len(stray)} B 가 바뀌었다: ${stray[0]:07X}...")
    # ★ 감사가 보는 선언을 남긴다.  이게 없으면 `check_build_invariants` 가
    #   여기서 바꾼 섹터를 "선언 없이 바뀐 섹터" 로 읽어 **거짓 실패**를 낸다.
    declare_route_c(
        track.parent, final, "title_menu",
        [{"name": name, "logical": f"${site:07X}", "bytes": len(encoded)}
         for name, sites, _room, encoded, _block in plan for site in sites],
        touched)

    import hashlib
    print(f"\n  Track 02 SHA-256  {hashlib.sha256(final).hexdigest().upper()}")
    print("  통과: 블록은 게임 해독기로 되풀어 대조 · 선언 밖 변경 0")


if __name__ == "__main__":
    main()
