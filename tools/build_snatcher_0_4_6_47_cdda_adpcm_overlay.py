#!/usr/bin/env python3
"""0.4.6.47: 검증된 $5B80 시간제 overlay 계약으로 CD-DA/ADPCM을 통합한다.

0.4.6.25처럼 FEC4 판정을 한 경로에서 완결한다. bank1 판정 뒤 FEC7의 ADPCM
legacy decision을 다시 실행하지 않는다. resident와 state 0/1/2/3 의미는 0.4.6.42
그대로이며, CPU 선복사 없이 resident의 helper -> renderer 순서를 사용한다.
"""
from __future__ import annotations

import hashlib
import json

import build_snatcher_0_4_6_43_cdda_adpcm as build
import build_subtitle_engine_cdda_state3_poc as cdda_state3

VERSION = "0.4.6.47"
BUILD_ID = 47
FEC4 = 0xFEC4
DIRECT_RETURN = 0xFEC7
DIRECT_TAIL = bytes((0x60,))
FROZEN_CDDA_ENGINE = build.BUILD / "engine_cdda_state3_frozen_8F20AF38.bin"
FROZEN_CDDA_INFO = build.BUILD / "engine_cdda_state3_frozen_8F20AF38.json"
BASELINE_42 = build.ROOT / "build" / "patch" / "0.4.6.42"


def sha(blob: bytes) -> str:
    return hashlib.sha256(blob).hexdigest().upper()


def patch_direct_return() -> dict[str, str]:
    """JSR bank bridge 뒤 legacy FEC7로 흘리지 않고 resident 호출자에 RTS한다."""
    bios = build.OUT / build.BIOS_NAME
    image = bytearray(bios.read_bytes())
    at = FEC4 - 0xE000
    want = bytes((0x20, 0xD4, 0xFF))
    if bytes(image[at:at + 3]) != want:
        raise SystemExit(f"FEC4 bridge drifted: {image[at:at+3].hex(' ')}")
    legacy = bytes((0xC9, 0xFF, 0xF0))
    old = bytes(image[at + 3:at + 3 + len(DIRECT_TAIL)])
    if old != legacy[:len(DIRECT_TAIL)]:
        raise SystemExit(f"FEC7 legacy head drifted: {old.hex(' ')}")
    image[at + 3:at + 3 + len(DIRECT_TAIL)] = DIRECT_TAIL
    bios.write_bytes(image)
    digest = sha(bytes(image))

    preload_path = build.OUT / "bios_preload.json"
    preload = json.loads(preload_path.read_text(encoding="utf-8"))
    preload["bios_sha256"] = digest
    preload["sha256"] = digest.lower()
    preload["native_overlay_decision"] = {
        "entry": "FEC4", "bridge": "JSR FFD4",
        "direct_return": "FEC7 " + DIRECT_TAIL.hex(" ").upper(),
        "legacy_fallthrough": False, "cpu_precopy": False,
        "resident_contract": "copy helper -> helper ENTRY -> copy selected renderer",
    }
    preload_path.write_text(
        json.dumps(preload, ensure_ascii=False, indent=2), encoding="utf-8")
    return {"bios_sha256": digest, "fec7_old": old.hex(" ").upper(),
            "fec7_new": DIRECT_TAIL.hex(" ").upper()}


def build_frozen_cdda_engine() -> None:
    """현재 작업팩이 아니라 0.4.6.42의 고정 8F20 팩으로 CD-DA 엔진을 재현한다."""
    cdda_state3.t17.PACK = build.preload.PACK
    cdda_state3.OUT = FROZEN_CDDA_ENGINE
    cdda_state3.INFO = FROZEN_CDDA_INFO
    cdda_state3.main()
    info = json.loads(FROZEN_CDDA_INFO.read_text(encoding="utf-8"))
    if info["pack_sha256"] != sha(build.preload.PACK.read_bytes()):
        raise SystemExit("frozen CD-DA engine was not built from the 8F20 pack")


