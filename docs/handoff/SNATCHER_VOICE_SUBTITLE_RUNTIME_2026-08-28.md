# SNATCHER 음성 자막 런타임 인계 — 2026-08-28

## ★ 다음 시작점

현재 남은 핵심 문제는 **한 ADPCM 음성 안에서 2번째 이후 자막 조각을 안전하게
다시 그리는 호출 경로** 하나다.

1. **`lua/SUB/0.4.38.lua`는 사용하지 않는다.** 3번째 조각 전환에서 게임이
   멈추는 것이 재현됐다.
2. 미카 3조각 음성 `ADPCM_00309D_D000_0E`로 재현한다.
3. 다음 실험은 Lua 우선, 디스크 빌드 없이 진행한다.
4. `$601E` 상주 컨트롤러에만 의존하지 말고, 음성 재생 중 반복되는 BIOS의
   `$E742/$E74A` IRQ·ADPCM 대기 경로에서 안전하게 `rebuild`를 호출할 수 있는
   지점을 찾는다.
5. 음성 열쇠·mini index·자막 데이터·allocator는 이미 검증됐으므로 다시
   만들지 않는다.

한 줄 결론:

> 0.4.38에서 Lua는 3번째 selector를 정확히 썼지만, CPU가 ADPCM 대기 경로에
> 있는 동안 엔진 호출이 다시 오지 않아 `ready=00`이 소비되지 않았다.

---

## 1. 현재 완성된 범위

- 게임 본문 검토 완료.
- 전체 음성 수집과 Whisper 초벌 전사 완료. 자세한 정본 현황은
  `docs/handoff/SNATCHER_VOICE_MASTER_2026-08-28.md` 참고.
- 음성별 런타임 6바이트 열쇠 생성 및 매칭 완료.
- 자막 팩에서 `kind=효과음` 또는 `kind=기타`인 음성을 자동 제외하도록 빌더와
  검증기를 수정했다.
- 고정 VRAM `$1600` 대신 BAT+SATB의 현재 참조를 보고 빈 조각을 고르는 동적
  allocator가 동작한다.
- 한 음성에 자막 한 조각을 표시하는 경로는 동작한다.
- 다중 조각 데이터 검색도 정상이다. 남은 문제는 **음성 재생 중 다음 조각을
  실행시키는 시점과 호출 경로**다.

남은 콘텐츠 작업은 기술 문제 해결 뒤 다음 정도다.

- 원음을 들으며 `효과음`/`기타` 분류
- 문장별 자막 조각과 시작 시각·지속 시간 조정
- 고유명사·오탈자 교정
- 처음부터 끝까지 전수 플레이 확인
- 마지막에만 네이티브/디스크 반영

---

## 2. 현재 자막 팩 정본

현재 생성물:

```text
build/cutscene_subs/subtitle_pack.bin               180,818 B
build/cutscene_subs/engine_ac_lua_frame_mini.bin        631 B
```

팩 집계:

```text
ADPCM 자막 조각       1,911
ADPCM 음성 열쇠         894
CD-DA 엔트리            646
너비 초과 자막           56
```

팩 roundtrip 검증은 ADPCM `1911/1911`, CD-DA `646/646`으로 통과했다.
남는 경고는 예전부터 있던 CD-DA 1섹터 겹침 네 쌍뿐이다.

```text
60338–60649   / 60648–60959
81837–81962   / 81961–82086
172816–173109 / 173108–173401
191462–191644 / 191643–191825
```

정본 데이터:

```text
snatcher_tool/translation/voice_keys.tsv
snatcher_tool/translation/voice_console_keys.tsv
snatcher_tool/translation/voice_subtitles_keyed.tsv
snatcher_tool/translation/voice_subtitles.tsv
```

### 효과음 처리 규칙

행을 삭제하지 않는다. `voice_keys.tsv`의 `kind`에 아래처럼 표시한다.

