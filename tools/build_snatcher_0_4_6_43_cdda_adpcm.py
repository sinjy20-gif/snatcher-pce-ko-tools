#!/usr/bin/env python3
"""0.4.6.43: 실기 PASS CD-DA Track17과 ADPCM D000의 무Lua 통합판."""
from __future__ import annotations

import csv
import hashlib
import io
import json
from pathlib import Path
import sys

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "tools"))

import build_snatcher_0_4_6_40_native_preload as preload  # noqa: E402
import build_snatcher_0_4_6_29_native_arm as native  # noqa: E402
# 재무장 걸쇠가 읽는 두 바이트의 오프셋.  상수를 여기 베껴 두지 않는다 --
# 정의는 상주부 패처 하나뿐이고, 어긋나면 걸쇠가 엉뚱한 바이트를 본다.
import patch_bios_cdda_rom_resident as cdda_resident  # noqa: E402

VERSION = "0.4.6.43"
BUILD_ID = 43
BUILD = ROOT / "build" / "cutscene_subs"
OUT = ROOT / "build" / "patch" / VERSION
BIOS_NAME = f"Syscard3_galmuri_{VERSION}.pce"
BUNDLE = BUILD / "cdda17_adpcm_d000_frozen_8F20AF38.bundle.bin"
CDDA_ENGINE = BUILD / "engine_cdda_state3_poc.bin"
CDDA_INFO = BUILD / "engine_cdda_state3_poc.json"
AC_CDDA_TEMPLATE = 0x1FE800

# ★ 2026-09-04: CD-DA 스케줄러 연동용 정적 데이터.  **기본값 None = 꺼짐.**
#   켜지 않으면 번들도 armer 도 지금까지와 바이트까지 동일하다.
#
#   트랙 17 의 mini index 39 x 13 B 는 빌드 때 확정되므로 런타임 복사가 필요
#   없다 (ADPCM 이 복사하는 건 음성마다 항목이 달라서다).  여기에 행으로 실어
#   두면 뱅크 코드가 80 B 줄고, 스케줄러는 AC_SCHED.next 를 이 주소로 열기만
#   하면 된다.
#
#   ⚠ $1FEB00 은 AC 상단 자유 구간($1FEAA0-$1FFDBF, 약 4.8 KB) 안이다.
#     위쪽에서 실제로 쓰이는 것은 $1FFDC0 · $1FFFF0 (ac_readthrough) 둘뿐.
#     그래도 **런타임 무접촉은 아직 확인 전이다** -- lua/SUB/0.5.165 참고.
AC_CDDA_MINI = 0x1FEB00
CDDA_MINI_INDEX: Path | None = None       # BUILD / "cdda_track17_mini_index.bin"

