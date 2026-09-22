# 자막 고정 경로 · 국장실 떨림 인계서 (2026-08-29)

## 지금 확정된 상태

### 채택한 자막 경로

- 자막 VRAM은 **고정 `$1600`**.
- controller + stage rearm은 정상이다.
- 조각 전환과 음성 종료에는 이전 자막 SATB/Sprite RAM 항목만 와이프한다.
- 이 조합은 [0.4.82-fixedbase-fragment-wipe.lua](C:/snatcher/lua/SUB/0.4.82-fixedbase-fragment-wipe.lua)다.

구성은 다음과 같다.

```
0.4.82
 ├─ 0.4.82-fixedbase-patched-marker
 │   └─ 0.4.58 controller + stage rearm
 │       └─ 0.4.57 voice-key controller
 └─ 0.4.48 fragment/end SATB wipe
```

`0.4.82`로 정커 본부에서 국장실 대화까지 자막·조각 전환·종료가 깨끗하게 진행된 것을 확인했다. allocator와 ping-pong은 이 경로에 들어 있지 않다.

## ping-pong 결론 — 사용하지 않는다

`0.4.71/.73` 계열은 키별 A/B base ping-pong 실험이었다. 다음은 모두 실측으로 배제됐다.

- SATB 슬롯 주소, 팔레트 `F`, 슬롯 순서: 정상.
- 새 base는 글리프 업로드가 끝난 뒤 2프레임째에야 SATB가 참조: 조기 handoff 아님.
- 업로드 뒤 한 프레임에 바뀌는 칸은 모두 화면에서 쓰지 않는 꼬리 작업공간.
- `$1600` 기준과 A/B base의 **실제 표시 타일** 해시가 모두 일치:
  `0.4.81 ... visible=... mismatch=0`.

따라서 ping-pong은 화면 품질을 개선하지 못하며 다시 섞지 않는다. 관련 측정 Lua는 원인 추적 기록으로만 보존한다.

## 국장실 떨림: 현재 증거

### VRAM 충돌은 아님

[0.4.83-director-room-timing.lua](C:/snatcher/lua/SUB/0.4.83-director-room-timing.lua)는 `0.4.82` 위에서 시간만 측정한다. 국장실 실행에서 `$1600`을 이미 화면이 참조한 채 덮으려 했다는 `★★` 기록은 없었다.

### 업로드 시간은 매우 김

같은 실행의 `0.4.70` 로그에서 글리프 한 조각 업로드가 약 30~67 스캔라인을 점유했다. `$vdc.scanline`이 263에서 0으로 순환하므로 음수 표시는 아래처럼 보정해서 읽는다.

| 원 로그 | 실제 span |
|---|---:|
| 238 → 27 | 52줄 |
| 13 → 47 | 34줄 |
| 228 → 32 | 67줄 |
| 20 → 80 | 60줄 |
| 19 → 54 | 35줄 |
| 213 → 251 | 38줄 |

국장실은 래스터 IRQ로 그림 창을 분할하는 장면이다. 긴 AC→stage→VDC 블록 전송이 표시 구간에 걸치면 IRQ가 늦어져 화면이 떨릴 수 있다. 이것이 현재 **유력한 가설**이지만, 아직 인과 확정은 아니다.

> `0.4.70-when.lua`은 wrap-around span을 음수로 기록하는 표시 버그가 있다. 원자료 자체는 유효하며, 이후 수정할 때 `(end - start + 263) % 263`으로 기록만 고치면 된다.

## 한 글자 전송 대조 실험

목표는 한 자막 조각의 실제 AC/VDC 전송을 첫 글리프 1회로 줄여 국장실 떨림이 줄어드는지 보는 것이다.

### 폐기한 방법

- `0.4.84`: push count만 1이 되어 표시 슬롯만 줄고, glyph loop 자체는 확인되지 않았다.
- `0.4.85`: loop branch의 위치가 1바이트 앞이었다.
- `0.4.86`: Mesen Lua에서 실행 callback 주소와 코드 바이트 read/patch 경로가 신뢰되지 않아 `$00/$16`을 읽었다.

이 세 파일은 **판정용으로 사용 금지**다.

