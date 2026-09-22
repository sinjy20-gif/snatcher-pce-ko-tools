#!/usr/bin/env python3
"""떠둔 VRAM 덤프들의 **타일 블록이 디스크 어디에 있는지** 한꺼번에 찾는다.

왜 되나
    VRAM 덤프 = 블록이 풀린 결과다 (헌정에서 4,032 B 바이트 일치로 확인).
    그러니 덤프의 타일 바이트를 목표로 삼아 디스크를 훑으면 자리가 나온다.
    프로브 주행이 화면마다 필요 없어진다.

빠르게 하는 법 -- 두 겹
    1) **1 바이트 관문**: 목표가 0 으로 시작하면 첫 명령은 `$40+개수` 다.
       `bytes.find` 로 그 자리만 C 속도로 건너뛴다.
    2) **앞부분 판독기**: 거기서 64 B 만 풀어 목표와 대조한다.
       ⚠ `gfx_block_codec.decompress` 에 작은 `max_out` 을 주면 자르는 게 아니라
         **예외를 던진다** -- 그래서 정답까지 걸러진다 (2026-09-09 에 밟았다).
         전용 판독기를 따로 둔 이유다.
    통과한 것만 진짜 해독기로 완전히 풀어 확인한다.

    python tools/gfx_locate_blocks.py                    쓸 수 있는 덤프 전부
    python tools/gfx_locate_blocks.py --dump <이름>      하나만
"""
from __future__ import annotations

import argparse
import csv
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import gfx_block_codec as codec                        # noqa: E402

ROOT = Path(r"C:\snatcher")
DUMP = ROOT / "dump"
ATLAS = ROOT / "build" / "gfx" / "dump_atlas"
# * 2026-09-11.  여기 두 값이 환경 A 컴퓨터에 묶여 있었다 -- 세션마다 달라지는
#   스크래치패드 경로와, 09-09 정리 때 이미 지운 판(0.6.2)이다.  환경 A에선 캐시가
#   남아 있어 안 드러났고 환경 B에서 처음 터졌다.
#   캐시는 프로젝트 안으로 옮기고, 원본 트랙은 **남아 있는 그래픽 이전 판**을 찾는다.
#   그래픽 블록은 일본 원본 자료라 우리 판들 사이에서 같다.  혹시 어긋나도
#   patch_gfx_screen.py 가 굽기 직전에 블록 시작/끝 $FF 를 따로 검사한다.
CACHE = ROOT / "build" / "gfx" / "_cache"
LOGICAL = CACHE / "track02_logical.bin"
TRACK02_NAME = "Snatcher CD-ROMantic (Japan) (Track 02) [KO].bin"
TRACK_CANDIDATES = ("0.6.2", "0.6.4", "0.4.6.61-dictionary-key-vram")


def track02_path() -> Path:
    for version in TRACK_CANDIDATES:
        candidate = ROOT / "build" / "patch" / version / TRACK02_NAME
        if candidate.is_file():
            return candidate
    raise SystemExit(
        "그래픽 이전 판의 Track 02 를 못 찾았다.  찾아본 곳: "
        + ", ".join(str(ROOT / "build" / "patch" / v / TRACK02_NAME)
                    for v in TRACK_CANDIDATES))
RAW, USER, HDR = 2352, 2048, 16

PREFIX = 64          # 앞 몇 바이트로 거를까
BACK_TILES = 8       # 블록 시작이 tile_lo 보다 몇 장 앞일 수 있나


def logical_image() -> bytes:
    if LOGICAL.is_file():
        return LOGICAL.read_bytes()
    CACHE.mkdir(parents=True, exist_ok=True)
    raw = track02_path().read_bytes()
    out = bytearray()
    for base in range(0, len(raw) - RAW + 1, RAW):
        out += raw[base + HDR:base + HDR + USER]
    LOGICAL.write_bytes(out)
    return bytes(out)


