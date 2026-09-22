# SNATCHER 전체 자막 Lua 전수시험 — 접수처 정지 인계서 (2026-08-29)

## 0. 결론

`902키 / 1,950조각` 전체 자막을 Lua로 연결해 정주행하는 시험은 **아직 시작할
수 없는 상태**다. 최신 시험판 `0.4.52b-full-subtitle-audit`도 접수처에서 멈췄다.

오늘 두 가지 가설을 제거했지만 정지는 그대로였다.

1. 자막이 없는 음성에서 allocator가 먼저 무장하는 문제를 제거했다.
2. MISS 동안 옛 `E6800_0E` BIOS gate를 임시 차단하고 반환 직전에 원값을
   복원했다.

둘 다 적용된 마지막 실행에서도 실제 첫 접수처 자막 키에 도달하지 못했다.
따라서 현재 정지를 allocator나 특정 자막 조각의 문제로 단정하면 안 된다.
다음 작업은 **같은 디스크·같은 세이브에서 Lua 0개 기준판부터 이분해야 한다.**

현재 `lua/SUB/0.4.52-full-subtitle-audit.lua`는 실패 재현판이다. 전수검증용으로
계속 플레이하지 말 것.

### 후속 확인 (기준판 PASS)

같은 `0.4.6.12-dialogue-hunt`·같은 세이브에서 **SUB Lua를 하나도 실행하지
않고 접수처 정상 진행을 확인했다.** 따라서 디스크/BIOS/세이브는 기준 조건에서
정상이며, 정지 범위는 `0.4.52`가 불러오는 Lua 통합 체인 안으로 좁혀졌다.

다음 시험용으로 `lua/SUB/0.4.53-readonly-key-audit.lua`를 만들었다. 이 파일은
memory exec callback을 등록하지 않고, 게임 RAM·AC·VRAM·Sprite RAM write가
0 B다. `endFrame`에서 Mesen 상태와 ADPCM RAM을 읽어 6 B 키만 TSV로 기록한다.

후속 런타임도 **정상 진행**했다. 관측 순서는 다음과 같다.

```text
MISS 00600EE48B98  0조각
MISS 00A00E8022A8  0조각
KEY  00680E2A1321  2조각
KEY  00580E298008  1조각
KEY  00D00E437790  3조각
```

따라서 Mesen 상태/ADPCM RAM 읽기, 6 B 키 생성, 902키 lookup은 무죄다. 다음
분리판은 `lua/SUB/0.4.54-ac-upload-only.lua`이며, 팩과 631 B 엔진을 AC에 쓰는
동작만 검사한다.

`0.4.54-ac-upload-only.lua`도 접수처 **정상 진행**을 확인했다. 따라서 AC에
정본 팩과 631 B 엔진을 올리는 동작도 무죄다. 다음 분리판은
`lua/SUB/0.4.55-fec4-readonly.lua`이며, 같은 AC 업로드에 `$FEC4` 읽기 전용
callback만 추가한다.

`0.4.55-fec4-readonly.lua`도 접수처 **정상 진행**을 확인했다. 실제 관측 키는
`6000 -> A000 -> 6800 -> 5800 -> D000`이었고 모든 진입에서 state는 00이었다.
따라서 AC 업로드와 `$FEC4` callback 등록/읽기도 무죄다. 세 번째 실제 키
`00680E2A1321`이 옛 native gate 조건 `0068_0E`와 정확히 겹치므로, 다음 판
`0.4.56-fec4-transition-audit.lua`는 매 `$FEC4`에서 emulator actual key와 게임
RAM gate key를 동시에 읽어 전환 첫 호출의 어긋남 여부를 측정한다.

`0.4.56`도 정상 진행했다. `6800` 시작의 결정적 두 호출은 다음과 같았다.

```text
call 4091  actual=00680E2A1321  gate=00680E2A1321  state=00
call 4092  actual=00680E2A1321  gate=00000E000000  state=02
```

첫 호출에서 actual/gate가 정확히 일치했고, native BIOS가 `$22A7`을 소비한 다음
state 02로 정상 진입했다. 이후 게임도 정상 진행했다. 따라서 전환 키 불일치와
state 02 자체는 원인이 아니다. 다음 판 `0.4.57-controller-only.lua`는 allocator,
wipe, Y 보정, stage 재무장을 모두 빼고 KEY 성공 시 mini/selector/gate를 쓰는
controller만 시험한다.

