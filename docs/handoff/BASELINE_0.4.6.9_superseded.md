# BASELINE — 대체됨 (결함 있음, 쓰지 말 것)

버전: `0.4.6.9`
확정일: 2026-08-27 → **같은 날 `0.4.6.10`으로 대체**
상태: **기준판 아님.** 리셋 결함 확인.

> **결함:** 일회성 가드가 아케이드 카드 포트3 주소 래치(`$1A32`)에 의존한다.
> 그 래치는 여러 코어에서 콘솔 리셋으로 지워지지 않아, 리셋 후 "이미 적재됨"으로
> 오판하고 선적재를 건너뛴다. AC 메모리는 비어 있으므로 번역이 사라진다.
> read-back을 구현하지 않은 코어에서는 반대로 무한 재적재가 되어 부팅에서
> 멈춘다. RetroArch Beetle PCE(PC·Android), Beetle SuperGrafx에서 재현됨.
>
> 수정판은 **`build/patch/0.4.6.10`** 이며 인계서는
> `docs/handoff/SNATCHER_AC_GUARD_FIX_2026-08-27.md` 다.
>
> 아래 내용 중 **접수처 복구 부분은 유효하다** — `0.4.6.10`이 같은 코드를
> 바이트 동일하게 물려받았고, 여기 적힌 런타임 합격 로그가 그 근거다.

이 폴더는 접수처 복구의 런타임 합격 기록으로 보존한다. 실행에는 쓰지 말 것.

---

## 합격 근거

```text
SUB 0.3.32 [1/4] guard window ptr=$3499  $66E5=20 D4 FF
SUB 0.3.32 [2/4] ARMED  $66F8=4C D4 FF  $66E5=20 40 5E
SUB 0.3.32 [3/4] repair entered at $66F8 on frame 4666
SUB 0.3.32 [4/4] REPAIR PASS: $2C00-$2DFF byte exact (2 frame(s) after arming)
SUB 0.3.32        hooks restored: $66E5=20 D4 FF $66F8=4C 3F 68
SUB 0.3.32        held byte exact for 180 frames after the repair
```

사용자 화면 확인: 접수처 액션 메뉴 정상 — "깨끗하다" (2026-08-27).

---

## AC 선적재 배치

| 항목 | AC 목적지 | 크기 |
|---|---:|---:|
| translation_all | `$000000` | 1,124,416 B |
| subtitle_pack | `$1C0000` | 89,598 B |
| subtitle_helper | `$1F1C00` | 320 B |
| subtitle_renderer | `$1F1F00` | 671 B |

합계 `1,215,005 B`.

BIOS 첫 유효 게임 CD_READ에서 네 페이로드를 한 번에 적재하고, 이후 장면에서
패치 페이로드 재적재는 없다. 일반 게임 장면 데이터의 CD 읽기는 정상적으로
계속 발생한다 — 이것은 제거 대상이 아니다.

부팅 시 약 1.2 MiB를 한 번에 읽으므로 시작할 때 긴 적재가 한 번 있다.

---

## 접수처 복구 (0.4.6.9에서 추가)

디스크 변경은 한 곳뿐. `$66F8`은 디스크상 원본이며 armed 상태에서만 런타임에 바뀐다.

```text
Track02 $66E5   20 D4 FF        JSR $FFD4   (원본 20 40 5E)
Track02 $66F8   4C 3F 68        원본 유지

BIOS bank0 $FFD4  08 78 A9 01 53 80   PHP / SEI / LDA #$01 / TAM #$80
BIOS bank1 $FFDA  4C 54 F0            dispatch로 착지
BIOS bank1 $F054  150 B               dispatch $F054 / repair $F08A
BIOS bank1 $F04E  53 80               TAM #$80 -> bank 0
BIOS bank0 $F050  68 28 60            PLA / PLP / RTS (기존 BIOS 바이트)
```

---

## SHA-256

```text
BIOS      F4DAC8EA0BD7BDAD64AC772C0BD3256F67AE4B06E04150ACEAF3F39BF00D2FF4
Track 02  0E056291FF6F7616154C268937D56F7C9F2F99C58A5FC53F4F800F88B095CAAE
Track 24  E580185BCBB01D9738C3F965C1C458E2E1729D3AE1E9F962B8C1B3311E4F8289
```

Track 01·03~23은 원본 그대로(하드링크).

---

## 재생산

```powershell
& 'C:\snatcher\_archive_2026-08-12\tools\python\python.exe' `
  'C:\snatcher\tools\build_snatcher_0_4_6_9.py'
```

---

## 관련 문서

```text
docs/handoff/SNATCHER_RECEPTION_FIX_2026-08-27.md      이 빌드의 인계서 (최신)
docs/handoff/SNATCHER_PRELOAD_RECEPTION_2026-08-27.md  폐기된 주장 포함, 위 문서로 대체
lua/SUB/0.3.32.lua                                     검증 스크립트
tools/build_snatcher_0_4_6_9.py                        빌더
tools/build_snatcher_0_4_6_0.py                        AC 선적재 본체 (기반)
```
