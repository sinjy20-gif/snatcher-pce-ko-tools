# SNATCHER 자막 네이티브 이식 정적 분석 — 2026-08-29

> **후속 런타임 상태:** 전체 Lua 전수시험은 접수처 정지로 아직 시작하지 못했다.
> `0.4.52a/b` 실패와 다음 분리 순서는
> `docs/handoff/SNATCHER_FULL_SUBTITLE_AUDIT_BLOCKED_2026-08-29.md`를 먼저 볼 것.

## 결론

현재 `0.4.48-fragment-wipe.lua`의 동작을 **그대로 디스크에 넣을 수 있는 상태는
아니지만, 네이티브 이식 경로는 성립한다.** 새로 처음부터 만들 필요는 없다.

기존 `0.4.6.11`에서 다음 골격을 재사용할 수 있다.

- 부팅 때 Track 24의 payload를 Arcade Card RAM에 적재하는 BIOS 로더
- `$601E -> $7F49` 상주 컨트롤러 호출점
- `$5B80-$5E1F`의 672 B 임시 엔진 영역
- AC `$1F1C00` helper와 `$1F1F00` renderer 슬롯
- 게임의 sprite push 루프 `$6463`
- 음성 종료를 `$180D` 상태로 판정하는 lifecycle
- bank 0 `$FFD4`에서 bank 1로 넘어가는 검증된 IRQ-safe 다리

새로 필요한 것은 네 덩어리다.

1. 실제 음성의 6 B 키를 콘솔에서 만드는 dispatcher
2. 해당 키의 최대 11개 조각을 mini index로 옮기는 코드
3. `$601E` 호출을 60 Hz 시계로 쓰는 16-bit 조각 scheduler
4. 음성 종료 때 한 프레임 기다렸다 VRAM을 복원하는 native cleanup

동적 allocator 전체와 Mesen 전용 Sprite RAM 직접 wipe는 네이티브로 그대로
옮기지 않는다. 첫 native 후보는 실측된 고정 VRAM `$1600-$1ABF`를 쓰고,
allocator는 충돌 진단용 Lua로 보존하는 편이 현실적이다.

---

## 1. 현재 Lua 체인이 실제로 하는 일

실행 진입점:

```text
lua/SUB/0.4.48-fragment-wipe.lua
  -> lua/SUB/0.4.45.lua
       -> lua/SUB/0.4.31.lua
       -> lua/SUB/0.3.43-defer.lua
```

### `0.4.31.lua`

- 호스트의 `subtitle_pack.bin`과 631 B 엔진을 AC RAM에 쓴다.
- Mesen의 `emu.getState()`와 `pceAdpcmRam`으로 실제 음성 6 B 키를 만든다.
- 팩의 1,950개 ADPCM 조각을 Lua table로 전부 읽어 둔다.
- 현재 음성에 해당하는 조각만 AC `$1EF000` mini index에 쓴다.
- Lua의 `endFrame`을 정확한 60 Hz 조각 타이머로 사용한다.
- 조각 경계에서 CPU selector를 바꾸고 `ready=0`을 쓴다.
- 기존 `0.4.6.11`의 한 음성짜리 gate를 열기 위해 `$22A6/$22A7/$22AA`를
  가짜 `E6800_0E`로 바꾼다.

### `0.4.45.lua`

- 팩과 엔진의 record/glyph 주소 짝을 검사한다.
- record Y를 `122`로 강제한다.
- 다음 조각에서 덮인 stage 루틴을 다시 써 넣는다.
- `0.3.43-defer` 동적 VRAM allocator를 켠다.
- 디스크가 선적재한 옛 팩/엔진 대신 호스트 파일을 AC에 다시 쓴다.

### `0.3.43-defer.lua`

- 음성/조각마다 BAT와 SATB를 스캔해 현재 참조되지 않는 19글자 블록을 고른다.
- 엔진의 VRAM/SAT pattern 피연산자 4 B를 런타임에 수정한다.
- 빌린 VRAM을 snapshot하고, SATB가 놓은 뒤 지연 복원한다.

### `0.4.48-fragment-wipe.lua`

- allocator의 `PATCHED base=$xxxx` **로그 문자열을 파싱**해 선택 주소를 안다.
- 조각 전환과 음성 종료 때 VRAM SATB와 Mesen 내부 Sprite RAM을 직접 스캔한다.
- 선택 블록을 가리키는 sprite 8 B를 0으로 지운다.

