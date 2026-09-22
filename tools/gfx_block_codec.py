#!/usr/bin/env python3
"""헌정 화면 그래픽 블록 코덱 -- Snatcher 원본 포맷 디코더·전개기·탐색기.

포맷 (2026-09-09 정적 해독 · `docs/handoff/SNATCHER_GFX_ROUTE_C_2026-09-09.md`)
---------------------------------------------------------------------------
    P[0]       플래그(bit7·bit6) + 표 길이 N (하위 7비트)
    P[1..N]    니블 변환표
    P[N+1..]   RLE 압축된 **플레이너** 4bpp 타일 (또는 BAT)

원본 루틴은 Track 02 오버레이(섹터 251-254 = CPU $6000-$7FFF)에 있다:

    $7061  압축 해제 -- 명령 10 종.  ⚠ **루프 머리**다 (`$7152 JMP $7061`)
    $71B0  128 B 버퍼에 쌓다가 차면 전개 후 VRAM 업로드
    $71C5  N != 0 일 때만 도는 **픽셀 단위 16색 재매핑** (전치가 아니다)

⚠ Track 02 는 Mode 1 / 2352 B 섹터다.  섹터마다 304 B (헤더 16 + ECC 288) 가
데이터가 아니므로 **평평한 파일 오프셋을 CPU 주소로 쓰면 안 된다.**  섹터의
[16 : 16+2048] 만 이어붙인 **논리 이미지**를 만들어 쓸 것.

⚠ 전개기는 **해석하지 말고 흉내 낼 것.**  `ROL $3Bxx,X` 가 버퍼 바이트를 돌리면서
캐리를 A 로 되돌리는 고리라, 손으로 수식화하면 거의 틀린다.

실측으로 확정된 자리 (2026-09-09):

    헌정 타일  논리 $0224B4B  압축 1,153 B -> 4,032 B = 126 타일 (MAWR $1100)
    헌정 BAT   논리 $02289C1  압축   789 B -> 2,048 B = 32x32 (종류 $08, 본문은 P+2)

    python tools/gfx_block_codec.py --scan          디스크에서 블록 찾기
    python tools/gfx_block_codec.py --at 0x224B4B   한 자리를 디코드해 보기
"""
from __future__ import annotations

import argparse
import sys
from pathlib import Path

if hasattr(sys.stdout, "reconfigure"):
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")

ROOT = Path(r"C:\snatcher")
TRACK02_JP = (ROOT / "rom(japan)" / "Snatcher CD-ROMantic (Japan)"
              / "Snatcher CD-ROMantic (Japan) (Track 02).bin")

# 업로더 진입 때 $3B00 에 있던 원본 헌정 타일 앞 16 B (Lua 0.3.x 실측).
BUFFER_SIG = bytes.fromhex("8000400020001000080004000300FC00")

BLOCK = 0x80          # $71B0 이 128 B 마다 전개·업로드한다


class Bad(Exception):
    """스트림이 규약에 안 맞는다."""


