# SNATCHER 오늘 작업 인계서 — 자막 정지 해결·VRAM 키별 측정·최신 빌드 (2026-08-29)

> ⚠ **이 문서는 17:37 기준이다. 세 곳이 이후에 뒤집혔다.**
> 읽기 전에 [SNATCHER_VDC_LATCH_ONEGLYPH_2026-08-29](SNATCHER_VDC_LATCH_ONEGLYPH_2026-08-29.md) §5 를 볼 것.
>
> - **§2 · §6** allocator → 키별 고정 base 표 방향은 19:03 에 고정 `$1600` 으로 뒤집혔다.
>   §6 의 다음 시작점 1~3번은 따라가면 안 된다.
> - **§3 의 `0.4.69-vdc`** 는 덤프가 전부 헤더뿐이다. 검사한 적이 없다.
> - **§5 의 CD-DA** "읽기 전용 probe 로 수집해야 한다" 는 틀렸다. 이미 수집돼 있다
>   (`voice_events_raw.tsv` CDDA 119쌍). 남은 것은 실기 시작 LBA 취득 하나뿐이다.

## 한 줄 결론

오늘은 전체 자막 Lua가 접수처에서 멈추던 원인을 **다중 조각 전환 때 스테이징 코드가 글리프 데이터로 덮이는 문제**로 확정하고 Lua에서 재무장해 통과시켰다. 이후 VRAM allocator의 한계를 실측으로 확인해, 앞으로는 **음성 키별 고정 VRAM base 표**를 만드는 방향으로 전환했다. 최신 디스크 산출물은 `0.4.6.14-reviewed`다.

## 1. 확정되어 바뀐 것

### 1-1. 다중 조각 자막 정지 해결

증상은 미카 3조각 음성 등에서 2~3번째 자막 뒤 게임이 멈추는 것이었다.

- 원인: 엔진 entry가 `$5D77`의 31 B stage 루틴을 JSR한다.
- 이 stage 영역은 직후 글리프 전송 버퍼이기도 해서, 첫 자막 조각이 끝난 뒤에는 글리프 비트맵으로 덮인다.
- Lua timer가 다음 조각에서 `ready=0`을 쓰면 entry가 그 비트맵을 코드로 실행한다. 두 번째 조각까지는 우연히 복귀할 수 있고, 세 번째에서 BIOS 루프로 빠져 멈췄다.
- 해결: 조각 전환 직전에 `$5D77`의 원본 stage 31 B를 다시 써서 JSR 대상이 항상 정상 루틴이 되게 했다.

검증:

- `0.4.58-controller-stage.lua`: 미카 3조각과 이후 진행 정상.
- `0.4.59-controller-stage-allocator.lua`: matched-only allocator 결합도 정상.
- `0.4.60-full-stack.lua`: fragment/end wipe까지 결합해 정상.
- `0.4.61-full-subtitle-audit.lua`: 위 체인을 TSV로 기록하는 전수시험 기반.

현재 권장 Lua 전수시험 진입점:

- [0.4.62-reviewed-full-subtitle-audit.lua](C:/snatcher/lua/SUB/0.4.62-reviewed-full-subtitle-audit.lua)

`0.4.62`는 팩 헤더를 직접 읽어 실제 `902 keys / 1,950 fragments / 183,918 B`를 표시한다. Power Cycle 후 이 파일 하나만 로드한다.

### 1-2. MISS/효과음이 allocator를 먼저 무장하던 버그 제거

기존에는 `$F61A` allocator가 모든 rate `$0E` ADPCM에서 먼저 무장하고, 뒤의 `$FEC4`가 KEY/MISS를 판정했다. 그래서 자막 없는 효과음도 VRAM을 건드릴 수 있었다.

- `0.4.31.lua`가 KEY 일치 후에만 allocator arm을 호출하도록 변경.
- `0.3.43-defer.lua`에 `SUB_ALLOCATOR_REQUIRE_MATCHED` 모드 추가.
- MISS 두 건(`00600EE48B98`, `00A00E8022A8`)에서 allocator 무장이 0회인 것을 확인.

### 1-3. 팩/엔진 세대 불일치 가드 추가

자막 팩만 다시 만들면 엔진에 박힌 record/glyph AC 오프셋이 옛 위치를 계속 보는 문제가 있었다. 이 경우 글리프 수가 쓰레기값이 되어 SATB가 무너질 수 있다.

- [0.4.45.lua](C:/snatcher/lua/SUB/0.4.45.lua)에 팩↔엔진 오프셋 검사, AC 팩 재업로드 검사, 엔진 강제 재업로드를 넣었다.
- [build_subtitle_pipeline.py](C:/snatcher/tools/build_subtitle_pipeline.py)가 팩 → 냉검증 → 631 B 엔진 순서를 강제한다.
- 오늘 다시 실행해 팩 `183,918 B`, 엔진 `631 B`, `902키 / 1,950조각` 검증 통과.