따라서 `0.4.48`은 단순 데이터 로더가 아니다. 음성 식별, 조각 선택, 프레임
타이밍, VRAM 선택, lifecycle, 하드웨어 밖의 Sprite RAM 직접 수정까지 Lua가
맡고 있다.

---

## 2. 정적 분석에서 새로 발견한 즉시 수정 사항

### 2.1 mini index 5조각 상한과 현재 팩이 맞지 않는다

현재 Lua/엔진 설정:

```text
SUB_VOICE_MINI_COUNT = 5
MINI_COUNT = 5
```

`0.4.31.lua`는 조각이 5개보다 많으면 아래 assert로 즉시 멈춘다.

```text
assert(#parts <= MINI_COUNT, 'mini index overflow: ' .. #parts)
```

그런데 2026-08-29 현재 팩은 다음과 같다.

```text
ADPCM 조각             1,950
ADPCM 음성 키            902
음성당 최대 조각           11

1조각 284키
2조각 292키
3조각 237키
4조각  84키
5조각   2키
7조각   2키
11조각  1키
```

상한을 넘는 실제 키:

```text
ADPCM_006010_FFFF_0E  FF FF 0E 08 8D 80   7조각
ADPCM_00359E_FFFF_0E  FF FF 0E 18 8A 0E  11조각
ADPCM_003677_FFFF_0E  FF FF 0E BD 51 88   7조각
```

그러므로 현재 `subtitle_pipeline PASS`는 **팩 구조/왕복/엔진 주소의 PASS**이지,
`0.4.48` 전수 실행 가능 PASS가 아니다. Lua 정주행 전에 mini 상한을 11로 올리고
검증기에 `max parts <= runtime mini count` 관문을 추가해야 한다.

AC 공간 문제는 없다.

```text
$1EF000-$1EF08E   11 × 13 B = 143 B
```

### 2.2 현재 진입점은 고정 경로가 아니라 allocator 경로다

`SNATCHER_PORTRAIT_FIXED_VRAM_2026-08-28.md`는 고정 `$1600-$1ABF`를 채택하고
allocator를 예비안으로 보존한다고 적었다. 하지만 실제 `0.4.48 -> 0.4.45` 체인은
`0.3.43-defer.lua`를 실행한다.

즉 현재 상태는 다음 두 사실을 구분해야 한다.

```text
문서상 출하 후보       고정 $1600-$1ABF
현재 채택 Lua 실험판   동적 allocator + fragment/end wipe
```

native 첫 판은 둘을 섞지 말고 고정 `$1600`으로 단순화한다. 실제 전수 플레이에서
충돌이 나오면 allocator 이식을 논의한다.

### 2.3 CD-DA 698개는 팩에만 있고 현재 런타임에는 연결되지 않았다

현재 팩:

```text
ADPCM 1,950조각 / 902키
CD-DA   698구간
```

`0.4.31/0.4.45/0.4.48` 체인은 ADPCM만 감지한다. CD-DA LBA selector나 timer는
없다. 따라서 네이티브 이식 완료의 범위를 다음처럼 나눠야 한다.

```text
1차  ADPCM 전체 키 + 다중 조각
2차  CD-DA LBA 구간
```

### 2.4 주소 정본이 서로 어긋나 있다

`tools/subtitle_layout.py`에는 아직 다음 옛 배치가 적혀 있다.

```text
engine $1F0000
free   $1F1C00
```

현재 Lua와 디스크 계열이 실제 사용하는 배치는 다음이다.

```text
pack       $1C0000
mini       $1EF000
helper     $1F1C00
renderer   $1F1F00
```

또 현재 `subtitle_vram_helper.json`은 VRAM `$7900` artifact인데,
`subtitle_layout.py`의 현재 상수는 `$1600`이다. native 빌더를 만들기 전에 실제
배치를 한 파일로 통합하지 않으면 옛 helper/renderer를 다시 싣는 사고가 난다.

---

## 3. 현재 메모리 예산

### Arcade Card RAM

현재 생성물 기준:

