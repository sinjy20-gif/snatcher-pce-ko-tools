# BASELINE — BIOS AC 적재팩 완성본

버전: `0.4.6.10`
확정일: 2026-08-27
상태: **고정.** AC 선적재 + 접수처 UI 복구 + 리셋 내성까지 확인.

이전 기준판 `0.4.6.9`를 대체한다. `0.4.6.9`는 리셋 결함이 확인됐으므로 쓰지 말 것.

이 폴더의 파일은 수정하지 말 것. 다음 작업은 새 버전 폴더에서 한다.

---

## 확인된 것

| 항목 | 확인 | 방법 |
|---|---|---|
| AC 선적재 | O | 첫 부팅 긴 로딩 + 한글 표시 |
| 타이틀 화면 | O | 실행 확인 |
| 게임 진입 · 대사 | O | 실행 확인 |
| **리셋 후 재적재** | O | RetroArch Beetle PCE (PC), 리셋 후 다시 적재 |
| 접수처 액션 UI 복구 | 바이트 동일 | `0.4.6.9`에서 런타임 합격, 코드 바이트 동일함을 확인 |

접수처 복구는 `0.4.6.10`에서 런타임 재확인을 하지 않았다. 코드는 `0.4.6.9`와
바이트 동일하다. 한 번 더 닫고 싶으면 Mesen에서 `lua/SUB/0.3.32.lua`.

---

### 코어 호환 (2026-08-27, `0.4.6.10` 기준)

```text
Beetle SuperGrafx (Android)   O   <- 기준 코어
Geargrafx (Android)           O
Beetle PCE (PC)               O
Beetle PCE (Android)          X   원인 미규명. 배제 — 우리가 손댈 영역 아님
Beetle PCE Fast (Android)     X   미재확인 (0.4.6.9까지 실패)
Mesen                         기준 검증 환경
```

---

## `0.4.6.10`에서 고친 것 — 일회성 가드

`0.4.6.4`~`0.4.6.9`는 아케이드 카드 포트3 주소 래치(`$1A32`)에 매직을 써두고
그것을 되읽어 "이미 적재됨"을 판정했다. **그 래치는 페이로드와 아무 연결이
없고, 여러 코어에서 콘솔 리셋으로 지워지지 않는다.**

래치가 설명하는 것은 **소프트 리셋 후 선적재를 건너뛰는 증상**이다.

```
PC RetroArch Beetle PCE     리셋 후 로딩 없이 타이틀, 번역 없음
Android Beetle SuperGrafx   리셋 후 LOAD FAIL, 재적재 안 일어남
```

Android Beetle PCE의 부팅 실패는 **이것과 별개다.** 작업 중 같은 래치로
묶어 설명했으나, 래치를 제거한 `0.4.6.10`에서도 그 코어는 실패하므로
그 묶음은 반증됐다. 원인 미규명, 배제 대상.

`0.4.6.10`은 래치를 완전히 제거하고 **AC 메모리를 실제로 되읽는다.**

```text
A9 00 20 32 BF   LDA #$00 / JSR $BF32     포트0 -> AC $010000
A2 00            LDX #$00
AD 00 1A         LDA $1A00                AC에서 읽기
DD CE FF         CMP $FFCE,X              state_table과 대조
D0 08            BNE preload_needed
E8 E0 06 D0 F3   INX / CPX #6 / 반복

$FFCE            AC 15 51 00 01 02        state_table
```

게시 단계도 같은 테이블을 쓴다(`BD CE FF` / `8D 00 1A`). 가드가 보는 것과
그것을 참으로 만드는 것이 같은 6바이트라 둘이 어긋날 수 없다.

이 매직이 존재한다는 것은 **네 페이로드 적재가 전부 성공하고 게시까지 돌았다**와
동치다. 페이로드 이미지의 `$010000`은 `FF FF FF FF FF FF`이므로 부분 적재도
걸러진다. 리셋으로 AC가 비면 매직도 사라져 자동 재적재된다.

부수 변경: 캐이브가 280 B라 언롤을 루프로 압축했고, 코드가 40 B 늘며 범위를
벗어난 원거리 분기 두 개(`boot_done`, `restore_windows`)를 `JMP`로 바꿨다.

---

## AC 선적재 배치

| 항목 | AC 목적지 | 크기 |
|---|---:|---:|
| translation_all | `$000000` | 1,124,416 B |
| subtitle_pack | `$1C0000` | 89,598 B |
| subtitle_helper | `$1F1C00` | 320 B |
| subtitle_renderer | `$1F1F00` | 671 B |

합계 `1,215,005 B`. 부팅 시 한 번에 적재되고 이후 장면에서 패치 페이로드
재적재는 없다. 일반 게임 장면 데이터의 CD 읽기는 정상적으로 계속 발생한다.

---

## 접수처 복구 (0.4.6.9에서 도입, 그대로 유지)

```text
Track02 $66E5   20 D4 FF        JSR $FFD4   (원본 20 40 5E)
Track02 $66F8   4C 3F 68        원본 유지, armed일 때만 런타임 변경

BIOS bank0 $FFD4  08 78 A9 01 53 80   PHP / SEI / LDA #$01 / TAM #$80
BIOS bank1 $FFDA  4C 54 F0            dispatch로 착지
BIOS bank1 $F054  150 B               dispatch $F054 / repair $F08A
BIOS bank1 $F04E  53 80               TAM #$80 -> bank 0
BIOS bank0 $F050  68 28 60            PLA / PLP / RTS (기존 BIOS 바이트)
```

---

## 해시

```text
BIOS      sha256 4F0A0B0CFDC942BD5AD4463E73F9F9473D74EC472CB1C9CAA4F613E9499B1450
          md5    C3B9429941A7FF94778A181E8F921017
Track 02  sha256 0E056291FF6F7616154C268937D56F7C9F2F99C58A5FC53F4F800F88B095CAAE
Track 24  sha256 E580185BCBB01D9738C3F965C1C458E2E1729D3AE1E9F962B8C1B3311E4F8289
```

RetroArch는 BIOS를 파일명으로 찾는다. 시스템 폴더에 `syscard3.pce`로 넣고,
위 md5로 실제 로드되는 것이 이 빌드인지 확인할 것.

Track 01·03~23은 원본 그대로(하드링크).

---

## 재생산

```powershell
& 'C:\snatcher\_archive_2026-08-12\tools\python\python.exe' `
  'C:\snatcher\tools\build_snatcher_0_4_6_10.py'
```

---

## 관련 문서

```text
docs/handoff/SNATCHER_AC_GUARD_FIX_2026-08-27.md    이 빌드의 인계서 (최신)
docs/handoff/SNATCHER_RECEPTION_FIX_2026-08-27.md   접수처 복구 상세 (0.4.6.9)
lua/SUB/0.3.32.lua                                  접수처 검증 스크립트
tools/build_snatcher_0_4_6_10.py                    빌더
tools/build_snatcher_0_4_6_0.py                     AC 선적재 본체 (기반)
```