# ★ 2026-09-04 밤: 전 트랙 연결.  **기본값 None = 꺼짐.**
#
#   트랙 17 하나만 붙이던 CDDA_MINI_INDEX(13 B/구간) 대신,
#   전 트랙 mini index(5 B/구간) + 트랙 디렉터리(16 B/트랙) 두 블롭을 싣는다.
#   vram 즉치는 구간이 아니라 **트랙**의 성질이라 디렉터리로 옮겼다 --
#   헬퍼가 무장 한 번에 저장/복원을 한 쌍만 하기 때문이다.
#   (ADPCM 의 디렉터리 9 B/음성 구조와 같다.  native_arm.py:328-331)
#
#   tools/build_cdda_mini_index_all.py --write 로 만든다.
# ★ 2026-09-05: $1FF900 -> $1FFA00.
#   트랙 3 을 이사 기록으로 되살리면서 구간이 710 -> 733 개가 됐고 mini 가
#   3,550 -> 3,665 B 로 늘어 $1FF900 을 81 B 넘겼다.  256 B 밀어 3,840 B 를 준다
#   (여유 175 B).  디렉터리 256 B 는 $1FFA00~$1FFAFF 로, AC 상단 자유 구간
#   ($1FEAA0-$1FFDBF) 안에 그대로 있다.
#   ⚠ lo 바이트가 $00 이라 디렉터리 색인(TXA + ASL x4, 최대 240)이 자리올림
#     없이 그대로 돈다 -- 옮길 때 이 성질을 깨지 말 것.
AC_CDDA_DIR = 0x1FFA00                    # mini index($1FEB00 + 3,665 B) 뒤
CDDA_MINI_ALL: Path | None = None         # BUILD / "cdda_mini_index_all.bin"
CDDA_TRACK_DIR: Path | None = None        # BUILD / "cdda_track_directory.bin"
CDDA_DIR_STRIDE = 16                      # build_cdda_mini_index_all.py 와 같아야 한다
CDDA_MINI_STRIDE = 5
# 렌더러 패딩 안 "지금 트랙 BCD" 자리.  코드(618 B) 뒤 · 매체 지문(+670) 앞.
# cdda_start 가 무장 때 심고, 스케줄러가 $20A2 와 비교한다.
CDDA_TRACK_BYTE_OFF = 660
# ★ 이사 기록 2 B 를 렌더러 패딩에 심는다 (인계서 §32).  0 이면 안 심는다.
CDDA_MOVE_BYTE_OFF = 0   # ★2026-09-06 이사 전면 폐기 (인계서 §36)

# CD-DA 전용 스케줄러가 심긴 CPU 주소.  None 이면 예전처럼 CD-DA 는 스케줄러를
# 통째로 건너뛴다 (엔진이 자기 타이머로 셌다).  주면 그 주소를 JSR 로 부른다.
# 심는 쪽은 tools/patch_bios_cdda_scheduler.py -- BANK1_FREE 밖 구간이다.
CDDA_SCHEDULER_AT: int | None = None      # 예: 0xECF9
# CD-DA ROM 상주판의 주소표. None이면 기존 슬롯형 경로를 바이트까지 보존한다.
CDDA_ROM_INFO: Path | None = None

CDDA_ACTIVE_SENTINEL = None
ACTIVE_RETURN = None
ACTIVE_BUILDER = None
PRECOPY_CPU = True
COMPLETE_DECISION = False
# 진단 전용. None이면 출하 코드와 바이트 동일. 값을 주면 ADPCM elapsed가
# 해당 프레임에 도달한 뒤 busy 비트를 무시하고 기존 2단 철거로 들어간다.
ADPCM_FORCE_RELEASE_AFTER_FRAMES: int | None = None
# ★ 2026-09-03: 무거운 arm 을 줄 24 가 아니라 $E424 훅(줄 160)에서 돌린다.
#   끄면 안전밸브(다음 FEC4)만 남아 지금까지의 동작으로 돌아간다 -- A/B 용.
# 2026-09-03: RCR 경로가 실패한다 (0.5.163 실측).
#   seq=0 인 프레임(=$E424 가 안 도는 프레임)만 안전밸브로 정상 arm 되고,
#   seq=2/3 인 프레임은 슬롯만 소비되고 STATE=1 이 안 온다 -- 검색이 miss 다.
#   $E424 호출 수가 장면마다 0/2/3 으로 달라 slot_index=2 가 줄 160 을 못 짚는다.
#   훅을 끄면 지연은 그대로 두고 **안전밸브만** 남아 자막이 살아난다.
DEFER_ARM = False

# 같은 ADPCM 엔진이 active AC 슬롯에 남아 있음을 증명하는 선택 기능.
# None이면 기존 번들/dispatcher를 바이트까지 그대로 만든다.
ADPCM_REUSE_SIGNATURE_OFFSET: int | None = None
ADPCM_REUSE_SIGNATURE: bytes | None = None


