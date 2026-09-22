# SNATCHER 2026-08-31 — 환경 B 세션 인계서

환경 A에서 들고 온 08-30 작업물을 환경 B 트리에 얹고, 그 위에서 세 가지를 했다.
**CD-DA 자막의 단위를 트랙으로 바꾸고**, VRAM 수집의 막힌 곳을 열고,
네이티브 LBA 조회를 환경 B에서 다시 구워 **실기로 재검증**했다.

---

## 0. 30초 요약

```
✔ 이관 3 묶음        DEV·STUDIO·DISC_SAVES  해시 3,754/3,754  번역 손실 0
✔ 수집 막힘 규명      SUB_VRAM_MAP_ONLY_SUBTITLES 가 902 밖을 막고 있었다
✔ 수집 대상 넓힘      0.5.26 새 진입점 -- 음성 마스터 1,024키 기준
✔ 관측 현황 열        vram_observed 를 마스터 다섯 곳에 · 도구화
✔ CD-DA 관찰 창고     덤프가 사라져도 결과가 안 날아간다
✔ ★ CD-DA 트랙 종속   1 트랙 = 1 음성.  스튜디오·팩 빌더까지 관통
✔ 자막 세로 자리      위/중간/아래.  엔진 변경 0
✔ Lua 정리           547 -> 22  (dofile 사슬로 정함)
✔ ★ 0.4.6.27 재빌드   환경 B에서 굽고 **실기 5/5 재현**
✗ 결합부             아직.  다음 작업 (BASELINE §12.7-1)
```

---

## 1. 이관 — 손실 없음을 어떻게 확인했나

`C:\snatcher\8월 31일\` 의 세 묶음을 얹었다.  **STUDIO 가 DEV 의 상위집합**이고
(DEV 전용 4 개뿐), DISC_SAVES 가 디스크·BIOS·dump·세이브를 들고 왔다.

행 수만 보면 셋 다 줄어들어 겁먹게 되어 있다.  **셋 다 무손실이었다.**

```
master  15,779 -> 15,713 행   R103xx~R104xx 대역이 재번호됐다
                              text_key 로 대조하면 262 행이 사라진 것처럼 보이지만
                              ★ jp_text 전문으로 대조하면 번역 소실 0
                              검토O 14,521 -> 15,694  (+1,173)
cdda_subtitles  648/번역646 -> 19/번역0
                              없어진 게 아니라 cdda_subtitles_timed.tsv 로 이름이 갈렸다
voice_subtitles  118 -> 1,963 행
                              event_id 체계가 바뀐 전면 재생성.  옛 id 는 세션 안에서만 유일
