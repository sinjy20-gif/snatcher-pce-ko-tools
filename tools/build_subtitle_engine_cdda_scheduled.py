#!/usr/bin/env python3
"""트랙 17 39 구간을 스케줄러 기반으로 그리는 CD-DA 렌더러 (2026-09-03 저녁).

`build_subtitle_engine_cdda_track17_poc.py` 는 안 건드린다 (다른 빌더가 참조한다).
이 파일은 그 옆에 **새 경로**로 만든다.

무엇이 다른가
-------------
    track17_poc(671 B)   generic(602) + 자체 타이머(69, 문턱 3 개 고정)
    이 판(602 B)          generic(602) 만.  타이머는 BIOS 스케줄러가 대신 센다

렌더러(602 B) 자체는 record_engine.build(lookup=False, ...) 그대로다.
바뀌는 것은 조립 과정뿐이다:

    ★ build_tail(69 B, 문턱 판정) 을 안 붙인다
    ★ build_entry(14 B, 게임 코드 가로채 elapsed 세기) 로 표준 entry 를
      덮어쓰지 **않는다** -- record_engine 의 표준 entry(ready 체크 +
      blank_frame)가 그대로 남는다.  ADPCM 이 오늘 쓰기 시작한 그 보호를
      CD-DA 도 공짜로 받는다 (blank_frame=True)
    ★ record_ptr 초기값은 39 구간 중 **첫 구간**으로 둔다.
      (스케줄러가 무장 시 즉시 덮으므로 사실상 임의값이어도 되지만,
       혼자 돌려서 확인할 때를 위해 맞는 값을 넣어 둔다)

이 판이 하지 않는 것
---------------------
    스케줄러 코드(sched_due_cdda) 신설      -- 다음 단계
    cdda_start 를 이 렌더러로 바꾸는 무장 코드 수정  -- 다음 단계
    cdda_signature 재계산                   -- 다음 단계 (602 B 구조가 나와야 정한다)

    python build_subtitle_engine_cdda_scheduled.py            보고만
    python build_subtitle_engine_cdda_scheduled.py --write    저장
"""
from __future__ import annotations

import argparse
import csv
import hashlib
import json
import struct
from pathlib import Path

import build_subtitle_engine as base
import build_subtitle_engine_ac_record_poc as record_engine
import subtitle_layout as layout

ROOT = Path(__file__).resolve().parents[1]
BUILD = ROOT / "build" / "cutscene_subs"
PACK = BUILD / "subtitle_pack.bin"
MINI_TSV = BUILD / "cdda_track17_mini_index.tsv"
MINI_ALL_TSV = BUILD / "cdda_mini_index_all.tsv"   # 전 트랙판.  있으면 이쪽이 정본
OUT = BUILD / "engine_cdda_scheduled_track17.bin"
INFO = BUILD / "engine_cdda_scheduled_track17.json"

SAFE_BYTES = 0x5E20 - base.ENGINE_LO   # 672 B 슬롯 한도 (변경 없음)

# ★ 매체 지문 (2026-09-04 신설)
#
# 디스패처는 active 슬롯이 ADPCM 것인지 CD-DA 것인지를 **한 바이트로** 가른다.
# 지금까지는 CD-DA 엔진의 timer 첫 opcode(+602 = $38 SEC)를 봤는데, 그건
# "ADPCM 이 그 자리에 마침 $38 이 아니다" 에 기댄 우연이다.  렌더러를 다시
# 구우면 언제든 깨진다.
#
# 그래서 **ADPCM 이 절대 닿지 않는 자리**를 쓴다.  무장 코드는 슬롯을
# `max(adpcm_bytes, cdda_bytes)` 만큼 ADPCM 템플릿(+FF 패딩)으로 덮으므로,
# ADPCM 길이보다 뒤쪽은 반드시 $FF 다.  거기에 CD-DA 만 값을 둔다.
#
#   ADPCM 666 B  ->  +670 은 FF 패딩
#   CD-DA        ->  +670 에 $CD
#
# ⚠ ADPCM 렌더러가 671 B 를 넘으면 이 전제가 깨진다.  통합 빌드에서
#   `adpcm_bytes <= MEDIA_MAGIC_AT` 를 반드시 확인할 것.
MEDIA_MAGIC_AT = 670
MEDIA_MAGIC = 0xCD
IMAGE_BYTES = MEDIA_MAGIC_AT + 1       # 671 B (패딩 포함 최종 블롭 크기)


