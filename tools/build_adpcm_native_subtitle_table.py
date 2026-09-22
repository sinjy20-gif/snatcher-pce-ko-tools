#!/usr/bin/env python3
"""Native ADPCM dispatcher용 LBA→subtitle payload 표를 만든다.

directory entry (9 B, LBA 오름차순)
    start_lba u24 BE + payload absolute AC pointer u24 LE
    + vram_base_hi + pattern_base_lo + pattern_attr   (음성마다 다른 VRAM 자리)

payload
    count u8 + subtitle_pack ADPCM index entry 13 B × count

팩에 실제 자막 record가 있는 runtime key만 들어간다. 따라서 효과음/미등록 음성은
directory miss로 끝나며 state를 열지 않는다.
"""
from __future__ import annotations

import json
import argparse
import os
import struct
from collections import defaultdict
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / "build" / "cutscene_subs"
PACK = OUT / "subtitle_pack.bin"
MASTER = OUT / "adpcm_lba_master_index.bin"
DIR_OUT = OUT / "adpcm_native_subtitle_dir.bin"
PAYLOAD_OUT = OUT / "adpcm_native_subtitle_payload.bin"
INFO_OUT = OUT / "adpcm_native_subtitle_table.json"

AC_DIR = 0x1F2800
# 6 -> 9 (2026-09-02).  뒤 3 B 가 **음성마다 다른 VRAM 자리**다.
#
# 왜 필요한가
#   armer 는 D000 하나만 무장했다.  자막 글리프를 박을 VRAM 자리가 음성마다
#   달라야 하는데(초상화가 자리를 뺏는다) 그 값을 나를 칸이 없어서, 검증된
#   D000 의 자리를 엔진 코드 안 즉치값으로 들고 있었기 때문이다.
#
# 왜 base 가 아니라 즉치값 3 개인가
#   6280 에 곱셈기가 없다.  세 값은 전부 PAT_VRAM 하나에서 나오지만
#   (build_subtitle_engine_ac_record_poc.py 참고) 시프트·마스크를 런타임에
#   시키면 코드가 는다.  여기서 미리 계산해 넣으면 armer 는 3 B 를 엔진
#   사본에 **복사만** 하면 된다.
#
#       vram_base_hi_imm    = base >> 8
#       pattern_base_lo_imm = ((base >> 6) << 1) & 0xFF
#       pattern_attr_imm    = 0x80 | ((((base >> 6) << 1) >> 8) & 7) << 4 | PALETTE
DIR_STRIDE = 9
PALETTE = 15                       # build_subtitle_engine_ac_record_poc.py 와 같아야 한다
VRAM_PAIRS = ROOT / "build" / "cutscene_subs" / "vram_key_bases_pairs.tsv"
VRAM_SINGLE = ROOT / "build" / "cutscene_subs" / "vram_key_bases.tsv"
CONSOLE_KEYS = ROOT / "snatcher_tool" / "translation" / "voice_console_keys.tsv"

def vram_immediates(base: int) -> bytes:
    """VRAM 글리프 블록 base(워드) -> 엔진이 들고 있는 즉치값 3 B."""
    pat = (base >> 6) << 1
    return bytes((base >> 8 & 0xFF, pat & 0xFF,
                  0x80 | ((pat >> 8) & 7) << 4 | PALETTE))