def audit_overlay() -> dict[str, object]:
    """성공판의 resident와 시간제 overlay 계약을 최종 산출물에서 증명한다."""
    track_name = build.preload.TRACK02_NAME
    track42 = (BASELINE_42 / track_name).read_bytes()
    track47 = (build.OUT / track_name).read_bytes()
    if track47 != track42:
        raise SystemExit("0.4.6.47 Track02 resident drifted from 0.4.6.42")

    dispatcher = (build.BUILD / "cdda17_adpcm_d000_dispatcher.bin").read_bytes()
    forbidden = []
    for size in (653, 671):
        # TAI $1A00,$5B80,#size -- state 발행 전 CPU renderer 선복사 금지.
        sig = bytes((0xF3, 0x00, 0x1A, 0x80, 0x5B, size & 0xFF, size >> 8))
        if sig in dispatcher:
            forbidden.append(size)
    if forbidden:
        raise SystemExit(f"CPU renderer pre-copy remains in dispatcher: {forbidden}")

    bios = next(build.OUT.glob("*.pce")).read_bytes()
    direct = bytes((0x20, 0xD4, 0xFF)) + DIRECT_TAIL
    if bios[FEC4 - 0xE000:FEC4 - 0xE000 + len(direct)] != direct:
        raise SystemExit("FEC4 direct-return bytes drifted")
    return {
        "track02_equals_0_4_6_42": True,
        "track02_sha256": sha(track47),
        "cpu_precopy_signatures_absent": True,
        "fec4_bytes": direct.hex(" ").upper(),
        "frozen_cdda_pack_sha256": sha(build.preload.PACK.read_bytes()),
        "frozen_cdda_engine_sha256": sha(FROZEN_CDDA_ENGINE.read_bytes()),
    }


def main() -> None:
    build_frozen_cdda_engine()
    build.VERSION = VERSION
    build.BUILD_ID = BUILD_ID
    build.OUT = build.ROOT / "build" / "patch" / VERSION
    build.BIOS_NAME = f"Syscard3_galmuri_{VERSION}.pce"
    build.CDDA_ACTIVE_SENTINEL = None
    build.ACTIVE_RETURN = None
    build.ACTIVE_BUILDER = None
    build.PRECOPY_CPU = False
    build.COMPLETE_DECISION = True
    build.CDDA_ENGINE = FROZEN_CDDA_ENGINE
    build.CDDA_INFO = FROZEN_CDDA_INFO
    build.main()

    direct = patch_direct_return()
    audit = audit_overlay()
    manifest_path = build.OUT / "manifest.json"
    manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
    manifest.update({
        "bios": build.BIOS_NAME,
        "bios_sha256": direct["bios_sha256"],
        "bios_preload": json.loads(
            (build.OUT / "bios_preload.json").read_text(encoding="utf-8")),
        "purpose": "single-owner $5B80 overlay: CD-DA and ADPCM complete FEC4 decision",
        "resident_modified": False,
        "state_contract_modified": False,
        "cpu_engine_precopy": False,
        "legacy_fec7_fallthrough": False,
        "direct_return_patch": direct,
        "overlay_static_audit": audit,
    })
    manifest_path.write_text(
        json.dumps(manifest, ensure_ascii=False, indent=2), encoding="utf-8")

    test = build.OUT / "TEST_IN_MESEN.txt"
    test.write_text(test.read_text(encoding="utf-8") +
        "\n0.4.6.47 overlay contract:\n"
        "  FEC4 bank1 decision returns through FEC7 RTS; legacy decision is not run twice.\n"
        "  No active renderer is pre-copied to CPU $5B80.\n"
        "  The byte-identical 0.4.6.42 resident leases $5B80 through helper -> renderer.\n"
        "  CD-DA renderer owns its state3 end; ADPCM keeps $180D bit20 -> state3.\n"
        # ★시각을 여기 또 적지 않는다.  PASS A 가 위에서 마스터를 읽어 찍으므로
        #   여기 박아 두면 두 숫자가 갈라져 어느 쪽이 맞는지 알 수 없게 된다.
        "  PASS order: clean ACT1, CD-DA per PASS A above, D000 1/2/3 + UI restore.\n",
        encoding="utf-8")
    print(f"{VERSION} single-owner overlay candidate")
    print("  FEC4 JSR $FFD4 / tail " + DIRECT_TAIL.hex(" ").upper() +
          " · no legacy fall-through · no CPU pre-copy")
    print(f"  BIOS {direct['bios_sha256']}")


if __name__ == "__main__":
    main()
