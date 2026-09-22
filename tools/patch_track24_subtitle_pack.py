#!/usr/bin/env python3
"""빌드된 Track 24 의 자막 팩을 **현재 팩**으로 갈아끼운다.

왜 이 단계가 따로 필요한가
--------------------------
`.43/.47` 체인은 Track 24 를 기준판에서 통째로 복사하고 끝에 native bundle 만
덧붙인다.  자막 팩은 그 **기준판 구간**에 있으므로, 팩을 다시 구워도 디스크에는
옛 팩이 남는다.

    2026-09-01 실측 (0.4.6.62)
      새 팩 CDC3A4C4 183,909 B  -> 디스크에서 찾을 수 없음 (-1)
      옛 팩 8F20AF38 183,918 B  -> 오프셋 121,805,392 에 그대로

같은 날 아침 헬퍼가 똑같이 안 실려 하루를 태웠다 (`patch_track24_helper.py`).

무엇을 하나
-----------
팩은 Mode1 섹터 90 개의 user 영역(2,048 B)에 **2,048 씩 쪼개져** 들어 있다.
raw 로 이어붙어 있지 않으므로 섹터마다 나눠 쓰고 EDC/ECC 를 다시 계산한다.

    시작 섹터   `SNSB` 머리를 user 영역 경계에서 찾아 정한다
    용량        90 섹터 x 2,048 = 184,320 B
    꼬리        새 팩이 짧으면 옛 자리를 0 으로 덮는다 -- BIOS 선적재 표에 박힌
                업로드 길이는 그대로이므로 쓰레기가 AC 로 올라가지 않게 한다

    python tools/patch_track24_subtitle_pack.py 0.4.6.62            검사만
    python tools/patch_track24_subtitle_pack.py 0.4.6.62 --write    갈아끼움
"""
from __future__ import annotations

import argparse
import hashlib
import json
import shutil
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path[:0] = [str(ROOT / "tools"), str(ROOT / "extraction" / "patch" / "static")]

import build_disc_subtitle_hook as rawdisc  # noqa: E402
import subtitle_layout as layout  # noqa: E402

BUILD = ROOT / "build" / "cutscene_subs"
PACK = BUILD / "subtitle_pack.bin"
TRACK24_NAME = "Snatcher CD-ROMantic (Japan) (Track 24) [KO].bin"
RAW, USER, HEAD = 2352, 2048, 16
SECTORS_FALLBACK = 90             # 선적재 표를 못 읽을 때만 쓴다
MASTER = BUILD / "adpcm_lba_master_index.bin"
GFX_PAYLOAD = ROOT / "build" / "gfx" / "gfx_screens.bin"
AC_GFX = 0x1A0000


def pack_with_adpcm_master(pack: bytes, *, include_gfx: bool = False) -> bytes:
    """BIOS의 pack preload 행에 LBA master를 합친다.

    네이티브 GFX는 실패한 실험 기능이므로 일반/출하 빌드에는 절대로 암묵적으로
    넣지 않는다. GFX 전용 실험을 재현할 때만 명시적으로 include_gfx를 켠다.
    """
    master = MASTER.read_bytes()
    offset = layout.AC_ADPCM_LBA_MASTER - layout.AC_PACK
    if len(pack) > offset:
        raise SystemExit(
            f"팩이 ADPCM master 자리를 침범한다: {len(pack):,} > {offset:,}")
    out = bytearray(pack + bytes((0xFF,)) * (offset - len(pack)) + master)
    if include_gfx:
        if not GFX_PAYLOAD.exists():
            raise SystemExit(f"GFX 페이로드가 없다: {GFX_PAYLOAD}")
        gfx = GFX_PAYLOAD.read_bytes()
        gfx_at = AC_GFX - layout.AC_PACK
        if gfx_at < len(pack) or gfx_at + len(gfx) > offset:
            raise SystemExit(
                f"GFX가 팩/master와 겹친다: {gfx_at:,}+{len(gfx):,}, master {offset:,}")
        if out[gfx_at:gfx_at + len(gfx)] != bytes((0xFF,)) * len(gfx):
            raise SystemExit("GFX를 넣을 FF 간격이 비어 있지 않다")
        out[gfx_at:gfx_at + len(gfx)] = gfx
    return bytes(out)