def safe_bases() -> tuple[dict[bytes, int], set[bytes]]:
    """콘솔 6 B 키 -> 실제 native가 싣는 안전 base와 단일 fallback 키.

    native directory는 지금도 base_a 하나만 저장한다. pairs의 B는 release gate가
    요구했지만 런타임에서는 읽지 않는다. 따라서 A/B 두 자리를 못 만든 키도
    엄격한 $100 정렬 단일표에 안전 base가 있으면 그 값을 쓸 수 있다.
    """
    import csv as _csv
    import io as _io
    utf16_marks = (bytes((0xFF, 0xFE)), bytes((0xFE, 0xFF)))

    def rd(path):
        raw = path.read_bytes()
        enc = "utf-16" if raw[:2] in utf16_marks else "utf-8-sig"
        return list(_csv.DictReader(_io.StringIO(raw.decode(enc)), delimiter="\t"))

    if not VRAM_PAIRS.is_file():
        raise SystemExit(f"안전자리표가 없다: {VRAM_PAIRS}  --  먼저 "
                         "python tools/build_vram_key_bases.py --pairs --align 0x100")
    names = {}
    for row in rd(CONSOLE_KEYS):
        text = (row.get("runtime_key_hex") or "").replace(" ", "").strip()
        name = (row.get("key") or "").strip().upper()
        if name and len(text) == 12:
            names[name] = bytes.fromhex(text)
    out: dict[bytes, int] = {}
    for row in rd(VRAM_PAIRS):
        name = (row.get("key") or "").strip().upper()
        raw = (row.get("base_a") or "").strip()
        if not raw or name not in names:
            continue
        try:
            out[names[name]] = int(raw, 16)
        except ValueError:
            continue
    fallback: set[bytes] = set()
    if VRAM_SINGLE.is_file():
        for row in rd(VRAM_SINGLE):
            name = (row.get("key") or "").strip().upper()
            raw = (row.get("base") or "").strip()
            if not raw or name not in names or names[name] in out:
                continue
            try:
                base = int(raw, 16)
            except ValueError:
                continue
            # 현재 native 즉치값 계약과 helper의 CD-DA 예약 판정을 그대로 검증한다.
            need = 19 * 0x40
            if (base < 0x2000 or base % 0x100 or
                    (base >> 8) == 0x79 or
                    base + need > 0x8000 or
                    (base >> 13) != ((base + need - 1) >> 13)):
                continue
            runtime = names[name]
            out[runtime] = base
            fallback.add(runtime)
    return out, fallback


