#!/usr/bin/env python3
"""빌린 CPU RAM $5B80-$5E1E (671 B) 를 되돌려주는 코드를 BIOS 뱅크 $01 에 넣는다.

왜
--
자막 엔진이 게임의 스크립트 VM 데이터 스택 671 B 를 빌리고 **안 돌려준다**.
게임은 그 자리를 자기 데이터로 읽어가서 틀린 재료로 그린다 -- 챕터1~접수처
화면 파손의 진범이다.  자세한 것은
`docs/handoff/SNATCHER_CPU_CACHE_ROOT_CAUSE_2026-09-01.md`.

Lua 로는 `lua/SUB/0.5.105-no077.lua` 가 같은 일을 해서 오프닝 3 케이스와
접수처가 전부 정상임을 확인했다.  이 도구는 그것의 네이티브판이다.

어디에
------
케이브 `$FEC4` 는 껍데기이고 판정은 이미 뱅크 $01 에서 돈다
(`$FEC4 JSR $FFD4` -> `TAM #$80` -> `$FFDA JMP $F0EA` -> ... -> `$F370`).
그래서 새 트램폴린이 필요 없다.  뱅크 $01 안에서 이어 붙인다.

    $F760  A9 01 8D DF 7F   LDA #$01 / STA $7FDF   CD-DA 시작   5 B
    $F863  A9 01 8D DF 7F   LDA #$01 / STA $7FDF   ADPCM 시작   5 B
    $F370  AD DF 7F         LDA $7FDF              판정 진입    3 B

앞의 둘은 `JSR`(3) + `NOP NOP`(2), 뒤는 `JSR`(3) 로 **정확히 맞바꾼다.**
새 루틴은 `$FC7A-$FFD9` (864 B · JP 원본도 FF) 에 놓는다.

왜 이 순서로 되나
-----------------
상주부는 `$7F4F JSR $FEC4` 로 **먼저 판정을 묻고** `$7F5B` 에서 복사한다.
그래서 판정 안에서 뜨면 아직 게임 데이터다.

되돌리기는 슬롯 **밖**에서 해야 한다.  반납 STZ 가 `$5BEB`/`$5C3F` 로 슬롯
**안**이라, 헬퍼가 복원하면 실행 중인 자기 코드를 데이터로 갈아치워 죽는다
(Lua 0.5.105 첫 판이 BIOS 화면으로 튕겼다).  `$F370` 은 슬롯 밖이다.

플래그가 필요 없다 -- "슬롯에 헬퍼 서명($5B83 = $AD)이 남았나" 로 미반납을
판정한다.  되돌리면 게임 데이터가 서명을 덮으므로 다음엔 저절로 안 걸린다.

⚠ AC 채널
    저장/복원이 채널 0($1A00)의 포인터를 갈아치운다.  보존하지 않는다.
      · start_sub 뒤에는 PLA x25 / JMP $FA17 이 오고, 그 뒤 상주부가 $7F87 에서
        채널 0 을 통째로 다시 세운 다음 복사한다 -> 안전
      · entry_hook 뒤에는 판정이 이어지는데, 채널 0 을 쓰는 경로는 자기가
        직접 세운다 ($F3A3 처럼) -> 안전하다고 **보이지만 정적으로 증명 못 했다**
    회귀 테스트로 잡는다.  이상하면 여기부터 의심할 것.

⚠ `TAI $1A00,$5B80,#671` 서명을 쓰지 말 것 -- `0.4.6.47` 에 그것을 찾아 빌드를
   세우는 감사가 있다 (별개 계약).  페이지별 `LDA $1A00 / STA abs,X` 루프를 쓴다.
   상주부의 렌더러 복사($7FBB)와 같은 모양이라 검증된 패턴이기도 하다.

    python tools/patch_bios_cpu_cache.py 0.4.6.48            # 시늉만 (기본)
    python tools/patch_bios_cpu_cache.py 0.4.6.48 --write
"""
from __future__ import annotations

import argparse
import hashlib
import json
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "extraction" / "patch" / "static"))
from build_disc_patch import Assembler  # noqa: E402

ROM_CPU = 0xE000
BANK1_FILE = 0x2000                  # 뱅크 $01 의 파일 오프셋
CODE_CPU = 0xFC7A                    # 뱅크 $01 의 빈 자리

