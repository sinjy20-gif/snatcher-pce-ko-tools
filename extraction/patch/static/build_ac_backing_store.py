#!/usr/bin/env python3
"""Build the minimal Arcade Card backing-store image for 0.3.0-uitest.

The input is the already-built 0.3.0-uitest Track-24 append.  Occupied SRT4
records are copied unchanged (704 bytes each); only the sparse slot image is
removed.  A dense 16-bit slot -> record-index table is emitted separately.
This is a storage artifact, not a new renderer or translation format.
"""

from __future__ import annotations

import argparse
import csv
import base64
import hashlib
import json
from pathlib import Path


ROOT = Path(r"C:\snatcher")
DEFAULT_BUILD = ROOT / "build" / "patch" / "0.3.0-uitest"

RAW_SECTOR_BYTES = 2352
USER_OFFSET = 16
USER_BYTES = 2048
RECORD_BYTES = 704
SLOT_COUNT = 0x4000
EMPTY_INDEX = 0xFFFF
RUNTIME_MARKER = 0xA5
AC_BYTES = 2 * 1024 * 1024


def sha256(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest().upper()


def build(build_dir: Path) -> dict[str, object]:
    out_dir = build_dir / "ac_backing_store"
    raw = (build_dir / "track24_appended_raw.bin").read_bytes()
    if len(raw) != SLOT_COUNT * RAW_SECTOR_BYTES:
        raise RuntimeError("unexpected Track-24 append size")

    with (build_dir / "direct_records.tsv").open(
        "r", encoding="utf-8-sig", newline=""
    ) as handle:
        rows = list(csv.DictReader(handle, delimiter="\t"))
    if not rows or len(rows) > SLOT_COUNT:
        raise RuntimeError(f"unexpected occupied record count: {len(rows)}")

    records = bytearray()
    slot_map = [EMPTY_INDEX] * SLOT_COUNT
    seen_slots: set[int] = set()
    for record_index, row in enumerate(rows):
        slot = int(row["final_slot"], 16)
        if not 0 <= slot < SLOT_COUNT or slot in seen_slots:
            raise RuntimeError(f"invalid or duplicate final slot: {row['final_slot']}")
        seen_slots.add(slot)
        start = slot * RAW_SECTOR_BYTES + USER_OFFSET
        payload = raw[start:start + RECORD_BYTES]
        if payload[:4] != b"SDR4":
            raise RuntimeError(f"missing SRT4 record at slot {slot:04X}")
        if payload[5] != int(row["source_length"]):
            raise RuntimeError(f"source length mismatch at slot {slot:04X}")
        records.extend(payload)
        slot_map[slot] = record_index

    map_bytes = b"".join(value.to_bytes(2, "little") for value in slot_map)
    # Runtime map: one 21-bit absolute AC address per original SRT4 slot.
    # Four bytes per slot makes the lookup address simply slot << 2; byte 3 is
    # zero for a hit and FF for an empty slot.  The 704-byte records themselves
    # remain byte-for-byte identical to the CD-backed build.
    address_map_bytes = SLOT_COUNT * 4
    records_base = address_map_bytes
    address_map = bytearray(b"\xFF" * address_map_bytes)
    for slot, record_index in enumerate(slot_map):
        if record_index == EMPTY_INDEX:
            continue
        address = records_base + record_index * RECORD_BYTES
        entry = slot * 4
        address_map[entry:entry + 3] = address.to_bytes(3, "little")
        address_map[entry + 3] = RUNTIME_MARKER

    out_dir.mkdir(parents=True, exist_ok=True)
    (out_dir / "slot_to_record_index_le16.bin").write_bytes(map_bytes)
    (out_dir / "slot_to_ac_address_le24x4.bin").write_bytes(address_map)
    (out_dir / "srt4_records_704b.bin").write_bytes(records)

    # 704 B 레코드를 AC 에 통째로 올리던 옛 경로의 산출물.  주소표 64 KB 를 빼면
    # 2,885 개가 한도다.
    #
    # **현행 경로는 이것을 안 쓴다.**  stage 3(build_ac_dynamic_0_1_5/14)이 읽는 것은
    # `srt4_records_704b.bin` 하나뿐이고, 거기서 96 B 로 압축해 AC 에 올린다
    # (3,903 레코드면 375 KB).  이 이미지를 읽는 것은 build_ac_self_preload*.py 와
    # lua/AC_BACKING_STORE_PRELOAD.lua 뿐이다.
    #
    # 2026-08-19: 번역이 늘어 3,903 레코드가 되면서 처음으로 한도를 넘었다.  예전에는
    # 여기서 RuntimeError 로 **빌드 전체를 죽였는데**, 쓰지도 않는 산출물 때문에
    # 정식 빌드가 막히는 것은 맞지 않다.  이제는 그 파일만 건너뛴다.
    image = bytes(address_map) + records
    legacy_fits = len(image) <= AC_BYTES
    if legacy_fits:
        (out_dir / "arcade_card_preload_used.bin").write_bytes(image)
        (out_dir / "arcade_card_preload_2mb.bin").write_bytes(
            image + bytes(AC_BYTES - len(image))
        )
    else:
        capacity = (AC_BYTES - address_map_bytes) // RECORD_BYTES
        print(f"  NOTE: 옛 AC 프리로드 이미지는 안 만든다 -- "
              f"{len(records) // RECORD_BYTES:,} 레코드가 704 B 한도 {capacity:,} 개를 "
              f"넘는다 ({len(image):,} B > {AC_BYTES:,} B).")
        print(f"        현행 경로는 이 파일을 쓰지 않는다 (stage 3 이 96 B 로 압축한다). "
              f"build_ac_self_preload*.py 를 쓰려면 그때 다시 봐야 한다.")

    manifest = {
        "format": "0.3.0-uitest-SRT4-records-plus-slot-map",
        "source_build": str(build_dir),
        "slot_count": SLOT_COUNT,
        "occupied_slots": len(rows),
        "record_bytes": RECORD_BYTES,
        "map_entry_bytes": 2,
        "empty_map_value": EMPTY_INDEX,
        "map_bytes": len(map_bytes),
        "runtime_map_entry_bytes": 4,
        "runtime_map_bytes": len(address_map),
        "records_base": records_base,
        "runtime_marker": RUNTIME_MARKER,
        "records_bytes": len(records),
        "used_bytes": len(image),
        "capacity_bytes": AC_BYTES,
        "free_bytes": AC_BYTES - len(image),
        "files": {
            "slot_to_record_index_le16.bin": sha256(map_bytes),
            "slot_to_ac_address_le24x4.bin": sha256(address_map),
            "srt4_records_704b.bin": sha256(records),
            **({"arcade_card_preload_used.bin": sha256(image),
                "arcade_card_preload_2mb.bin":
                    sha256(image + bytes(AC_BYTES - len(image)))}
               if legacy_fits else {}),
        },
    }
    (out_dir / "manifest.json").write_text(
        json.dumps(manifest, ensure_ascii=False, indent=2) + "\n", encoding="utf-8"
    )

    # Mesen disables io/os by default. Emit an embedded preload script so the
    # integration test does not depend on relaxing emulator security settings.
    encoded = base64.b64encode(image).decode("ascii")
    chunks = "\n".join(f'  "{encoded[i:i + 4096]}",' for i in range(0, len(encoded), 4096))
    lua = f'''-- Generated self-contained AC preload for ac_0.1.1.
-- No io/os access is required.
local ac = emu.memType.pceArcadeCardRam
local chunks = {{
{chunks}
}}
local alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
local decode = {{}}
for i = 1, #alphabet do decode[string.byte(alphabet, i)] = i - 1 end
local address = 0
local carry, bits = 0, 0
for _, chunk in ipairs(chunks) do
  for i = 1, #chunk do
    local value = decode[string.byte(chunk, i)]
    if value then
      carry = carry * 64 + value
      bits = bits + 6
      while bits >= 8 do
        bits = bits - 8
        local byte = math.floor(carry / (2 ^ bits)) % 256
        emu.write(address, byte, ac)
        address = address + 1
        carry = carry % (2 ^ bits)
      end
    end
  end
end
emu.displayMessage("AC Backing Store", string.format("Preloaded %d bytes", address))
emu.log(string.format("AC backing store embedded preload complete: %d bytes", address))
'''
    (out_dir / "AC_BACKING_STORE_PRELOAD_EMBEDDED.lua").write_text(lua, encoding="ascii")
    return manifest


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--build", type=Path, default=DEFAULT_BUILD)
    args = parser.parse_args()
    manifest = build(args.build)
    print(json.dumps(manifest, ensure_ascii=False, indent=2))


if __name__ == "__main__":
    main()
