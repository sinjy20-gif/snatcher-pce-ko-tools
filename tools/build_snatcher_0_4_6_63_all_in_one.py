#!/usr/bin/env python3
"""0.4.6.63: **최신 대사 + 최신 자막 + 671 B 처방**을 한 장에 굽는다.

왜 지금까지 한 장이 아니었나
----------------------------
자막 체인은 기준판 디스크를 통째로 복사한 뒤 그 위에 자막만 얹는다.  그런데 그
기준판이 함수 안에 **`0.4.6.22-dictionary-key-vram` 으로 박혀 있었다** (08-30 마스터).

```
.48 / .62   자막은 최신인데 Track02(대사)가 08-30 에 멈춰 있다
.61         대사는 최신인데 자막 팩이 옛것이고 671 B 처방도 없다
```

`0.4.6.61-dictionary-key-vram` 이 그 기준판의 최신판이므로, 기준판만 갈아끼우면
대사와 자막이 한 디스크에 같이 실린다 (`build_snatcher_0_4_6_40_native_preload.BASELINE`).

Track02 가 안 부딪히는 근거 (2026-09-01 실측)
---------------------------------------------
`.48` 과 `.61-dictionary-key-vram` 의 Track02 는 34,345 섹터 중 **2 개만** 다르다.

```
섹터 250   4 구간 (마지막이 128 B)
섹터 254   2 바이트뿐 -- user +051E · +0523
           A9 96 8D E2 BF / A9 03 8D E3 BF  = 번역 페이로드 주소·길이
자막 상주부 자리 (user +04D2 부근)   양쪽 완전히 동일
```

즉 대사 빌드는 **번역 페이로드를 가리키는 포인터만** 바꾸고 자막 상주부는 손대지
않는다.  그래서 `.47` 의 "Track02 는 0.4.6.42 와 바이트 동일" 감사는 새 기준판을
기준으로 다시 걸면 된다 -- 감사의 뜻은 "상주부가 우리가 시작한 디스크에서 안
흔들렸는가" 이지 "영원히 .42 여야 한다" 가 아니다.

전제
----
```
python tools/build_subtitle_set.py [--reviewed-only]      팩 + 파생물 (태그가 찍힌다)
python tools/build_snatcher_0_4_6_61_dictionary_key_vram.py   최신 마스터 -> 기준판
```

쓰는 법
-------
```
python tools/build_snatcher_0_4_6_63_all_in_one.py --tag <TAG>
python tools/patch_track24_subtitle_pack.py 0.4.6.63 --write
python tools/patch_bios_cpu_cache.py 0.4.6.63 --write
```
"""
from __future__ import annotations

import argparse
import hashlib
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
BUILD = ROOT / "build" / "cutscene_subs"
sys.path.insert(0, str(ROOT / "tools"))

import build_snatcher_0_4_6_47_cdda_adpcm_overlay as build  # noqa: E402

VERSION = "0.4.6.63"
DEFAULT_BASELINE = "0.4.6.61-dictionary-key-vram"