```

> ★ **행 수로 판정하지 말 것.**  키가 재번호되면 행 대조는 거짓 손실을 보고한다.
> `jp_text` 전문(레코드의 모든 line 을 이어붙인 것)으로 맞춰야 진짜가 나온다.

덮어쓴 원본은 `_premerge_20260831_home\` 에 있다.  묶음 폴더는 지웠고(2.37 GB),
지우기 전에 **라이브에 없는 파일 0** 을 확인했다.  내가 고친 6 파일의 환경 A 원본은
`_premerge_20260831_home/bundle_originals/`, 환경 A 판이 못 덮은 세이브 5 개는
`SaveStates_older_from_home/` 에 있다.

### ⚠ 번들이 `dump\` 를 빠뜨린다 — 반복되는 구멍

번들 최상위는 `SUB build docs lua snatcher_tool tools` 뿐이다.  그런데 Mesen
관측기는 전부 `C:/snatcher/dump/` 에 쓰고 변환 도구는 전부 거기서 읽는다.
2026-08-22 에 `dump\glyph_used_*.tsv` 를 잃은 것과 같은 사고다.

이번에도 처음 두 묶음에는 없었고 DISC_SAVES 로 따로 받았다.  **다음 번들부터는
`dump\` 를 포함시킬 것** (`tools/make_handoff_bundle.ps1`).

---

## 2. ★ VRAM 수집이 902 밖을 못 잡던 이유

`0.5.25` 래퍼가 스위치를 켜고 있었다.

```lua
SUB_VRAM_MAP_ONLY_SUBTITLES = true      -- 팩(902)에 있는 키만 기록
```

실측 근거: 08-30 관측 257 개가 **전부** `has_subtitle=1` 이고 팩 밖은 0 개.
마스터의 15% 가 `has_subtitle=0` 인데 하나도 안 걸리는 것은 우연이 아니다.
rate 필터 탓도 아니다 — `has_subtitle=0` 152 행 중 151 행이 말소리와 같은 rate `$0E`.

그리고 **`has_subtitle` 자체를 믿으면 안 된다.**

> "실제로 효과음이라고 되어 있는데 효과음이 아닌 게 있음"  — 소유자 2026-08-31

그 152 행의 `status` 는 전부 `ambiguous_audio` 다.  분류기가 판단을 **보류**한 것이지
효과음으로 확정한 것이 아니다.  그래서 목표는 전수 관측이다.

### ⚠ 그렇다고 필터를 끄면 안 된다

엔진 `VRAM-key-map-0.2.lua` 를 받아 읽어보니 **키 계산이 08-29 판과 완전히 같다**
(`finish = readAddress + adpcmLength` 를 매 프레임 재계산).  08-30 이 100% 깨끗했던
것은 표본이 나아져서가 아니라 **팩 필터가 찢어진 키를 걸러냈기 때문**이다.

```
296행   if subtitleKeys and not subtitleKeys[id] then return nil end
```

08-29 주행은 192 키 중 **142 키가 못 붙는다.**  그중 73 개는 첫 바이트가
`3A · 7C · FD · E5 …` — 팩 902 키의 첫 바이트는 `00`(742) 아니면 `FF`(160) 뿐이라
존재할 수 없는 값이다.  재생 도중 `readAddress` 가 굴러간 뒤 뜬 찢어진 표본이다.

    -> 끄지 말고 **넓힌다.**

엔진에 세 번째 키 출처를 더했다 (추가만 함, 기존 동작 불변).

```lua
SUB_VRAM_MAP_ALL_VOICE_KEYS = true   -- voice_console_keys.tsv 의 1,024키로 거른다
SUB_VRAM_MAP_ONLY_SUBTITLES = true   -- 기존.  팩 902키
(둘 다 없으면)                        -- 필터 없음.  찢어진 키까지 들어온다
```

마스터는 실제 주행으로 모은 표라 진짜 음성은 다 있고 찢어진 키는 없다.
파싱 로직은 파이썬으로 모사해 **1,024 키가 나오는 것까지 확인**했다.

### 수집은 이것으로 돈다

```
snatcher_tool/mesen/0.5.26-adpcm-cdda-vram-map-all.lua    ★ 이것을 로드한다
snatcher_tool/mesen/0.5.25-adpcm-cdda-vram-map.lua        902 전용.  비교용으로 남김
snatcher_tool/mesen/VRAM-key-map-0.2.lua                  엔진 -- 직접 로드하면 필터가 꺼진다
```

Power Cycle 뒤 **이것 하나만** 로드한다.  한 판 돌면 ADPCM 과 CD-DA 가 같이 쌓인다
(파일 넷이 로드 시점에 열린다.  ADPCM 키 스위치와 무관하다).

### ⚠ 변환 명령의 함정

```python
# tools/build_vram_key_bases.py:89
files = sorted(ROOT.glob("dump/vram_key_spans_*.tsv"))
```

이 글롭은 **`vram_key_spans2_*` 를 안 잡는다.**  그냥 돌리면 깨진 08-29 파일 하나만
읽어서 50 이 나온다.  `--spans` 로 직접 주되 단일 파일만 받으므로 여러 주행은
합쳐서 넘긴다.

---

## 3. 관측 현황 — `tools/mark_vram_observed.py` (새 도구)

수집 한 판 돌 때마다 이것 하나만 돌리면 된다.  ADPCM·CD-DA 둘 다 찍는다.

```
voice_events · voice_keys · voice_console_keys      키 단위
cdda_segments · cdda_subtitles                      트랙/clip 단위
열: vram_observed (O/빈칸) · vram_bases (찾은 후보 base 개수)
```

ADPCM 은 **음성 마스터에 있는 키만** 센다 — 날짜로 안 걸러도 찢어진 표본이 걸러진다.
CD-DA 는 원자료가 유실된 옛 관찰을 `cdda_runtime_safe_positions.tsv` 의 `clips` 열에서
되살린다 (123 clip).

```
2026-08-31 현재   ADPCM 264 / 1,055 행 (고유 키 263/1,024)
                  CD-DA  123 / 408 clip
