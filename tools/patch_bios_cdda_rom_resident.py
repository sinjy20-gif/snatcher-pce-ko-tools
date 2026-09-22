#!/usr/bin/env python3
"""CD-DA ROM 상주 코드/스케줄러를 BIOS에 심는다.

ROM 상주 디스패처를 켠 빌드에만 쓴다. ADPCM의 기존 STATE 경로는 건드리지
않으며, 기본은 검증만 하고 `--write`가 있어야 BIOS를 바꾼다.
"""
from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path

import build_snatcher_cdda_scheduler as sched
import build_subtitle_engine_cdda_rom as rom
import subtitle_layout as layout

ROOT = Path(__file__).resolve().parents[1]
BUILD = ROOT / "build" / "cutscene_subs"

# ROM renderer 뒤 BIOS 여백.  2026-09-13 첫 글리프/마지막 팔레트 보정으로
# renderer가 $FEB0까지 늘어났으므로 그 바로 뒤부터 CD-DA 전용 CPU RAM 임대
# save/restore를 둔다. 아래의 명시적 겹침 검사도 함께 유지한다.
CACHE_CODE_ORIGIN = 0xFEB1

# CD-DA 사설 상태 바이트의 `track_bcd` 기준 오프셋.
#
# 295 B 캐시 바로 뒤부터 $1F1EFF까지 25 B가 남는다. 첫 1 B를 이번 CD 재생
# 건의 자막 소진 표식으로 쓴다. 게임 RAM과 ADPCM 공유 슬롯 밖이다.
AC_PLAYBACK_DONE = layout.AC_CDDA_ROM_CACHE + rom.DATA_BYTES
PLAYBACK_DONE_MAGIC = 0xA5


def build_cache_code(state: int, track_bcd: int, data_origin: int, data_bytes: int,
                     labels: dict[str, int] | None = None) -> tuple[bytes, dict[str, int]]:
    """CD-DA RAM 캐시를 별도 AC 틈에 저장/복원하는 BIOS 루틴."""
    if data_bytes > layout.AC_CDDA_ROM_CACHE_MAX:
        raise SystemExit(
            f"CD-DA cache {data_bytes} B가 AC 틈 {layout.AC_CDDA_ROM_CACHE_MAX} B를 넘는다")
    a = sched.base.Asm(CACHE_CODE_ORIGIN, labels)
    # cdda_rom_request가 JMP로 들어온다. 이미 CD-DA가 active면 바깥쪽
    # 게임 스냅샷을 다시 뜨지 않는다(연속 pulse/ADPCM 중첩 보호).
    a.label("cache_save")
    a.abs_(0xAD, state)
    a.branch(0xF0, "cache_idle")
    a.emit(0x4C); a.word("cache_arm")
    a.label("cache_idle")
    a.label("cache_snapshot")
    # request 시점에는 게임이 AC CH1을 쓰고 있을 수 있으므로 8 B 보존한다.
    for i in range(8):
        a.abs_(0xAD, 0x1A12 + i); a.emit(0x48)
    sched.ac_ptr_const(a, 1, layout.AC_CDDA_ROM_CACHE)
    # TIN: CPU src 증가, AC data port dst 고정.
    a.emit(0xD3); a.word(data_origin); a.word(0x1A10); a.word(data_bytes)
    for i in reversed(range(8)):
        a.emit(0x68); a.abs_(0x8D, 0x1A12 + i)
    a.label("cache_arm")
    a.emit(0xA9, 0x01); a.abs_(0x8D, state); a.emit(0x60)

    # scheduler는 진입 때 CH1을 이미 스택에 보존한다. 여기서는 그대로 써도
    # cdda_store가 원래 CH1을 되돌린다. TAI: AC port 고정, CPU dst 증가.
    a.label("cache_restore")
    sched.ac_ptr_const(a, 1, layout.AC_CDDA_ROM_CACHE)
    a.emit(0xF3); a.word(0x1A10); a.word(data_origin); a.word(data_bytes)
    # done_latch는 보존한다. state/data만 반납한 뒤에도 같은 CD 재생 건의
    # 레벨 신호가 남아 dispatcher를 다시 열 수 있기 때문이다.
    a.abs_(0x9C, state); a.emit(0x60)
    return a.finish(), a.labels