`0.4.57-controller-only.lua`에서는 `OK:3 / MISS:2`까지 갔고, 미카 D000의
2번째 조각 `오퍼레이터를 맡고 있는 미카`가 정상 표시된 화면에서 정지했다.
로그상 Lua timer는 `PART 2/3 at 90f`, `PART 3/3 at 180f`까지 모두 공급했지만
화면은 2번째 조각에 남았다.
따라서 전체 키 controller의 매칭, mini 준비, selector, gate, 첫 출력과 2조각
전환까지는 성공했다. 이 판은 의도적으로 stage 재무장을 뺐으므로, 첫 rebuild가
임시 stage 루틴을 글리프 데이터로 덮은 뒤 다음 호출이 그 데이터를 코드로 실행한
기존 다중 조각 정지와 일치한다. 다음 판 `0.4.58-controller-stage.lua`는 0.57에
stage 재무장만 추가하고 allocator/wipe/Y 보정은 계속 제외한다.

`0.4.58-controller-stage.lua`는 정상 통과했다. 6800의 2번째 조각과 D000의
2·3번째 조각 직전에 각각 `$5D77`의 31 B stage 루틴을 복원했고 총 3회
`STAGE REARM`이 발생했다. 미카 3조각 표시와 이후 게임 진행 모두 정상이다.
따라서 controller, 전체 키, Lua timer, multi-fragment 생명주기는 stage 재무장을
포함하면 정상이다. 다음 판 `0.4.59-controller-stage-allocator.lua`는 이 정상
경로에 matched-only allocator만 추가하고 wipe/Y 보정은 제외한다.

`0.4.59-controller-stage-allocator.lua`도 정상 통과했다. MISS 두 건에는 allocator
무장이 없었고, 세 KEY에서만 `armed key=`와 `PATCHED`가 발생했다. 6800은
`$1600->$1A00`, 5800은 `$1600`, D000은 `$1600->$1A80->$2BC0`을 선택했고
stage 재무장 3회와 이후 게임 진행이 정상이다. wipe를 뺀 판이라 음성 종료 때
옛 SATB 참조가 남아 `$1600/$1A80은 게임이 가져갔다 -- 복원하지 않는다`가
나온 것은 예상 범위다. 다음 판 `0.4.60-full-stack.lua`는 이 정상 체인 위에
0.4.48 fragment/end wipe만 추가한다.

`0.4.60-full-stack.lua` 로그에서는 fragment wipe 3회, end wipe 3회가 발생했고
VRAM SATB/Sprite RAM 슬롯 수가 매번 일치했으며 write failure는 0이었다. 마지막
`$2BC0`은 음성 종료 4프레임 뒤 복원됐다. `$1600/$1A80은 게임이 가져갔다`는
게임이 그 VRAM 내용을 다시 쓴 경우 옛 백업으로 덮지 않는 allocator의 보수적
DROP 판정이다. 사용자가 이전의 찰나 UI 패턴 깨짐도 이번에는 보이지 않는다고
확인했다.

실패한 `0.4.52` 대신 새 전수시험 기준판은
`lua/SUB/0.4.61-full-subtitle-audit.lua`다. 검증된 0.60 체인은 바꾸지 않고
KEY/MISS/PART/ARM/PATCH/STAGE/WIPE/RESTORE/DROP만 TSV에 기록한다.

첫 `0.4.61` 실행도 정상 통과했고 TSV에는 KEY 3, MISS 2, PART 3, PATCH 6,
WIPE 6, DROP 5, RESTORE 1이 기록됐다. 로드 배너의 `STAGE REARM ONLY`를 실제
STAGE로 잘못 센 1건을 수정하여 파일 표시 버전을 `0.4.61a`로 올렸다. 또한
1,950조각 전수시험의 속도와 로그 크기를 위해 allocator의 +01/+02/+04/+08/
+16/+30 상세 SATB 출력만 껐다. allocator 선택·PATCH·DROP·RESTORE 기록과 실제
동작은 그대로다.

---

## 1. 시험 환경과 정본 데이터

```text
게임 빌드   build/patch/0.4.6.12-dialogue-hunt
CUE          Snatcher CD-ROMantic (Japan) [KO].cue
BIOS         Syscard3_galmuri_0.4.6.12-dialogue-hunt.pce
자막 팩      build/cutscene_subs/subtitle_pack.bin
런타임 표    build/cutscene_subs/subtitle_runtime_key_map.tsv
팩 규모      183,918 B / 902 runtime keys / 1,950 fragments
최대 조각    11
Lua 진입점   lua/SUB/0.4.52-full-subtitle-audit.lua
```

런타임 키 대조표는 다시 검사했고 정확히 `1,950 fragments / 902 runtime keys`다.
팩/엔진 정합성 가드도 통과했으며 엔진은 631 B다.

현재 Lua 체인:

```text
0.4.52-full-subtitle-audit.lua
  -> 0.4.48-fragment-wipe.lua
       -> 0.4.45.lua
            -> 0.4.31.lua              키 판정·selector·timer
            -> 0.3.43-defer.lua        allocator
```

---

## 2. 최초 실패 — allocator가 MISS보다 먼저 무장