def load_mini() -> list[dict]:
    """렌더러의 초기값(record_ptr · vram base)을 어느 표에서 뽑을지 고른다.

    ★ 2026-09-04 밤: **전 트랙판이 있으면 그쪽이 정본이다.**

    전 트랙 연결(§16-17) 때 런타임이 읽는 표는 `cdda_mini_index_all` 로 옮겼는데
    이 빌더의 입력만 옛 트랙17 표로 남았다.  같은 팩으로 구운 동안은 우연히
    맞았지만, 팩을 다시 구운 순간 옛 표의 `rec_off` 가 낡아 **첫 구간 레코드가
    111칸/2px 같은 쓰레기로 읽혔다** (2026-09-04, 0.5.1 빌드에서 잡힘).

    전 트랙 표는 `build_cdda_mini_index_all.py` 가 굽는 자리에서 이미
    "705 구간 전부 팩에서 레코드로 파싱된다" 를 검산하고 낸다.  그래서 여기서
    다시 status 열을 보지 않는다 (그 표엔 그 열이 없다).

    ⚠ 초기값은 **자리표시자**다.  전 트랙 모드에서는 `cdda_start` 가 무장 때
      트랙 디렉터리의 값을 렌더러 즉치 자리에 심는다.  그래도 유효해야 하므로
      트랙 17 의 첫 구간을 골라 옛 판과 같은 $7900 이 되게 한다.
    """
    if MINI_ALL_TSV.exists():
        with MINI_ALL_TSV.open(encoding="utf-8-sig", newline="") as f:
            rows = list(csv.DictReader(f, delimiter="\t"))
        if not rows:
            raise SystemExit(f"mini index 표가 비어 있다: {MINI_ALL_TSV}")
        t17 = [r for r in rows if (r.get("track") or "").strip() == "17"]
        rows = (t17 or rows)
        for r in rows:
            if not r.get("vram_base"):
                raise SystemExit(f"vram_base 가 없다: {r}")
        return rows

    if not MINI_TSV.exists():
        raise SystemExit(f"mini index 표가 없다: {MINI_TSV}\n"
                         "  python build_cdda_track17_mini_index.py --write 먼저")
    with MINI_TSV.open(encoding="utf-8-sig", newline="") as f:
        rows = list(csv.DictReader(f, delimiter="\t"))
    if not rows:
        raise SystemExit("mini index 표가 비어 있다")
    for r in rows:
        if r["status"] != "verified" or not r["vram_base"]:
            raise SystemExit(f"#{r['index']} 가 verified 가 아니다: {r}")
    return rows


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--write", action="store_true")
    args = ap.parse_args()

    rows = load_mini()
    first = rows[0]

    blob = PACK.read_bytes()
    if blob[:4] != b"SNSB" or struct.unpack_from("<H", blob, 4)[0] != 6:
        raise SystemExit("subtitle pack must be SNSB v6")
    glyph_off, = struct.unpack_from("<I", blob, 10)
    record_off, = struct.unpack_from("<I", blob, 26)

    first_ptr = layout.AC_PACK + record_off + int(first["rec_off"])

    # 첫 구간의 표시 레코드가 실제로 유효한지 확인 (track17_poc.records() 의
    # 마지막 검증과 같은 것 -- 여기서는 첫 항목 하나만 판다).
    cells, width, _flags, y, frames = struct.unpack_from(
        "<BBBBH", blob, record_off + int(first["rec_off"]))
    if not (1 <= cells <= 19 and 1 <= width <= 192 and frames > 0):
        raise SystemExit(f"첫 구간 레코드가 이상하다: {cells}칸/{width}px/y{y}/{frames}f")

    old_vram = layout.PAT_VRAM
    try:
        layout.PAT_VRAM = int(first["vram_base"], 16)
        build_args = dict(glyph_base=layout.AC_PACK + glyph_off, lookup=False,
                          timed=False, overlay_palette=True, vdc_rearm=True,
                          blank_frame=True, idle_state=True, expire_frames=True)
        pass1, labels = record_engine.build(None, **build_args)
        engine, labels = record_engine.build(labels, **build_args)
    finally:
        layout.PAT_VRAM = old_vram

    if len(pass1) != len(engine):
        raise SystemExit("2-pass 크기가 다르다 -- 라벨이 안정화되지 않았다")

    print(f"generic(blank_frame=True) 렌더러 {len(engine)} B")

    image = bytearray(engine)
    rp = labels["record_ptr"] - base.ENGINE_LO
    image[rp:rp + 3] = first_ptr.to_bytes(3, "little")

    # ★ 2026-09-04 실기에서 잡힘: ready 를 1 로 구워 둔다.
    #
    # entry 는 `LDA ready / BNE ...` 라 **ready == 0 이 "새 레코드를 그려라"** 다
    # (다 그리면 스스로 `LDA #$01 / STA ready` 로 잠근다).  record_engine 이
    # 구워 내는 기본값은 0 이므로, 그대로 두면 렌더러가 **무장되자마자** 위에서
    # 심은 표 #1 을 그려 버린다.  스케줄러는 첫 구간을 미리 안 심는 설계라
    # (native_arm: "첫 자막이 프레임 2189 라 그전에는 화면이 비어 있어야 한다")
    # 이 한 바이트가 그 설계를 깨고 있었다 -- 실기에서 면책 화면에 모스크바
    # 자막이 떴다.
    #
    # 스케줄러는 구간이 되면 `STZ ready` 로 내려 준다.
    #
    # ★ 2026-09-04 저녁 정정: 1 이 아니라 **$FF** 다.
    #
    #   1 은 "그릴 건 없다, push 만 해라" 라서 그리기는 막았지만 **push 는 못
    #   막았다.**  구워진 count 가 0 인데 게임의 $6463 은 do-while 이라 0 이
    #   256 으로 돌고, 목록 끝을 넘어가 엔진 코드와 그 뒤 RAM 을 스프라이트로
    #   읽는다 -- 실기에서 자막 자리도 아닌 곳에 판마다 다른 노이즈가 떴다.
    #
    #   $FF 는 idle_state=True 가 만든 세 번째 상태다 (BMI -> RTS).
    #   첫 구간이 올 때까지 아무것도 안 밀고 조용히 나간다.
    image[labels["ready"] - base.ENGINE_LO] = 0xFF

    # ★ build_entry(14 B) 를 안 심는다 -- 표준 entry(ready 체크 + blank_frame)가
    #   그대로 남는다.  entry~rebuild 사이가 얼마나 되는지만 참고로 찍는다.
    entry_at = labels["entry"] - base.ENGINE_LO
    rebuild_at = labels["rebuild"] - base.ENGINE_LO
    print(f"entry +{entry_at} .. rebuild +{rebuild_at}  ({rebuild_at - entry_at} B, 표준 entry 유지)")

    if len(image) > SAFE_BYTES:
        raise SystemExit(f"렌더러가 슬롯을 넘는다: {len(image)} / {SAFE_BYTES}")

    # ★ 매체 지문 꼬리를 붙인다 (위 MEDIA_MAGIC_AT 주석 참고).
    code_bytes = len(image)
    if code_bytes > MEDIA_MAGIC_AT:
        raise SystemExit(f"렌더러가 지문 자리를 침범한다: "
                         f"{code_bytes} B > +{MEDIA_MAGIC_AT}")
    image += bytes((0xFF,)) * (IMAGE_BYTES - len(image))
    image[MEDIA_MAGIC_AT] = MEDIA_MAGIC
    if len(image) > SAFE_BYTES:
        raise SystemExit(f"지문 포함 이미지가 슬롯을 넘는다: {len(image)} / {SAFE_BYTES}")
    print(f"코드 {code_bytes} B + FF 패딩 -> 이미지 {len(image)} B  "
          f"(매체 지문 +{MEDIA_MAGIC_AT} = ${MEDIA_MAGIC:02X})")

    print(f"\n라벨 (스케줄러 연동에 필요한 것)")
    for name in ("entry", "ready", "record_ptr", "count", "list",
                 "stage", "vram_base_hi_imm", "pattern_base_lo_imm",
                 "pattern_attr_imm", "blank"):
        off = labels.get(name)
        if off is None:
            print(f"   {name:22s} (라벨 없음)")
        else:
            print(f"   {name:22s} +{off - base.ENGINE_LO}")

    if args.write:
        OUT.write_bytes(bytes(image))
        info = {
            "purpose": "Track 17 39-segment scheduled CD-DA renderer (no self timer)",
            "engine_bytes": len(image),
            "code_bytes": code_bytes,
            "media_magic_offset": MEDIA_MAGIC_AT,
            "media_magic": MEDIA_MAGIC,
            "safe_limit": SAFE_BYTES,
            "blank_frame": True,
            "expire_frames": True,
            "record_ptr_initial": f"{first_ptr:06X}",
            "vram_base_initial": first["vram_base"],
            "segment_count": len(rows),
            "pack_sha256": hashlib.sha256(blob).hexdigest().upper(),
            "engine_sha256": hashlib.sha256(bytes(image)).hexdigest().upper(),
            "labels": {k: v - base.ENGINE_LO for k, v in sorted(labels.items())},
        }
        INFO.write_text(json.dumps(info, ensure_ascii=False, indent=2) + "\n",
                        encoding="utf-8")
        print(f"\n-> {OUT}")
        print(f"-> {INFO}")
    else:
        print("\n(보고만 했다.  저장하려면 --write)")


if __name__ == "__main__":
    main()