```text
pack       $1C0000-$1ECE6D   183,918 B
빈 간격    $1ECE6E-$1EEFFF     8,594 B
mini(11)   $1EF000-$1EF08E       143 B
빈 간격    $1EF08F-$1F1BFF    11,121 B
helper     $1F1C00-$1F1D3F       320 B (현재 슬롯 크기)
빈 간격    $1F1D40-$1F1EFF       448 B
renderer   $1F1F00-$1F2176       631 B
```

팩·mini·helper·renderer는 현재 크기에서 겹치지 않는다. Track 24 payload도 기존
89,598 B 팩 대신 183,918 B 팩을 싣는 것뿐이라 loader 구조를 바꿀 필요가 없다.

### CPU RAM

```text
$5B80-$5E1F   안전 엔진 영역 672 B
현재 엔진                    631 B
남음                          41 B

$7F49-$7FDF   상주 컨트롤러 151 B
현재 resident                151 B
남음                           0 B
```

현재 엔진을 `overlay_palette=False`로 메모리에서 재조립한 결과는 655 B였다.
이 변형은 palette 초기화 루틴을 stage와 겹치지 않으므로 Lua의 stage 재무장이
필요 없고, 17 B가 남는다. 현재 팩의 ADPCM 기록 최대 셀 수도 18이라 확인됐다.

### BIOS bank 1

실제 `0.4.6.11` BIOS에서 16 B 이상 연속 FF 구간을 다시 센 결과:

```text
$ECF9-$F04D     853 B
$F0EA-$FC76   2,957 B
$FC7A-$FFD9     864 B
$FFDD-$FFFF      35 B
```

상주부 151 B에 새 dispatcher/scheduler를 구겨 넣을 이유가 없다. 이미 reception
repair가 사용하는 bank 0 `$FFD4` -> bank 1 전환 다리를 확장해 위 공간에 큰
컨트롤러를 두는 것이 가장 안전하다.

---

## 4. 기능별 재사용 판정

| 기능 | 기존 0.4.6.11 | 현재 Lua | native 판정 |
|---|---|---|---|
| Track 24 -> AC 부팅 적재 | 있음 | 호스트 파일로 덮어씀 | 그대로 재사용, payload만 교체 |
| `$601E` 프레임 호출 | 있음 | resident/engine 호출에 사용 | 재사용 |
| VRAM 저장/복원 helper | 있음, 옛 주소 artifact | allocator가 주소 수정/지연 복원 | `$1600`으로 재빌드하고 종료 복원 1프레임 지연 |
| renderer/팩 조회 | 671 B 옛 엔진 | 631 B mini 엔진 | 631/655 B 계열 재사용 |
| 음성 시작 식별 | `E6800_0E` 한 개 | Mesen 6 B 키 | 새 native dispatcher 필요 |
| 효과음 제외 | 한 개 gate라 불완전 | 팩에 키 없으면 무개입 | dispatcher 검색 실패 = 무개입 |
| 조각 2..N 선택 | 옛 2조각 구조 | Lua timer + mini index | 새 16-bit scheduler 필요 |
| stage 재무장 | 없음 | exec callback으로 코드 복원 | 655 B engine 변형으로 제거 가능 |
| Y=122 강제 | 없음 | count_ok callback | 현재 팩 1,950개 전부 Y=122라 native에서는 불필요 |
| VRAM allocator | 없음 | BAT+SATB 스캔 | 첫 native 판에서는 제외 |
| 종료 wipe | 없음 | Mesen Sprite RAM 직접 0 | 1프레임 delayed restore로 대체 |
| CD-DA | 팩 선적재만 | 미연결 | ADPCM 뒤 별도 구현 |

---

## 5. 권장 native 구조

### 음성 시작

BIOS `AD_PLAY` 시작 직전에서:

1. `$22A6/$22A7` end와 `$22AA` rate를 읽는다.
2. ADPCM RAM `end/4`, `end/2`, `5*end/8` 세 바이트를 읽는다.
3. 정렬된 팩 ADPCM 색인에서 6 B 키를 찾는다.
4. 같은 키의 연속 항목을 최대 11개 `$1EF000` mini index로 복사한다.
5. 첫 9 B selector를 AC renderer 이미지에 쓴다.
6. 일치할 때만 subtitle state를 1로 만든다.

기존 `E6800_0E` 가짜 fingerprint와 `STZ $22A7` 우회는 제거한다. start hook이
음성당 정확히 한 번 실행되므로 008FA4 false trigger도 구조적으로 사라진다.