def patch_lifecycle(image: bytearray, dispatcher: dict, slabels: dict[str, int],
                    state: int, cache_labels: dict[str, int],
                    legacy_cache_save: int | None = None) -> list[dict]:
    """크기를 바꾸지 않고 request/종료 두 곳을 전용 캐시에 연결한다."""
    dlabels = {k: int(v, 16) for k, v in dispatcher["labels"].items()}
    request = dlabels["cdda_rom_request"]
    save = cache_labels["cache_save"]
    restore = cache_labels["cache_restore"]
    request_replacements = [bytes((0x4C, save & 0xFF, save >> 8, 0xEA, 0xEA, 0xEA))]
    if legacy_cache_save is not None:
        request_replacements.append(bytes((0x4C, legacy_cache_save & 0xFF,
                                           legacy_cache_save >> 8, 0xEA, 0xEA, 0xEA)))
    patches = [
        # 기존 6 B: LDA #1 / STA state / RTS. JMP save 뒤 save의 RTS가
        # request를 호출한 원래 JSR로 직접 돌아간다.
        (request,
         bytes((0xA9, 0x01, 0x8D, state & 0xFF, state >> 8, 0x60)),
         request_replacements,
         "CD-DA request -> cache save"),
    ]
    for name in ("cdda_stopped", "cdda_state3"):
        at = slabels[name]
        patches.append((
            at,
            bytes((0xA9, 0x00, 0x8D, state & 0xFF, state >> 8)),
            bytes((0x20, restore & 0xFF, restore >> 8, 0xEA, 0xEA)),
            f"{name} -> cache restore",
        ))
    report = []
    for cpu, expected, replacement, name in patches:
        at = off1(cpu)
        got = bytes(image[at:at + len(expected)])
        accepted = tuple(replacement) if isinstance(replacement, list) else (replacement,)
        if got not in (expected, *accepted):
            raise SystemExit(
                f"{name} ${cpu:04X} 불일치: {got.hex(' ')} / 예상 {expected.hex(' ')}")
        image[at:at + len(accepted[0])] = accepted[0]
        report.append({"name": name, "cpu": f"{cpu:04X}",
                       "before": expected.hex(" ").upper(),
                       "after": accepted[0].hex(" ").upper()})
    return report


def off1(cpu: int) -> int:
    return 0x2000 + cpu - 0xE000