### 현재 올바른 방법

[build_subtitle_engine_oneglyph.py](C:/snatcher/tools/build_subtitle_engine_oneglyph.py)가 원본 `engine_ac_lua_frame_mini.bin`과 동일한 631B 진단용 엔진을 만든다.

변경은 정확히 세 바이트다.

```
engine +$06D: AD 38 5D  ->  A9 01 EA
              LDA record.cells  ->  LDA #1 / NOP
```

이 바이트는 loop가 시작되기 전에 internal `count`와 `remaining` 양쪽에 들어가는 A 값을 1로 만든다. 그러므로 글리프 전송 루프와 SATB push가 모두 처음부터 한 칸이다. 런타임 코드 패치가 아니다.

생성 파일:

`build/cutscene_subs/engine_ac_lua_frame_oneglyph.bin`

[0.4.87-director-true-one-glyph.lua](C:/snatcher/lua/SUB/0.4.87-director-true-one-glyph.lua)가 이 엔진을 `.82` 경로에 지정한다.

### 반드시 남은 한 번의 검증

이전 `.87` 실행은 실패했다. 원인: 원본·진단 엔진이 같은 길이/매직이라 `0.4.31`이 AC에 남은 원본을 재사용했다. 그 실행에서 와이프가 `14/18/16칸`이었던 것이 증거다.

수정 완료:

- `0.4.31.lua`: `SUB_VOICE_FORCE_ENGINE_UPLOAD`이면 첫 `ensureInstalled()`에서 AC pack/engine을 무조건 다시 올리고 즉시 false로 낮춘다.
- `0.4.57-controller-only.lua`: `SUB_CONTROLLER_ENGINE_PATH`, `SUB_CONTROLLER_FORCE_ENGINE_UPLOAD`를 전달한다.
- `0.4.58-controller-stage.lua`: 같은 대체 engine path로 stage routine을 읽는다.
- `0.4.87`: 대체 engine path + force upload를 켠다.

**다음 실행 방법:** Power Cycle 뒤 `.87` 하나만 실행하고 국장실에 간다.

성립 조건:

1. 시작 로그에 `AC install #1 · pack ... · engine 631 B`가 반드시 있다.
2. 모든 자막은 첫 글자 한 칸만 보인다.
3. `FRAGMENT/END WIPE`의 SATB·Sprite RAM 슬롯 수가 1칸이다.

판정:

- 떨림이 사라지거나 크게 줄면: 전송량/래스터 IRQ 지연이 직접 원인으로 확정. 다음 구현은 업로드를 여러 프레임/VBlank에 나누는 방향.
- 떨림이 그대로면: VDC 전송량 단독 원인은 아니다. 그때는 SATB push 또는 와이프 타이밍을 분리해서 본다.

## 변경 파일 목록

- [0.4.31.lua](C:/snatcher/lua/SUB/0.4.31.lua) — 대체 엔진 1회 강제 업로드 옵션 추가.
- [0.4.57-controller-only.lua](C:/snatcher/lua/SUB/0.4.57-controller-only.lua) — 대체 엔진 경로/강제 업로드 전달.
- [0.4.58-controller-stage.lua](C:/snatcher/lua/SUB/0.4.58-controller-stage.lua) — 대체 엔진의 stage routine 사용 가능.
- [0.4.70-when.lua](C:/snatcher/lua/SUB/0.4.70-when.lua) — wrapper가 child stack을 지정 가능.
- [0.4.82-fixedbase-fragment-wipe.lua](C:/snatcher/lua/SUB/0.4.82-fixedbase-fragment-wipe.lua) — 현재 고정 경로 시험판.
- [0.4.83-director-room-timing.lua](C:/snatcher/lua/SUB/0.4.83-director-room-timing.lua) — 국장실 timing 측정.
- [build_subtitle_engine_oneglyph.py](C:/snatcher/tools/build_subtitle_engine_oneglyph.py) 및 생성 binary — 유효한 한 글자 엔진 실험.
- [0.4.87-director-true-one-glyph.lua](C:/snatcher/lua/SUB/0.4.87-director-true-one-glyph.lua) — 다음에 실행할 대조판.
