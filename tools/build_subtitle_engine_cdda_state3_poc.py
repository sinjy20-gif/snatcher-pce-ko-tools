#!/usr/bin/env python3
"""CD-DA 엔진이 **스스로 종료를 선언**하게 만든다 (BIOS decision 자리 회수용).

왜
--
BIOS `$FEC4` decision 창은 `$FF10` 부트 훅까지 76 B 뿐이고 73 B 가 차 있다.
그 73 B 의 25 B 가 `active` 분기 -- renderer 의 16-bit elapsed 를 **2,683 프레임**
과 비교하는 코드다.  그 숫자는 Track 17 오프닝 한 곡의 길이다.

    -> ADPCM 은 물론이고 **다른 CD-DA 트랙 하나만 늘어도 못 쓴다.**
    -> 자리를 회수하려고 옮기는 것이 아니라, 일반화하려면 나가야 하는 코드다.

무엇을 바꾸나 -- 3 바이트
------------------------
타이머는 이미 종료를 알고 있다.  `X` 는 0/1/2 구간 index 이고 문턱을 넘으면
`INX` 로 하나 올라간다.  즉 **`X == 3` 이 곧 "끝났다"** 이고 전용 분기까지 있다.

```
    CPX #$03 / BEQ timer_ret      (원래)   그냥 돌아갔다
    CPX #$03 / BEQ finish         (이 판)
  finish:  STX $7FDF                       X 가 이미 3 이다
  timer_ret: RTS                           기존 것으로 떨어진다
```

`LDA #$03 / STA $7FDF` (5 B) 가 아니라 **`STX $7FDF` 3 B** 다.  X 를 그대로 쓴다.
엔진의 남는 패딩이 정확히 3 B 이므로 **슬롯을 안 키운다.**

    이전 시안(§11.3)  슬롯 671 -> 704 · resident copy · 디스크 빌더 · ADPCM 렌더러까지
    이 판              엔진 3 B 뿐.  나머지 전부 손 안 댐

부작용 (의도된 것)
------------------
`elapsed` 가 3 B 밀려 `$5E1A` -> `$5E1D` 가 된다.  0.4.6.24 는 그 주소를 어서션으로
묶어 놨는데, 그것은 **BIOS 가 elapsed 를 읽었기 때문**이다.  이제 안 읽으므로
그 제약 자체가 사라진다.  새 디스크 빌더는 elapsed 주소를 요구하지 않는다.

출력은 별도 이름으로 낸다.  0.4.6.24 가 쓰는 `engine_cdda_track17_poc.bin` 은
**건드리지 않는다.**
"""
from __future__ import annotations

import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

import build_subtitle_engine as base            # noqa: E402
import build_subtitle_engine_cdda_track17_poc as t17   # noqa: E402

ROOT = Path(__file__).resolve().parents[1]
BUILD = ROOT / "build" / "cutscene_subs"
OUT = BUILD / "engine_cdda_state3_poc.bin"
INFO = BUILD / "engine_cdda_state3_poc.json"

STATE = 0x7FDF          # resident 의 상태 바이트.  3 = 복원 요청


def build_tail(origin: int, known: dict[str, int], ptr_second_lo: int,
               labels: dict[str, int] | None = None) -> tuple[bytes, dict[str, int]]:
    """t17.build_tail 과 동일하되 `X == 3` 에서 상태 3 을 직접 쓴다."""
    merged = dict(known)
    if labels:
        merged.update(labels)
    a = base.Asm(origin, merged)
    a.label("timer")
    # entry가 A=elapsed.hi로 들어온다. hi-$08은 0/1/2 세 구간의 index다.
    a.emit(0x38, 0xE9, t17.START_FIRST >> 8)      # SEC / SBC #$08
    a.branch(0x90, "timer_ret")                   # < 36 s
    a.emit(0xC9, 0x03)
    a.branch(0xB0, "timer_ret")                   # >= 45 s
    a.emit(0xAA)                                  # TAX: 0=첫 줄,1=둘째,2=끝
    a.abs_(0xAD, "elapsed")
    a.emit(0xDD); a.word("threshold_low")         # CMP low_table,X
    a.branch(0x90, "desired")
    a.emit(0xE8)                                  # 문턱을 넘었으면 다음 상태

    a.label("desired")
    a.emit(0xE0, 0x00); a.branch(0xF0, "timer_ret")
    a.emit(0xE0, 0x03); a.branch(0xF0, "finish")   # ★ 유일한 변경점
    a.emit(0xE0, 0x01); a.branch(0xF0, "first_line")

    # 둘째 줄. record_ptr의 low byte 자체를 phase 표식으로 쓴다.
    a.abs_(0xAD, known["record_ptr"])
    a.emit(0xC9, ptr_second_lo); a.branch(0xF0, "timer_push")
    a.emit(0xA9, ptr_second_lo); a.abs_(0x8D, known["record_ptr"])
    a.emit(0x4C); a.word(known["rebuild"])

    a.label("first_line")
    a.abs_(0xAD, known["ready"]); a.branch(0xD0, "timer_push")
    # stage 앞 31 B는 최초 한 번만 실행하는 팔레트 초기화 루틴이다.
    a.abs_(0x20, known["stage"])
    a.emit(0x4C); a.word(known["rebuild"])

    a.label("timer_push")
    a.emit(0x4C); a.word(known["push"])

    # ★ 종료 선언.  timer_push 는 JMP 라 여기로 흘러들지 않는다.
    #   X 가 3 이므로 상수를 싣지 않고 그대로 쓴다 (STX abs = 3 B).
    a.label("finish")
    a.abs_(0x8E, STATE)

    a.label("timer_ret")
    a.emit(0x60)
    a.label("threshold_low")
    a.emit(t17.START_FIRST & 0xFF, t17.START_SECOND & 0xFF, t17.END_SECOND & 0xFF)
    a.label("elapsed")
    a.emit(0x00, 0x00)
    return a.finish(), a.labels


def main() -> None:
    # 0.4.6.24 의 산출물을 덮지 않도록 출력 이름부터 갈아 끼운다.
    t17.build_tail = build_tail
    t17.OUT = OUT
    t17.INFO = INFO
    t17.main()

    image = OUT.read_bytes()
    if len(image) != t17.SLOT_BYTES:
        raise SystemExit(f"슬롯 크기가 틀렸다: {len(image)} != {t17.SLOT_BYTES}")
    # 변경점이 실제로 들어갔는지 본다 -- STX $7FDF = 8E DF 7F
    if bytes((0x8E, STATE & 0xFF, STATE >> 8)) not in image:
        raise SystemExit("STX $7FDF 가 이미지에 없다")
    print(f"  ★ STX ${STATE:04X} 삽입 확인 · 엔진이 스스로 state 3 을 쓴다")


if __name__ == "__main__":
    main()