첫 `0.4.52` 실행 로그의 결정적인 순서:

```text
DYNAMIC FRAGMENT ... armed: end=$6000 ...
SUB 0.4.45 ★ MISS #1 00600EE48B98
DYNAMIC FRAGMENT ... armed: end=$A000 ...
SUB 0.4.45 ★ MISS #2 00A00E8022A8
```

원인은 콜백 순서였다.

```text
$F61A   0.3.43 allocator가 모든 rate-$0E ADPCM에 먼저 무장
$FEC4   0.4.31이 뒤늦게 6 B 키를 계산하고 KEY/MISS 판정
```

즉 `자막 없는 음성은 무개입`이라는 0.4.31의 전제가 합성 체인에서는 깨져
있었다.

### 적용한 수정 (`0.4.52a`)

- `0.4.31.lua`가 팩 KEY 일치를 확정한 뒤에만
  `_G.SUB_ALLOCATOR_ARM_MATCHED(voice.id)`를 호출한다.
- `0.3.43-defer.lua`에 `SUB_ALLOCATOR_REQUIRE_MATCHED` 모드를 추가했다.
- 이 모드에서는 `$F61A` 콜백이 allocator를 무장하지 않는다.
- `0.4.45.lua`가 해당 모드를 켠다.

결과:

```text
MISS #1 00600EE48B98
MISS #2 00A00E8022A8
```

두 MISS 앞뒤로 `armed`/`PATCHED`가 0회가 됐다. **allocator 선행 개입은 실제로
제거됐다.** 그러나 접수처 정지는 그대로였다. 따라서 allocator 선행 무장은
버그였지만 이번 정지의 충분조건은 아니었다.

근거 로그:

```text
dump/sub_0_4_52_full_audit_20260829_015647.tsv
```

---

## 3. 두 번째 실패 — legacy E6800 gate 임시 차단도 효과 없음

남은 가설은 다음이었다.

- Lua의 실제 6 B 키 판정은 MISS다.
- 하지만 `0.4.6.11/12` BIOS에는 옛 단일 `E6800_0E` gate가 남아 있다.
- `$22A7`의 stale `$68`을 native gate가 별도로 보고 state를 시작할 수 있다.

### 적용한 수정 (`0.4.52b`)

MISS 음성이 재생되는 동안 `$FEC4` 진입마다:

1. `$22A7` 원값을 저장한다.
2. native gate가 판정할 때만 `$22A7=0`으로 보이게 한다.
3. 공통 반환점 `$FF0F` 실행 직전에 원값을 복원한다.

따라서 함수 밖의 게임 RAM 값은 보존된다. 로그도 다음처럼 바뀌었다.

```text
MISS #1 00600EE48B98 · legacy gate blocked
MISS #2 00A00E8022A8 · legacy gate blocked
```

이 실행에도 `armed`, `PATCHED`, `KEY`는 0회였고 **접수처에서 똑같이 멈췄다.**
따라서 stale E6800 gate 가설도 현재 증상을 설명하지 못한다.

근거 로그:

```text
dump/sub_0_4_52_full_audit_20260829_015955.tsv
```

주의: 임시 차단 코드는 아직 다른 장면에서 검증하지 않았다. 정지 해결책으로
채택된 것이 아니며, 현재는 실험 코드다.

---

## 4. 앞의 두 MISS는 데이터상 정상

두 키는 정본 팩 누락이나 검색 실패가 아니다. 마스터에서 `효과음`으로 표시되어
의도적으로 제외됐다.

```text
00600EE48B98  ADPCM_00383A_6000_0E  "<원문 6자>"              효과음
00A00E8022A8  ADPCM_00306B_A000_0E  "<원문 8자>!"          효과음
```

실제 접수처 미카 첫 자막은 팩에 존재한다.

```text
runtime key  00D00E437790
voice        ADPCM_00309D_D000_0E
fragments    3
1            저는 JUNKER 본부에서 안내와
2            오퍼레이터를 맡고 있는 미카
3            슬레이튼입니다. 잘 부탁드립니다.
```

마지막 실패 로그는 이 `D000` KEY가 나오기 전에 끝난다. 즉 "첫 자막 내용이
깨져서 멈춤" 단계까지도 아직 가지 못했다.

---

## 5. 현재 수정된 파일

```text
lua/SUB/0.4.31.lua
  - AUDIT MISS 로그
  - KEY 확정 뒤 allocator opt-in 호출
  - MISS 동안 legacy gate 임시 차단/복원 (실험)

lua/SUB/0.3.43-defer.lua
  - SUB_ALLOCATOR_REQUIRE_MATCHED
  - SUB_ALLOCATOR_ARM_MATCHED 런타임 진입점

lua/SUB/0.4.45.lua
  - allocator matched-only 모드 활성화

lua/SUB/0.4.48-fragment-wipe.lua
  - 기존 조각 전환/종료 wipe; 오늘 본체 변경 없음

lua/SUB/0.4.52-full-subtitle-audit.lua
  - 전체 902키/1,950조각 KEY/MISS/PART/PATCH/WIPE TSV 기록
  - 현재 표시 버전 0.4.52b

tools/build_subtitle_runtime_key_map.py
  - 정본 팩 기준 runtime key 대조표 생성/검사
```