# ★★ 2026-09-18: `CODE_LIMIT = 0xFFDA` 는 **낡은 값이었다.**
#   그 시절엔 $FD1F 뒤가 비어 있었지만, 지금은 CD-DA ROM 렌더러가 **$FD1F 에
#   402 B** 로 앉아 있다 ($FD1F 가 `53 55 42` = "SUB" 서명으로 시작 · 402 B 중
#   FF 가 3 개뿐 -- 실물 확인).  지금 코드가 $FD1E 에서 딱 끝나 우연히 안 부딪혔다.
#
#   한 바이트만 늘려도 조용히 깨진다.  게다가 사슬 순서가 [6/8] cpu_cache ->
#   [7/8] cdda_rom_resident 라서, 넘치면 렌더러가 **우리 반납 꼬리를 덮는다**
#   (반대가 아니다).  반납이 잘리면 화면이 깨지는데 빌드는 성공한다.
#
#   그래서 한도를 따로 적지 않고 **렌더러 쪽 상수를 그대로 물어온다** -- 둘이
#   어긋날 수가 없게 한다 (상수 복제가 이 저장소의 상습 함정이다).
try:
    from build_subtitle_engine_cdda_rom import ROM_ORIGIN as _CDDA_ROM_ORIGIN
except Exception as _problem:                                    # noqa: BLE001
    raise SystemExit(
        "CD-DA ROM 렌더러 원점을 못 읽었다 -- 한도를 모르면 굽지 않는다: "
        f"{_problem}")
CODE_LIMIT = _CDDA_ROM_ORIGIN        # ★ 렌더러가 시작하는 자리가 곧 천장이다

STATE = 0x7FDF
# ★★★★ 2026-09-06 밤 -- **되돌렸다.**  `+0` 으로 옮겼다가 0.5.12 가 게임 시작부터
#   깨졌다 (접수처 텍스트 박스가 통째로 쓰레기.  실기 스크린샷).
#
#   왜 틀렸나 -- 게임이 `$5B80` 에 `$53` 을 **상시로 쓴다** (pc=$BE50, 한 주행 49 회,
#   frame 5165 부터 = 게임 초반).  그러면 `maybe_restore` 가 "아직 우리 것" 으로
#   오인해 **묵은 스냅샷을 살아 있는 게임 스택 위에 덮는다.**  CD-DA 뿐 아니라
#   ADPCM 음성마다 도는 경로라 게임 시작부터 터진다.
#
#       0.5.11  RESTORE  8 회
#       0.5.12  RESTORE 19 회   ★두 배 이상 -- 로그에 이미 나와 있었다
#
#   근거로 삼은 2.3.0 관측("게임은 +0 을 안 쓴다")은 **그 사건을 담을 수 없는
#   창**이었다.  0.5.11 은 STATE 가 02 에 굳어 복원이 아예 안 돌았고, 그래서
#   게임이 그 자리를 되쓰는 구간까지 간 적이 없었다.  §45-1 과 같은 실수다.
#
#   ⚠ 그러니 소유 표식은 **값이 아니라 1 회성 표식**이어야 하고, 그 표식은
#     슬롯 밖에 있어야 한다.  CD-DA 전용 설계(§49)가 그 방향이다.
#
# (아래는 되돌리기 전의 설명.  기록으로 남긴다.)
# ★★★★ 2026-09-06 밤 -- 소유 표식을 `+3` 에서 `+0` 으로 옮긴다 (인계서 §42-4 · §45-6).
#
#   있던 것   SLOT_SIG = $5B83 (+3) · HELPER_SIG = $AD   헬퍼 entry 첫 바이트
#
#   그런데 **게임이 방을 바꾸며 쓰는 33 B 가 `$5B81~$5BA1`(+1~+33)** 이라
#   그 안에 +3 이 들어 있다.  실측(2.1.0/2.2.0/2.3.0, 3 주행 모두):
#
#       무장 +2,122 프레임 = 35.37 초에 게임 pc=$8D8B 가 $5B83 <- B1
#       -> 서명 소멸 -> `maybe_restore` 가 "이미 반납됨" 으로 읽는다
#       -> 671 B 가 게임에 영영 안 돌아간다
#
#   `+0` 은 그 사정권 **밖**이다.  2.3.0 전수 관측:
#
#       $5B80 에 쓴 pc   EA9E(게임) frame 311~349 = 부팅 때뿐
#                        5BEB/5C3F(우리 헬퍼가 반납하며 00 을 쓴다)
#                        7FD9/FD19(복사·복원 루프)
#       트랙 3 구간(43,621~52,594) 내내 게임은 +0 을 한 번도 안 썼다
#
#   그리고 `+0` 은 **이미 소유 표식이다** -- 헬퍼가 반납할 때 `$5BEB`/`$5C3F`
#   에서 `$5B80 <- 00` 을 쓰고, 상주부 무장 경로도 `$7F5E` 에서 `#$53` 을 본다.
#   자기 청소 성질도 그대로다: 복원이 게임 데이터를 되쓰면 $53 이 아니게 된다.
#
#   ⚠ 남는 위험은 옛것과 같은 종류다 -- 게임 데이터가 우연히 그 자리에 $53 을
#     두면 "이미 우리 것" 으로 읽어 스냅샷을 건너뛴다 (1/256).  옛 $AD 와 동급.
#   ⚠ §41-6: 트랙 10(165 줄) 처럼 방이 더 많은 트랙에서 게임이 +0 을 쓰는지는
#     아직 안 쟀다.  전수 테스트 때 `lua/HQ/2.3.0-dispatch-gate.lua` 로 확인할 것.
SLOT_LO, SLOT_SIG = 0x5B80, 0x5B83
CPU_CACHE_BYTES = 671
AC_CACHE = 0x1F0E00
HELPER_SIG = 0xAD                    # 헬퍼 entry 첫 바이트 (LDA)