PACK_INDEX_STRIDE = 13


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--pack", type=Path, default=PACK)
    ap.add_argument("--tag", default=None,
                    help="기본 산출물을 덮지 않을 파일명 suffix")
    ap.add_argument("--skip-missing-lba", action="store_true",
                    help="LBA 색인에 없는 음성은 빼고 만든다 (기본은 중단)")
    args = ap.parse_args()
    # 상위 빌더(build_subtitle_set.py)가 인자를 못 넘기므로 환경변수로도 받는다
    # -- 팩 빌더의 SNATCHER_SUBTITLE_SKIP_* 와 같은 방식이다.
    if os.environ.get("SNATCHER_SUBTITLE_SKIP_MISSING_LBA", "0") == "1":
        args.skip_missing_lba = True
    pack = args.pack.read_bytes()
    master = MASTER.read_bytes()
    if len(master) % 9:
        raise SystemExit("master LBA index 크기가 9의 배수가 아니다")
    if pack[:4] != b"SNSB":
        raise SystemExit("subtitle pack magic 불일치")

    count, index_off = struct.unpack_from("<HI", pack, 14)

    # ★ 주인표: 항목 위치 -> event_id (sector 가 든 고유 키).  팩 빌더가 같이 낸다.
    #   런타임 키 6 B 로 묶으면 충돌한 두 음성의 조각이 섞이므로 주인으로 묶는다.
    owners = []
    owner_tsv = OUT / "adpcm_index_owner.tsv"
    if owner_tsv.exists():
        import csv as _c, io as _i
        for row in _c.DictReader(
                _i.StringIO(owner_tsv.read_bytes().decode("utf-8-sig")),
                delimiter="\t"):
            owners.append((row.get("event_id") or "").strip())
        if len(owners) != count:
            raise SystemExit(
                f"주인표 행수({len(owners)})가 팩 항목 수({count})와 다르다 -- "
                "팩과 주인표를 같이 다시 만들 것")

    groups: dict[object, list[bytes]] = defaultdict(list)
    key6_of: dict[object, bytes] = {}
    for i in range(count):
        at = index_off + i * PACK_INDEX_STRIDE
        entry = pack[at:at + PACK_INDEX_STRIDE]
        if len(entry) != PACK_INDEX_STRIDE:
            raise SystemExit("subtitle pack ADPCM index 잘림")
        gid = owners[i] if owners else entry[:6]
        groups[gid].append(entry)
        key6_of[gid] = entry[:6]

    lbas_by_key: dict[object, set[int]] = defaultdict(set)
    if owners:
        # event_id -> start_lba 는 마스터 색인 TSV 에 있다 (key 열이 고유 키다).
        import csv as _c2, io as _i2
        # ★ 전체 대응표를 쓴다.  이진 조회표는 같은 LBA 무리를 빼 놓기 때문에
        #   그것만 보면 합칠 대상이 도착하지 못한다.
        tsv = OUT / "adpcm_lba_all.tsv"
        if not tsv.exists():
            tsv = OUT / "adpcm_lba_master_index.tsv"
        if not tsv.exists():
            raise SystemExit("주인별로 묶으려면 adpcm_lba_all.tsv 가 필요하다")
        for row in _c2.DictReader(
                _i2.StringIO(tsv.read_bytes().decode("utf-8-sig")), delimiter="\t"):
            k = (row.get("key") or "").strip()
            v = (row.get("start_lba") or "").strip()
            if k and v:
                lbas_by_key[k].add(int(v, 16))
    else:
        for at in range(0, len(master), 9):
            row = master[at:at + 9]
            lbas_by_key[row[3:9]].add(int.from_bytes(row[:3], "big"))

    def _name(g):
        return g if isinstance(g, str) else g.hex().upper()

    missing = sorted(_name(g) for g in groups if g not in lbas_by_key)
    if missing and not args.skip_missing_lba:
        raise SystemExit("자막 key에 LBA가 없다: " + ", ".join(missing[:8])
                         + "\n  결국 다 넣어야 한다.  이번 판만 빼려면 --skip-missing-lba")
    if missing:
        print(f"  LBA 색인에 없는 음성 {len(missing)} 개를 뺀다 -- 자막이 안 실린다")
        for name in missing:
            print(f"     {name}")
        for g in [g for g in groups if g not in lbas_by_key]:
            del groups[g]

    # 안전한 VRAM 자리가 없는 음성은 **싣지 않는다.**  자리를 모르면 글리프를
    # 아무 데나 박게 되고 그것은 배경을 깨뜨린다 (소유자 방침: 안전구역 없으면
    # 자막을 안 넣는다).  directory miss 로 끝나므로 state 도 안 열린다.
    bases, fallback_bases = safe_bases()
    bases_lookup = bases
    no_base = sorted(_name(g) for g in groups if key6_of[g] not in bases)
    for g in list(groups):
        if key6_of[g] not in bases:
            del groups[g]
    if not groups:
        raise SystemExit("안전자리가 있는 자막 음성이 하나도 없다")

    rows = sorted((lba, key, entries)
                  for key, entries in groups.items()
                  for lba in lbas_by_key[key])
    # ★ 같은 LBA 는 버리지 않고 **한 버킷으로 합친다** (2026-09-02).
    #   payload 항목마다 런타임 키 6 B 가 있으므로 런타임이 안에서 가른다.
    #   단 디렉터리가 VRAM 자리를 하나만 들고 가므로, 자리가 다르면 못 합친다.
    buckets: dict[int, list] = {}
    for lba, key, entries in rows:
        buckets.setdefault(lba, []).append((key, entries))

    merged_rows, base_conflicts = [], []
    for lba in sorted(buckets):
        members = buckets[lba]
        member_bases = {bases_lookup[key6_of[k]] for k, _ in members}
        if len(member_bases) > 1:
            base_conflicts.append((lba, [k for k, _ in members], sorted(member_bases)))
            continue
        joined = [e for _, ents in members for e in ents]
        merged_rows.append((lba, members[0][0], joined))
    rows = merged_rows

    multi = sum(1 for lba in buckets if len(buckets[lba]) > 1)
    if multi:
        print(f"  같은 LBA 버킷 병합 {multi} 곳")
    if base_conflicts:
        print(f"  ★ VRAM 자리가 달라 못 합친 버킷 {len(base_conflicts)} 곳 -- 자막이 안 실린다")
        for lba, keys, bs in base_conflicts:
            print(f"     LBA {lba:06X}  " + " / ".join(keys)
                  + "  자리 " + " ".join(f"${b:04X}" for b in bs))

    payload_base = AC_DIR + len(rows) * DIR_STRIDE
    directory = bytearray()
    payload = bytearray()
    max_parts = 0
    for lba, key, entries in rows:
        # 한도 19 의 근거 (2026-09-01 에 11 -> 19 로 올렸다)
        # ------------------------------------------------------------
        # 11 은 형식 한계가 아니라 **그때까지 관측된 최댓값**이었다.  실제 천장은
        # armer 의 복사 루프가 정한다 -- `arm_copy_mini` 는 옮길 바이트 수를
        # 8 비트 한 칸(`TOTAL+1`)에 담고 DEC 로 센다
        # (build_snatcher_0_4_6_29_native_arm.py: "총 바이트=count*13 ... 8-bit").
        #
        #     19 조각 x 13 B = 247 B  <= 255   8 비트 안에 든다
        #     20 조각 x 13 B = 260 B  >  255   카운터가 돌아 죽는다
        #
        # 받는 자리도 넉넉하다.  AC_MINI($1EF000) 다음 배치가 helper($1F1C00)라
        # 11,264 B 가 비어 있고 247 B 만 쓴다.
        #
        # 계기: 재수집으로 음성이 8.19 초에서 32.2 초까지 자라면서
        # ADPCM_00359E_FFFF_0E 가 자막 12 조각이 됐다 (조각 번호 중복 아님).
        if not 1 <= len(entries) <= 19:
            raise SystemExit(f"조각 수 범위 오류: {_name(key)} -> {len(entries)}"
                             "  (한 음성에 19 조각까지.  더 나누려면 armer 의"
                             " 8 비트 복사 카운터부터 넓혀야 한다)")
        pointer = payload_base + len(payload)
        if pointer > 0xFFFFFF:
            raise SystemExit("AC payload pointer 범위 초과")
        directory += lba.to_bytes(3, "big")
        directory += pointer.to_bytes(3, "little")
        directory += vram_immediates(bases[key6_of[key]])
        payload.append(len(entries))
        for entry in entries:
            payload += entry
        max_parts = max(max_parts, len(entries))

    end = payload_base + len(payload)
    if end > 0x200000:
        raise SystemExit(f"Arcade Card 범위 초과: ${end:06X}")
    dir_out, payload_out, info_out = DIR_OUT, PAYLOAD_OUT, INFO_OUT
    if args.tag:
        safe_tag = "".join(c for c in args.tag if c.isalnum() or c in "_-")
        if not safe_tag or safe_tag != args.tag:
            raise SystemExit("--tag는 영문/숫자/_/-만 허용")
        dir_out = OUT / f"adpcm_native_subtitle_dir_{safe_tag}.bin"
        payload_out = OUT / f"adpcm_native_subtitle_payload_{safe_tag}.bin"
        info_out = OUT / f"adpcm_native_subtitle_table_{safe_tag}.json"
    dir_out.write_bytes(directory)
    payload_out.write_bytes(payload)
    info = {
        "directory_base": f"{AC_DIR:06X}",
        "subtitle_keys": len(groups),
        "directory_entries": len(rows),
        "directory_stride": DIR_STRIDE,
        "directory_bytes": len(directory),
        "payload_base": f"{payload_base:06X}",
        "payload_bytes": len(payload),
        "end_exclusive": f"{end:06X}",
        "subtitle_fragments": sum(len(e) for _, _, e in rows),
        "max_parts": max_parts,
        # 2026-09-09: 여기가 `[]` 로 박혀 있었다.  안전자리가 없어 뺀 음성이
        # 있어도 매니페스트는 0 이라고 적어서, 무엇이 빠졌는지 나중에 알 길이
        # 없었다.  아래 print 도 정의되지 않은 이름(`explicitly_excluded`)을 돌아
        # NameError 로 죽었다 -- 즉 이 경로는 한 번도 안 밟혀 본 자리다.
        "excluded_unsafe_keys": no_base,
        "single_base_fallback_keys": sorted(
            _name(g) for g in groups if key6_of[g] in fallback_bases),
        "layout": "dir: lba24be + payload_ptr24le; payload: count8 + pack_index13[]",
    }
    info_out.write_text(json.dumps(info, ensure_ascii=False, indent=2), encoding="utf-8")
    print(f"native ADPCM subtitle directory {len(groups)} keys / {len(rows)} LBA routes / {len(directory):,} B @ ${AC_DIR:06X}")
    if no_base:
        print(f"  안전한 VRAM 자리가 없어 뺀 음성 {len(no_base)} 개"
              "  (안전자리 없으면 자막을 안 싣는다)")
        for name in no_base:
            print(f"     {name}")
    fallback_used = sorted(_name(g) for g in groups if key6_of[g] in fallback_bases)
    if fallback_used:
        print(f"  A/B 두 자리 대신 검증된 단일 base를 쓴 음성 {len(fallback_used)} 개")
        for name in fallback_used:
            print(f"     {name}")
    print(f"payload {info['subtitle_fragments']} fragments / {len(payload):,} B @ ${payload_base:06X}-${end-1:06X}")
    print(f"max parts {max_parts} · LBA collision 0 · missing 0")
    print(dir_out)
    print(payload_out)


if __name__ == "__main__":
    main()
