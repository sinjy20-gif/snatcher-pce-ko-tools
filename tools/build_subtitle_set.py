#!/usr/bin/env python3
"""자막 한 벌을 **현재 스튜디오 표**로 굽는다 -- 팩 + 그 팩에서 나오는 것 전부.

왜 한 명령이어야 하나
---------------------
엔진과 색인이 **팩의 오프셋을 빌드 때 상수로 박는다**.  팩만 다시 굽고 나머지를
그대로 두면 자막이 **조용히 안 뜬다** (`build_subtitle_chain.py` 머리말의 2026-08-26
실측: 팩이 커지며 기록 시작이 3,359 B 밀렸는데 엔진은 옛 자리를 계속 봤다).

그리고 `0.4.6.4x` 체인은 기본이 **얼어붙은 팩** (`subtitle_pack.frozen_8F20AF38.bin`)
이다.  스튜디오에서 자막을 고쳐도 디스크에 안 들어간다 -- 2026-09-01 오전에 헬퍼가
Track 24 에 안 실려 하루를 태운 것과 같은 구멍이다.

그래서 이 도구는 팩을 굽고, **그 팩의 해시를 태그로 삼아** 파생물을 같이 굽는다.
태그가 곧 짝이 맞는다는 증거다.

    subtitle_pack.bin                              팩 (스튜디오 표에서)
    adpcm_native_subtitle_dir_<TAG>.bin            ADPCM 색인
    adpcm_native_subtitle_payload_<TAG>.bin        ADPCM 본문
    engine_ac_lua_frame_rearm_<TAG>_6600.bin       ADPCM 렌더러 ($6600)
    (CD-DA 엔진은 디스크 빌더가 팩에서 다시 굽는다)

쓰는 법
-------
    python tools/build_subtitle_set.py                   전체 (검토 O 무관)
    python tools/build_subtitle_set.py --reviewed-only   검토 O 만 싣는다
    python tools/build_subtitle_set.py --check           태그만 보고 안 굽는다

찍히는 태그를 디스크 빌더에 그대로 넘긴다.

    python tools/build_snatcher_0_4_6_62_live_subs.py --tag <TAG>

⚠ 스튜디오를 켜 둔 채로 돌리지 말 것 (docs/MERGE_CHECKLIST.md §1).
"""
from __future__ import annotations

import argparse
import hashlib
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
BUILD = ROOT / "build" / "cutscene_subs"
PACK = BUILD / "subtitle_pack.bin"
PY = sys.executable


def sha8(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()[:8].upper()


def run(script: str, *args: str) -> None:
    cmd = [PY, str(ROOT / "tools" / script), *args]
    print("  $ " + " ".join(cmd[1:]), flush=True)
    result = subprocess.run(cmd, cwd=ROOT)
    if result.returncode != 0:
        raise SystemExit(f"{script} 가 {result.returncode} 로 죽었다")


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--skip-keyless", action="store_true",
                    help="콘솔 키가 없는 음성은 자막을 빼고 굽는다 (기본은 빌드 중단)")
    ap.add_argument("--skip-oversize", action="store_true",
                    help="엔진 한도(19칸)를 넘는 자막은 빼고 굽는다 (기본은 빌드 중단)")
    ap.add_argument("--skip-collisions", action="store_true",
                    help="콘솔 키가 겹쳐 구분 안 되는 음성은 빼고 굽는다 (기본은 빌드 중단)")
    ap.add_argument("--reviewed-only", action="store_true",
                    help="검토 O 인 자막만 싣는다")
    ap.add_argument("--check", action="store_true",
                    help="지금 팩의 태그만 보고 아무것도 안 굽는다")
    args = ap.parse_args()

    if args.check:
        if not PACK.exists():
            raise SystemExit(f"팩이 없다: {PACK}")
        print(f"팩   {PACK.name}  {PACK.stat().st_size:,} B")
        print(f"태그 {sha8(PACK)}")
        return

    print("[1/3] 자막 팩")
    run("build_subtitle_pack.py",
        *(["--reviewed-only"] if args.reviewed_only else []),
        *(["--skip-keyless"] if args.skip_keyless else []),
        *(["--skip-oversize"] if args.skip_oversize else []),
        *(["--skip-collisions"] if args.skip_collisions else []))
    tag = sha8(PACK)
    print(f"\n  팩 {PACK.stat().st_size:,} B · 태그 {tag}\n")

    print("[2/3] ADPCM 색인/본문")
    run("build_adpcm_native_subtitle_table.py",
        "--pack", str(PACK), "--tag", tag)

    print("\n[3/3] ADPCM 렌더러 ($6600)")
    run("build_subtitle_engine_vdc_rearm.py",
        "--pack", str(PACK), "--pat-vram", "0x6600", "--tag", f"{tag}_6600")

    made = [
        BUILD / f"adpcm_native_subtitle_dir_{tag}.bin",
        BUILD / f"adpcm_native_subtitle_payload_{tag}.bin",
        BUILD / f"engine_ac_lua_frame_rearm_{tag}_6600.bin",
    ]
    print("\n=== 한 벌 완성 ===")
    print(f"  태그 {tag}   (팩 해시 앞 8 자리 -- 짝이 맞는다는 증거다)")
    missing = [p for p in made if not p.exists()]
    for p in made:
        mark = "" if p.exists() else "   ★ 안 만들어졌다"
        size = f"{p.stat().st_size:,} B" if p.exists() else "-"
        print(f"  {p.name:<52s} {size}{mark}")
    if missing:
        raise SystemExit("파생물이 빠졌다 -- 위 목록 확인")
    print("\n다음:")
    print(f"  python tools/build_snatcher_0_4_6_62_live_subs.py --tag {tag}")


if __name__ == "__main__":
    main()
