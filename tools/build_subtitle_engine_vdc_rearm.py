#!/usr/bin/env python3
"""국장실 "위 그림이 중간중간 짧게 보이는" 증상 대조용 -- VDC 재무장 엔진.

무엇이 다른가
-------------
원본 631 B 는 글리프 루프 **밖**에서 VDC 레지스터를 한 번 고르고 19 글리프를
흘려보낸다.  선택 래치는 하나뿐이고 되읽을 수 없으므로, 그 사이 래스터 분할
IRQ 가 VDC 를 한 번만 건드려도 남은 글리프가 엉뚱한 레지스터로 들어간다.

    +$093  ST0 #$02        ; VWR 선택 -- 루프 밖, 딱 한 번
           ... 80 B ...    ; 이 구간이 조각마다 그대로 노출된다
    +$0E3  TIA -> $0002

이 판은 그 선택을 **TIA 직전**으로 옮기고 PHP/SEI~PLP 로 감싼다.  TIA 자체가
중단 불가이므로 늘어나는 IRQ 지연은 ST/LDA/STA 몇 개뿐이다.  즉 떨림(전송량
경로)을 악화시키지 않고 래치 경합만 없앤다.

한 글자 엔진(engine_ac_lua_frame_oneglyph.bin)과 다른 점:
한 글자판은 루프 반복만 1 회로 줄여서 **떨림은 줄었지만 위 그림 증상은 그대로**
였다.  셋업 구간은 조각마다 한 번씩 똑같이 실행되기 때문이다.  이 판이 바로
그 셋업 구간을 없앤다.

왜 오프셋 표를 같이 내보내나
----------------------------
in-loop 로 코드가 들어가면 `ready` / `selector` / `stage` 가 뒤로 밀린다.
그런데 0.4.57 은 631/345/343 을, 0.4.58 은 `$5D77` 과 파일 오프셋 504 를
하드코딩한다.  지금 잘 도는 그 체인을 건드리면 known-good 경로를 잃으므로,
새 체인(0.4.89)이 읽을 표를 여기서 같이 만든다.  Lua 에 JSON 파서가 없어서
`.json` 과 `.lua` 를 둘 다 쓴다.

    python tools/build_subtitle_engine_vdc_rearm.py
"""
from __future__ import annotations

import argparse
import json
import struct
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path[:0] = [str(ROOT / "tools")]

import build_subtitle_engine as base
import build_subtitle_engine_ac_record_poc as record_engine
import subtitle_layout as layout

PACK = ROOT / "build" / "cutscene_subs" / "subtitle_pack.bin"
BUILD = ROOT / "build" / "cutscene_subs"
OUT = BUILD / "engine_ac_lua_frame_rearm.bin"
INFO = BUILD / "engine_ac_lua_frame_rearm.json"
LUA = BUILD / "engine_ac_lua_frame_rearm.lua"

# 원본 미니 엔진과 반드시 같아야 하는 값들 (build_subtitle_engine_ac_lua_frame_mini.py)
MINI_INDEX = 0x1EF000
MINI_COUNT = 11
# ★ 2026-09-03: 672 -> 671 로 줄였다.  CPU 캐시 백업이 실제로 뜨는 범위가
#   `5B80+671` ($5B80-$5E1E) 이다 (patch_bios_cpu_cache.py · *.cpu_cache.json).
#   672 를 허용하면 마지막 한 바이트가 **백업 밖**이라, 그 자리를 우리 코드로
#   덮고도 되돌려주지 못한다 -- 챕터1 화면 파손의 그 함정과 같은 종류다.
SAFE_BYTES = 671

REFERENCE = ROOT / "build" / "cutscene_subs" / "engine_ac_lua_frame_mini.bin"