def decompress(d: bytes, pos: int, *, max_out: int, max_in: int) -> tuple[bytearray, int]:
    """`$7061` 을 그대로 옮긴 것.  (출력, 소비한 입력 끝 위치) 를 준다.

    ⚠ 6502 카운터는 0 이 256 을 뜻한다 (`DEC/BNE`, `CPY/BNE`).  그대로 살렸다.
    """
    out = bytearray()
    start = pos
    end = len(d)
    while True:
        if pos >= end or pos - start > max_in:
            raise Bad("입력 초과")
        if len(out) > max_out:
            raise Bad("출력 초과")
        c = d[pos]

        if c == 0xFF:                                   # $711D  끝
            return out, pos + 1

        if c == 0x00:                                   # $70AD  고정+리터럴 번갈아
            n = d[pos + 1] or 0x100
            b = d[pos + 2]
            lit = d[pos + 3:pos + 3 + n]
            if len(lit) < n:
                raise Bad("리터럴 부족")
            for k in range(n):
                out.append(b)
                out.append(lit[k])
            pos += 3 + n
        elif c == 0x01:                                 # $708B  16비트 RLE
            cnt = d[pos + 1] | (d[pos + 2] << 8)
            out.extend(bytes((d[pos + 3],)) * cnt)
            pos += 4
        elif c == 0x02:                                 # $7073  두 바이트 짝
            n = d[pos + 1] or 0x100
            out.extend(bytes((d[pos + 2], d[pos + 3])) * n)
            pos += 4
        elif c < 0x40:                                  # $70D0  짧은 RLE (3-63)
            out.extend(bytes((d[pos + 1],)) * c)
            pos += 2
        elif c < 0x80:                                  # $70E6  0 채우기
            out.extend(bytes(((c & 0x3F) or 0x100)))
            pos += 1
        elif c == 0x80:                                 # $7155  16비트 리터럴
            cnt = d[pos + 1] | (d[pos + 2] << 8)
            lit = d[pos + 3:pos + 3 + cnt]
            if len(lit) < cnt:
                raise Bad("긴 리터럴 부족")
            out.extend(lit)
            pos += 3 + cnt
        elif c < 0xC0:                                  # $713B  짧은 리터럴
            n = c & 0x7F
            lit = d[pos + 1:pos + 1 + n]
            if len(lit) < n:
                raise Bad("리터럴 부족")
            out.extend(lit)
            pos += 1 + n
        elif c < 0xFE:                                  # $711E  0 과 리터럴 번갈아
            n = (c & 0x3F) or 0x100
            lit = d[pos + 1:pos + 1 + n]
            if len(lit) < n:
                raise Bad("리터럴 부족")
            for b in lit:
                out.append(0)
                out.append(b)
            pos += 1 + n
        else:                                           # $717E  4바이트 무늬
            n = d[pos + 1] or 0x100
            out.extend(bytes(d[pos + 2:pos + 6]) * n)
            pos += 6


def expand(buf: bytearray, table: bytes) -> None:
    """`$71C5` 를 명령 단위로 그대로 흉내 낸다.  buf(128 B) 를 제자리에서 고친다."""
    for x in range(0x1F, -1, -1):
        a = 0                                           # CLA
        cnt = 8                                         # LDA #$08 / STA $07
        while True:
            a = table[a & 0x0F]                         # AND #$0F / TAY / LDA ($14),Y
            c = (a >> 7) & 1                            # ASL A
            a = (a << 1) & 0xFF
            for off in (0x60, 0x40, 0x20, 0x00):        # ROL $3Bxx,X / ROL A
                m = buf[off + x]
                buf[off + x] = ((m << 1) | c) & 0xFF
                c = (m >> 7) & 1
                top = (a >> 7) & 1
                a = ((a << 1) | c) & 0xFF
                c = top
            cnt -= 1                                    # DEC $07 / BPL
            if cnt < 0:
                break


def render(d: bytes, p: int, *, max_out: int = 0x8000,
           max_in: int = 0x4000) -> tuple[bytes, int, dict]:
    """블록 하나를 통째로 풀어 VRAM 에 올라갈 바이트열을 만든다."""
    header = d[p]
    n = header & 0x7F
    table = d[p + 1:p + 1 + n]
    # ⚠ N = 0 이면 변환표가 **없다** (`$71C1 LDA $10 / BEQ $71ED` -- 전개를 건너뛴다).
    #    실제 헌정 블록이 바로 이 경우다 (헤더 $80).  표 16칸을 강제하면 놓친다.
    if n and len(table) < 16:
        raise Bad("변환표가 16칸이 안 된다")
    raw, end = decompress(d, p + 1 + n, max_out=max_out, max_in=max_in)
    # ⚠ 128 배수를 강제하면 안 된다.  실측된 진짜 블록(섹터 259 +691)이
    #    **4,800 B** 다 -- 128 의 배수가 아니다.  한때 이걸 필수 조건으로 걸어
    #    스캔이 진짜를 통째로 걸러냈다.
    if not raw:
        raise Bad("출력이 없다")
    vram = bytearray()
    for i in range(0, len(raw), BLOCK):
        blk = bytearray(raw[i:i + BLOCK])
        if n:                                           # $71C1  N=0 이면 전개 없음
            expand(blk, table)
        vram += blk
    info = {"header": header, "n": n, "raw": len(raw), "end": end,
            "pre": bytes(raw)}                          # 전개 전 -- 지문이 이쪽일 수도 있다
    return bytes(vram), end, info