```

⚠ `cdda_segments.tsv` 는 `build_cdda_segments.py` 가 다시 만들면 열이 날아간다.
재생성 뒤에는 이 도구를 다시 돌린다.
⚠ 스튜디오를 켠 채 돌리지 않는다 (`docs/MERGE_CHECKLIST.md` §1).

---

## 4. CD-DA 안전위치 — 관찰 창고 (도구 고침)

`build_cdda_runtime_safe_positions.py` 는 그때 `dump/` 에 있는 파일만 읽고 결과를
**통째로 덮어썼다.**  덤프가 유실되면 결과도 같이 사라진다 — 이번 이관에서 실제로
그럴 뻔했다 (255/698 을 만든 원자료가 안 왔다).

**결과를 합치는 것은 답이 아니다.**  창의 답은 관찰들의 **교집합**이라, 새 관찰이
"그 자리 쓰였다" 고 하면 옛 답은 틀린 답이 된다.  옛 `vram_base` 를 살려두면 자막을
그래픽 위에 올린다.  그래서 합치는 것은 답이 아니라 **관찰 자체**다.

```
build/cutscene_subs/cdda_vram_observations.tsv      ★ 관찰 창고 (새로 생김)
  source(파일 이름) · clip · lba_from · lba_to · first · last
```

덤프를 한 번 읽으면 창고에 붙이고, 계산은 늘 창고 전체로 한다.

### 그 과정에서 잡은 진짜 버그

`split_observations` 가 `first` 가 줄어드는 지점으로만 관찰을 갈랐다.  창고에 여러
덤프가 이어 붙으면 경계에서 안 줄어들 수 있고, 그러면 **서로 다른 주행 두 개가 한
관찰로 뭉쳐 합집합**이 된다.  자기시험으로 확인했다.

```
주행 A  4000-5FFF 비었음
주행 B  5000-5FFF 비었음      (4000-4FFF 는 B 에서 쓰였다는 뜻)
고치기 전  base 4000   <- 위험.  B 가 쓰는 자리
고친 뒤    base 5000   <- 정답
```

`source` 가 바뀌면 무조건 새 관찰로 가르게 했다.  그 밖에 덮어쓰기 전 자동 백업,
`검증된 창 N ▲/▼ M` 델타 출력, **관찰이 0 이면 아무것도 안 하고 종료** 를 넣었다.

---

## 5. ★★ CD-DA 자막은 트랙 종속이다

> "1개 트랙은 1개 음성이랑 동일한거임 거기 안에 자막들이 종속되는 형식인거고,
> 지금 마스터는 왼쪽에 자막들이 다 나와있어서 이게 한개 음성인지 싱크를 전체를
> 기준으로 맞출 수가 없음"  — 소유자 2026-08-31

clip 408 개를 늘어놓으면 어디까지가 한 음성인지 안 보이고, 시간을 clip 안에서만
재게 되어 트랙 통짜를 들으며 싱크를 맞출 수가 없다.

### 5-1. 데이터

```
cdda_subtitles.tsv   track + part · start_sec = **트랙 기준 절대시각**
                     649행 -> 649행 · 트랙 19개 · 번역 647 -> 647 (손실 0)
                     clip 은 출처로 남긴다 (LBA 환산 · 일본어 원문)
