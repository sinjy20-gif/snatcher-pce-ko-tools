#!/usr/bin/env python3
"""0.4.6.40: frozen ADPCM native 세트를 Track24에서 선적재하는 무Lua D000 POC."""
from __future__ import annotations

import hashlib
import json
from pathlib import Path
import shutil
import sys

ROOT = Path(__file__).resolve().parents[1]
sys.path[:0] = [str(ROOT / "tools"), str(ROOT / "extraction" / "patch" / "static")]

import build_snatcher_0_4_6_11 as release  # noqa: E402
import build_snatcher_0_4_6_29_native_arm as native  # noqa: E402
import build_disc_subtitle_hook as rawdisc  # noqa: E402
import build_track24_loader_proof as track24raw  # noqa: E402

VERSION = "0.4.6.40"
BUILD_ID = 40
OUT = ROOT / "build" / "patch" / VERSION
BIOS_NAME = f"Syscard3_galmuri_{VERSION}.pce"
BUILD = ROOT / "build" / "cutscene_subs"

PACK = BUILD / "subtitle_pack.frozen_8F20AF38.bin"
ENGINE = BUILD / "engine_ac_lua_frame_rearm_frozen_8F20AF38_6600.bin"
ENGINE_INFO = BUILD / "engine_ac_lua_frame_rearm_frozen_8F20AF38_6600.json"
DIR = BUILD / "adpcm_native_subtitle_dir_frozen_8F20AF38.bin"
PAYLOAD = BUILD / "adpcm_native_subtitle_payload_frozen_8F20AF38.bin"
MASTER = BUILD / "adpcm_lba_master_index.bin"
HELPER = BUILD / "subtitle_vram_helper.bin"
BUNDLE = BUILD / "adpcm_native_frozen_8F20AF38.bundle.bin"

AC_DIR = 0x1F2800
# payload 는 디렉터리 **바로 뒤**여야 한다.  디렉터리 항목 안의 포인터가
# `AC_DIR + 항목수*6` 으로 계산돼 박히기 때문이다
# (build_adpcm_native_subtitle_table.py 의 payload_base).
#
# 예전에는 이 자리를 902 개 기준인 0x1F3D24 로 못박아 뒀다.  그래서 음성이
# 903 개가 되는 순간 6 B 가 어긋나 "integrated bundle overlap" 으로 빌드가
# 통째로 섰다 (2026-09-01).  이제는 세지 않고 **재어서** 쓴다.
# 주소는 armer 가 정한다.  전에는 두 파일에 따로 적어 두었는데, 자리를 옮기며
# preload 만 고치고 armer 를 안 고쳐서 **자막이 한 줄도 안 나왔다** (2026-09-01):
# 엔진 원본을 새 자리에 써 놓고, 음성마다 그것을 슬롯으로 복사하는 armer 는
# 옛 자리(0xFF 채움)를 읽어 렌더러를 지웠다.  이제 한 곳에서만 정한다.
AC_MASTER, AC_TEMPLATE = native.AC_MASTER, native.AC_ENGINE_TEMPLATE


def ac_payload() -> int:
    """지금 디렉터리 크기에 맞는 payload 시작 주소."""
    return AC_DIR + DIR.stat().st_size
TRACK02_NAME = "Snatcher CD-ROMantic (Japan) (Track 02) [KO].bin"
TRACK24_NAME = "Snatcher CD-ROMantic (Japan) (Track 24) [KO].bin"
RAW, USER = 2352, 2048
TRACK24_FILE_LBA, TRACK24_INDEX1_LBA = 234924, 235149