def _pass_a_text() -> str:
    """PASS A 판정 시각을 **지금 마스터에서 읽어** 쓴다.

    ★ 2026-09-05.  여기는 36.46/40.59/44.72 가 박혀 있었다.  그 값은 고정 타이머
      시절(0.4.6.23)의 것인데, 그 뒤로 소유자가 싱크를 다시 맞춰 실제 시각이
      36.091/40.916/44.552 로 옮겨갔다.  판마다 낡은 숫자가 따라 나가면 실기에서
      멀쩡한 것을 틀렸다고 판정하게 된다.  그래서 표에서 직접 읽는다.
    """
    tsv = ROOT / "snatcher_tool" / "translation" / "cdda_subtitles.tsv"
    try:
        raw = tsv.read_bytes()
        enc = "utf-16" if raw[:2] in (b"\xff\xfe", b"\xfe\xff") else "utf-8-sig"
        rows = [r for r in csv.DictReader(io.StringIO(raw.decode(enc)),
                                          delimiter="\t")
                if (r.get("track") or "").lstrip("0") == "17"
                and (r.get("ko_text") or "").strip()]
        rows.sort(key=lambda r: float(r.get("start_sec") or 0))
    except Exception as exc:                      # 표가 없거나 깨졌다
        return ("PASS A -- opening Track 17 CD-DA:\n"
                f"  ★판정 시각을 못 읽었다 ({exc}).  cdda_subtitles.tsv 를 볼 것\n")
    if len(rows) < 3:
        return ("PASS A -- opening Track 17 CD-DA:\n"
                "  ★트랙 17 에 한국어 구간이 3 개 미만이다\n")
    out = ["PASS A -- opening Track 17 CD-DA:"]
    for i, r in enumerate(rows[:3]):
        out.append(f"  {float(r['start_sec']):.3f}s  {r['ko_text'].strip()}")
    last = rows[2]
    end = float(last["start_sec"]) + float(last.get("duration_sec") or 0)
    out.append(f"  {end:.3f}s  그 줄이 사라진다")
    out.append(f"  (트랙 17 한국어 구간 {len(rows)} 개 · 마지막 "
               f"{float(rows[-1]['start_sec']):.3f}s)")
    return "\n".join(out) + "\n"


def sha(blob: bytes) -> str:
    return hashlib.sha256(blob).hexdigest().upper()