def encode(d: bytes) -> bytes:
    """`$7061` 이 그대로 풀 수 있는 스트림으로 압축한다 (동적계획법 · 최적에 가깝다).

    왜 탐욕이 아닌가 (2026-09-09 실측)
    ---------------------------------------------------------------------
    명령을 우선순위로 고르면 **한쪽만 잘한다.**  `$02`(2바이트 무늬)를 앞에
    두면 BAT 은 2,084 -> 885 B 로 좋아지는데 타일이 1,166 -> 2,028 B 로 나빠진다.
    자료마다 유리한 명령이 다르기 때문이다:

        타일  플레이너 4bpp 라 `XX 00 XX 00`  -> `$C0-$FD` (0+리터럴)
        BAT   `10 01 10 01`                  -> `$02` (2바이트 무늬) · `$00`

    그래서 자리마다 모든 명령을 후보로 놓고 **뒤에서부터 최소 비용**을 구한다.

    실측 (원본 압축기와 비교):

        헌정 BAT    2,048 B  ->  558 B  (원본 789 B   · **231 B 낫다**)
        헌정 타일   4,032 B  ->  999 B  (원본 1,153 B · **154 B 낫다**)
        한글 타일   4,448 B  ->  771 B  (자리 1,153 B · **382 B 여유**)
    """
    n = len(d)
    INF = float("inf")
    cost = [INF] * (n + 1)
    move: list[tuple | None] = [None] * (n + 1)
    cost[n] = 1                                     # $FF 종료

    for i in range(n - 1, -1, -1):
        best: float = INF
        bmv: tuple | None = None

        def try_(c: int, j: int, mv: tuple) -> None:
            nonlocal best, bmv
            if j <= n and cost[j] + c < best:
                best, bmv = cost[j] + c, mv

        run = 1
        while i + run < n and d[i + run] == d[i] and run < 0xFFFF:
            run += 1

        if d[i] == 0:                                # $40-$7F  0 채우기
            for k in range(min(run, 0x3F), 0, -1):
                try_(1, i + k, ("zero", k))
        if run >= 3:                                 # $03-$3F / $01  RLE
            try_(2, i + min(run, 0x3F), ("rle", min(run, 0x3F)))
            if run >= 0x100:
                try_(4, i + run, ("rle16", run))

        if i + 1 < n:                                # $02  2바이트 무늬
            a, b = d[i], d[i + 1]
            k = 0
            while i + 2 * k + 1 < n and d[i + 2 * k] == a and d[i + 2 * k + 1] == b and k < 0xFF:
                k += 1
            if k >= 2:
                try_(4, i + 2 * k, ("pair", k))

        k = 0                                        # $C0-$FD  0+리터럴 번갈아
        while i + 2 * k + 1 < n and d[i + 2 * k] == 0 and k < 0x3D:
            k += 1
        for kk in range(k, 1, -1):
            try_(1 + kk, i + 2 * kk, ("altz", kk))

        if i + 1 < n:                                # $00  고정바이트+리터럴
            cb = d[i]
            k = 0
            while i + 2 * k + 1 < n and d[i + 2 * k] == cb and k < 0xFF:
                k += 1
            if k >= 2:
                try_(3 + k, i + 2 * k, ("alt", k, cb))

        if i + 3 < n:                                # $FE  4바이트 무늬
            pat = d[i:i + 4]
            k = 0
            while i + 4 * k + 3 < n and d[i + 4 * k:i + 4 * k + 4] == pat and k < 0xFF:
                k += 1
            if k >= 2:
                try_(6, i + 4 * k, ("quad", k))

        for k in range(1, min(0x3F, n - i) + 1):     # $81-$BF  짧은 리터럴
            try_(1 + k, i + k, ("lit", k))
        if n - i > 0x3F:                             # $80  긴 리터럴
            k = min(0xFFFF, n - i)
            try_(3 + k, i + k, ("lit16", k))

        cost[i], move[i] = best, bmv

    out = bytearray()
    i = 0
    while i < n:
        mv = move[i]
        assert mv is not None
        t = mv[0]
        if t == "zero":
            out.append(0x40 | mv[1]); i += mv[1]
        elif t == "rle":
            out += bytes((mv[1], d[i])); i += mv[1]
        elif t == "rle16":
            k = mv[1]; out += bytes((0x01, k & 0xFF, k >> 8, d[i])); i += k
        elif t == "pair":
            out += bytes((0x02, mv[1], d[i], d[i + 1])); i += 2 * mv[1]
        elif t == "altz":
            k = mv[1]; out.append(0xC0 | k)
            out += bytes(d[i + 2 * j + 1] for j in range(k)); i += 2 * k
        elif t == "alt":
            k, cb = mv[1], mv[2]; out += bytes((0x00, k & 0xFF, cb))
            out += bytes(d[i + 2 * j + 1] for j in range(k)); i += 2 * k
        elif t == "quad":
            out += bytes((0xFE, mv[1])) + d[i:i + 4]; i += 4 * mv[1]
        elif t == "lit":
            k = mv[1]; out.append(0x80 | k); out += d[i:i + k]; i += k
        else:
            k = mv[1]; out += bytes((0x80, k & 0xFF, k >> 8)); out += d[i:i + k]; i += k
    out.append(0xFF)
    return bytes(out)