# 오프닝 스킵 감지 (2026-09-01 오전 확정값 · 0.5.102 와 같은 가드)
TRACK = 0x26F9                       # 재생 중인 트랙 (하위 7 비트)
CDDA_TRACK = 0x11
CDDA_SIG_ADDR = 0x5DDA               # CD-DA 서명
CDDA_SIG = 0x38
SKIP_INPUT = 0x222D                  # $8011 LDA $222D / AND #$0C / BEQ / JMP $8411

def labels_of_dispatcher() -> int:
    """디스패처 `extra` 레이블 = entry 훅 자리.  json 이 없으면 옛 상수."""
    info = ROOT / "build" / "cutscene_subs" / "cdda17_adpcm_d000_dispatcher.json"
    if info.is_file():
        try:
            return int(json.loads(info.read_text(encoding="utf-8"))["labels"]["extra"], 16)
        except Exception:
            pass
    return 0xF370


SITE_DEFAULTS = {
    "start_cdda": (0xF760, bytes((0xA9, 0x01, 0x8D, 0xDF, 0x7F))),
    "start_adpcm": (0xF863, bytes((0xA9, 0x01, 0x8D, 0xDF, 0x7F))),
    "entry": (0xF370, bytes((0xAD, 0xDF, 0x7F))),
}


def off1(cpu: int) -> int:
    """뱅크 $01 의 CPU 주소를 파일 오프셋으로."""
    return BANK1_FILE + (cpu - ROM_CPU)


def sha(blob: bytes) -> str:
    return hashlib.sha256(blob).hexdigest().upper()


def set_ac0(a: Assembler, address: int) -> None:
    """AC 채널 0 포인터를 address 로 세우고 자동증가를 켠다 (상주부 $7F87 과 같은 모양)."""
    a.emit(0xA9, address & 0xFF)
    a.abs(0x8D, 0x1A02)
    a.emit(0xA9, (address >> 8) & 0xFF)
    a.abs(0x8D, 0x1A03)
    a.emit(0xA9, (address >> 16) & 0xFF)
    a.abs(0x8D, 0x1A04)
    a.emit(0xA9, 0x01)
    a.abs(0x8D, 0x1A07)
    a.abs(0x9C, 0x1A08)
    a.emit(0xA9, 0x11)
    a.abs(0x8D, 0x1A09)