```

접으면서 드러난 겹침 12 쌍은 전부 **1 ms 반올림 오차**였다.  앞 자막의 duration 을
다음 시작까지로 줄여 0 으로 만들었다 (글은 안 지웠다).

### 5-2. LBA 환산 — `tools/subtitle_split.py` 한 곳

LBA 는 트랙 안에서 정확히 선형이다 (**75 섹터/초**, 19 트랙 전부 검산).

```python
S.cdda_track_spans(segments)              # 트랙 -> (0초에 해당하는 LBA, 끝)
S.cdda_window(row, segments, base, limit) # 자막 한 줄 -> (lba_from, lba_to)
S.trim_cdda_overlaps(index)               # 이웃과 한 섹터 겹치는 끝을 당긴다
```

> ★ **빌더와 검증기가 같은 값을 내야 한다.**  따로 적어 뒀더니 한쪽만 고쳐서
> "나눈 창이 비었다" 가 698 번 났고, 트림을 빌더에만 넣었더니 이번엔 "원본 표에
> 없다" 가 났다.  그래서 셋 다 공용 모듈에 있다.

⚠ `cdda_window` 는 그 시각이 아직 원래 clip 안에 있으면 **clip 기준으로** 잰다.
수학적으로 같은 값인데 `int()` 자르는 자리 때문에 한 섹터가 흔들리고, 안전위치표는
`(lba_from, lba_to)` **정확 일치**로 채점해서 그 한 섹터에 검증이 통째로 날아간다
(실측: 255 -> 104).  clip 기준으로 잡아 190 까지 회복했다.

### 5-3. 스튜디오

세그먼트 표를 읽은 뒤 **화면용으로만** 트랙 단위로 접는다 (`LoadCddaTables`).
접은 행의 `clip` 칸에 트랙 번호를 넣어서 나머지 코드가 그대로 돈다.
`cddaSegments.Dirty = false` 로 파일에 안 돌아가게 막았다.

```
왼쪽 목록    19 트랙          ▶듣기 -> logs/cdda/trackNN.wav 통짜
아래 조각표  그 트랙의 자막 전부 · 트랙 절대시각
관측 칸      트랙 안 clip 하나라도 관측됐으면 O
위치 칸      위 / 중간 / 아래 · 단추 4 개
```

⚠ CD-DA 그리드는 **열이 하드코딩**이다.  TSV 에 열만 넣어서는 안 보인다.
`cddaGrid.Columns` 목록과 `RefreshCddaGrid` 의 `cells[N]` 둘 다 고쳐야 한다
(`UpdateCddaRow` 는 이름으로 찾으므로 안전).  음성 탭은 열이 자동이라 그냥 보인다.

### 5-4. 팩 재빌드 — 통과

```
자막 팩 183,918 B
  CD-DA 색인  698 개   겹침 없음      <- 동결본과 같은 개수
  ADPCM 색인  1950 조각 (902 음성)
  기록 2632 · 글리프 836
verify_subtitle_pack.py -> 전부 통과 -- 팩만 보고 글이 그대로 돌아왔다
```

---

## 6. 자막 세로 자리 — 위/중간/아래

**엔진은 한 줄도 안 바꿨다.**  y 는 빌드 때 레코드에 박힌다 (6280 에 곱셈기가 없어
런타임은 계산을 안 한다).  빌더에 이미 절반이 있었다.

```python
POSITIONS = {"위": 32, "중간": 122, "아래": 192}
DEFAULT_POS = {"adpcm": "중간", "cdda": "아래"}   # 소유자 지시로 기본값 유지
```

`pos` 열이 비면 그 기본값이다.  `cdda_subtitles.tsv` 와 `voice_subtitles.tsv` 에
열을 넣었고 (`voice_subtitles_keyed.tsv` 엔 원래 있었다), 스튜디오 두 탭에
`위 · 중간 · 아래 · 위치 기본` 단추를 달았다.  자막 **한 줄 단위**로 다르게 줄 수 있다.

---

## 7. Lua 정리 — 547 -> 22

`lua/` · `snatcher_tool/mesen/` · `SUB/lua/` 의 525 개를 `_archive/lua_20260831/` 로
**원래 경로 그대로** 옮겼다.  지운 것은 없다.  색인은 `lua/README_현행.md`.

> ★ 이름만 보고 옮기면 안 된다.  **dofile 사슬**을 따라가서 정했고, 그 과정에서
> 깨진 것 3 개가 나와 되살렸다.
>
> ```
> 0.4.93-hq-key-vram -> 0.4.89-vdc-rearm -> 0.4.48-fragment-wipe
> 0.4.94-hq-key-vram-cdda -> CD-DA/CDDA_SUBTITLE_POC_0.1.3
> ```
>
> 그냥 옮겼으면 START_HERE 가 지정한 동작 조합이 로드 실패했을 것이다.

---

## 8. ★ 네이티브 LBA 조회 — 환경 B에서 재빌드 · 실기 재검증

`0.4.6.27` BIOS 가 환경 A에만 있었다.  빌더(`tools/build_snatcher_0_4_7_0_lba_probe.py`,
안에 `VERSION = "0.4.6.27"`)와 입력이 다 있어 재생성했다.

```
build/patch/0.4.6.27/Syscard3_galmuri_0.4.6.27.pce
  디스패처 626 B / 뱅크1 여유 2,957 B · LBA 색인 902 항목 @ AC $1F2800
  관측 슬롯 AC $1F2700 · 훅 $F5F5 · BUILD $1B