def sha(blob: bytes) -> str:
    return hashlib.sha256(blob).hexdigest().upper()


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("version")
    ap.add_argument("--write", action="store_true")
    ap.add_argument("--existing", action="store_true",
                    help="이미 ROM renderer/scheduler가 심긴 BIOS에 lifecycle fix만 적용")
    ap.add_argument("--upgrade", action="store_true",
                    help="--existing 대상의 검증된 renderer/scheduler도 새 빌드로 교체")
    ap.add_argument("--output-bios", type=Path,
                    help="원본을 보존하고 이 경로에 결과를 쓴다")
    args = ap.parse_args()
    out = ROOT / "build" / "patch" / args.version
    bios = out / f"Syscard3_galmuri_{args.version}.pce"
    info_path = BUILD / "engine_cdda_rom.json"
    disp_path = BUILD / "cdda17_adpcm_d000_dispatcher.json"
    for path in (bios, info_path, disp_path):
        if not path.exists():
            raise SystemExit(f"없다: {path}")
    meta = json.loads(info_path.read_text(encoding="utf-8"))
    dispatcher = json.loads(disp_path.read_text(encoding="utf-8"))
    previous_resident_path = out / "cdda_rom_resident.json"
    previous_resident = (json.loads(previous_resident_path.read_text(encoding="utf-8"))
                         if args.existing and previous_resident_path.exists() else None)
    code = (BUILD / "engine_cdda_rom.bin").read_bytes()
    image = bytearray(bios.read_bytes())
    existing_exact = bool(
        previous_resident is not None and
        sha(bytes(image)) == previous_resident.get("output_sha256")
    )
    if args.existing and previous_resident is not None and not existing_exact:
        raise SystemExit("기존 BIOS 전체 SHA가 cdda_rom_resident 기록과 다르다")
    origin = int(meta["rom_origin"], 16)
    state = int(meta["cdda_state_cpu"], 16)
    track = int(meta["track_bcd_cpu"], 16)
    labels = {k: int(v, 16) for k, v in meta["labels"].items()}
    kwargs = dict(ready_cpu=labels["ready"], record_ptr_cpu=labels["record_ptr"],
                  vram_hi_cpu=labels["imm_vram_hi"], vram_lo_cpu=labels["imm_pat_lo"],
                  vram_attr_cpu=labels["imm_attr"], stage_cpu=labels["stage"],
                  stage_template_ac=None, stage_bytes=0, mini_stride=5,
                  track_byte_cpu=track, private_state_cpu=state,
                  done_latch_ac=AC_PLAYBACK_DONE,
                  done_latch_value=PLAYBACK_DONE_MAGIC,
                  done_latch_track_cpu=sched.CD_SUBQ_RAW_TRACK)
    sched_origin = 0xECF9
    first, slabels = sched.build_scheduler_cdda(sched_origin, None, **kwargs)
    scheduler, slabels = sched.build_scheduler_cdda(sched_origin, slabels, **kwargs)
    if len(first) != len(scheduler):
        raise SystemExit("scheduler two-pass 크기 불일치")
    if len(scheduler) > 0xF04D - sched_origin + 1:
        raise SystemExit("scheduler가 bankA 공간을 넘는다")
    # CD-DA 무장은 dispatcher의 cdda_check -> cdda_start가 직접 cdda_state=2로
    # 처리한다. 이전 시험판은 유일한 `LDA #1 / STA STATE`를 CD-DA 시작점으로
    # 오인했는데, 실제로는 ADPCM arm 성공 경로였다. 상태 쓰기는 패치하지 않는다.
    cache1, cache_labels1 = build_cache_code(
        state, track, int(meta["data_origin"], 16), int(meta["data_bytes"]))
    cache_code, cache_labels = build_cache_code(
        state, track, int(meta["data_origin"], 16), int(meta["data_bytes"]), cache_labels1)
    if len(cache1) != len(cache_code):
        raise SystemExit("cache code two-pass 크기 불일치")
    if origin + len(code) > CACHE_CODE_ORIGIN:
        raise SystemExit(
            f"ROM renderer ${origin:04X}-${origin + len(code) - 1:04X}와 "
            f"cache code ${CACHE_CODE_ORIGIN:04X}가 겹친다")
    if CACHE_CODE_ORIGIN + len(cache_code) - 1 > rom.ROM_LIMIT:
        raise SystemExit("cache code가 BIOS bank 1 여백을 넘는다")

    checks = ((origin, code, "ROM renderer", "renderer"),
              (sched_origin, scheduler, "CD-DA scheduler", "scheduler"))
    for cpu, blob, name, previous_key in checks:
        if existing_exact:
            valid = True
        elif args.existing and previous_resident is not None:
            previous = previous_resident[previous_key]
            previous_bytes = int(previous["bytes"])
            region = bytes(image[off1(cpu):off1(cpu) + previous_bytes])
            valid = sha(region) == previous["sha256"]
        else:
            region = bytes(image[off1(cpu):off1(cpu) + len(blob)])
            valid = region == (blob if args.existing else b"\xFF" * len(blob))
        if not valid:
            raise SystemExit(f"{name} 자리 ${cpu:04X}가 {'기존 코드와 다르다' if args.existing else '비어 있지 않다'}")
    cache_region = image[off1(CACHE_CODE_ORIGIN):off1(CACHE_CODE_ORIGIN) + len(cache_code)]
    cache_ok = existing_exact or cache_region in (b"\xFF" * len(cache_code), cache_code)
    # --existing은 바로 전 ROM-resident 판의 짧은 cache code를 새 판으로
    # 교체할 수 있다. 기록된 SHA와 뒤쪽 FF 여백을 모두 확인한 경우만 허용한다.
    if not cache_ok and args.existing:
        if previous_resident is not None:
            previous = previous_resident["cache_code"]
            old_bytes = int(previous["bytes"])
            old_region = image[off1(CACHE_CODE_ORIGIN):off1(CACHE_CODE_ORIGIN) + old_bytes]
            old_sha = sha(bytes(old_region))
            tail = cache_region[old_bytes:]
            cache_ok = (old_sha == previous["sha256"] and
                        tail == b"\xFF" * len(tail))
    if not cache_ok:
        raise SystemExit(f"cache code 자리 ${CACHE_CODE_ORIGIN:04X}가 비어 있지 않다")
    print(f"ROM renderer  ${origin:04X}-${origin + len(code) - 1:04X} {len(code)} B")
    print(f"scheduler     ${sched_origin:04X}-${sched_origin + len(scheduler) - 1:04X} {len(scheduler)} B")
    print(f"cache code    ${CACHE_CODE_ORIGIN:04X}-${CACHE_CODE_ORIGIN + len(cache_code) - 1:04X} {len(cache_code)} B")
    print(f"cache data    AC ${layout.AC_CDDA_ROM_CACHE:06X}-${layout.AC_CDDA_ROM_CACHE + int(meta['data_bytes']) - 1:06X}")
    print("state hook    CD-DA private lifecycle만 (ADPCM STATE 경로 보존)")
    print(f"cache/state   ${labels['ready']:04X}-${labels['blank']:04X} · state ${state:04X}")
    if not args.write:
        print("(시늉만 했다. 실제 반영은 --write)")
        return
    before = sha(bytes(image))
    if not args.existing or args.upgrade:
        image[off1(origin):off1(origin) + len(code)] = code
        image[off1(sched_origin):off1(sched_origin) + len(scheduler)] = scheduler
    image[off1(CACHE_CODE_ORIGIN):off1(CACHE_CODE_ORIGIN) + len(cache_code)] = cache_code
    lifecycle_slabels = slabels
    if previous_resident is not None and not args.upgrade:
        lifecycle_slabels = {
            k: int(v, 16) for k, v in previous_resident["scheduler"]["labels"].items()
        }
        # 완성판에는 옛 cache_restore 주소를 부르는 JSR이 이미 박혀 있다.
        # 두 곳을 원래 5바이트로 정규화한 뒤 새 restore 주소로 다시 패치한다.
        old_restore = int(previous_resident["cache_code"]["labels"]["cache_restore"], 16)
        old_hook = bytes((0x20, old_restore & 0xFF, old_restore >> 8, 0xEA, 0xEA))
        original = bytes((0xA9, 0x00, 0x8D, state & 0xFF, state >> 8))
        for name in ("cdda_stopped", "cdda_state3"):
            at = off1(lifecycle_slabels[name])
            if bytes(image[at:at + 5]) != old_hook:
                raise SystemExit(f"{name} 옛 cache_restore hook 불일치")
            image[at:at + 5] = original
    legacy_save = None
    if args.upgrade and previous_resident is not None:
        legacy_save = int(previous_resident["cache_code"]["labels"]["cache_save"], 16)
    lifecycle_patches = patch_lifecycle(
        image, dispatcher, lifecycle_slabels, state, cache_labels, legacy_save)
    dest = args.output_bios.resolve() if args.output_bios else bios
    dest.parent.mkdir(parents=True, exist_ok=True)
    dest.write_bytes(image)
    info_out = (dest.with_suffix(".cdda_rom_resident.json")
                if args.output_bios else out / "cdda_rom_resident.json")
    info_out.write_text(json.dumps({
        "renderer": {"cpu": f"{origin:04X}", "bytes": len(code), "sha256": sha(code)},
        "scheduler": {"cpu": f"{sched_origin:04X}", "bytes": len(scheduler),
                      "sha256": sha(scheduler), "labels": {k: f"{v:04X}" for k, v in slabels.items()}},
        "cache_code": {"cpu": f"{CACHE_CODE_ORIGIN:04X}", "bytes": len(cache_code),
                       "sha256": sha(cache_code),
                       "labels": {k: f"{v:04X}" for k, v in cache_labels.items()}},
        "cache_data": {"ac": f"{layout.AC_CDDA_ROM_CACHE:06X}",
                       "cpu": f"{int(meta['data_origin'], 16):04X}",
                       "bytes": int(meta["data_bytes"])},
        "playback_done_latch": {
            "ac": f"{AC_PLAYBACK_DONE:06X}",
            "value": f"{PLAYBACK_DONE_MAGIC:02X}",
            "set_by": "scheduler part>=count",
            "cleared_by": "dispatcher state=1/rom_cdda_init",
            "suppresses": "dispatcher cdda_start level re-entry",
        },
        "cdda_state": f"{state:04X}", "state_hook": lifecycle_patches,
        "input_sha256": before, "output_sha256": sha(bytes(image)),
    }, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    print(f"-> {dest}")


if __name__ == "__main__":
    main()