def decode_prefix(d: bytes, pos: int, need: int) -> bytes | None:
    """앞 `need` 바이트만 푼다.  못 풀면 None.  (명령표는 `$7061` 실측)"""
    out = bytearray()
    end = len(d)
    while len(out) < need:
        if pos >= end:
            return None
        c = d[pos]; pos += 1
        if c == 0xFF:
            break
        if c == 0x00:                                   # [n][b] 번갈아
            if pos + 1 >= end: return None
            n, b = d[pos], d[pos + 1]; pos += 2
            for _ in range(n):
                out.append(b)
                if pos >= end: return None
                out.append(d[pos]); pos += 1
        elif c == 0x01:                                 # [lo][hi][b]
            if pos + 2 >= end: return None
            n = d[pos] | (d[pos + 1] << 8); b = d[pos + 2]; pos += 3
            out += bytes([b]) * n
        elif c == 0x02:                                 # [n][b1][b2]
            if pos + 2 >= end: return None
            n, b1, b2 = d[pos], d[pos + 1], d[pos + 2]; pos += 3
            out += bytes([b1, b2]) * n
        elif c <= 0x3F:                                 # [b] x c
            if pos >= end: return None
            out += bytes([d[pos]]) * c; pos += 1
        elif c <= 0x7F:                                 # 0 x (c & 0x3F)
            out += bytes(c & 0x3F)
        elif c == 0x80:                                 # [lo][hi] 리터럴
            if pos + 1 >= end: return None
            n = d[pos] | (d[pos + 1] << 8); pos += 2
            out += d[pos:pos + n]; pos += n
        elif c <= 0xBF:                                 # 리터럴 (c & 0x7F)
            n = c & 0x7F
            out += d[pos:pos + n]; pos += n
        elif c <= 0xFD:                                 # 0 과 리터럴 번갈아
            for _ in range(c & 0x3F):
                out.append(0)
                if pos >= end: return None
                out.append(d[pos]); pos += 1
        elif c == 0xFE:                                 # [n][4 B]
            if pos + 4 >= end: return None
            n = d[pos]; pat = d[pos + 1:pos + 5]; pos += 5
            out += pat * n
        else:
            return None
    return bytes(out[:need])


def block_starts(vram: bytes, lo: int, hi: int) -> list[int]:
    """블록이 시작할 만한 타일 = 빈 타일 뒤의 첫 비어있지 않은 타일."""
    def blank(t: int) -> bool:
        return not any(vram[t * 32:(t + 1) * 32])
    out = []
    for t in range(max(0, lo - 2), hi + 1):
        if not blank(t) and (t == 0 or blank(t - 1)):
            out.append(t)
            if t > 0:
                out.append(t - 1)          # 블록이 빈 타일 한 장 앞에서 시작하기도 한다
    return sorted(set(x for x in out if x >= 0))


def gate_positions(d: bytes, want: bytes) -> list[int]:
    """스트림이 시작할 만한 자리 (C 속도로 좁힌다)."""
    spots: list[int] = []
    lead = 0
    while lead < len(want) and want[lead] == 0:
        lead += 1
    if 3 <= lead <= 0x3F:                               # ① 0 런 명령 (짧다)
        g = bytes([0x40 + lead]); at = 0
        while True:
            i = d.find(g, at)
            if i < 0: break
            spots.append(i); at = i + 1
    elif lead > 0x3F:                                   # ①-b 긴 0 런
        # `$40-$7F` 는 한 번에 63 개까지다.  더 길면 `$7F` 를 잇거나
        # `$01 [lo][hi] 00` (16 비트 RLE) 를 쓴다.  둘 다 본다.
        # ⚠ BAT 블록이 여기 걸린다 -- 앞 몇 행이 빈 칸이라 0 이 수백 개다.
        for g in (bytes([0x7F]),
                  bytes([0x01, lead & 0xFF, (lead >> 8) & 0xFF, 0x00])):
            at = 0
            while True:
                i = d.find(g, at)
                if i < 0: break
                spots.append(i); at = i + 1
    if lead < 3 and len(want) >= 4:                     # ② 리터럴 명령 + 원문 바이트
        head = want[:4]; at = 0
        while True:
            i = d.find(head, at)
            if i < 0: break
            at = i + 1
            for back in (1, 3):                         # $81-$BF (1 B) · $80 lo hi (3 B)
                j = i - back
                if j < 0: continue
                c = d[j]
                if (back == 1 and 0x81 <= c <= 0xBF) or (back == 3 and c == 0x80):
                    spots.append(j)
    return spots