```

LBA 색인도 오늘 바뀐 팩 기준으로 다시 만들었다 (**902/902 키 일치**).

### 실기 결과 — PASS (2026-08-31, 소유자 확인)

```
#1  $0A0000  11단계  miss  BUILD $1B   정답 (표 최대보다 큼)
#2  $003057   9단계  miss  BUILD $1B   정답 (표 최소보다 작음 = 자막 없는 음성)
#3  $00306B   9단계  OK
#4  $003078  10단계  OK
#5  $003083   8단계  OK
표 무결성  다섯 번 다 살아있음
```

환경 A에서 나온 결과와 **완전히 같다.**  팩을 갈아엎고 색인을 다시 만들었는데도 같은
답이 나왔으므로 **재생성 경로가 검증됐다.**

### 폐기된 진단 문구를 걷어냈다

`0.5.45` 가 miss 마다 이렇게 찍고 있었다.

```
(X) 동적 %06X 는 표에 있다  -> 비교/분기 논리 문제
(X) 동적 %06X 가 표에 없다  -> mid*9 주소 계산이 틀렸다
```

둘 다 "마지막으로 읽은 항목이 표에 있으면/없으면 이상하다" 는 어림짐작에서 나왔는데
그 전제가 틀렸다 (밤 인계서 §2-3).  이분검색이 경계에서 어느 항목에 내려앉는지는
정답 여부와 무관하다.  **정상 주행에서 매번 거짓 경보가 떠서 진짜 오류와 안 갈린다.**

이제 표 범위 기준으로 찍는다 — `표 최소 %06X 보다 작다` / `표 최대보다 크다` /
`표 범위 안이지만 항목이 없다`.  §5-2 의 양성 건은 그 자리에 `(양성, §5-2)` 로 붙는다.

### 안내문도 낡아 있었다

`TEST_IN_MESEN.txt` 가 `0.5.35` · 슬롯 `$1F2400/$1F2200` 으로 적혀 있었다.  그것은
**자리를 옮기기 전** 값이고, 그대로 물리면 선적재 패딩에 지워지는 옛 자리를 본다.
빌더의 템플릿까지 고쳐서 다시 구워도 안 틀리게 했다.

---

## 9. 다음 작업 — 결합부 (BASELINE §12.7-1)

조회는 **검증이 끝났다.**  남은 것은 그 결과를 실제로 쓰는 단계다.

```
1  ★ 감지기와 결합    조회 결과 -> selector/record 기입 -> state 1
2  탐색 상한 물리기    목표가 표 범위 밖이면 표 끝을 한 칸 넘어 읽는다 (양성)
3  CD-DA 흡수         같은 LBA 판별기로 -> Track 17 고정 해제
```

§9.1 기준으로 1·2 번(키 만들기 · 레코드 찾기)은 끝났고 **3·4·5 번(selector 걸기 ·
조각 전환 · fail-closed)이 남았다.**

### 지금 Lua 가 하는 일 (네이티브가 대신해야 할 것)

`lua/SUB/0.4.93-hq-key-vram.lua`:

```lua
patchEngine(where, base, kind)      -- 엔진 이미지의 즉시값 3 개를 고친다
  off.vram_base_hi_imm     <- base >> 8
  off.pattern_base_lo_imm  <- ((base >> 6) << 1) & 0xFF
  off.pattern_attr_imm     <- 0x80 | (((base >> 13) & 7) << 4) | 0x0F