def make_bundle() -> bytes:
    adpcm_template = bytearray(preload.ENGINE.read_bytes())
    if ADPCM_REUSE_SIGNATURE_OFFSET is not None:
        signature = bytes(ADPCM_REUSE_SIGNATURE or b"")
        if not signature:
            raise SystemExit("ADPCM reuse signature가 비었다")
        if ADPCM_REUSE_SIGNATURE_OFFSET < len(adpcm_template):
            raise SystemExit("ADPCM reuse signature가 엔진 본문과 겹친다")
        need = ADPCM_REUSE_SIGNATURE_OFFSET + len(signature)
        if need > 671:
            raise SystemExit(f"ADPCM reuse signature가 671 B 슬롯을 넘는다: {need}")
        # ★ 2026-09-17: `need` 까지가 아니라 **슬롯 끝 671 B 까지** 채운다.
        #   출하 엔진은 653 B 인데 복사는 671 B 를 읽는다 -> 653~670 이
        #   **초기화 안 된 AC 쓰레기**로 실려 왔다.  그중 +670 은 CPU $5E1E 로
        #   가서 **매체 판정**(media_magic $CD)에 쓰인다 -- 하필 $CD 면 ADPCM 을
        #   CD-DA 로 오인한다.  0xFF 로 덮으면 그 축이 통째로 닫힌다.
        adpcm_template.extend(bytes((0xFF,)) * (671 - len(adpcm_template)))
        adpcm_template[ADPCM_REUSE_SIGNATURE_OFFSET:need] = signature
    rows = [
        (preload.AC_DIR, preload.DIR.read_bytes()),
        (preload.ac_payload(), preload.PAYLOAD.read_bytes()),
        (preload.AC_TEMPLATE, bytes(adpcm_template)),
        (AC_CDDA_TEMPLATE, CDDA_ENGINE.read_bytes()),
    ]
    # LBA master는 subtitle_pack preload 행에 $1E0000으로 같이 적재된다.
    # 스케줄러 연동을 켰을 때만 mini index 를 정적으로 싣는다 (2026-09-04).
    if CDDA_MINI_INDEX is not None:
        mini = CDDA_MINI_INDEX.read_bytes()
        if len(mini) % 13:
            raise SystemExit(f"mini index 가 13 배수가 아니다: {len(mini)} B")
        rows.append((AC_CDDA_MINI, mini))
    # 전 트랙 판.  트랙 17 전용판과 **동시에 켜지 않는다**.
    if CDDA_MINI_ALL is not None:
        if CDDA_MINI_INDEX is not None:
            raise SystemExit("CDDA_MINI_INDEX 와 CDDA_MINI_ALL 을 같이 켤 수 없다")
        if CDDA_TRACK_DIR is None:
            raise SystemExit("CDDA_MINI_ALL 을 켰으면 CDDA_TRACK_DIR 도 줘야 한다")
        mini = CDDA_MINI_ALL.read_bytes()
        tdir = CDDA_TRACK_DIR.read_bytes()
        if len(mini) % CDDA_MINI_STRIDE:
            raise SystemExit(
                f"mini index 가 {CDDA_MINI_STRIDE} 배수가 아니다: {len(mini)} B")
        if len(tdir) % CDDA_DIR_STRIDE:
            raise SystemExit(
                f"트랙 디렉터리가 {CDDA_DIR_STRIDE} 배수가 아니다: {len(tdir)} B")
        if AC_CDDA_MINI + len(mini) > AC_CDDA_DIR:
            raise SystemExit(
                f"mini index({len(mini)} B)가 디렉터리 자리 ${AC_CDDA_DIR:06X} 를 넘는다")
        rows.append((AC_CDDA_MINI, mini))
        rows.append((AC_CDDA_DIR, tdir))
    end = max(at + len(blob) for at, blob in rows)
    image = bytearray((0xFF,)) * (end - preload.AC_DIR)
    occupied: list[tuple[int, int]] = []
    for at, blob in rows:
        lo, hi = at - preload.AC_DIR, at - preload.AC_DIR + len(blob)
        if any(lo < old_hi and hi > old_lo for old_lo, old_hi in occupied):
            raise SystemExit(f"integrated bundle overlap at ${at:06X}")
        image[lo:hi] = blob
        occupied.append((lo, hi))
    BUNDLE.write_bytes(image)
    return bytes(image)


