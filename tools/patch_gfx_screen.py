#!/usr/bin/env python3
"""전면 그래픽 화면을 **디스크에서 제자리 치환**한다 (route C, 화면 여러 개).

`patch_gfx_dedication_route_c.py` 를 일반화한 것이다.  헌정 화면 하나만 있을
때는 표를 박아 두어도 됐지만 화면이 늘어나면서 화면마다 스크립트를 뜨는 것은
말이 안 된다.  훅 0 개 · 런타임 코드 0 바이트라는 성질은 그대로다 -- 게임이
자기 압축 해제기로 우리 그림을 푼다.

새로 넣은 관문 둘
    1) **사본 검사.**  같은 블록이 디스크에 여러 벌 있는 화면이 실제로 있다
       (`$039914A`/`$05EF630` 등 3 건 실측).  한 벌만 갈면 그 화면은 **가끔**
       일본어로 나온다.  기본은 거절하고, `--all-copies` 를 줘야 전부 간다.
    2) **route_c 선언 누적.**  기준판이 이미 route_c 를 갖고 있으면 덮지 않고
       블록·섹터를 **더한다**.  감사 도구(`check_build_invariants.py`)가
       `route_c.sectors_touched` 로 오버레이 섹터 변경을 판정하므로, 덮으면
       앞 화면이 거짓 실패로 뜬다.

⚠ 헤더는 **원본을 보존**한다.  BAT 의 `P[1]` 은 `$6FFC` 에서 제로페이지 `$0A`
  로 들어가는 인자인데 무엇에 쓰이는지 아직 모른다.  설명 못 하는 값은 안 바꾼다.

⚠ Track 02 는 Mode 1 / 2352 B 섹터다.  논리(사용자영역만) 오프셋을 물리로 옮기고
  건드린 섹터마다 EDC/ECC 를 다시 계산한다.

★ 쓰고 나서 **다시 풀어서** 우리 .bin 과 바이트로 대조한다.  자기 식을 두 번 쓰는
  검산이 아니라, 게임과 같은 해독기(`gfx_block_codec.decompress`)로 되읽는 것이다.

    python tools/patch_gfx_screen.py --screen rss                 보고만
    python tools/patch_gfx_screen.py --screen rss --write
"""
from __future__ import annotations

import argparse
import hashlib
import json
import os
import shutil
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from build_disc_subtitle_hook import rebuild_mode1_sector      # noqa: E402
import gfx_block_codec as codec                                # noqa: E402

ROOT = Path(r"C:\snatcher")
PATCH = ROOT / "build" / "patch"
GFX = ROOT / "build" / "gfx"
TRACK02 = "Snatcher CD-ROMantic (Japan) (Track 02) [KO].bin"

RAW, USER, HDR = 2352, 2048, 16