def sha8(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()[:8].upper()


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--tag", help="build_subtitle_set.py 가 찍어준 태그")
    ap.add_argument("--baseline", default=DEFAULT_BASELINE,
                    help="대사 번역이 들어 있는 기준판 폴더 이름")
    ap.add_argument("--version", default=VERSION)
    ap.add_argument("--adpcm-reuse", action="store_true",
                    help="같은 ADPCM 활성 슬롯이면 671 B 재복사를 생략")
    args, rest = ap.parse_known_args()
    sys.argv = [sys.argv[0], *rest]

    pack = BUILD / "subtitle_pack.bin"
    if not pack.exists():
        raise SystemExit("팩이 없다.  python tools/build_subtitle_set.py 먼저")
    tag = sha8(pack)
    if args.tag and args.tag.upper() != tag:
        raise SystemExit(f"태그 불일치: 준 것 {args.tag} · 지금 팩 {tag}")

    need = {
        "DIR": BUILD / f"adpcm_native_subtitle_dir_{tag}.bin",
        "PAYLOAD": BUILD / f"adpcm_native_subtitle_payload_{tag}.bin",
        "ENGINE": BUILD / f"engine_ac_lua_frame_rearm_{tag}_6600.bin",
    }
    missing = [p.name for p in need.values() if not p.exists()]
    if missing:
        raise SystemExit("이 팩의 파생물이 없다: " + ", ".join(missing) +
                         "\n  python tools/build_subtitle_set.py 를 먼저")

    baseline = ROOT / "build" / "patch" / args.baseline
    if not baseline.exists():
        raise SystemExit(f"기준판이 없다: {baseline}\n"
                         "  python tools/build_snatcher_0_4_6_61_dictionary_key_vram.py 먼저")

    preload = build.build.preload
    preload.BASELINE = baseline               # ★ 대사 번역을 물려받는다
    preload.PACK = pack
    preload.DIR = need["DIR"]
    preload.PAYLOAD = need["PAYLOAD"]
    preload.ENGINE = need["ENGINE"]
    info = BUILD / f"engine_ac_lua_frame_rearm_{tag}_6600.json"
    if info.exists():
        preload.ENGINE_INFO = info
    preload.BUNDLE = BUILD / f"adpcm_native_{tag}.bundle.bin"

    build.FROZEN_CDDA_ENGINE = BUILD / f"engine_cdda_state3_{tag}.bin"
    build.FROZEN_CDDA_INFO = BUILD / f"engine_cdda_state3_{tag}.json"
    build.BASELINE_42 = baseline              # Track02 감사도 같은 기준판으로
    build.VERSION = args.version
    build.BUILD_ID = 63
    build.DIRECT_TAIL = bytes((0xC9, 0x00, 0x60))
    if args.adpcm_reuse:
        # ★★ 2026-09-17 개편 -- 자리를 **유도한다** (하드코딩 금지)
        #
        #   옛 판은 `666` 이 박혀 있었다.  "현재 ADPCM 엔진은 666 B" 라는 그때의
        #   사실에 기댄 값이라 엔진 크기가 바뀌면 조용히 어긋난다.
        #   (출하 엔진은 지금 **653 B** 다 -- frozen 파일이 기준이고,
        #    팩태그 json(669 B)이 아니다.  측정 도구가 그걸 잘못 읽어 나를 두 번 속였다.)
        #
        #   슬롯 = max(ADPCM, CD-DA) = 671 B.  끝 두 바이트가 꼬리다:
        #       +670  media_magic ($CD) -- 임자 있다.  CPU $5E1E 로 실려 매체 판정
        #       +669  ★ 재사용 표식.  CPU $5E1D.  우리가 쓴다
        #
        #   표식을 **CPU 쪽에서** 읽으므로 1 B 면 된다 (LDA abs/CMP/BEQ = 7 B).
        #   AC 를 들여다보던 옛 판은 포인터 세팅만 ~24 B 라 +45 B 였고,
        #   뱅크1 여유 10 B 에 안 들어갔다.
        import json as _json
        _ad = _json.loads(build.build.preload.ENGINE_INFO.read_text(encoding="utf-8"))
        _cd = _json.loads((BUILD / "engine_cdda_scheduled_track17.json")
                          .read_text(encoding="utf-8"))
        _slot = max(_ad["engine_bytes"], _cd["engine_bytes"])
        if _cd["media_magic_offset"] != _slot - 1:
            raise SystemExit(
                f"media_magic 이 슬롯 끝이 아니다 ({_cd['media_magic_offset']} "
                f"vs {_slot - 1}) -- 표식 자리를 다시 따져야 한다")
        build.build.ADPCM_REUSE_SIGNATURE_OFFSET = _slot - 2
        build.build.ADPCM_REUSE_SIGNATURE = bytes.fromhex(tag[:2])

    print(f"기준판 {baseline.name}          <- 대사 번역")
    print(f"팩     {pack.name} {pack.stat().st_size:,} B  태그 {tag}")
    print()
    build.main()
    print("\n이어서:")
    print(f"  python tools/patch_track24_subtitle_pack.py {args.version} --write")
    print(f"  python tools/patch_bios_cpu_cache.py {args.version} --write")


if __name__ == "__main__":
    main()