def patch_native_bios() -> tuple[int, str]:
    master = preload.MASTER.read_bytes()
    directory = preload.DIR.read_bytes()
    ad = json.loads(preload.ENGINE_INFO.read_text(encoding="utf-8"))
    cd = json.loads(CDDA_INFO.read_text(encoding="utf-8"))
    cdda = CDDA_ENGINE.read_bytes()
    rom = (json.loads(CDDA_ROM_INFO.read_text(encoding="utf-8"))
           if CDDA_ROM_INFO is not None else None)
    if cd["pack_sha256"] != sha(preload.PACK.read_bytes()):
        raise SystemExit("CD-DA engine is not paired with frozen 8F20AF38 pack")
    # 매체 지문.  두 세대를 다 받는다.
    #
    #   구세대 (자체 타이머 엔진)  timer 라벨 +602 의 $38(SEC).
    #     ADPCM 이 그 자리에 마침 $38 이 아니라는 **우연**에 기댄다
    #   신세대 (스케줄 연동 엔진)  media_magic_offset +670 의 $CD.
    #     ADPCM 길이(666) 뒤라 무장 코드가 반드시 $FF 로 덮는 자리다 -- 우연이 아니다
    if "media_magic_offset" in cd:
        sig_off = int(cd["media_magic_offset"])
        sig_val = int(cd["media_magic"])
        if len(cdda) <= sig_off or cdda[sig_off] != sig_val:
            raise SystemExit(f"CD-DA 매체 지문이 어긋났다: +{sig_off} 가 "
                             f"${sig_val:02X} 가 아니다")
        adpcm_bytes = ad["engine_bytes"]
        if adpcm_bytes > sig_off:
            raise SystemExit(
                f"ADPCM 렌더러({adpcm_bytes} B)가 지문 자리 +{sig_off} 를 덮는다.\n"
                "  build_subtitle_engine_cdda_scheduled.py 의 MEDIA_MAGIC_AT 을 올릴 것")
    else:
        sig_off = int(cd["labels"]["timer"])
        sig_val = 0x38
        if len(cdda) != 671 or cdda[sig_off:sig_off + 3] != bytes((0x38, 0xE9, 0x08)):
            raise SystemExit("CD-DA state3 engine timer signature drifted")

    offsets = ad["offsets"]
    selector_ac = native.AC_ENGINE + offsets["selector"]
    native.base.BUILD_ID = BUILD_ID
    # 2026-09-02: native ADPCM directory is 9 B per route.
    # The final three bytes are the per-voice VRAM immediates.  Treating this
    # as the old 6 B layout still lets the LBA lookup find a route, but leaves
    # the renderer/helper at the template's fixed $6600 base.
    emitter = native.make_armer(
        len(directory) // 9, selector_ac, ad["engine_bytes"],
        0x5B80 + offsets["ready"], 0x5B80 + offsets["selector"],
        0x5B80 + offsets["stage"], offsets["stage"],
        ad["stage_routine_bytes"],
        cdda_template_ac=AC_CDDA_TEMPLATE,
        cdda_engine_bytes=cd["engine_bytes"],
        cdda_signature_offset=sig_off,
        cdda_signature=sig_val,
        cdda_track_raw=0x11,
        cdda_active_sentinel=CDDA_ACTIVE_SENTINEL,
        # 스케줄러 연동 (2026-09-04).  셋 다 None/0 이면 옛 경로 그대로다.
        cdda_mini_ac=AC_CDDA_MINI if CDDA_MINI_INDEX is not None else None,
        cdda_mini_count=(CDDA_MINI_INDEX.stat().st_size // 13
                         if CDDA_MINI_INDEX is not None else 0),
        cdda_scheduler_at=CDDA_SCHEDULER_AT,
        # 전 트랙 (2026-09-04).  CDDA_MINI_ALL 을 켰을 때만.
        cdda_dir_ac=AC_CDDA_DIR if CDDA_MINI_ALL is not None else None,
        cdda_dir_count=(CDDA_TRACK_DIR.stat().st_size // CDDA_DIR_STRIDE
                        if CDDA_MINI_ALL is not None else 0),
        cdda_dir_stride=CDDA_DIR_STRIDE,
        cdda_track_byte_off=CDDA_TRACK_BYTE_OFF,
        cdda_move_byte_off=CDDA_MOVE_BYTE_OFF,
        # ★ CD-DA 렌더러의 즉치 오프셋.  ADPCM 것(imm_offsets)과 다르다.
        cdda_imm_offsets=((cd["labels"]["vram_base_hi_imm"],
                           cd["labels"]["pattern_base_lo_imm"],
                           cd["labels"]["pattern_attr_imm"])
                          if CDDA_MINI_ALL is not None else None),
        cdda_rom_entry=(int(rom["entry"], 16) if rom is not None else None),
        cdda_state_cpu=(int(rom["cdda_state_cpu"], 16) if rom is not None else None),
        cdda_ready_cpu=(int(rom["labels"]["ready"], 16) if rom is not None else None),
        cdda_blank_cpu=(int(rom["labels"]["blank"], 16) if rom is not None else None),
        cdda_count_cpu=(int(rom["labels"]["count"], 16) if rom is not None else None),
        cdda_track_cpu=(int(rom["track_bcd_cpu"], 16) if rom is not None else None),
        # 옛 BCD 트랙 비교(rc8)는 정상 무장까지 막아 Beetle/Mednafen에서
        # CD-DA 자막을 전멸시켰다. 새 판은 CD-DA 전용 AC 캐시 바로 뒤의
        # 재생 건 표식 하나만 본다. 게임 RAM $5E1F는 실제 쓰기 때문에 못 쓴다.
        cdda_replay_latch=None,
        cdda_done_latch_ac=((cdda_resident.AC_PLAYBACK_DONE
                             if rom is not None else None)),
        cdda_done_latch_value=cdda_resident.PLAYBACK_DONE_MAGIC,
        # rc13: 표식에 트랙을 실어 연속 재생으로 넘어온 다음 트랙을 구별한다.
        cdda_done_latch_track=(cdda_resident.sched.CD_SUBQ_RAW_TRACK
                               if rom is not None else None),
        cdda_imm_cpus=(tuple(int(rom["labels"][name], 16) for name in
                              ("imm_vram_hi", "imm_pat_lo", "imm_attr"))
                        if rom is not None else None),
        precopy_cpu=PRECOPY_CPU,
        complete_decision=COMPLETE_DECISION,
        imm_offsets=(offsets["vram_base_hi_imm"],
                     offsets["pattern_base_lo_imm"],
                     offsets["pattern_attr_imm"]),
        adpcm_reuse_signature_offset=ADPCM_REUSE_SIGNATURE_OFFSET,
        adpcm_reuse_signature=ADPCM_REUSE_SIGNATURE,
        adpcm_initial_delay=ad.get("initial_delay", False),
        adpcm_force_release_after_frames=ADPCM_FORCE_RELEASE_AFTER_FRAMES,
    )
    # ★ 지연 arm 을 실제로 굴리는 쪽.  $E424 의 2 번째 호출(줄 160)에서 돈다.
    # ★ 2026-09-03: 지연 arm 은 armer 에서 통째로 빠졌다 (기준 빌드를 0.4.6.72 로
    #   되돌리기로 했다 -- 소환은 오버클럭으로 닫는다).  되살리려면
    #   _archive/20260903_lba_repair_ab/armer_with_defer_*.py 를 되돌리고
    #   DEFER_ARM 을 True 로 한다.  base 의 RCR 상수/훅/rcr_tail 은 그대로 남아 있다.
    rcr_emitter = None
    # 2026-09-03: ADPCM 재생 진입점이 둘이라 훅도 둘이다.
    #   $E03C AD_PLAY  -> $F5F5   ADPCM RAM 재생      (예전부터 있던 훅)
    #   $E03F AD_CPLAY -> $F687   CD 스트리밍 재생    ★ 새로 건다
    # 자막이 안 뜨던 FFFF/오버사이즈 173 건은 전부 뒤쪽 경로였다.  디렉터리도
    # 팩도 이분 검색도 멀쩡했고, 감지 루틴을 **아예 안 탔다** (0.5.142/0.5.143).
    cplay_ret = native.base.HOOK_CPLAY_RET
    first, labels = native.base.build_dispatcher(
        native.base.BANK1_FREE_LO, native.AC_MASTER, len(master) // 9,
        extra_return=native.FEC4_RET, extra_builder=emitter,
        extra_return2=ACTIVE_RETURN, extra_builder2=ACTIVE_BUILDER,
        cplay_return=cplay_ret,
        rcr_return=native.base.HOOK_RCR_RET if DEFER_ARM else None,
        rcr_builder=rcr_emitter)
    code, labels = native.base.build_dispatcher(
        native.base.BANK1_FREE_LO, native.AC_MASTER, len(master) // 9, labels,
        extra_return=native.FEC4_RET, extra_builder=emitter,
        extra_return2=ACTIVE_RETURN, extra_builder2=ACTIVE_BUILDER,
        cplay_return=cplay_ret,
        rcr_return=native.base.HOOK_RCR_RET if DEFER_ARM else None,
        rcr_builder=rcr_emitter)
    if len(first) != len(code):
        raise SystemExit("integrated dispatcher two-pass mismatch")
    room = native.base.BANK1_FREE_HI - native.base.BANK1_FREE_LO + 1
    if len(code) > room:
        raise SystemExit(f"integrated dispatcher overflow: {len(code)}/{room}")

    bios = OUT / BIOS_NAME
    temp = OUT / (BIOS_NAME + ".tmp")
    native.base.patch_image(bios, temp, code, cplay_hook=True, rcr_hook=DEFER_ARM)
    image = bytearray(temp.read_bytes())
    temp.unlink()
    at = native.FEC4 - 0xE000
    if bytes(image[at:at + 3]) != native.FEC4_ORIG:
        raise SystemExit("FEC4 baseline mismatch after integrated patch")
    image[at:at + 3] = bytes((0x20, 0xD4, 0xFF))
    bios.write_bytes(image)
    (BUILD / "cdda17_adpcm_d000_dispatcher.bin").write_bytes(code)
    (BUILD / "cdda17_adpcm_d000_dispatcher.json").write_text(
        json.dumps({
            "version": VERSION,
            "bytes": len(code),
            "room": room,
            "free": room - len(code),
            "adpcm_hooks": {
                "ad_play": f"{native.base.HOOK:04X}",
                "ad_cplay": f"{native.base.HOOK_CPLAY:04X}",
                "rcr_defer": (f"{native.base.HOOK_RCR:04X}" if DEFER_ARM else None),
            },
            "defer_arm": DEFER_ARM,
            "cdda_template": f"{AC_CDDA_TEMPLATE:06X}",
            "cdda_media_signature_cpu": f"{0x5B80 + sig_off:04X}",
            "cdda_media_signature": f"{sig_val:02X}",
            "cdda_rom_resident": (rom is not None),
            "adpcm_reuse_signature_offset": ADPCM_REUSE_SIGNATURE_OFFSET,
            "adpcm_reuse_signature": (ADPCM_REUSE_SIGNATURE.hex().upper()
                                        if ADPCM_REUSE_SIGNATURE else None),
            "labels": {k: f"{v:04X}" for k, v in labels.items()},
        }, ensure_ascii=False, indent=2), encoding="utf-8")
    return len(code), sha(bytes(image))


