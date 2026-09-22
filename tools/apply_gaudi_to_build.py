#!/usr/bin/env python3
"""가우디 한글 키패드를 이미 구운 판에 **제자리로** 얹는다.

`build_gaudi_gibson_hook_test.py` 는 0.7.11 을 원본으로 새 시험 폴더를 만드는
구조라 출하 판에는 못 쓴다.  여기서는 같은 조각을 같은 순서로, 판 폴더 안에서
직접 적용한다.

    1. BIOS 글리프  45 개 가나 코드의 글리프를 한글 음절로 바꾼다 (위 입력창)
    2. Track 02 훅  `$B9E0` 검색 비교 입구에서 `깁슨` -> `ギブスン` 으로 되돌린다
    3. 자판 그림    타일 블록·타일맵 제자리 치환은 별도 도구가 한다
                    (`patch_gaudi_keypad_native.py`)

⚠ 2 번은 `HOOK_ORIGINAL` 바이트를 먼저 대조한다.  기준판이 다르면 거기서 멈춘다.
⚠ 매니페스트의 `route_c.sectors_touched` 는 **덮지 않고 더한다** --
  `check_build_invariants.py` 가 그 값으로 오버레이 섹터 변경을 판정한다.

    python tools/apply_gaudi_to_build.py 0.7.12
"""
from __future__ import annotations

import argparse
import json
import shutil
import sys
from datetime import datetime
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path[:0] = [str(ROOT / "tools"), str(ROOT / "extraction" / "patch" / "static")]

import build_gaudi_gibson_hook_test as hook                    # noqa: E402
import build_gaudi_keypad_test as keypad                       # noqa: E402

TRACK02 = "Snatcher CD-ROMantic (Japan) (Track 02) [KO].bin"


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("version")
    args = ap.parse_args()

    folder = ROOT / "build" / "patch" / args.version
    track = folder / TRACK02
    bios = folder / f"Syscard3_galmuri_{args.version}.pce"
    manifest_path = folder / "manifest.json"
    for p in (track, bios, manifest_path):
        if not p.is_file():
            sys.exit(f"없다: {p}")

    stamp = datetime.now().strftime("%Y%m%d_%H%M%S")
    for p in (track, bios):
        backup = p.with_suffix(p.suffix + f".bak_gaudi_{stamp}")
        shutil.copy2(p, backup)
        print(f"  보관 {backup.name}")

    # 1. BIOS 글리프 -- 가나 코드는 그대로 두고 보이는 글자만 한글로
    tmp_bios = bios.with_suffix(bios.suffix + ".tmp")
    bios_info = keypad.patch_bios(bios, tmp_bios)
    tmp_bios.replace(bios)
    print(f"  BIOS 글리프 {len(keypad.SYLLABLES)} 자  SHA {bios_info['sha256'][:16]}")

    # 2. Track 02 검색 훅
    tmp_track = track.with_suffix(track.suffix + ".tmp")
    track_info = hook.patch_track(track, tmp_track)
    tmp_track.replace(track)
    print(f"  검색 훅  ${hook.HOOK_CPU:04X} -> ${hook.CAVE_CPU:04X} · 동굴 "
          f"{track_info['cave_size']} B · 섹터 {track_info['sectors']}")

    manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
    route_c = dict(manifest.get("route_c", {}))
    route_c["sectors_touched"] = sorted(set(route_c.get("sectors_touched", []))
                                        | set(track_info["sectors"]))
    manifest.update({
        "route_c": route_c,
        "bios_sha256": bios_info["sha256"],
        "track02_sha256": track_info["sha256"],
        "gaudi_keypad": {
            "bios_glyphs": len(keypad.SYLLABLES),
            "search_hook": {"cpu": f"{hook.HOOK_CPU:04X}", "cave": f"{hook.CAVE_CPU:04X}",
                            "mapping": track_info["mapping"]},
        },
    })
    manifest_path.write_text(json.dumps(manifest, ensure_ascii=False, indent=2) + "\n",
                             encoding="utf-8")
    print("  매니페스트 갱신 (route_c 섹터 누적)")
    print("\n다음: python tools/patch_gaudi_keypad_native.py " + args.version + " --write")


if __name__ == "__main__":
    main()