```text
효과음   -> 팩에서 제외
기타     -> 팩에서 제외
대사     -> 포함
빈칸     -> 포함
```

이 규칙은 아래 두 파일에 동일하게 들어갔다.

```text
tools/build_subtitle_pack.py
tools/verify_subtitle_pack.py
```

`ADPCM_00306B_A000_0E`의 “다음 회도 기대해 주세요!” 자막 행은 삭제하지 않고
복구했다. 대신 `voice_keys.tsv`에서 `kind=효과음`으로 표시했으므로 현재 팩에는
들어가지 않는다.

---

## 3. 음성 열쇠

런타임 열쇠는 다음 6바이트다.

```text
end_addr u16 LE
rate
ADPCM RAM sample @ end/4
ADPCM RAM sample @ end/2
ADPCM RAM sample @ 5*end/8
```

현재 자막이 연결된 열쇠끼리 충돌은 없다.

관련 도구:

```text
tools/build_voice_console_keys.py
tools/analyze_voice_sample_positions.py
```

미카 시험 음성:

```text
원본 key     ADPCM_00309D_D000_0E
런타임 key   00 D0 0E 43 77 90
```

세 조각:

```text
1  0.0초  1.5초    저는 JUNKER 본부에서 안내와
2  1.5초  1.5초    오퍼레이터를 맡고 있는 미카
3  3.0초  3.633초  슬레이튼입니다. 잘 부탁드립니다.
```

---

## 4. allocator 현황

`lua/SUB/0.3.42-wide.lua`는 BAT와 SATB가 현재 참조하지 않는 19글자 블록을
조각마다 고른다. 음성이 끝나면 이전 블록을 복구한다.

이번 작업에서 엔진별 오프셋을 외부에서 지정할 수 있게 했다.

```text
SUB_ALLOCATOR_ENGINE
SUB_ALLOCATOR_REBUILD_OFFSET
SUB_ALLOCATOR_COUNT_OK_OFFSET
SUB_ALLOCATOR_VRAM_LO_OFFSET
SUB_ALLOCATOR_VRAM_HI_OFFSET
SUB_ALLOCATOR_PAT_LO_OFFSET
SUB_ALLOCATOR_ATTR_OFFSET
```

실제 로그에서 한 음성의 조각 전환 때 `$1600 -> $1A00`, `$1600 -> $1A80`처럼
서로 다른 참조되지 않은 블록을 골랐다. 따라서 현 멈춤의 원인을 allocator나
VRAM 후보 탐색으로 되돌리지 않는다.

참고: 과거 `INTRUDER $1A40`은 마지막 자막 글자 자체를 침범으로 집계했을
가능성이 있어, 그 한 줄만으로 게임 충돌이라고 단정하지 않는다.

---

## 5. 엔진 구조에서 발견한 실제 버그

옛 timed 엔진은 `selector`, `next_selector`, `elapsed`를 19글자 sprite list와
겹쳐 썼다.

- selector/list의 시작 주소 공유는 검색 전에는 의도된 구조였다.
- 하지만 `next_selector`와 `elapsed`가 17~18번째 글자의 데이터 자리를 차지했다.
- 긴 문장이 이 영역을 덮어 다음 selector와 timer를 망가뜨렸다.
- 그 결과 문장 끝의 색 깨짐, 잔여 패턴, 다음 조각 누락이 생겼다.

이를 없애기 위해 새 엔진 빌더를 만들었다.

```text
tools/build_subtitle_engine_ac_lua_frame_mini.py
build/cutscene_subs/engine_ac_lua_frame_mini.bin
build/cutscene_subs/engine_ac_lua_frame_mini.json
```

새 엔진은 631 B로 안전 한도 672 B 안에 든다.

주요 오프셋:

```text
entry       +3
rebuild     +17
count_ok    +118
ready       +343
selector    +345
list        +345
index       +440
record      +440
stage       +503
```

allocator가 쓰는 VRAM 피연산자도 확인했다.