def build_code() -> tuple[bytes, dict[str, int]]:
    a = Assembler(CODE_CPU)

    # ---- start_sub : 빌리기 직전에 671 B 를 AC 로 뜬다 ----
    a.label("start_sub")
    # ★ 슬롯이 이미 우리 것이면 뜨지 않는다.  음성이 반납 없이 연달아 나면
    #   우리 코드를 게임 데이터인 줄 알고 떠서 나중에 쓰레기를 되돌리게 된다.
    #   (Lua 0.5.105 의 "뜨기 건너뜀 -- 슬롯이 이미 우리 것이다" 와 같은 가드)
    a.abs(0xAD, SLOT_SIG)
    a.emit(0xC9, HELPER_SIG)
    a.branch(0xF0, "start_done")
    set_ac0(a, AC_CACHE)
    # TIN: src 증가 · dst 고정.  0.8 POC 와 같다.  한 방에 671 B.
    a.emit(0xD3)
    a.word(SLOT_LO)
    a.word(0x1A00)
    a.word(CPU_CACHE_BYTES)
    a.label("start_done")
    a.emit(0xA9, 0x01)                      # 원래 명령
    a.abs(0x8D, STATE)
    a.emit(0x60)                            # RTS

    # ---- entry_hook : 판정 진입 ----
    #  state 0 -> 미반납이면 되돌린다
    #  state 2 -> CD-DA 인데 스킵 입력이 들어왔으면 종료를 요청한다 (2 -> 3)
    a.label("entry_hook")
    a.abs(0xAD, STATE)
    a.branch(0xF0, "maybe_restore")
    a.emit(0xC9, 0x02)
    a.branch(0xD0, "entry_done")            # 1 이나 3 이면 통과

    # ★ 스킵 감지.  `$8411` 은 RAM 오버레이라 BIOS 에서 훅을 못 건다.  그래서
    #   게임이 보는 것과 **같은 입력 조건**을 본다 ($8011 LDA $222D / AND #$0C).
    #   가드는 0.5.102 와 같다: track $11 · state $02 · signature $38.
    #   이것이 없으면 이른 스킵에서 엔진이 state 2 에 갇혀 반납이 영영 안 온다
    #   (0.4.6.59 실측: 스킵 뒤 state 0 도 복원도 오지 않았다).
    a.abs(0xAD, TRACK)
    a.emit(0x29, 0x7F)
    a.emit(0xC9, CDDA_TRACK)
    a.branch(0xD0, "entry_done")
    a.abs(0xAD, CDDA_SIG_ADDR)
    a.emit(0xC9, CDDA_SIG)
    a.branch(0xD0, "entry_done")
    a.abs(0xAD, SKIP_INPUT)
    a.emit(0x29, 0x0C)
    a.branch(0xF0, "entry_done")
    a.emit(0xA9, 0x03)                      # 종료 요청
    a.abs(0x8D, STATE)
    a.branch(0x80, "entry_done")

    a.label("maybe_restore")
    a.abs(0xAD, SLOT_SIG)
    a.emit(0xC9, HELPER_SIG)
    a.branch(0xD0, "entry_done")            # 서명이 없으면 이미 반납됨
    a.abs(0x20, "restore")
    a.label("entry_done")
    a.abs(0xAD, STATE)                      # 원래 명령의 결과를 그대로 돌려준다
    a.emit(0x60)

    # ---- restore : AC -> $5B80  671 B ----
    # TAI $1A00 은 금지(감사 서명).  상주부 렌더러 복사($7FBB)와 같은 페이지 루프.
    a.label("restore")
    set_ac0(a, AC_CACHE)
    # ★★ 2026-09-18: 마지막 덩이를 **159 -> 157** 로 줄인다.  코드 크기는 그대로
    #   (`CPX #` 즉치만 바뀐다) -- 이 구간은 여유가 **0 B** 라 늘릴 수가 없다
    #   ($FD1F 부터 CD-DA ROM 렌더러 402 B).
    #
    #   157 이면 $5D80~$5E1C 까지만 되돌리고 **$5E1D·$5E1E 는 손대지 않는다.**
    #
    #     $5E1D  ADPCM 엔진 재사용 표식.  적재가 템플릿에서 실어 온 값이 남아야
    #            다음 arm 이 671 B 복사를 건너뛴다.  반납이 덮으면 영원히 miss 다
    #            (0.7.25 가 정확히 그래서 hit 0 이었다)
    #     $5E1E  media_magic ($CD)
    #
    #   ⚠ 동작하는 매체 판정을 건드리는 것처럼 보이지만 **아니다.**
    #     `lua/SUB/0.5.179-magic-read-order.lua` 로 읽기와 **직전 쓰기**를 짝지어
    #     실측했다 (3,600 프레임 · 반납 9 회):
    #
    #       $5E1E  $FC49 <- 적재($7FD9)  2,705    ← 매체 판정은 **적재 뒤에만** 읽는다
    #       $5E1E  $F3F6 <- 적재($7FD9)  2,705
    #       $5E1E  $FCA4 <- 반납($FD19)      8    ← 저장(빌리기) 쪽의 단순 복사뿐
    #       $5E1D  $FCA4 <- 반납($FD19)      8    ← 같은 저장 쪽
    #       $5E1D  $F67E <- 반납($FD19)      8    ← 우리 재사용 검사 자신
    #       -> **게임 읽기 0.**  반납된 값을 보는 놈이 없다 = 관측상 무변화
    #
    #   ⚠ 남은 한계: 위 실측은 **한 장면**이다.  꼬리 소유권 지도
    #     ($5E1A CDDA_STATE · $5E1B TRACK_BCD · $5E1C 엔진 · $5E1F 는 게임)와
    #     맞물려 정황은 강하지만, 다른 장면에서 게임이 $5E1D·$5E1E 를 읽는다면
    #     그 두 바이트가 영구히 게임에게 안 돌아간다.
    for page, (dst, count) in enumerate(((0x5B80, 256), (0x5C80, 256), (0x5D80, 157))):
        a.emit(0xA2, 0x00)                  # LDX #0
        loop = f"r{page}"
        a.label(loop)
        a.abs(0xAD, 0x1A00)                 # LDA $1A00
        a.abs(0x9D, dst)                    # STA dst,X
        a.emit(0xE8)                        # INX
        if count != 256:
            a.emit(0xE0, count)             # CPX #count
        a.branch(0xD0, loop)
    a.emit(0x60)

    return a.finish(), a.labels


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("version", help="예: 0.4.6.48")
    ap.add_argument("--write", action="store_true", help="실제로 쓴다 (기본은 시늉만)")
    ap.add_argument("--out", help="다른 파일로 저장 (기본은 제자리)")
    args = ap.parse_args()

    src = ROOT / "build" / "patch" / args.version / f"Syscard3_galmuri_{args.version}.pce"
    if not src.exists():
        raise SystemExit(f"BIOS 가 없다: {src}")
    image = bytearray(src.read_bytes())
    before = sha(bytes(image))

    code, labels = build_code()
    end = CODE_CPU + len(code)
    if end > CODE_LIMIT:
        raise SystemExit(f"코드가 넘친다: {len(code)} B > {CODE_LIMIT - CODE_CPU} B")

    # ---- 1. 빈 자리인가 ----
    at = off1(CODE_CPU)
    room = bytes(image[at:at + len(code)])
    if room != b"\xFF" * len(code):
        bad = sum(1 for b in room if b != 0xFF)
        raise SystemExit(f"${CODE_CPU:04X} 가 비어 있지 않다 (FF 아닌 바이트 {bad}개)")

    # ---- 2. 끼울 자리를 **찾는다** (주소를 못박지 않는다) ----
    #
    # 2026-09-02: 디스패처가 커지면(D000 일반화로 2386 -> 2415 B) 이 자리들이
    # 통째로 밀린다.  예전에는 $F760 / $F863 을 상수로 들고 있어서 그때마다
    # "start_cdda 가 다르다" 로 죽었다.  패턴이 유일하므로 찾아 쓴다.
    #
    #     슬롯형 판: start_cdda / start_adpcm 이 정확히 2 개
    #     ROM CD-DA판: CD-DA는 전용 상태를 직접 쓰므로 start_adpcm 1 개만 남는다
    #     entry                      AD DF 7F         디스패처 `extra` 레이블
    bank = bytes(image[off1(0xE000):off1(0xE000) + 0x2000])
    want5 = SITE_DEFAULTS["start_cdda"][1]
    found = []
    # ★ 여기서 `at` 을 쓰지 말 것 -- 위에서 잡아 둔 코드 자리다.  2026-09-02 에
    #   이 루프가 그것을 덮어 `image[-1:...] = code` 가 되면서 코드가 제자리
    #   대신 파일 끝에 끼워졌다 (BIOS 가 165 B 커지고 $FC7A 는 FF 로 남았다).
    scan = bank.find(want5)
    while scan >= 0:
        found.append(0xE000 + scan)
        scan = bank.find(want5, scan + 1)
    dispatcher_info = ROOT / "build" / "cutscene_subs" / "cdda17_adpcm_d000_dispatcher.json"
    dispatcher = (json.loads(dispatcher_info.read_text(encoding="utf-8"))
                  if dispatcher_info.is_file() else {})
    rom_cdda = bool(dispatcher.get("cdda_rom_resident"))
    expected = 1 if rom_cdda else 2
    if len(found) != expected:
        raise SystemExit(
            f"state 기록 자리가 {len(found)} 개다 ({expected} 개여야 한다): "
            + ", ".join(f"${x:04X}" for x in found))
    if rom_cdda:
        # ROM판에서 남은 유일한 STATE=1은 native armer의 ADPCM 성공 경로다.
        SITES = {
            "start_adpcm": (found[0], want5),
            "entry": (labels_of_dispatcher(), SITE_DEFAULTS["entry"][1]),
        }
    else:
        SITES = {
            "start_cdda": (found[0], want5),
            "start_adpcm": (found[1], want5),
            "entry": (labels_of_dispatcher(), SITE_DEFAULTS["entry"][1]),
        }

    for name, (cpu, want) in SITES.items():
        got = bytes(image[off1(cpu):off1(cpu) + len(want)])
        if got != want:
            raise SystemExit(
                f"{name} ${cpu:04X} 가 다르다: {got.hex(' ').upper()} != {want.hex(' ').upper()}")

    # ---- 3. 패치 ----
    patches: dict[str, str] = {}
    for name in ("start_cdda", "start_adpcm"):
        if name not in SITES:
            continue
        cpu, want = SITES[name]
        blob = bytes((0x20, labels["start_sub"] & 0xFF, labels["start_sub"] >> 8, 0xEA, 0xEA))
        image[off1(cpu):off1(cpu) + len(want)] = blob
        patches[name] = f"${cpu:04X} {want.hex(' ').upper()} -> {blob.hex(' ').upper()}"
    cpu, want = SITES["entry"]
    blob = bytes((0x20, labels["entry_hook"] & 0xFF, labels["entry_hook"] >> 8))
    image[off1(cpu):off1(cpu) + len(want)] = blob
    patches["entry"] = f"${cpu:04X} {want.hex(' ').upper()} -> {blob.hex(' ').upper()}"

    image[at:at + len(code)] = code

    # ---- 4. 금지 서명이 안 들어갔나 ----
    for size in (653, CPU_CACHE_BYTES):
        sig = bytes((0xF3, 0x00, 0x1A, 0x80, 0x5B, size & 0xFF, size >> 8))
        if sig in bytes(image):
            raise SystemExit(f"금지된 TAI $1A00,$5B80,#{size} 서명이 들어갔다")

    print(f"BIOS      {src}")
    print(f"코드      ${CODE_CPU:04X}-${end - 1:04X}   {len(code)} B / {CODE_LIMIT - CODE_CPU} B")
    for name, addr in sorted(labels.items(), key=lambda kv: kv[1]):
        print(f"  {name:<12} ${addr:04X}")
    print("패치")
    for name, txt in patches.items():
        print(f"  {name:<12} {txt}")
    print(f"sha256    {before[:16]} -> {sha(bytes(image))[:16]}")

    if not args.write:
        print("\n시늉만 했다.  실제로 쓰려면 --write")
        return
    dst = Path(args.out) if args.out else src
    dst.write_bytes(bytes(image))
    info = dst.with_suffix(".cpu_cache.json")
    info.write_text(json.dumps({
        "source_sha256": before, "output_sha256": sha(bytes(image)),
        "code_cpu": f"{CODE_CPU:04X}", "code_bytes": len(code),
        "labels": {k: f"{v:04X}" for k, v in labels.items()},
        "patches": patches, "cpu_cache": f"{SLOT_LO:04X}+{CPU_CACHE_BYTES}",
        "ac_cache": f"{AC_CACHE:06X}",
    }, ensure_ascii=False, indent=2), encoding="utf-8")
    print(f"\n썼다: {dst}\n정보: {info}")


if __name__ == "__main__":
    main()