마지막 파일 SHA-256:

```text
0.4.31.lua                         EFD8CDFB9589E56B8159CE26E66FE527966920EA0F2EB8E5D4C1F5E42B0C83C6
0.3.43-defer.lua                   4B4CCC945405556F54D8FF7A36E1A07670BF8B32F50C7A28362A09021D1F362D
0.4.45.lua                         4071954AB277E7047F13ABCC73E09127D173D948122E37DBD18936FE5F005C24
0.4.48-fragment-wipe.lua           B0D8BCBDB27ABACC6FC818A52EA6BA3124D8D849311937BD817A8771E9DBE104
0.4.52-full-subtitle-audit.lua     D1FBB1757C6818D51899304E0BDA8F60E75FA74F61FB613D4F6652B7CD9BA814
```

---

## 6. 내일 첫 작업 — 기능을 더 얹지 말고 기준판부터 분리

### 1단계: 같은 디스크·같은 세이브, Lua 0개

Power Cycle 후 `0.4.6.12-dialogue-hunt`를 **SUB Lua 없이** 접수처까지 진행한다.

```text
Lua 없이도 멈춤  -> 현재 0.4.6.12 빌드/BIOS 또는 접수처 복구 경로 회귀
Lua 없이는 정상  -> 0.4.52 체인의 로드시 쓰기 또는 callback 잔류가 원인
```

이 결과 없이는 다음 가설을 세우지 말 것.

### 2단계: 읽기 전용 키 로거

`$FEC4`를 쓰는 현재 0.4.31 체인을 로드하지 말고, `$F61A`에서 실제 ADPCM
6 B 키와 프레임만 기록하는 **완전 읽기 전용** Lua를 만든다.

금지 항목:

```text
AC pack/engine upload
$22A6/$22A7/$22AA write
$7FDF write
VRAM/SATB/Sprite RAM write
$5B80 엔진 callback
allocator/wipe
```

읽기 전용판이 정상 진행하면 키 수집과 접수처 진행을 먼저 분리할 수 있다.

### 3단계: 정지 순간 상태 한 번만 수집

정지 재현 시 아래 값을 한 번에 기록한다.

```text
CPU PC/SP
$7FDF subtitle state
$20F5 lock
$22A6/$22A7/$22AA legacy fingerprint
$180D ADPCM status
$5B80 magic
$5CD7 ready (ENGINE+$157)
$5CD9 selector 9 B (ENGINE+$159)
actual ADPCM 6 B key
```

과거 비슷한 정지는 `state=02`, `PC=$E742` 계열이었지만 **이번 실행에서 다시
측정하지 않았으므로 동일 원인이라고 쓰면 안 된다.**

### 4단계: Lua 없이는 정상일 때만 로드시 쓰기 이분

다음 순서로 하나씩 붙인다.

```text
A  읽기 전용 키 로그만
B  pack/engine AC 업로드만
C  KEY 일치 controller만 (allocator/wipe 없음, 고정 $1600)
D  matched-only allocator
E  0.4.48 fragment/end wipe
```

첫 정지 단계가 원인 범위다. 현재처럼 전 체인을 한꺼번에 다시 고치지 말 것.

---

## 7. 하지 말아야 할 것

- `0.4.52b`로 전수 플레이를 계속하지 않는다.
- MISS 두 건을 팩 검색 오류로 취급하지 않는다. 둘 다 효과음 제외가 정상이다.
- allocator 침범 문제와 이번 접수처 정지를 한 문제로 합치지 않는다.
- `0.4.52a/b`의 실패만으로 고정 `$1600` 또는 allocator 자체를 폐기하지 않는다.
- 정지 순간 state/PC를 재측정하기 전에 과거 `008FA4` 원인과 같다고 단정하지 않는다.
- 현재 실험 코드를 디스크/BIOS 빌더에 반영하지 않는다.

---

## 8. 다음 성공 기준

최소 성공은 접수처에서 다음 순서가 확인되는 것이다.

```text
MISS 00600EE48B98              진행
MISS 00A00E8022A8              진행
KEY  00D00E437790 · 3조각      자막 1/2/3 전환
음성 종료                       게임 진행
다음 음성                       정상
```

이 한 장면이 통과한 뒤에만 전체 자막 정주행과 VRAM 충돌 감시를 재개한다.