def pack_region(folder: Path) -> tuple[int, int]:
    """이 빌드가 팩에 내준 섹터 수와 그 바이트 수.

    예전에는 90 으로 박혀 있었다.  그런데 이 자리는 **팩 크기를 따라 늘어난다**
    -- 선적재가 `subtitle_pack` 행에 몇 섹터를 잡았는지가 곧 자리다.  팩이 90
    섹터를 넘긴 날(185,581 B = 91 섹터) 디스크는 91 섹터로 구워졌는데 이 도구만
    90 을 고집해 "팩이 자리보다 크다" 로 멈췄다 (2026-09-01).
    """
    manifest = folder / "bios_preload.json"
    if manifest.exists():
        data = json.loads(manifest.read_text(encoding="utf-8"))
        for row in data.get("rows", []):
            if row.get("name") == "subtitle_pack":
                count = int(row["sectors"])
                return count, count * USER
    return SECTORS_FALLBACK, SECTORS_FALLBACK * USER


def sha(b: bytes) -> str:
    return hashlib.sha256(b).hexdigest().upper()


def find_pack(disc: bytes, magic: bytes) -> int:
    hits = []
    at = disc.find(magic)
    while at >= 0:
        if (at - HEAD) % RAW == 0:
            hits.append(at)
        at = disc.find(magic, at + 1)
    if len(hits) != 1:
        raise SystemExit(f"팩 후보가 {len(hits)} 개다 -- 자동 판정 불가: {hits[:5]}")
    return hits[0]


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("version", help="예: 0.4.6.62")
    ap.add_argument("--write", action="store_true")
    ap.add_argument("--pack", type=Path, default=PACK)
    ap.add_argument(
        "--include-gfx-payload", action="store_true",
        help="실패한 GFX native POC 재현 전용; 일반/출하 빌드에서는 사용 금지")
    args = ap.parse_args()

    target = ROOT / "build" / "patch" / args.version / TRACK24_NAME
    if not target.exists():
        raise SystemExit(f"없다: {target}")
    sectors, capacity = pack_region(target.parent)
    pack = args.pack.read_bytes()
    new = pack_with_adpcm_master(pack, include_gfx=args.include_gfx_payload)
    if len(new) > capacity:
        raise SystemExit(f"팩이 자리보다 크다: {len(new):,} > {capacity:,}"
                         f"  (이 빌드가 내준 자리는 {sectors} 섹터다)")

    disc = bytearray(target.read_bytes())
    at = find_pack(bytes(disc), new[:4])          # `SNSB` 머리는 판이 바뀌어도 같다
    sector = (at - HEAD) // RAW
    old = bytes().join(
        bytes(disc[(sector + i) * RAW + HEAD:(sector + i) * RAW + HEAD + USER])
        for i in range(sectors))

    print(f"{args.version} / {TRACK24_NAME}")
    print(f"  팩 자리   오프셋 {at:,}  = Mode1 섹터 {sector} ~ {sector + sectors - 1}")
    print(f"  디스크의 것 {sha(old[:len(new)])[:16]}  ({capacity:,} B 자리)")
    print(f"  새 팩       {sha(pack)[:16]}  {len(pack):,} B")
    print(f"  + LBA master @ AC ${layout.AC_ADPCM_LBA_MASTER:06X}  "
          f"합계 {len(new):,} B")
    if args.include_gfx_payload:
        print(f"  + GFX payload @ AC ${AC_GFX:06X}  {GFX_PAYLOAD.stat().st_size:,} B")
    if old[:len(new)] == new and not any(old[len(new):]):
        print("  == 이미 같다.  할 일 없음")
        return
    if not args.write:
        print("  (검사만 함.  실제로 바꾸려면 --write)")
        return

    backup = target.with_suffix(".bin.pre_pack_patch")
    if not backup.exists():
        shutil.copy2(target, backup)
        print(f"  백업 {backup.name}")

    padded = new + bytes(capacity - len(new))     # 꼬리를 0 으로 -- 쓰레기 업로드 방지
    for i in range(sectors):
        lo = (sector + i) * RAW
        chunk = padded[i * USER:(i + 1) * USER]
        disc[lo + HEAD:lo + HEAD + USER] = chunk
        sec = bytearray(disc[lo:lo + RAW])
        rawdisc.rebuild_mode1_sector(sec)
        disc[lo:lo + RAW] = sec
    target.write_bytes(bytes(disc))

    back = target.read_bytes()
    got = b"".join(back[(sector + i) * RAW + HEAD:(sector + i) * RAW + HEAD + USER]
                   for i in range(sectors))
    assert got[:len(new)] == new, "기입 확인 실패"
    assert len(back) == len(disc), "길이가 변했다"
    print(f"  ★ 갈아끼움 완료 · 섹터 {sectors} 개 EDC/ECC 재계산 · 길이 불변")


if __name__ == "__main__":
    main()