```text
+144 = 00
+146 = 16
+255 = B0
+260 = 8F
```

즉 19글자 list 자체는 이제 독립돼 있다. **631 B 엔진의 메모리 배치는 살릴
가치가 있지만, 이를 호출하는 0.4.38 방식은 폐기한다.**

---

## 6. Lua 실험 계보

```text
lua/SUB/0.4.31.lua
  pack 로더와 6바이트 음성 열쇠 매처의 기반.
  configurable engine/selector/mini index와 Lua timer 옵션이 추가됨.

lua/SUB/0.4.35.lua
  mini index + 동기식 next selector 시험.
  3조각 중 첫 조각만 실행.

lua/SUB/0.4.36.lua
  0.4.35 + 동적 allocator.

lua/SUB/0.4.37.lua
  16비트 elapsed >= next start 시험 + 동적 allocator.
  672 B 한도에 정확히 맞았으나, 이후 list 내부 메모리 중첩 문제를 발견해 폐기.

lua/SUB/0.4.38.lua
  631 B 독립 list 엔진 + Lua frame timer + 동적 allocator.
  ★ 3번째 조각에서 정지. 사용 금지.

lua/SUB/0.4.39-inspect.lua
  0.4.38 정지 상태를 변경하지 않고 읽는 진단 전용 스크립트.
```

이번 단계에서는 디스크나 BIOS 출하 빌드를 만들지 않았다.

---

## 7. 0.4.38 정지 증거

미카 3조각 음성에서 기록된 흐름:

```text
KEY 00D00E437790 · 3조각
LUA PART 2/3 at 90f
allocator가 다음 블록 선택
LUA PART 3/3 at 180f
이후 count_ok 없음
화면은 2번째 자막에 남고 게임 진행 정지
```

정지한 채 `0.4.39-inspect.lua`만 불러 읽은 결과:

```text
CPU pc=$E742 sp=$B7
magic=53 55 42 ready=00 state=02
CPU selector: 00 D0 0E 43 77 90 00 B4 00
MINI #1: 00 D0 0E 43 77 90 00 00 00 ...
MINI #2: 00 D0 0E 43 77 90 00 5A 00 ...
MINI #3: 00 D0 0E 43 77 90 00 B4 00 ...
```

해석:

- CPU selector는 MINI #3과 정확히 일치한다.
- `B4 00`은 180프레임 시작 시각도 정확하다.
- 따라서 팩, 열쇠, mini index, Lua의 조각 선택은 정상이다.
- `ready=00`, `state=02`가 그대로인 것은 새 selector가 요청 상태로 남았지만
  엔진의 rebuild가 다시 호출되지 않았다는 뜻이다.
- CPU PC `$E742`는 엔진 내부가 아니라 BIOS의 IRQ/ADPCM 대기 경로다.
- 과거 `dump/probe_voice_freeze_008FA4_post.tsv` 계열에서도 음성 재생 중
  `$E742/$E74A`가 반복되는 것이 이미 관측됐다.

중요한 반증:

- 1→2와 2→3은 모두 **같은 ADPCM 재생, 같은 6바이트 열쇠** 안의 전환이다.
- 1→2는 90f에 성공했고 2→3은 180f에 실패했다.
- 중간에 새 `KEY` 또는 새 음성 `armed` 로그는 없다.
- 그러므로 “AD 주소가 달라서”가 아니라, 그 순간 엔진 호출 기회가 사라지는
  문제다.

---

## 8. 다음 조사 순서

### A. 호출 흐름 측정

미카 음성을 재생하면서 다음 주소의 실행 횟수와 순서를 한 로그에 기록한다.

```text
$601E                  기존 상주 controller 호출점
$5B80 + 3              engine entry
$5B80 + 17             rebuild
$5B80 + 118            count_ok
$E742 / $E74A           BIOS IRQ·ADPCM 대기 경로
```