setHelperBase(base)                 -- AC 헬퍼 control block 에 같은 값
  HELPER_CTL+4 lo · +5 hi · +6 base>>13 · +7 base>>5
```

`base` 는 `vram_key_bases_pairs.lua` 에서 키로 찾는다 — 그 표가 곧 안전 VRAM 자리다.

### ⚠ 결합 전에 알아둘 것

```
· 지금 결합해도 자막이 뜨는 것은 50 개뿐이다 (ADPCM safe 50/902).
  fail-closed 라 나머지는 조회에 성공해도 state 를 안 연다.  정상이다 --
  파이프라인 연결 전이므로.  수집(0.5.26)이 이것을 올린다
· 0.4.6.26 · 0.4.6.27 이 둘 다 "정적 통과 -> 실기 크래시" 였다.  원인은 감지기·
  가드·조회를 **한 번에 넣은 것**이다.  0.4.7.0 이 위험 0 POC 로 조회만 먼저
  증명했다.  결합도 같은 방식으로 쪼갠다
· 조회 경로는 위험 0 으로 확인됐다.  그래서 다음 실패는 **결합부**로 범위가 좁혀진다
```

---

## 10. 환경 A로 들고 갈 것 (환경 B -> 환경 A)

이번에 환경 B에서 만들거나 고친 것들이다.  **환경 A에는 없다.**

```
tools/mark_vram_observed.py                      새 도구
tools/build_cdda_runtime_safe_positions.py       관찰 창고
tools/subtitle_split.py                          cdda_window · trim · track_spans
tools/build_subtitle_pack.py                     트랙 기준 LBA 환산
tools/verify_subtitle_pack.py                    같은 규칙 공유
tools/build_snatcher_0_4_7_0_lba_probe.py        TEST_NOTE 갱신
snatcher_tool/mesen/0.5.26-adpcm-cdda-vram-map-all.lua   새 진입점
snatcher_tool/mesen/VRAM-key-map-0.2.lua         ALL_VOICE_KEYS 키 출처 추가
lua/SUB/0.5.45-fixed-abi.lua                     폐기 진단 문구 제거
snatcher_tool/studio_source/MainForm.cs + exe    트랙 종속 · 관측 칸 · 위치 단추
snatcher_tool/translation/cdda_subtitles.tsv     트랙 종속 649행
snatcher_tool/translation/voice_*.tsv            vram_observed · pos 열
build/cutscene_subs/subtitle_pack*.bin           팩 · LBA 색인 재생성
build/patch/0.4.6.27/                            재빌드 + 실기 PASS
lua/ 전체 재배치                                  22개 + _archive/lua_20260831/
```

---

## 11. 주의 (오늘 새로 밟은 것)

```
· 행 수로 번역 손실을 판정하지 않는다.  jp_text 전문으로 대조한다
· 수집기 필터를 끄지 않는다.  넓힌다 (찢어진 키가 들어온다)
· has_subtitle 을 믿지 않는다.  ambiguous_audio 는 보류지 확정이 아니다
· dump/vram_key_spans_*.tsv 글롭은 spans2_ 를 안 잡는다
· CD-DA 안전위치 도구는 관찰이 0 이면 아무것도 안 한다 (예전엔 덮어썼다)
· LBA 환산·트림은 subtitle_split.py 한 곳.  빌더만 고치면 검증기가 깨진다
· 스튜디오 CD-DA 그리드는 열이 하드코딩.  TSV 만 고치면 안 보인다
· Lua 를 옮길 때는 dofile 사슬을 먼저 따라간다
· 빌더는 같은 VERSION 폴더가 있으면 거부한다 (실기에서 어느 것을 로드했는지
  알 수 없게 되므로).  안내문만 고칠 때는 파일을 직접 쓴다
```