def sha(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest().upper()


def make_bundle() -> bytes:
    rows = [
        (AC_DIR, DIR.read_bytes()),
        (ac_payload(), PAYLOAD.read_bytes()),
        (AC_TEMPLATE, ENGINE.read_bytes()),
    ]
    # LBA master는 subtitle_pack preload 행의 $1E0000 뒷부분에 싣힌다.
    # loader 행을 하나 더 늘리지 않고, 커진 native 본문과도 겹치지 않는다.
    end = max(at + len(blob) for at, blob in rows)
    out = bytearray((0xFF,)) * (end - AC_DIR)
    occupied: list[tuple[int, int]] = []
    for at, blob in rows:
        lo, hi = at - AC_DIR, at - AC_DIR + len(blob)
        if any(lo < old_hi and hi > old_lo for old_lo, old_hi in occupied):
            raise SystemExit(f"native bundle overlap at ${at:06X}")
        out[lo:hi] = blob
        occupied.append((lo, hi))
    BUNDLE.write_bytes(out)
    return bytes(out)


def payload_file_sector(preload: dict, row: dict) -> int:
    first = min(int(item["relative_sector"]) for item in preload["rows"])
    return int(preload["track24_base_bytes"]) // RAW + int(row["relative_sector"]) - first


# 자막 체인이 물려받는 디스크.  Track02(대사 번역)와 Track24 의 선적재가 여기서 온다.
#
# 2026-09-01: 상수로 뺐다.  전에는 함수 안에 `0.4.6.22-dictionary-key-vram` 이
# 박혀 있어서 **대사 번역이 08-30 에 멈춰 있었다.**  자막을 아무리 새로 구워도
# 대사는 그 시점 것이 나갔고, 두 파이프라인이 한 장에 못 들어가는 원인이었다.
# 같은 계보의 최신판을 넘기면 대사와 자막이 한 디스크에 함께 실린다.
BASELINE = ROOT / "build" / "patch" / "0.4.6.22-dictionary-key-vram"


def stage_from_baseline(bundle: bytes) -> tuple[dict, int]:
    baseline = BASELINE
    if not baseline.exists():
        raise SystemExit(f"기준판이 없다: {baseline}")
    shutil.copytree(baseline, OUT)
    preload_path = OUT / "bios_preload.json"
    preload = json.loads(preload_path.read_text(encoding="utf-8"))

    # Track24 끝에 native bundle을 표준 Mode1/2352 섹터로 추가한다.
    track24_path = OUT / TRACK24_NAME
    track24 = bytearray(track24_path.read_bytes())
    if len(track24) % RAW:
        raise SystemExit("Track24 is not raw-sector aligned")
    first_abs = TRACK24_FILE_LBA + len(track24) // RAW
    relative = first_abs - TRACK24_INDEX1_LBA
    padded = bundle + bytes((0xFF,)) * (-len(bundle) % USER)
    appended = bytearray()
    for i in range(0, len(padded), USER):
        lba = first_abs + i // USER
        sector = track24raw.make_mode1_sector(lba, padded[i:i + USER])
        track24raw.verify_mode1_sector(sector, lba)
        appended += sector
    track24 += appended

    # 기존 renderer 한 섹터를 frozen/$6600 653 B 이미지로 교체한다.
    by_name = {row["name"]: row for row in preload["rows"]}
    renderer_row = by_name["subtitle_renderer"]
    renderer_sector = payload_file_sector(preload, renderer_row)
    at = renderer_sector * RAW + 16
    old = bytes(track24[at:at + 3])
    if old != b"SUB":
        raise SystemExit("baseline renderer has no SUB magic")
    engine = ENGINE.read_bytes()
    track24[at:at + USER] = engine + bytes((0xFF,)) * (USER - len(engine))
    raw_at = renderer_sector * RAW
    sec = bytearray(track24[raw_at:raw_at + RAW])
    rawdisc.rebuild_mode1_sector(sec)
    track24[raw_at:raw_at + RAW] = sec
    track24_path.write_bytes(track24)
    renderer_row["bytes"] = len(engine)

    full, rem = divmod(len(bundle), 0x2000)
    row = {
        "name": "adpcm_native_bundle", "relative_sector": relative,
        "absolute_lba": first_abs, "bytes": len(bundle),
        "sectors": len(padded) // USER, "full_chunks": full,
        "final_sectors": (rem + USER - 1) // USER,
        "destination": AC_DIR,
    }
    rows = list(preload["rows"]) + [row]

    # 5행 loader를 다시 어셈블한다. loop형이라 bank0 $FEC4-$FFD3에 들어간다.
    loader = release.build_loader(rows)
    if len(loader) > 0xFFD4 - 0xFEC4:
        raise SystemExit(f"5-row BIOS loader overflow: {len(loader)}/272")
    old_bioses = list(OUT.glob("*.pce"))
    if len(old_bioses) != 1:
        raise SystemExit("baseline must contain exactly one BIOS")
    image = bytearray(old_bioses[0].read_bytes())
    lo, hi = 0xFEC4 - 0xE000, 0xFFD4 - 0xE000
    image[lo:hi] = loader + bytes((0xFF,)) * (hi - lo - len(loader))
    boot_hook = release.base.BOOT_HOOK
    image[0xE009 - 0xE000:0xE00C - 0xE000] = bytes(
        (0x4C, boot_hook & 0xFF, boot_hook >> 8))
    bios = OUT / BIOS_NAME
    bios.write_bytes(image)
    old_bioses[0].unlink()

    preload["rows"] = rows
    preload["code_bytes"] = len(loader)
    preload["boot_hook"] = f"{boot_hook:04X}"
    preload["raw_payload_bytes"] = int(preload["raw_payload_bytes"]) + len(appended)
    preload["user_payload_bytes"] = int(preload["user_payload_bytes"]) + len(padded)
    preload_path.write_text(json.dumps(preload, ensure_ascii=False, indent=2), encoding="utf-8")
    return preload, renderer_sector


def patch_native_bios() -> tuple[int, str]:
    master = MASTER.read_bytes()
    directory = DIR.read_bytes()
    eng = json.loads(ENGINE_INFO.read_text(encoding="utf-8"))
    dir_count = len(directory) // 9      # 항목 9 B (LBA 3 + ptr 3 + VRAM 3)
    selector_ac = native.AC_ENGINE + eng["offsets"]["selector"]
    off = eng["offsets"]
    native.base.BUILD_ID = BUILD_ID
    emitter = native.make_armer(dir_count, selector_ac, eng["engine_bytes"],
        0x5B80 + off["ready"], 0x5B80 + off["selector"],
        0x5B80 + off["stage"], off["stage"], eng["stage_routine_bytes"],
        # 음성마다 VRAM 자리를 갈아 끼우게 한다 -- 이것이 없으면 armer 가
        # 검증된 D000 한 키만 연다 (2026-09-02).
        imm_offsets=(off["vram_base_hi_imm"], off["pattern_base_lo_imm"],
                     off["pattern_attr_imm"]),
        adpcm_initial_delay=eng.get("initial_delay", False))
    first, labels = native.base.build_dispatcher(
        native.base.BANK1_FREE_LO, native.AC_MASTER, len(master) // 9,
        extra_return=native.FEC4_RET, extra_builder=emitter)
    code, labels = native.base.build_dispatcher(
        native.base.BANK1_FREE_LO, native.AC_MASTER, len(master) // 9, labels,
        extra_return=native.FEC4_RET, extra_builder=emitter)
    if len(first) != len(code):
        raise SystemExit("native dispatcher 2-pass mismatch")

    bios = OUT / BIOS_NAME
    temp = OUT / (BIOS_NAME + ".tmp")
    native.base.patch_image(bios, temp, code)
    image = bytearray(temp.read_bytes())
    temp.unlink()
    at = native.FEC4 - 0xE000
    if bytes(image[at:at + 3]) != native.FEC4_ORIG:
        raise SystemExit("FEC4 baseline mismatch after native patch")
    image[at:at + 3] = bytes((0x20, 0xD4, 0xFF))
    bios.write_bytes(image)
    return len(code), sha(bytes(image))


def main() -> None:
    if OUT.exists():
        raise SystemExit(f"output already exists: {OUT}")
    bundle = make_bundle()
    preload, renderer_sector = stage_from_baseline(bundle)
    code_bytes, bios_hash = patch_native_bios()

    preload_path = OUT / "bios_preload.json"
    preload.update({"version": VERSION, "revision": VERSION,
                    "bios_sha256": bios_hash, "sha256": bios_hash.lower()})
    preload_path.write_text(json.dumps(preload, ensure_ascii=False, indent=2), encoding="utf-8")

    manifest_path = OUT / "manifest.json"
    manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
    track02 = (OUT / TRACK02_NAME).read_bytes()
    track24 = (OUT / "Snatcher CD-ROMantic (Japan) (Track 24) [KO].bin").read_bytes()
    manifest.update({
        "version": VERSION,
        "purpose": "Lua-free frozen D000 native 3-fragment preload POC",
        "frozen_pack_sha256": sha(PACK.read_bytes()),
        "native_bundle_bytes": len(bundle),
        "native_bundle_sha256": sha(bundle),
        "native_dispatcher_bytes": code_bytes,
        "track24_renderer_sector": renderer_sector,
        "bios_sha256": bios_hash,
        "track02_sha256": sha(track02),
        "track24_sha256": sha(track24),
        "lua_required": False,
    })
    manifest_path.write_text(json.dumps(manifest, ensure_ascii=False, indent=2), encoding="utf-8")
    (OUT / "TEST_IN_MESEN.txt").write_text(
        f"{VERSION}\n\nPower Cycle. Select {BIOS_NAME}, open the [KO] CUE.\n"
        "Do not load any Lua. Play to ADPCM LBA $003083 (Mika D000).\n"
        "Expected: all three frozen-baseline subtitle fragments at 0/90/180 frames.\n",
        encoding="utf-8")
    print(f"{VERSION} Lua-free preload complete")
    print(f"  native bundle {len(bundle):,} B @ ${AC_DIR:06X}")
    print(f"  dispatcher {code_bytes} B · renderer sector {renderer_sector}")
    print(f"  BIOS {bios_hash}")
    print(OUT / "Snatcher CD-ROMantic (Japan) [KO].cue")


if __name__ == "__main__":
    main()