특히 90f와 180f 전후에 `$601E`와 engine entry가 실제로 몇 번 오는지 비교한다.

### B. Lua POC

가능하면 `$E742/$E74A` 안의 안전한 실행 지점 또는 ADPCM status polling 지점에
exec callback을 걸어 다음 조건에서만 engine `rebuild`를 한 번 호출하는 시험을
만든다.

```text
magic == "SUB"
state == 02
ready == 00
현재 selector가 mini index의 유효 레코드와 일치
재진입 중이 아님
```

주의:

- IRQ 문맥이므로 레지스터·플래그·스택 보존을 먼저 실측한다.
- callback 안에서 PC를 억지로 바꾸는 방식은 마지막 수단이다.
- 먼저 해당 경로가 엔진 호출이 없는 구간에도 매 프레임/IRQ 살아 있는지만
  read-only 카운터로 증명한다.
- 3조각이 모두 뜬 뒤 게임 진행과 타이틀 복귀까지 확인한다.

### C. 통과 기준

```text
조각 1/2/3 모두 정확한 시각에 한 번씩 표시
각 전환마다 count_ok 1회 이상
자막 끝 색 깨짐/파란 잔여 패턴 없음
음성 종료 후 allocator 원상복구
게임 진행 정지 없음
다음 음성 정상 연결
타이틀 복귀 정상
```

이 조건을 Lua에서 통과한 뒤에만 네이티브 코드와 디스크 반영을 검토한다.

---

## 9. 하지 말아야 할 것

- `0.4.38.lua`로 다시 장시간 테스트하지 않는다.
- 자막 행을 효과음이라는 이유로 삭제하지 않는다. `kind`로 분류한다.
- 열쇠 충돌이나 mini index 오류를 처음부터 다시 의심하지 않는다. 정지 덤프가
  둘 다 정상임을 증명했다.
- 고정 VRAM `$1600`을 출하 해법으로 되돌리지 않는다.
- 다중 조각 전환이 해결되기 전에 디스크/BIOS 빌드부터 만들지 않는다.
- 콘텐츠 싱크 조정과 런타임 정지 원인 조사를 섞지 않는다.

---

## 10. 재생성·검증

프로젝트 루트 `C:\snatcher`에서:

```powershell
python tools/build_voice_console_keys.py
python tools/build_subtitle_pack.py
python tools/verify_subtitle_pack.py
python tools/build_subtitle_engine_ac_lua_frame_mini.py
```

검증 시 기대값:

```text
subtitle_pack.bin                         180,818 B
engine_ac_lua_frame_mini.bin                  631 B
ADPCM                                     1,911조각 / 894키
CD-DA                                        646
허용된 기존 경고                         1섹터 overlap 4쌍
```

팩 숫자가 달라졌다면 먼저 `voice_keys.tsv`의 `kind` 수정이나
`voice_subtitles_keyed.tsv`의 콘텐츠 변경 여부를 확인한다.

---

## 11. 관련 인계서

```text
docs/handoff/SNATCHER_VOICE_MASTER_2026-08-28.md
  전체 1055 음성 수집·Whisper·Studio 정본

docs/handoff/SNATCHER_ALLOCATOR_CDDA_2026-08-28.md
  allocator의 배경, VRAM 침범 측정, CD-DA 및 008FA4 조사

docs/handoff/SNATCHER_AC_GUARD_FIX_2026-08-27.md
  AC guard/false trigger 관련 이전 해결 기록
```

## 최종 상태

음성 수집·전사·열쇠·팩·동적 VRAM 배치는 충분히 앞으로 왔다. 현재 출하를 막는
기술 문제는 **동일 ADPCM 재생 중 2번째 이후 조각을 BIOS 대기 구간에서도
실행시키는 안전한 호출 경로**다. 이것만 닫히면 남은 일의 대부분은 사용자가
원음을 들으며 문장별 싱크와 분류를 다듬고 전수 확인하는 작업이다.