# 화면마다: (이름, 논리오프셋, 자리크기, 헤더바이트수, 산출물 stem)
#   stem -> `<stem>.pack` (넣을 것) · `<stem>.bin` (풀렸을 때 기대값)
SCREENS: dict[str, dict] = {
    "ending_struggle": {
        "base": "0.7.26",
        "version": "0.7.27-gfx-ending-g14",
        "what": "엔딩 투쟁 문구 (疑い。それは…)",
        "blocks": [
            ("타일", 0x0EB0103, 1491, 1, "ending_struggle.routec.tiles"),
            ("BAT",  0x0E98CF6, 1024, 2, "ending_struggle.routec.bat"),
        ],
    },
    "dedication": {
        "base": "0.6.5",
        "version": "0.6.6-gfx-routec",
        "what": "헌정 화면",
        "blocks": [
            ("타일", 0x0224B4B, 1153, 1, "dedication.routec.tiles"),
            ("BAT",  0x02289C1,  789, 2, "dedication.routec.bat"),
        ],
    },
    "disclaimer": {
        "base": "0.6.7-gfx-rss",
        "version": "0.6.8-gfx-disclaimer",
        "what": "파란 면책 화면 (<원문 11자>...)",
        "blocks": [
            ("타일", 0x02234A6, 5797, 1, "disclaimer.routec.tiles"),
            ("BAT",  0x02285E5,  988, 2, "disclaimer.routec.bat"),
        ],
    },
    "gibson": {
        # 깁슨 컴퓨터 문서 -- 반쪽 화면 9 장.
        # ⚠ 8 번은 이 장만 낱말 쪼개기를 허용해야 여덟 줄에 들어간다.
        #   그 $400 블록은 디스크에 두 벌이다 ($039914A/$05EF630) -- --all-copies 필수.
        # ⚠ 2·3·5 번은 타일 블록 짝을 아직 못 정했다 (원문도 못 그린다).
        "base": "0.6.8-gfx-disclaimer",
        "version": "0.6.9-gfx-gibson",
        "what": "깁슨 컴퓨터 문서 13 장",
        "blocks": [
            ("01타일", 0x05EB800, 2212, 1, "gibson01.routec.tiles"),
            ("01BAT",  0x05F2939, 414, 2, "gibson01.routec.bat"),
            ("02타일", 0x05EC0BF, 2272, 1, "gibson02.routec.tiles"),
            ("02BAT",  0x05F2AD7,  460, 2, "gibson02.routec.bat"),
            ("03타일", 0x05ECA52, 2501, 1, "gibson03.routec.tiles"),
            ("03BAT",  0x05F2CA3,  536, 2, "gibson03.routec.bat"),
            ("04타일", 0x05ED701, 725, 1, "gibson04.routec.tiles"),
            ("04BAT",  0x05F2EBB, 395, 2, "gibson04.routec.bat"),
            ("05타일", 0x05ED9D6, 2289, 1, "gibson05.routec.tiles"),
            ("05BAT",  0x05F3046,  461, 2, "gibson05.routec.bat"),
            ("06타일", 0x05EE39B, 2063, 1, "gibson06.routec.tiles"),
            ("06BAT",  0x05F3213, 395, 2, "gibson06.routec.bat"),
            ("07타일", 0x05EEBAA, 2694, 1, "gibson07.routec.tiles"),
            ("07BAT",  0x05F339E, 435, 2, "gibson07.routec.bat"),
            ("08타일", 0x05EF630, 2367, 1, "gibson08.routec.tiles"),
            ("08BAT",  0x05F3551,  535, 2, "gibson08.routec.bat"),
            ("09타일", 0x05F0530, 1128, 1, "gibson09.routec.tiles"),
            ("09BAT",  0x05F3768, 395, 2, "gibson09.routec.bat"),
            ("10타일", 0x05F0998, 1864, 1, "gibson10.routec.tiles"),
            ("10BAT",  0x05F38F3, 395, 2, "gibson10.routec.bat"),
            ("11타일", 0x05F10E0, 1917, 1, "gibson11.routec.tiles"),
            ("11BAT",  0x05F3A7E, 395, 2, "gibson11.routec.bat"),
            ("12타일", 0x05F185D, 2082, 1, "gibson12.routec.tiles"),
            ("12BAT",  0x05F3C09, 395, 2, "gibson12.routec.bat"),
            ("13타일", 0x05F207F, 1509, 1, "gibson13.routec.tiles"),
            ("13BAT",  0x05F3D94, 395, 2, "gibson13.routec.bat"),
        ],
    },
    "phone": {
        # 화상전화 안내 두 장.  창틀·얼굴 그림은 그대로 두고 파란 상자 안만 갈았다.
        "base": "0.6.9-gfx-gibson",
        "version": "0.6.10-gfx-phone",
        "what": "화상전화 안내 2 장",
        "blocks": [
            ("8타일",  0x07509F4, 3069, 1, "phone8.routec.tiles"),
            ("8BAT",   0x0752A9B,  216, 2, "phone8.routec.bat"),
            ("21타일", 0x0770840, 2225, 1, "phone21.routec.tiles"),
            ("21BAT",  0x077371F,  232, 2, "phone21.routec.bat"),
        ],
    },
    "rss": {
        # 헌정 판 위에 얹는다 -- 화면끼리 겹치는 블록이 없으므로 쌓으면 된다.
        "base": "0.6.6-gfx-routec",
        "version": "0.6.7-gfx-rss",
        "what": "RSS(Roland Sound Space) 안내 화면",
        "blocks": [
            ("타일", 0x0224FCC, 4021, 1, "rss.routec.tiles"),
            ("BAT",  0x0227BC1,  789, 2, "rss.routec.bat"),
        ],
    },
}


def phys(logical: int) -> int:
    sec, off = divmod(logical, USER)
    return sec * RAW + HDR + off


def read_logical(data: bytes, logical: int, n: int) -> bytes:
    out = bytearray()
    while n > 0:
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


def logical_of(data: bytes) -> bytes:
    """물리 트랙 -> 논리 이미지 (사본 검사에 쓴다)."""
    out = bytearray()
    for base in range(0, len(data) - RAW + 1, RAW):
        out += data[base + HDR:base + HDR + USER]
    return bytes(out)