## 2. VRAM 방향 전환: allocator 대신 키별 고정 base

### 이유

allocator는 음성 시작 시점의 빈 자리만 보고 고른다. 초상화나 UI는 그 직후 같은 VRAM을 점유할 수 있어, 나중 침범을 구조적으로 막지 못한다. 실제 allocator 로그에는 선택 후 게임 침범 사례가 축적되어 있다.

새 방식은 음성 키가 재생되는 전체 기간의 점유를 오프라인으로 누적하고, 그 구간 전체에서 비어 있던 19글자 블록만 그 키의 후보로 남긴다. 따라서 미래를 모르는 실시간 선택을 하지 않는다.

### 오늘 새로 만든 측정/분석 도구

- [VRAM-key-map.lua](C:/snatcher/lua/SUB/VRAM-key-map.lua): 1차 키별 점유/자유 base 측정.
- [VRAM-key-map-0.2.lua](C:/snatcher/lua/SUB/VRAM-key-map-0.2.lua): BAT 본체, 큰 BAT(128×64), 실제 DVSSR SATB 주소, 매 프레임 BAT 갱신을 반영한 수정 측정판.
- [build_vram_key_bases.py](C:/snatcher/tools/build_vram_key_bases.py): 측정 TSV에서 키별 base 표를 생성.
- [vram_key_bases.tsv](C:/snatcher/build/cutscene_subs/vram_key_bases.tsv): 키별 단일 base 후보.
- [vram_key_bases_pairs.tsv](C:/snatcher/build/cutscene_subs/vram_key_bases_pairs.tsv): 조각 전환용 ping-pong 두 base 후보.
- [0.4.64-fixedbase.lua](C:/snatcher/lua/SUB/0.4.64-fixedbase.lua): 표 기반 고정 base 실행판.

현재 측정 범위(정커 본부까지)에서는 키별 후보가 생성됐고, 0.2 기준으로 “자막 19셀을 둘 자유 base가 0개”인 관측 키는 아직 없다. 다만 **902키 전체가 측정된 것은 아니다.** 아직 플레이하지 않은 키는 표에 안전 판정이 없는 상태다.

## 3. 고정 base를 검증하며 추가로 만든 진단 Lua

다음은 출하 기능이 아니라 원인 규명용이다.

- [0.4.65-verify.lua](C:/snatcher/lua/SUB/0.4.65-verify.lua): 업로드 직후부터 VRAM 지문을 읽어 게임이 실제로 덮는지 검증.
  - 관측: 여러 사례에서 90프레임 동안 우리 글리프 블록 변경 0. 즉 “게임이 글리프 VRAM을 침범”이 주원인은 아니었다.
- [0.4.66-slots.lua](C:/snatcher/lua/SUB/0.4.66-slots.lua): SATB 슬롯 수/우리 자막 슬롯을 측정.
  - 빈 슬롯이 31~34개로, 19글자 자막에 슬롯 부족도 주원인으로 보기 어렵다.
- [0.4.67-blank.lua](C:/snatcher/lua/SUB/0.4.67-blank.lua): 새 조각 전 블록 전체를 비워 꼬리 글자 잔상을 분리.
  - 일부 꼬리 잔상은 같은 base 재사용의 결과임을 확인했지만, 화면 떨림의 전체 원인은 아니었다.
- [0.4.68-satb.lua](C:/snatcher/lua/SUB/0.4.68-satb.lua): 자막 줄의 SATB 항목을 덤프.
- [0.4.69-vdc.lua](C:/snatcher/lua/SUB/0.4.69-vdc.lua): VDC 레지스터가 잘못 선택되는지 검사.
- [0.4.70-when.lua](C:/snatcher/lua/SUB/0.4.70-when.lua): 업로드 타이밍과 이후 게임 재그리기를 측정.
  - 핵심 결론: 조각 전환 때 화면에 남아 있는 **이전 자막 스프라이트가 같은 base를 가리킨 채** 새 글리프가 덮여 한 프레임 찢어진다.
- [0.4.71-pingpong.lua](C:/snatcher/lua/SUB/0.4.71-pingpong.lua): 조각마다 두 base를 번갈아 써서 살아있는 이전 조각을 덮지 않는 실험판.
- [0.4.72-palette.lua](C:/snatcher/lua/SUB/0.4.72-palette.lua): 글자가 청록으로 보이는 문제의 색 3 팔레트 가설 검증판. VCE 팔레트를 직접 쓰므로 진단용이다.