def scan(d: bytes, *, want: bytes, limit: int) -> None:
    """헤더 후보를 훑어 정상적으로 풀리는 블록만 남기고 지문을 찾는다."""
    total = clean = 0
    for p in range(len(d) - 32):
        h = d[p]
        if (h & 0x7F) != 0x10:                          # 니블표 16 칸
            continue
        total += 1
        try:
            vram, end, info = render(d, p)
        except (Bad, IndexError):
            continue
        clean += 1
        # 전개 후·전개 전 둘 다 본다.  지문을 잰 $7256 이 $71EE 와 다른 루틴이라
        # 그 버퍼가 전개를 거쳤는지 확정이 안 됐다.
        for label, blob in (("전개후", vram), ("전개전", info["pre"])):
            hit = blob.find(want)
            if hit != -1:
                print(f"★ 지문 일치({label})  P=${p:07X}  헤더 ${info['header']:02X}  "
                      f"출력 {len(blob):,} B  지문 위치 +{hit}", flush=True)
        if clean >= limit:
            break
    print(f"헤더 후보 {total:,} · 규약대로 풀린 블록 {clean:,}")


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--file", default=str(TRACK02_JP))
    ap.add_argument("--scan", action="store_true")
    ap.add_argument("--at", type=lambda s: int(s, 0))
    ap.add_argument("--start", type=lambda s: int(s, 0), default=0)
    ap.add_argument("--end", type=lambda s: int(s, 0), default=0)
    ap.add_argument("--limit", type=int, default=10**9)
    args = ap.parse_args()

    d = Path(args.file).read_bytes()
    if args.end:
        d = d[args.start:args.end]
    elif args.start:
        d = d[args.start:]

    if args.at is not None:
        vram, end, info = render(d, args.at - args.start)
        print(f"헤더 ${info['header']:02X}  표 {info['n']} 칸  "
              f"압축 {info['end'] - args.at + args.start:,} B  ->  VRAM {len(vram):,} B")
        print("앞 32 B:", vram[:32].hex(" ").upper())
        print("지문:", "찾음 +%d" % vram.find(BUFFER_SIG)
              if BUFFER_SIG in vram else "없음")
        return

    if args.scan:
        scan(d, want=BUFFER_SIG, limit=args.limit)


if __name__ == "__main__":
    main()