def copies_of(image: bytes, blob: bytes) -> list[int]:
    hits, at = [], 0
    while True:
        i = image.find(blob, at)
        if i < 0:
            return hits
        hits.append(i)
        at = i + 1


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--screen", required=True, choices=sorted(SCREENS))
    ap.add_argument("--base", default=None, help="안 주면 화면 표의 기준판")
    ap.add_argument("--version", default=None)
    ap.add_argument("--all-copies", action="store_true",
                    help="같은 블록이 디스크에 여러 벌이면 전부 간다")
    ap.add_argument("--write", action="store_true")
    args = ap.parse_args()

    S = SCREENS[args.screen]
    base = args.base or S["base"]
    version = args.version or S["version"]
    blocks = S["blocks"]

    src_dir = PATCH / base
    out_dir = PATCH / version
    src_track = src_dir / TRACK02
    if not src_track.is_file():
        sys.exit(f"기준판 Track 02 가 없다: {src_track}")

    data = bytearray(src_track.read_bytes())
    # ⚠ 앞 224 섹터는 프리갭이라 통째로 0 이다.  거기서 모드 바이트를 보면 안 된다.
    #    우리가 실제로 건드릴 섹터에서 확인한다 (rebuild_mode1_sector 도 다시 본다).
    for _, logical, room, *_ in blocks:
        for sec in range(logical // USER, (logical + room - 1) // USER + 1):
            if data[sec * RAW + 15] != 1:
                sys.exit(f"섹터 {sec} 가 Mode 1 이 아니다 (모드 ${data[sec * RAW + 15]:02X})")

    image = logical_of(bytes(data))

    plan: list[tuple[str, int, bytes]] = []
    print("=" * 74)
    print(f"route C 제자리 치환   [{args.screen}] {S['what']}")
    print(f"기준 {base} -> {version}")
    print("=" * 74)

    for name, logical, room, hdr_n, stem in blocks:
        pack = GFX / f"{stem}.pack"
        want_p = GFX / f"{stem}.bin"
        if not pack.is_file() or not want_p.is_file():
            sys.exit(f"산출물이 없다: {pack.name} / {want_p.name}"
                     "  -> tools/build_gfx_screen_text.py 를 먼저 돌릴 것")
        new = pack.read_bytes()
        old = read_logical(bytes(data), logical, room)

        # 원본 헤더 보존 · 스트림만 교체
        payload = old[:hdr_n] + new[hdr_n:]
        if old[:hdr_n] != new[:hdr_n]:
            print(f"  [{name}] 헤더 보존: 원본 {old[:hdr_n].hex(' ')} "
                  f"(팩은 {new[:hdr_n].hex(' ')} 였다)")
        if len(payload) > room:
            sys.exit(f"[{name}] {len(payload)} B 가 자리 {room} B 를 넘는다")
        if old[room - 1] != 0xFF:
            sys.exit(f"[{name}] 원본 블록이 $FF 로 안 끝난다 -- 자리 계산이 틀렸다")
        # ★★ 시작도 확인한다.  블록은 앞 블록의 `$FF` 바로 뒤에서 시작한다.
        #    앞이 $FF 가 아니면 그 자리는 **다른 블록 한복판**이다.
        #    2026-09-10 에 이걸 안 봐서 가짜 시작($05EC012)에 1,391 B 를 쓰고
        #    화면을 통째로 깼다.  풀어서 그림이 맞는 것만으로는 부족하다.
        if read_logical(bytes(data), logical - 1, 1)[0] != 0xFF:
            sys.exit(f"[{name}] ${logical:07X} 앞이 $FF 가 아니다 -- 블록 시작이 "
                     "아니라 다른 블록 한복판이다")

        # 게임과 같은 해독기로 되읽어 검산한다
        out, _ = codec.decompress(payload, hdr_n, max_out=0x10000, max_in=room)
        expect = want_p.read_bytes()
        okmark = "OK" if bytes(out) == expect else "★불일치"
        print(f"  [{name}] 논리 ${logical:07X} · 자리 {room} B")
        print(f"        새 스트림 {len(payload)} B  (여유 {room - len(payload)} B)")
        print(f"        풀어보니 {len(out)} B / 기대 {len(expect)} B   {okmark}")
        if bytes(out) != expect:
            sys.exit("되읽기가 기대와 다르다 -- 쓰지 않는다")

        # ★ 사본 검사 -- 한 벌만 갈면 그 화면이 가끔 일본어로 나온다
        where = copies_of(image, old)
        extra = [w for w in where if w != logical]
        if extra:
            print(f"        ⚠ 같은 블록이 {len(where)} 벌 있다: "
                  + " ".join(f"${w:07X}" for w in where))
            if not args.all_copies:
                sys.exit("  사본을 안 갈면 화면이 가끔 원문으로 나온다."
                         "  --all-copies 를 줄 것")
            for w in extra:
                print(f"        사본도 간다: ${w:07X}")
                plan.append((f"{name}(사본)", w, payload))
        plan.append((name, logical, payload))

    if not args.write:
        print("\n보고만 했다.  반영하려면 --write 를 준다.")
        return

    touched: set[int] = set()
    for _, logical, payload in plan:
        touched |= write_logical(data, logical, payload)
    for sec in sorted(touched):
        blk = bytearray(data[sec * RAW:(sec + 1) * RAW])
        rebuild_mode1_sector(blk)
        data[sec * RAW:(sec + 1) * RAW] = blk
    print(f"\n  건드린 섹터 {len(touched)} 개 · EDC/ECC 재계산 완료")

    # 새 판 폴더 -- 안 바뀌는 트랙은 하드링크로 (같은 볼륨 · 디스크 0)
    out_dir.mkdir(parents=True, exist_ok=True)
    linked = copied = 0
    for f in sorted(src_dir.iterdir()):
        if not f.is_file():
            continue
        dst = out_dir / f.name
        if dst.exists():
            continue
        # ⚠ Track 24 는 안 건드리므로 그 `.pre_pack_patch` 사본은 물려받는 게 맞다.
        if f.name in (TRACK02, TRACK02 + ".pre_pack_patch"):
            continue
        try:
            os.link(f, dst)
            linked += 1
        except OSError:
            shutil.copy2(f, dst)
            copied += 1
    # ★★ 매니페스트와 같은 처방을 Track 02 에도 건다.  기준판에서 링크로 받아온
    #    파일에 제자리로 쓰면 같은 inode 인 **기준판까지 같이 바뀐다.**
    #    제자리 얹기(`--base` == `--version`)에서는 이게 유일한 안전장치다.
    dst_track = out_dir / TRACK02
    if dst_track.exists():
        dst_track.unlink()
    dst_track.write_bytes(bytes(data))
    print(f"  트랙/파일 링크 {linked} · 복사 {copied} · Track 02 새로 씀"
          f"{'  (제자리)' if src_dir == out_dir else ''}")

    # 쓴 파일에서 다시 한 번 (다른 출처로 검산)
    final = (out_dir / TRACK02).read_bytes()
    for name, logical, room, hdr_n, stem in blocks:
        want = (GFX / f"{stem}.bin").read_bytes()
        for at in {lg for nm, lg, _ in plan if nm.startswith(name)}:
            blob = read_logical(final, at, room)
            out, _ = codec.decompress(blob, hdr_n, max_out=0x10000, max_in=room)
            print(f"  검산 [{name}] ${at:07X} 되읽기 "
                  f"{'OK' if bytes(out) == want else '★불일치'}")

    # 매니페스트를 이 판의 실물에 맞춘다 (물려받은 값을 두면 거짓 실패가 난다)
    man_path = out_dir / "manifest.json"
    if man_path.is_file():
        man = json.loads(man_path.read_text(encoding="utf-8"))
        man["track02_sha256"] = hashlib.sha256(bytes(data)).hexdigest().upper()
        # ★ 앞 화면 선언을 덮지 않고 더한다
        rc = man.get("route_c") or {}
        rc_blocks = list(rc.get("blocks", []))
        rc_blocks += [{"screen": args.screen, "name": n,
                       "logical": ("$%07X" % lg), "bytes": len(pl)}
                      for n, lg, pl in plan]
        man["route_c"] = {
            "what": "전면 그래픽 화면을 디스크에서 제자리 치환 (훅 0 · 런타임 코드 0 B)",
            "base": base,
            "screens": sorted(set(rc.get("screens", [])) | {args.screen}),
            "blocks": rc_blocks,
            "sectors_touched": sorted(set(rc.get("sectors_touched", [])) | touched),
        }
        # ★★ 하드링크를 **먼저 끊는다.**  기준판에서 링크로 받아온 파일이라
        #    제자리에 쓰면 같은 inode 인 기준판 매니페스트까지 같이 바뀐다.
        #    2026-09-09 에 실제로 0.6.5 매니페스트를 오염시켰다.
        text = json.dumps(man, ensure_ascii=False, indent=2) + "\n"
        man_path.unlink()
        man_path.write_text(text, encoding="utf-8")
        print("  매니페스트 갱신: track02_sha256 + route_c 누적 (링크 끊고 새 파일)")

    print(f"\n  {out_dir}")
    print("  ⚠ Syscard3 는 기준판 것 그대로다 -- 훅도 런타임 코드도 없다")


if __name__ == "__main__":
    main()