def main() -> None:
    preload.VERSION = VERSION
    preload.BUILD_ID = BUILD_ID
    preload.OUT = OUT
    preload.BIOS_NAME = BIOS_NAME
    preload.BUNDLE = BUNDLE
    preload.make_bundle = make_bundle
    preload.patch_native_bios = patch_native_bios
    preload.main()

    manifest_path = OUT / "manifest.json"
    manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
    final_preload = json.loads((OUT / "bios_preload.json").read_text(encoding="utf-8"))
    manifest.update({
        "bios": BIOS_NAME,
        "bios_preload": final_preload,
        "purpose": "Lua-free integration of proven Track17 CD-DA and D000 ADPCM",
        "native_scope": {
            "cdda": "Track raw $11, c17_001 two lines, 2188/2435/2683f",
            "adpcm": "LBA $003083, three fragments, 0/90/180f",
        },
        "cdda_engine_sha256": sha(CDDA_ENGINE.read_bytes()),
        "cdda_template_ac": f"{AC_CDDA_TEMPLATE:06X}",
        "lua_required": False,
    })
    manifest_path.write_text(
        json.dumps(manifest, ensure_ascii=False, indent=2), encoding="utf-8")
    (OUT / "TEST_IN_MESEN.txt").write_text(
        f"{VERSION}\n\n"
        f"Power Cycle. Select {BIOS_NAME}, open the [KO] CUE.\n"
        "Do not load any state-changing Lua.\n\n"
        + _pass_a_text()
        + "\nPASS B -- ADPCM LBA $003083 (D000):\n"
        "  all three frozen-baseline fragments at 0/90/180 frames\n",
        encoding="utf-8")


if __name__ == "__main__":
    main()