즉 현재 가장 유력한 출하 경로는:

```text
키별 고정 base + 조각별 ping-pong + stage rearm + 끝/전환 wipe
```

아직 이 네 요소를 하나의 “전수 출하 Lua”로 합친 것은 아니다. `0.4.64~0.4.72`는 측정/실험 단계다.

## 4. 마스터·빌드에서 바뀐 것

### 마스터 복구와 개별 수정

마스터의 임베디드 줄바꿈 90개가 과거 ad-hoc `splitlines()` 저장으로 사라졌던 문제가 확인되어, 정상 백업을 기준으로 복구했다. 이후 사용자 원칙대로 일괄 자동 정리가 아니라 충돌 난 행만 수정했다.

- `R10066`, `R10257`: 2·3·4번으로 잘못 시작한 행을 1·2·3으로 수정.
- `R01316:1`, `R03646:1`: 문맥 없는 OBSERVED_PAGE 꼬리 집계 행을 출하 검토에서 제외.
- `R10432`, `R10452`: 페이지 경계를 넘어 이어지는 speakerless 설명문에 `[CONTINUOUS]` 표기.
- `R04271:3`: `범죄심리학, 사회정보`로 통일.
- `R04283:2`: 불필요한 앞 전각 공백 제거.

각 수정 직전 백업은 `snatcher_tool/translation/snatcher_ko_master.tsv.bak_20260829_*`로 남아 있다.

### 최신 빌드

최신 산출물은 다음이다.

- [0.4.6.14-reviewed CUE](<C:/snatcher/build/patch/0.4.6.14-reviewed/Snatcher CD-ROMantic (Japan) [KO].cue>)
- [0.4.6.14 manifest](C:/snatcher/build/patch/0.4.6.14-reviewed/manifest.json)

`0.4.6.14-reviewed`에는 Track 24에 번역 데이터와 자막 팩이 추가되어 있고, BIOS는 부팅 시 이를 AC RAM으로 preload한다.

- translation: 1,230,208 B
- subtitle pack: 183,918 B
- subtitle helper: 320 B
- subtitle renderer: 671 B

빌드 검증은 4개 payload byte-exact 및 AC 영역 비중첩을 통과했다.

## 5. CD-DA 자막: 오늘 확인된 정확한 상태

이 부분은 이전 설명을 정정한다.

- Lua 6바이트 runtime key로 연결하는 것은 **rate `$0E` ADPCM 자막 902키 / 1,950조각**이다.
- 그러나 subtitle pack에는 별도로 **CD-DA LBA index 698개**가 있다.
- CD-DA 행은 길이 초과 시 기존 LBA 범위 안에서 창을 나눈 항목 51개가 추가되어 있다.
- 따라서 CD-DA 음성도 자막 데이터는 존재한다. 다만 현재의 ADPCM 키 기반 Lua/VRAM-key-map은 CD-DA 재생을 잡지 않는다.

남은 CD-DA 작업은 “재생 단위”를 게임의 CD-DA 재생 명령/LBA 범위와 매칭하는 것이다. 즉 CD-DA track 파일을 그냥 임의로 쪼개는 것이 아니라, 게임이 시작·종료 LBA를 어떻게 지정하는지 읽기 전용 probe로 수집해야 한다. 그 결과가 있어야 각 자막 조각의 정확한 싱크/배치를 자동화할 수 있다.

## 6. 다음 시작점

1. `VRAM-key-map-0.2.lua`를 **자막 Lua 없이** Power Cycle 후 실행하고, 첫 장면부터 메탈기어 조우까지 진행한다.
2. 생성되는 `dump/vram_key_map2_*.tsv`, `dump/vram_key_spans2_*.tsv`를 분석해 신규 키의 자유 base 0개 여부를 확인한다.
3. 전수 키 표가 충분해지면 `0.4.64` 기반으로 stage rearm, ping-pong, wipe를 결합한 새 전수 Lua를 만든다.
4. 병행해서 CD-DA 재생 LBA 시작/종료 probe를 만든다. CD-DA는 현재 ADPCM key-map 측정 대상이 아니다.
5. 최종 전체 자막 정주행은 위 고정 base 경로가 합쳐진 뒤에 시작한다.

## 주의

- `0.4.31 / 0.4.57~0.4.63`과 `VRAM-key-map-0.2.lua`를 동시에 올리면 안 된다. 자막이 먼저 VRAM을 점유해 측정이 오염된다.
- 실험 Lua는 Power Cycle 뒤 **한 파일만** 로드한다.
- `0.4.52-full-subtitle-audit.lua`는 접수처 정지 재현판이므로 사용하지 않는다.