def find_at(d: bytes, vram: bytes, start_tile: int) -> list[tuple[int, int, int, int]]:
    """시작 타일이 `start_tile` 인 블록을 찾는다 -> [(논리, 압축, 풀림, 헤더B)]"""
    base = start_tile * 32
    want = vram[base:base + 0x4000]                     # 넉넉한 창.  길이는 블록이 정한다
    if not any(want[:2048]):
        return []                                       # 통째로 빈 창은 안 본다
    hits, seen = [], set()
    for i in gate_positions(d, want):
        got = decode_prefix(d, i, PREFIX)
        if got is None or got != want[:PREFIX]:
            continue
        try:
            full, end = codec.decompress(d, i, max_out=0x10000, max_in=16384)
        except Exception:
            continue
        n = len(full)
        if n < 512 or bytes(full) != want[:n]:          # 블록 전체가 VRAM 과 맞아야 한다
            continue
        for hdr_n in (1, 2):
            pos = i - hdr_n
            if pos >= 0 and pos not in seen:
                seen.add(pos)
                hits.append((pos, end - pos, n, hdr_n))
                break
    return hits


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--dump")
    ap.add_argument("--min-tiles", type=int, default=1)
    args = ap.parse_args()

    idx = ATLAS / "index.tsv"
    if not idx.is_file():
        sys.exit("먼저 tools/gfx_dump_atlas.py 를 돌릴 것")
    rows = list(csv.DictReader(idx.open(encoding="utf-8"), delimiter="\t"))
    if args.dump:
        rows = [r for r in rows if args.dump in r["dump"]]
    rows = [r for r in rows if int(r["tiles_nonblank"] or 0) >= args.min_tiles]

    d = logical_image()
    print(f"논리 이미지 {len(d):,} B · 대상 덤프 {len(rows)}\n")
    out_rows = []
    for r in rows:
        stem = r["dump"]
        vram = (DUMP / f"{stem}.vram.bin").read_bytes()
        lo = int(r["tile_lo"].lstrip("$"), 16)
        hi = int(r["tile_hi"].lstrip("$"), 16)
        t0 = time.time()
        found: list[tuple[int, int, int, int, int]] = []
        for st in block_starts(vram, lo, hi):
            for pos, csize, osize, hdr_n in find_at(d, vram, st):
                if all(pos != f[1] for f in found):
                    found.append((st, pos, csize, osize, hdr_n))
        dt = time.time() - t0
        if found:
            found.sort(key=lambda f: f[0])
            tiles = sum(f[3] for f in found) // 32
            print(f"  ★ {stem:34} 블록 {len(found)} 개 · 타일 {tiles} 장  ({dt:.1f}s)")
            for st, pos, csize, osize, hdr_n in found:
                print(f"        타일 ${st:03X}  논리 ${pos:07X}  "
                      f"압축 {csize} B -> {osize} B ({osize // 32} 장)")
                out_rows.append({"dump": stem, "tile_first": f"${st:03X}",
                                 "logical": f"${pos:07X}", "room": csize,
                                 "decoded": osize, "tiles": osize // 32,
                                 "hdr_bytes": hdr_n})
        else:
            print(f"     {stem:34} 못 찾음  ({dt:.1f}s)")
            out_rows.append({"dump": stem, "tile_first": r["tile_lo"], "logical": "",
                             "room": "", "decoded": "", "tiles": "", "hdr_bytes": ""})

    dst = ATLAS / "blocks.tsv"
    with dst.open("w", encoding="utf-8", newline="") as fh:
        w = csv.DictWriter(fh, fieldnames=list(out_rows[0]), delimiter="\t",
                           lineterminator="\n")
        w.writeheader(); w.writerows(out_rows)
    ok = len({r["logical"] for r in out_rows if r["logical"]})
    print(f"\n  서로 다른 블록 {ok} 개   -> {dst}")


if __name__ == "__main__":
    main()
