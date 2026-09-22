#!/usr/bin/env python3
"""CD-DA 전용 ROM 상주 렌더러를 만든다.

코드는 BIOS bank 1 `$FD1F`에, 가변 캐시는 스크립트 VM 스택 꼭대기
`$5CF3-$5E19`에 둔다.  기존 `engine_cdda_scheduled_track17`은 비교/되돌리기용
RAM 슬롯 이미지로 남겨 둔다.  이 도구는 그 파일을 바꾸지 않는다.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import struct
from pathlib import Path

import build_subtitle_engine as base
import build_subtitle_engine_ac_record_poc as record_engine
import build_subtitle_engine_cdda_scheduled as scheduled
import subtitle_layout as layout

ROOT = Path(__file__).resolve().parents[1]
BUILD = ROOT / "build" / "cutscene_subs"
PACK = BUILD / "subtitle_pack.bin"
OUT = BUILD / "engine_cdda_rom.bin"
DATA_OUT = BUILD / "engine_cdda_rom_data.bin"
INFO = BUILD / "engine_cdda_rom.json"

ROM_ORIGIN = 0xFD1F
ROM_LIMIT = 0xFFD9
DATA_ORIGIN = 0x5CF3
CDDA_STATE_CPU = 0x5E1A
TRACK_BCD_CPU = 0x5E1B
DATA_BYTES = 295


def _build_args(glyph_base: int) -> dict:
    return dict(glyph_base=glyph_base, lookup=False, timed=False,
                overlay_palette=True, vdc_rearm=True, blank_frame=True,
                idle_state=True, expire_frames=True,
                palette_each_push=True,
                rom_resident=True, origin=ROM_ORIGIN)


def _remap_data(labels: dict[str, int], code_bytes: int) -> dict[str, int]:
    """RAM 꼬리를 제외한 코드 라벨은 ROM에, 데이터 라벨은 $5CF3에 둔다."""
    data_at = ROM_ORIGIN + code_bytes
    mapped = dict(labels)
    for name, address in labels.items():
        if address < data_at:
            continue
        rel = address - data_at
        # track_bcd는 캐시 안에 두면 ADPCM arm 때 지워진다.  별도 상태 영역으로
        # 빼고, 그 뒤 데이터는 한 바이트 당겨 295 B로 만든다.
        if name == "track_bcd":
            mapped[name] = TRACK_BCD_CPU
        else:
            mapped[name] = DATA_ORIGIN + rel - (1 if rel > 8 else 0)
    return mapped


def build() -> tuple[bytes, bytes, dict[str, int], dict]:
    rows = scheduled.load_mini()
    first = rows[0]
    blob = PACK.read_bytes()
    if blob[:4] != b"SNSB" or struct.unpack_from("<H", blob, 4)[0] != 6:
        raise SystemExit("subtitle pack must be SNSB v6")
    glyph_off, = struct.unpack_from("<I", blob, 10)
    record_off, = struct.unpack_from("<I", blob, 26)
    first_ptr = layout.AC_PACK + record_off + int(first["rec_off"])

    old_vram = layout.PAT_VRAM
    try:
        layout.PAT_VRAM = int(first["vram_base"], 16)
        raw1, labels1 = record_engine.build(None, **_build_args(layout.AC_PACK + glyph_off))
        code_bytes = labels1["ready"] - ROM_ORIGIN
        labels = _remap_data(labels1, code_bytes)
        raw2, _labels2 = record_engine.build(labels, **_build_args(layout.AC_PACK + glyph_off))
    finally:
        layout.PAT_VRAM = old_vram

    if len(raw1) != len(raw2):
        raise SystemExit("ROM renderer two-pass 크기가 다르다")
    code = raw2[:code_bytes]
    raw_data = raw2[code_bytes:]
    # 원래 data block 안의 track_bcd(+8)를 상태 영역으로 빼 295 B 캐시로 만든다.
    data = raw_data[:8] + raw_data[9:]
    if len(data) != DATA_BYTES:
        raise SystemExit(f"ROM renderer data size {len(data)} != {DATA_BYTES}")
    if len(code) > ROM_LIMIT - ROM_ORIGIN + 1:
        raise SystemExit(f"ROM renderer {len(code)} B가 ${ROM_ORIGIN:04X}-${ROM_LIMIT:04X}를 넘는다")

    def data_offset(name: str) -> int:
        return labels[name] - DATA_ORIGIN

    data = bytearray(data)
    data[data_offset("record_ptr"):data_offset("record_ptr") + 3] = first_ptr.to_bytes(3, "little")
    data[data_offset("ready")] = 0xFF
    data[data_offset("blank")] = 0
    meta = {
        "code_bytes": len(code), "data_bytes": len(data),
        "rom_origin": f"{ROM_ORIGIN:04X}", "rom_end": f"{ROM_ORIGIN + len(code) - 1:04X}",
        "data_origin": f"{DATA_ORIGIN:04X}", "data_end": f"{DATA_ORIGIN + len(data) - 1:04X}",
        "cdda_state_cpu": f"{CDDA_STATE_CPU:04X}",
        "track_bcd_cpu": f"{TRACK_BCD_CPU:04X}",
        "entry": f"{labels['entry']:04X}", "record_ptr_initial": f"{first_ptr:06X}",
        "vram_base_initial": first["vram_base"], "segment_count": len(rows),
        "pack_sha256": hashlib.sha256(blob).hexdigest().upper(),
        "palette_each_push": True,
        "palette_before_rebuild": True,
        "palette_on_expire": True,
        "code_sha256": hashlib.sha256(code).hexdigest().upper(),
        "data_sha256": hashlib.sha256(data).hexdigest().upper(),
        "labels": {k: f"{v:04X}" for k, v in sorted(labels.items())},
    }
    return code, bytes(data), labels, meta


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--write", action="store_true")
    args = ap.parse_args()
    code, data, labels, meta = build()
    print(f"ROM 코드  ${meta['rom_origin']}-${meta['rom_end']}  {len(code)} B")
    print(f"RAM 캐시  ${meta['data_origin']}-${meta['data_end']}  {len(data)} B")
    print(f"상태      cdda=${meta['cdda_state_cpu']} track=${meta['track_bcd_cpu']}")
    print(f"entry     ${meta['entry']}  ready=${labels['ready']:04X} stage=${labels['stage']:04X}")
    if not args.write:
        print("(보고만 했다. 저장하려면 --write)")
        return
    OUT.write_bytes(code)
    DATA_OUT.write_bytes(data)
    INFO.write_text(json.dumps(meta, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    print(f"-> {OUT}")
    print(f"-> {DATA_OUT}")
    print(f"-> {INFO}")


if __name__ == "__main__":
    main()