def main() -> None:
    ap = argparse.ArgumentParser()
    # ★ 글리프 VRAM base 를 바꿔 굽는다.  기본값 $1600 은 배경 그림 데이터와
    # 겹친다 -- 배경 타일은 $1100 에서 시작해 그림 크기만큼 위로 자라고,
    # 국장실처럼 큰 그림에서는 $1A00 대까지 온다 (0.4.91 실측: 165/4096 엔트리).
    # 그림이 작은 장면에서만 안 겹쳤을 뿐이다.
    ap.add_argument("--pat-vram", default=None,
                    help="글리프 VRAM base (예: 0x7900).  기본은 subtitle_layout 값")
    ap.add_argument("--pack", type=Path, default=PACK,
                    help="엔진의 record/glyph 주소를 계산할 SNSB v6 팩")
    ap.add_argument("--tag", default=None,
                    help="기본 산출물을 덮지 않을 파일명 suffix (예: frozen_8F20AF38)")
    args = ap.parse_args()

    global OUT, INFO, LUA
    if args.tag:
        safe_tag = "".join(c for c in args.tag if c.isalnum() or c in "_-")
        if not safe_tag or safe_tag != args.tag:
            raise SystemExit("--tag는 영문/숫자/_/-만 허용")
        OUT = BUILD / f"engine_ac_lua_frame_rearm_{safe_tag}.bin"
        INFO = BUILD / f"engine_ac_lua_frame_rearm_{safe_tag}.json"
        LUA = BUILD / f"engine_ac_lua_frame_rearm_{safe_tag}.lua"
    if args.pat_vram is not None:
        layout.PAT_VRAM = int(args.pat_vram, 0)
        if not args.tag:
            tag = f"_{layout.PAT_VRAM:04X}"
            OUT = BUILD / f"engine_ac_lua_frame_rearm{tag}.bin"
            INFO = BUILD / f"engine_ac_lua_frame_rearm{tag}.json"
            LUA = BUILD / f"engine_ac_lua_frame_rearm{tag}.lua"

    glyph_last = layout.PAT_VRAM + layout.MAX_GLYPHS * 0x40 - 1
    if glyph_last > 0x7FFF:
        raise SystemExit(f"글리프 블록이 VRAM 을 넘는다: "
                         f"${layout.PAT_VRAM:04X}-${glyph_last:04X}")
    print(f"PAT_VRAM ${layout.PAT_VRAM:04X} · 글리프 블록 "
          f"${layout.PAT_VRAM:04X}-${glyph_last:04X}")

    blob = args.pack.read_bytes()
    if blob[:4] != b"SNSB":
        raise SystemExit(f"subtitle pack magic 불일치: {args.pack}")
    glyph_off, = struct.unpack_from("<I", blob, 10)
    record_off, = struct.unpack_from("<I", blob, 26)
    args = dict(glyph_base=layout.AC_PACK + glyph_off, lookup=True, timed=False,
                overlay_palette=True, index_base=MINI_INDEX,
                index_count=MINI_COUNT, record_base=layout.AC_PACK + record_off,
                wide_lookup=False, vdc_rearm=True, blank_frame=True, idle_state=True)

    first, labels = record_engine.build(None, **args)
    engine, labels = record_engine.build(labels, **args)
    if len(first) != len(engine):
        raise SystemExit(f"2-pass size mismatch: {len(first)} vs {len(engine)}")
    if len(engine) > SAFE_BYTES:
        raise SystemExit(f"rearm engine too big: {len(engine)} / {SAFE_BYTES}")

    offsets = {name: address - base.ENGINE_LO for name, address in labels.items()}
    for need in ("entry", "count_ok", "glyph_loop", "ready", "selector", "stage",
                 "vram_base_hi_imm", "pattern_base_lo_imm", "pattern_attr_imm"):
        if need not in offsets:
            raise SystemExit(f"label missing: {need}")

    # stage 루틴은 0.4.89 가 파일에서 그대로 읽어 $5B80+stage 에 다시 쓴다.
    # 그 루틴이 RTS($60)로 끝나는지 여기서 확인해 둔다 -- 런타임에서 못 찾으면
    # stage 재무장이 조용히 안 걸린다.
    stage_at = offsets["stage"]
    rts = engine.find(b"\x60", stage_at)
    if rts < 0 or rts - stage_at >= 64:
        raise SystemExit(f"stage RTS not found within 64 B of +{stage_at}")

    OUT.write_bytes(engine)

    info = {
        "engine_bytes": len(engine),
        "safe_limit": SAFE_BYTES,
        "engine_lo": base.ENGINE_LO,
        "vdc_rearm": True,
        "initial_delay": True,
        "mini_index": f"{MINI_INDEX:06X}",
        "mini_count": MINI_COUNT,
        "pat_vram": f"{layout.PAT_VRAM:04X}",
        "stage_routine_bytes": rts - stage_at + 1,
        "offsets": offsets,
    }
    INFO.write_text(json.dumps(info, ensure_ascii=False, indent=2), encoding="utf-8")

    lines = [
        "-- 자동 생성.  tools/build_subtitle_engine_vdc_rearm.py",
        "-- 손으로 고치지 말 것.  엔진을 다시 구우면 이 값도 같이 바뀐다.",
        "return {",
        f"  path = 'C:/snatcher/build/cutscene_subs/{OUT.name}',",
        f"  engine_lo = 0x{base.ENGINE_LO:04X},",
        f"  engine_bytes = {len(engine)},",
        f"  mini_index = 0x{MINI_INDEX:06X},",
        f"  mini_count = {MINI_COUNT},",
        f"  pat_vram = 0x{layout.PAT_VRAM:04X},",
        f"  stage_routine_bytes = {rts - stage_at + 1},",
        "  offsets = {",
    ]
    for name in sorted(offsets):
        lines.append(f"    {name} = {offsets[name]},")
    lines += ["  },", "}", ""]
    LUA.write_text("\n".join(lines), encoding="utf-8")

    print(f"VDC rearm engine {len(engine)} B / safe {SAFE_BYTES} B")
    if REFERENCE.is_file():
        ref = REFERENCE.read_bytes()
        print(f"  원본 미니 엔진 {len(ref)} B -> 순증 {len(engine) - len(ref):+d} B")
    print(f"  stage +{stage_at} · 루틴 {rts - stage_at + 1} B · CPU "
          f"${base.ENGINE_LO + stage_at:04X}")
    print(OUT)
    print(LUA)


if __name__ == "__main__":
    main()