가장 먼저 실측해야 할 것은 2번이다. Mesen의 `pceAdpcmRam` 읽기는 소리를
건드리지 않지만, 실제 콘솔은 ADPCM 주소/데이터 포트를 사용한다. 반드시
**재생 명령을 내리기 전** 세 바이트를 읽고 원래 포인터/제어 상태가 보존되는지
단일 음성 POC로 확인한다.

### 조각 타이밍

기존 callflow 로그에서 자막 음성 동안 `$601E`/engine entry는 사실상 프레임마다
왔다. 미카 `D000` 음성도 engine entry 399회, rebuild/count_ok 3회로 끝까지
통과했다.

따라서 native scheduler는 `$601E` resident 경로에서:

1. 16-bit elapsed 증가
2. mini[next].start_frame과 비교
3. 경계에서 mini 9 B -> CPU selector 복사
4. `ready=0`
5. engine entry 호출

순으로 만들 수 있다. scheduler 코드는 bank 1에 두고, 소량의 elapsed/part
상태만 안전한 RAM에 둔다.

### 종료 cleanup

Mesen 내부 Sprite RAM은 실제 하드웨어에서 CPU가 같은 방식으로 직접 지울 수
없다. `0.4.48`의 64-slot 직접 scan/wipe를 이식 대상으로 잡으면 안 된다.

고정 `$1600`에서는 조각 전환 사이에 VRAM을 복원하지 않는다. 음성 종료 때:

```text
종료를 본 첫 $601E   자막을 push하지 않고 restore_pending만 세움
다음 $601E           게임 SATB가 자막을 놓은 뒤 VRAM $1600 백업 복원
```

이 한 프레임 지연이 `0.4.48`의 눈에 보이는 목적을 하드웨어 방식으로 대체한다.

---

## 6. 기능을 하나씩 붙이는 시험 순서

### 0단계 — Lua 전수시험 준비

- mini count 5 -> 11
- pipeline verifier에 음성당 최대 조각 관문 추가
- `0.4.48` 하나만 켜고 정주행
- 멈춤, 자막 누락, 화면 깨짐, allocator 침범 로그 수집

### 1단계 — 한 음성 native scheduler

대상:

```text
ADPCM_00309D_D000_0E
runtime key 00 D0 0E 43 77 90
3조각, 경계 90f / 180f
```

이 단계에서는 범용 키 검색을 하지 않는다. 빌드 때 이 3개 mini entry를 박고,
고정 `$1600`, native 16-bit scheduler, delayed restore만 검증한다.

통과 기준:

```text
Lua 0개
조각 1/2/3 각각 한 번
90f/180f 전환
음성 종료 뒤 게임 진행
다음 음성 정상
타이틀 복귀 정상
종료 순간 UI 조각 노출 없음
```

### 2단계 — 범용 ADPCM dispatcher

- AD_PLAY 직전 6 B 키 생성
- 1,950개 정렬 색인 검색
- 같은 키의 1..11개 연속 항목 mini 복사
- 팩에 없는 음성/효과음 완전 무개입
- 옛 `E6800_0E` gate 제거

### 3단계 — ADPCM 전체 팩

- 현재 902키/1,950조각 연결
- Lua 정주행 결과와 같은 장면을 비교
- 그 뒤에만 자동 디스크 빌더에 연결

### 4단계 — CD-DA

- CD 재생 LBA 시작 훅
- 698개 구간 탐색
- 별도 frame/LBA scheduler
- 기존 1섹터 overlap 네 쌍의 우선순위 규칙 확정

---

## 7. 다음 구현의 정확한 시작점

다음 코드는 전체 출하 빌더가 아니라 **1단계 전용 POC**여야 한다.

```text
기준 디스크       0.4.6.11
음성              Mika D000 한 개
VRAM              고정 $1600-$1ABF
팩/엔진           현재 v6 팩 + 631/655 B 계열
mini              3개 빌드 시 고정
scheduler         BIOS bank 1
호출              $601E resident 경유
종료              한 프레임 delayed restore
Lua               없음
```

이 POC가 성공하기 전에는 범용 6 B ADPCM RAM reader나 CD-DA를 한꺼번에 넣지
않는다. 실패했을 때 원인이 scheduler인지 키 reader인지 구분할 수 있어야 한다.
